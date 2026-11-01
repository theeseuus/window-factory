import AppKit
import Darwin
import CryptoKit

// Reports the actual generated route without exposing the request/prompt text.
struct ImprovementRouteDiagnostic: Codable, Equatable {
    let appBuild: String, mode: String?, projectID: String?, repository: String?
    let queryOrder: [String], urlSHA256: String
    let encodedBytes: Int
    init(url: URL, appBuild: String) {
        let items = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
        self.appBuild = appBuild
        mode = items.first(where:{$0.name == "mode"})?.value
        projectID = items.first(where:{$0.name == "projectId"})?.value
        repository = items.first(where:{$0.name == "path"})?.value
        queryOrder = items.map(\.name)
        let data = Data(url.absoluteString.utf8)
        encodedBytes = data.count
        urlSHA256 = SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
    }
}

struct ImprovementAgentConfiguration: Codable {
    var repository: String?
    let runner: String
    let codexProjectID: String?
    init(repository: String? = nil, codexProjectID: String? = nil) {
        self.repository = repository; self.codexProjectID = codexProjectID; runner = "codex-desktop"
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
}

// Validate the owner-selected source checkout before constructing a desktop handoff.
enum ImprovementRepository {
    static func validate(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
        for relative in [".git","AGENTS.md","Sources/Main.swift","docs/improvements.md"] {
            guard FileManager.default.fileExists(atPath:url.appendingPathComponent(relative).path) else {
                throw AgentFailure("invalid_repository", "Choose the Window Factory source repository, containing AGENTS.md and docs/improvements.md.")
            }
        }
        return url
    }
}

@MainActor
final class ImprovementDispatcher {
    let store: ImprovementStore
    let directory: URL
    var changed: (() -> Void)?
    private var timer: Timer?
    // Only old build-58 receipts need process-liveness reconciliation.
    var alive: (Int32) -> Bool = {kill($0,0) == 0 || errno == EPERM}
    init(store: ImprovementStore, watch: Bool = true) {
        self.store = store; directory = store.url.deletingLastPathComponent().appendingPathComponent("improvement-runs")
        if watch, (try? store.all().contains(where:{$0.runs?.contains(where:{$0.active}) == true})) == true {
            timer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
                MainActor.assumeIsolated {try? self?.reconcile()}
            }
        }
    }
    var configurationURL: URL {store.url.deletingLastPathComponent().appendingPathComponent("improvement-agent.json")}
    func configuration() throws -> ImprovementAgentConfiguration {
        guard FileManager.default.fileExists(atPath:configurationURL.path) else {return ImprovementAgentConfiguration()}
        let value = try ImprovementFiles.read(ImprovementAgentConfiguration.self,from:configurationURL)
        guard ["codex-ai","codex-desktop"].contains(value.runner) else {throw AgentFailure("unsupported_runner", "Select the Codex desktop handoff for this build.")}
        return value
    }
    func configure(repository: String, codexProjectID: String? = nil) throws -> ImprovementAgentConfiguration {
        let url = try ImprovementRepository.validate(repository)
        if let codexProjectID {
            guard !codexProjectID.isEmpty, codexProjectID.utf8.count <= 256,
                  !codexProjectID.unicodeScalars.contains(where:CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains) else {
                throw AgentFailure("invalid_codex_project", "Supply the verified saved Codex project ID.")
            }
        }
        let previous = try configuration()
        // Repository changes invalidate the old binding; selecting the same repo preserves it.
        let binding = codexProjectID ?? (previous.repository == url.path ? previous.codexProjectID : nil)
        let value = ImprovementAgentConfiguration(repository:url.path,codexProjectID:binding)
        try ImprovementFiles.write(value,to:configurationURL); changed?(); return value
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
                            try store.markRunStarted(request.id,runID:run.id,sessionID:ImprovementRunLog.sessionID(root.appendingPathComponent("events.jsonl")))
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
    private(set) var lastPreparedRoute: ImprovementRouteDiagnostic?
    var openURL: (URL) -> Bool = {NSWorkspace.shared.open($0)}
    @discardableResult
    func openRequest(_ id: UUID, operationID: UUID = UUID()) throws -> Improvement {
        lastPreparedRoute = nil
        try reconcile()
        let original = try store.get(id)
        if let chat = original.handoffs?.last(where:{$0.threadID != nil}), let threadID = chat.threadID {
            guard openURL(ImprovementHandoffLink.chatURL(threadID)) else {throw AgentFailure("codex_open_failed", "Could not open the linked Codex chat. The request is preserved.")}
            return original
        }
        let config = try configuration()
        guard let path = config.repository else {throw AgentFailure("repository_required", "Choose the Window Factory repository before opening Codex.")}
        let repo = try ImprovementRepository.validate(path)
        guard let projectID = config.codexProjectID else {
            throw AgentFailure("codex_project_required", "The Codex project is not linked. Complete project setup before sending; your request is saved.")
        }
        guard !(try store.all()).contains(where:{$0.runs?.contains(where:{$0.active}) == true}) else {
            throw AgentFailure("agent_busy", "A previous background run is still active. Finish it before opening a new request.")
        }
        let handoff = try store.prepareHandoff(id,handoffID:operationID,repository:repo.path)
        let url = try ImprovementHandoffLink.newChatURL(request:original,handoff:handoff,projectID:projectID)
        lastPreparedRoute = ImprovementRouteDiagnostic(url:url,appBuild:store.build)
        guard openURL(url) else {
            try store.failHandoff(id,handoffID:handoff.id)
            throw AgentFailure("codex_open_failed", "Could not open Codex. Your request is saved; no model was started.")
        }
        changed?(); return try store.get(id)
    }
    func openChat(_ id: UUID) throws {
        let value = try store.get(id)
        guard let threadID = value.handoffs?.last(where:{$0.threadID != nil})?.threadID else {
            throw AgentFailure("chat_not_linked", "No chat has linked back yet. Press Send in the prepared Codex chat first.")
        }
        guard openURL(ImprovementHandoffLink.chatURL(threadID)) else {throw AgentFailure("codex_open_failed", "Codex could not open the linked chat.")}
    }
    func handle(_ request: AgentRequest) throws -> AgentToolResult {
        switch request.command {
        case .improvementAgent:
            let config = try request.repository.map {try configure(repository:$0,codexProjectID:request.codexProjectID)} ?? configuration()
            return AgentToolResult(improvementAgent:config)
        case .improvementDispatch:
            throw AgentFailure("background_dispatch_disabled", "Use improvement-open for a visible Codex handoff, then press Send in Codex. Background dispatch is no longer offered.")
        case .improvementOpen:
            let value = try openRequest(request.improvementID!,operationID:request.id)
            return AgentToolResult(improvementRoute:lastPreparedRoute,improvement:value)
        case .improvementLink:
            return AgentToolResult(improvement:try store.linkChat(request.improvementID!,handoffID:request.handoffID!,threadID:request.threadID!))
        default:
            try reconcile(); return try store.handle(request)
        }
    }
    func stop() {timer?.invalidate(); timer = nil}
}
