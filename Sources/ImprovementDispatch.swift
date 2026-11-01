import AppKit
import Darwin

struct ImprovementRun: Codable, Equatable {
    let id: UUID, startedAt: Date, repository: String, revision: Int
    var phase = "launching"
    var finishedAt: Date?, sessionID: String?
    var active: Bool { finishedAt == nil }
}
struct ImprovementAgentConfiguration: Codable {
    var repository: String?
    let runner: String
    init(repository: String? = nil) {self.repository = repository; runner = "codex-ai"}
}
struct ImprovementWorkerSpecification: Codable {
    let runID: UUID, requestID: UUID, repository: String, baselineCommit: String
    let text: String, context: String, sourceBuild: String
}
struct ImprovementAgentResult: Codable {
    let state: ImprovementState, note: String, targetBuild: Int?
    func validate() throws {
        guard [.implemented,.needsInput,.declined].contains(state) else {
            throw AgentFailure("invalid_agent_result", "Agent must report implemented, needs-input or declined.")
        }
        try ImprovementStore.validateUpdate(state:state,note:note,targetBuild:targetBuild)
    }
}
struct ImprovementWorkerReceipt: Codable {
    let finishedAt: Date, succeeded: Bool, result: ImprovementAgentResult, sessionID: String?
    static func failure(_ note: String) -> Self {
        Self(finishedAt:Date(),succeeded:false,result:ImprovementAgentResult(state:.needsInput,note:note,targetBuild:nil),sessionID:nil)
    }
}
struct ImprovementWorkerStarted: Codable {let workerPID: Int32, agentPID: Int32, date: Date}

enum ImprovementFiles {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try encoder.encode(value).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type,from:Data(contentsOf:url))
    }
    static func privateFile(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else {
            throw AgentFailure("agent_storage_failed", "Could not create private agent output.")
        }
        return try FileHandle(forWritingTo:url)
    }
}

// Fixed commands only; all user content travels as data, never shell source.
enum ImprovementRepository {
    static let fish = "/opt/homebrew/bin/fish"
    static func validate(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
        for relative in [".git","AGENTS.md","Sources/Main.swift","docs/improvements.md"] {
            guard FileManager.default.fileExists(atPath:url.appendingPathComponent(relative).path) else {
                throw AgentFailure("invalid_repository", "Choose the Window Factory source repository, containing AGENTS.md and docs/improvements.md.")
            }
        }
        return url
    }
    static func git(_ args: [String], at repository: URL, environment: [String:String]? = nil) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/machine-agent-git")
        process.arguments = args
        if let environment {process.environment = environment}
        process.currentDirectoryURL = repository; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {throw AgentFailure("repository_check_failed", "Machine Agent Git could not verify the selected repository.")}
        return String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func preflight(_ path: String) throws -> (URL,String) {
        let repository = try validate(path)
        guard try git(["status","--porcelain"],at:repository).isEmpty else {
            throw AgentFailure("repository_dirty", "The repository has uncommitted work. Finish that work before starting an improvement agent; your request remains saved.")
        }
        return (repository,try git(["rev-parse","HEAD"],at:repository))
    }
}

