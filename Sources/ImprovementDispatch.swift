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

struct ImprovementAgentConfiguration: Codable, Equatable {
    var repository: String?
    let runner: String
    let codexProjectID: String?
    let destinationRepository: String?
    init(repository: String? = nil, codexProjectID: String? = nil, destinationRepository: String? = nil) {
        self.repository = repository; self.codexProjectID = codexProjectID; self.destinationRepository = destinationRepository; runner = "codex-desktop"
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
    private(set) var isCreatingProject = false
    private var createdProjects: [UUID:String] = [:]
    var projectInitializer: @MainActor (String) async throws -> URL = {try await ImprovementProjectCreation.create($0)}
    let callbackCommand: String
    var copyPrompt: (String) -> Bool = {value in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value,forType:.string)
    }
    // Only old build-58 receipts need process-liveness reconciliation.
    var alive: (Int32) -> Bool = {kill($0,0) == 0 || errno == EPERM}
    init(store: ImprovementStore, watch: Bool = true, callbackCommand: String? = nil) {
        let executable = Bundle.main.executableURL?.path ?? "/Applications/Window Factory.app/Contents/MacOS/WindowFactory"
        self.callbackCommand = callbackCommand ?? ("'" + executable.replacingOccurrences(of:"'",with:"'\\''") + "' --cli")
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
        guard !isCreatingProject else {throw AgentFailure("project_creation_busy", "Wait for project creation to finish.")}
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
        let value = ImprovementAgentConfiguration(repository:url.path,codexProjectID:binding,destinationRepository:previous.destinationRepository)
        try ImprovementFiles.write(value,to:configurationURL); changed?(); return value
    }
    func configureDestination(_ path: String?) throws -> ImprovementAgentConfiguration {
        guard !isCreatingProject else {throw AgentFailure("project_creation_busy", "Wait for project creation to finish.")}
        let previous = try configuration()
        guard previous.repository != nil else {throw AgentFailure("repository_required", "Choose the app's source project first.")}
        let destination = try path.map {try ImprovementProjectCreation.validateDestination($0).path}
        let value = ImprovementAgentConfiguration(repository:previous.repository,codexProjectID:previous.codexProjectID,destinationRepository:destination)
        try ImprovementFiles.write(value,to:configurationURL); changed?(); return value
    }
    func createProject(_ path: String, operationID: UUID = UUID()) async throws -> ImprovementAgentConfiguration {
        let canonical = ImprovementProjectCreation.newDestinationURL(path).path
        if let previous = createdProjects[operationID] {
            guard previous == canonical else {throw AgentFailure("request_conflict", "This creation ID has another destination.")}
            return try configuration()
        }
        guard !isCreatingProject else {throw AgentFailure("project_creation_busy", "Wait for project creation to finish.")}
        guard try configuration().repository != nil else {throw AgentFailure("repository_required", "Choose the app's source project first.")}
        isCreatingProject = true; changed?()
        do {
            let url = try await projectInitializer(canonical)
            isCreatingProject = false
            let value = try configureDestination(url.path)
            createdProjects[operationID] = url.path
            return value
        } catch {
            isCreatingProject = false; changed?(); throw error
        }
    }
    @discardableResult
    func prepareRequest(_ id: UUID, operationID: UUID = UUID()) throws -> Improvement {
        guard !isCreatingProject else {throw AgentFailure("project_creation_busy", "Wait for project creation to finish before preparing the request.")}
        try reconcile()
        let original = try store.get(id)
        guard !(original.handoffs?.contains(where:{$0.threadID != nil}) ?? false) else {
            throw AgentFailure("chat_already_linked", "Open the existing chat to continue this request.")
        }
        let config = try configuration()
        guard let originPath = config.repository else {throw AgentFailure("repository_required", "Choose the app's source project first.")}
        let origin = try ImprovementRepository.validate(originPath)
        let destination = try ImprovementProjectCreation.validateDestination(config.destinationRepository ?? origin.path)
        guard !(try store.all()).contains(where:{$0.runs?.contains(where:{$0.active}) == true}) else {
            throw AgentFailure("agent_busy", "A previous run is active; finish it before preparing another request.")
        }
        let handoff = try store.prepareHandoff(id,handoffID:operationID,repository:destination.path,manual:true,originRepository:origin.path)
        let application = ImprovementApplication(name:"Window Factory",callbackCommand:callbackCommand)
        let prompt = try ImprovementHandoffLink.prompt(request:original,handoff:handoff,application:application)
        guard copyPrompt(prompt) else {throw AgentFailure("clipboard_unavailable", "The request is saved, but copying failed. Try preparing it again.")}
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
        _ = try prepareRequest(id,operationID:operationID)
        let url = ImprovementHandoffLink.manualComposerURL()
        lastPreparedRoute = ImprovementRouteDiagnostic(url:url,appBuild:store.build)
        guard openURL(url) else {
            throw AgentFailure("codex_open_failed", "Request copied. Open Codex manually, select or create the destination project, start a new chat, paste and send.")
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
    func handle(_ request: AgentRequest) async throws -> AgentToolResult {
        switch request.command {
        case .improvementAgent:
            var config = try request.repository.map {try configure(repository:$0,codexProjectID:request.codexProjectID)} ?? configuration()
            if let destination = request.destinationRepository {config = try configureDestination(destination == "app" ? nil : destination)}
            return AgentToolResult(improvementAgent:config)
        case .improvementPrepare:
            return AgentToolResult(improvement:try prepareRequest(request.improvementID!,operationID:request.id))
        case .improvementCreateProject:
            return AgentToolResult(improvementAgent:try await createProject(request.destinationRepository!,operationID:request.id))
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
