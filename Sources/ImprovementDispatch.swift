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
    var desktopDestination: CodexDestination?
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
    var desktopReady: (CodexDestination) async throws -> Void = {try await CodexDesktop().checkReady($0)}
    var desktopCreate: (String,String,UUID) async throws -> CodexProject = {try await CodexDesktop().createProject(name:$0,repository:$1,operationID:$2)}
    var desktopNewChat: (String,String) async throws -> CodexChat = {try await CodexDesktop().createChat(projectID:$0,repository:$1)}
    var desktopProjects: () async throws -> [CodexProject] = {try await CodexDesktop().projects()}
    var desktopChats: (String) async throws -> [CodexChat] = {try await CodexDesktop().chats(projectID:$0)}
    var desktopSelect: (String,String,Bool) async throws -> CodexDestination = {try await CodexDesktop().select(projectID:$0,chatID:$1,assignUnfiledChat:$2)}
    var desktopTransmit: (String,CodexDestination,UUID) async throws -> CodexSendReceipt = {try await CodexDesktop().send($0,to:$1,messageID:$2)}
    private var timer: Timer?
    private(set) var isCreatingProject = false
    private var createdProjects: [UUID:(path:String,select:Bool)] = [:]
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
        var value = ImprovementAgentConfiguration(repository:url.path,codexProjectID:binding,destinationRepository:previous.destinationRepository)
        if previous.repository == url.path {value.desktopDestination=previous.desktopDestination}
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
    func createProject(_ path: String, operationID: UUID = UUID(), selectAsDestination:Bool = true) async throws -> ImprovementAgentConfiguration {
        let canonical = ImprovementProjectCreation.newDestinationURL(path).path
        if let previous = createdProjects[operationID] {
            guard previous.path == canonical,previous.select == selectAsDestination else {throw AgentFailure("request_conflict", "This creation ID has another destination.")}
            return try configuration()
        }
        guard !isCreatingProject else {throw AgentFailure("project_creation_busy", "Wait for project creation to finish.")}
        guard try configuration().repository != nil else {throw AgentFailure("repository_required", "Choose the app's source project first.")}
        isCreatingProject = true; changed?()
        do {
            let url = try await projectInitializer(canonical)
            isCreatingProject = false
            let value = try selectAsDestination ? configureDestination(url.path) : configuration()
            createdProjects[operationID] = (url.path,selectAsDestination)
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
    func connectDesktop(projectID:String,chatID:String,assignUnfiled:Bool) async throws -> CodexDestination {
        guard !isCreatingProject else {throw AgentFailure("project_creation_busy","Wait for project creation to finish.")}
        let before=try configuration()
        guard before.repository != nil else {throw AgentFailure("repository_required","Choose the app's source repository first.")}
        let selected=try await desktopSelect(projectID,chatID,assignUnfiled)
        guard try configuration() == before else {throw AgentFailure("request_conflict","Connection settings changed during verification. Run setup again.")}
        var config=before;config.desktopDestination=selected
        try ImprovementFiles.write(config,to:configurationURL);changed?();return selected
    }
    private struct ChatCreation: Codable {
        let projectID:String, repository:String
        var chat:CodexChat?
    }
    func createDesktopChat(projectID:String,repository:String,operationID:UUID) async throws -> CodexChat {
        let url=store.url.deletingLastPathComponent().appendingPathComponent("improvement-codex-operations").appendingPathComponent(operationID.uuidString+".json")
        if FileManager.default.fileExists(atPath:url.path) {
            let previous=try ImprovementFiles.read(ChatCreation.self,from:url)
            guard previous.projectID==projectID,previous.repository==repository else {throw AgentFailure("request_conflict","This creation ID has another destination.")}
            guard let chat=previous.chat else {throw AgentFailure("codex_creation_unconfirmed","An earlier chat creation did not return a receipt. Inspect Codex before creating another chat.")}
            // A provider receipt can outlive a nonpersistent empty chat. Verify
            // the actual record on retry instead of repeating cached success.
            let checked=try await desktopSelect(projectID,chat.id,false)
            guard checked.repository==repository else {throw AgentFailure("codex_destination_mismatch","The previously created chat has another repository.")}
            return chat
        }
        try ImprovementFiles.write(ChatCreation(projectID:projectID,repository:repository,chat:nil),to:url)
        do {
            let chat=try await desktopNewChat(projectID,repository)
            try ImprovementFiles.write(ChatCreation(projectID:projectID,repository:repository,chat:chat),to:url)
            return chat
        } catch let error as ImprovementFailure where error.code=="codex_creation_unavailable" {
            // This provider gate runs before any external side effect. Preserve
            // uncertainty for other failures, but don't invent it for this one.
            try FileManager.default.removeItem(at:url)
            throw error
        }
    }
    func disconnectDesktop() throws {
        var config=try configuration();config.desktopDestination=nil
        try ImprovementFiles.write(config,to:configurationURL);changed?()
    }
    func sendDirect(_ id:UUID,operationID:UUID=UUID()) async throws -> CodexSendReceipt {
        guard !isCreatingProject else {throw AgentFailure("project_creation_busy","Wait for project creation to finish.")}
        let config=try configuration()
        guard let origin=config.repository,let destination=config.desktopDestination else {throw AgentFailure("codex_setup_required","Set up the Codex connection and choose a project/chat first.")}
        _ = try ImprovementRepository.validate(origin)
        try reconcile()
        guard !(try store.all()).contains(where:{$0.runs?.contains(where:{$0.active}) == true}) else {throw AgentFailure("agent_busy","A legacy run is active.")}
        func checkOtherWork() throws {
            let busy=try store.all(includeRemoved:true).contains {record in
                let sameChat=record.delivery?.destination.chatID == destination.chatID || record.handoffs?.contains(where:{$0.threadID == UUID(uuidString:destination.chatID)}) == true
                return record.id != id && sameChat && (record.state == .working || ["submitting","unconfirmed"].contains(record.delivery?.phase ?? ""))
            }
            guard !busy else {throw AgentFailure("codex_chat_busy","Another improvement is still in progress or unconfirmed in this chat. Resolve it before sending another request there.")}
        }
        try checkOtherWork()
        // Opening an exact existing chat loads its actual desktop writer; it carries
        // no prompt/project payload and never creates a composer or sends keystrokes.
        guard let chatID=UUID(uuidString:destination.chatID),openURL(ImprovementHandoffLink.chatURL(chatID)) else {throw AgentFailure("codex_open_failed","Could not open the chosen chat. Nothing was sent.")}
        try await Task.sleep(for:.milliseconds(300))
        try await desktopReady(destination) // Before the durable send-attempt marker.
        try checkOtherWork() // Recheck after suspension; another send may have started.
        let receipt=try await ImprovementDeliveryCoordinator.send(requestID:id,operationID:operationID,destination:destination,originRepository:origin,store:store,application:ImprovementApplication(name:"Window Factory",callbackCommand:callbackCommand),transmit:desktopTransmit)
        changed?();return receipt
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
        guard let threadID = value.handoffs?.last(where:{$0.threadID != nil})?.threadID ?? value.delivery.flatMap({UUID(uuidString:$0.destination.chatID)}) else {
            throw AgentFailure("chat_not_linked", "No chat has linked back yet. Press Send in the prepared Codex chat first.")
        }
        guard openURL(ImprovementHandoffLink.chatURL(threadID)) else {throw AgentFailure("codex_open_failed", "Codex could not open the linked chat.")}
    }
    func handle(_ request: AgentRequest) async throws -> AgentToolResult {
        switch request.command {
        case .improvementCodexCreateProject:
            return AgentToolResult(codexProject:try await desktopCreate(request.name!,request.repository!,request.id))
        case .improvementCodexNewChat:
            return AgentToolResult(codexChat:try await createDesktopChat(projectID:request.codexProjectID!,repository:request.repository!,operationID:request.id))
        case .improvementCodexProjects:
            return AgentToolResult(codexProjects:try await desktopProjects())
        case .improvementCodexChats:
            return AgentToolResult(codexChats:try await desktopChats(request.codexProjectID!))
        case .improvementConnect:
            return AgentToolResult(codexDestination:try await connectDesktop(projectID:request.codexProjectID!,chatID:request.threadID!.uuidString.lowercased(),assignUnfiled:request.confirm == true))
        case .improvementDisconnect:
            try disconnectDesktop();return AgentToolResult(improvementAgent:try configuration())
        case .improvementSend:
            let receipt=try await sendDirect(request.improvementID!,operationID:request.id)
            return AgentToolResult(codexReceipt:receipt,improvement:try store.get(request.improvementID!))
        case .improvementRemove:
            try store.removeFromList(request.improvementID!);return AgentToolResult(improvement:try store.get(request.improvementID!))
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