@MainActor
final class ImprovementDispatcher {
    let store: ImprovementStore
    let directory: URL
    var changed: (() -> Void)?
    private var timer: Timer?
    // Injectable launch/probe seams keep tests independent of models and live repositories.
    var preflight: (String) throws -> (URL,String) = ImprovementRepository.preflight
    var launch: (URL) throws -> Void = { directory in
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--improvement-worker",directory.path]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    var alive: (Int32) -> Bool = {kill($0,0) == 0 || errno == EPERM}
    init(store: ImprovementStore, watch: Bool = true) {
        self.store = store; directory = store.url.deletingLastPathComponent().appendingPathComponent("improvement-runs")
        if watch {
            timer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
                MainActor.assumeIsolated {try? self?.reconcile()}
            }
        }
    }
    var configurationURL: URL {store.url.deletingLastPathComponent().appendingPathComponent("improvement-agent.json")}
    func configuration() throws -> ImprovementAgentConfiguration {
        guard FileManager.default.fileExists(atPath:configurationURL.path) else {return ImprovementAgentConfiguration()}
        let value = try ImprovementFiles.read(ImprovementAgentConfiguration.self,from:configurationURL)
        guard value.runner == "codex-ai" else {throw AgentFailure("unsupported_runner", "This build supports the explicitly selected codex-ai subscription runner only.")}
        return value
    }
    func configure(repository: String) throws -> ImprovementAgentConfiguration {
        let url = try ImprovementRepository.validate(repository)
        let value = ImprovementAgentConfiguration(repository:url.path)
        try ImprovementFiles.write(value,to:configurationURL); changed?(); return value
    }
    @discardableResult
    func dispatch(_ id: UUID, operationID: UUID = UUID()) throws -> Improvement {
        try reconcile()
        let original = try store.get(id)
        if let previous = try store.all().first(where:{$0.runs?.contains(where:{$0.id == operationID}) == true}) {
            guard previous.id == id else {throw AgentFailure("request_conflict", "This dispatch ID already belongs to another request.")}
            return original
        }
        guard let path = try configuration().repository else {
            throw AgentFailure("repository_required", "Choose the Window Factory repository before sending to an agent.")
        }
        guard ![.implemented,.declined].contains(original.state) else {
            throw AgentFailure("request_finished", "This request already has an outcome. Save a new request for further changes.")
        }
        guard !(try store.all()).contains(where:{$0.runs?.contains(where:{$0.active}) == true}) else {
            throw AgentFailure("agent_busy", "An improvement agent is already active. Your request remains saved.")
        }
        let (repository,commit) = try preflight(path)
        let run = ImprovementRun(id:operationID,startedAt:Date(),repository:repository.path,revision:original.revision)
        let runDirectory = directory.appendingPathComponent(run.id.uuidString)
        let specification = ImprovementWorkerSpecification(runID:run.id,requestID:id,repository:repository.path,baselineCommit:commit,text:original.text,context:original.context,sourceBuild:original.build)
        try ImprovementFiles.write(specification,to:runDirectory.appendingPathComponent("input.json"))
        _ = try store.beginRun(id,run:run)
        do {try launch(runDirectory)} catch {
            let receipt = ImprovementWorkerReceipt.failure("Agent could not start. The request is saved; resolve the launch problem and send it again. \(error.localizedDescription)")
            try ImprovementFiles.write(receipt,to:runDirectory.appendingPathComponent("receipt.json"))
            try store.finishRun(id,runID:run.id,receipt:receipt)
            throw AgentFailure("agent_launch_failed", receipt.result.note)
        }
        changed?(); return try store.get(id)
    }
    func reconcile(now: Date = Date()) throws {
        for request in try store.all() {
            for run in request.runs ?? [] where run.active {
                let root = directory.appendingPathComponent(run.id.uuidString), receiptURL = root.appendingPathComponent("receipt.json")
                if FileManager.default.fileExists(atPath:receiptURL.path) {
                    let receipt: ImprovementWorkerReceipt
                    do {
                        let value = try ImprovementFiles.read(ImprovementWorkerReceipt.self,from:receiptURL)
                        try value.result.validate(); receipt = value
                    } catch {
                        receipt = .failure("The agent outcome could not be read or validated. Original run files were retained; inspect the repository before retrying.")
                    }
                    try store.finishRun(request.id,runID:run.id,receipt:receipt)
                } else {
                    let startedURL = root.appendingPathComponent("started.json")
                    if FileManager.default.fileExists(atPath:startedURL.path) {
                        let started = try ImprovementFiles.read(ImprovementWorkerStarted.self,from:startedURL)
                        if alive(started.workerPID) {
                            try store.markRunStarted(request.id,runID:run.id,sessionID:ImprovementWorker.sessionID(root.appendingPathComponent("events.jsonl")))
                            continue
                        }
                    } else if now.timeIntervalSince(run.startedAt) < 30 {continue}
                    // Never retry automatically: a stopped worker may already have changed files.
                    let receipt = ImprovementWorkerReceipt.failure("The agent stopped before returning a result. Inspect the repository and this run's logs before retrying; partial changes may remain.")
                    try ImprovementFiles.write(receipt,to:receiptURL)
                    try store.finishRun(request.id,runID:run.id,receipt:receipt)
                }
            }
        }
    }
    func handle(_ request: AgentRequest) throws -> AgentToolResult {
        switch request.command {
        case .improvementAgent:
            let config = try request.repository.map {try configure(repository:$0)} ?? configuration()
            return AgentToolResult(improvementAgent:config)
        case .improvementDispatch:
            return AgentToolResult(improvement:try dispatch(request.improvementID!,operationID:request.id))
        default:
            try reconcile(); return try store.handle(request)
        }
    }
    func stop() {timer?.invalidate(); timer = nil}
}
