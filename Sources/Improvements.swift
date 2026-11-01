import Foundation

enum ImprovementState: String, Codable, CaseIterable {
    case queued, working, needsInput = "needs-input", implemented, declined
    var title: String {
        switch self {
        case .queued: "Saved for later"
        case .working: "In progress"
        case .needsInput: "Needs your input"
        case .implemented: "Implemented; awaiting build"
        case .declined: "Not proceeding"
        }
    }
}
struct ImprovementUpdate: Codable, Equatable {
    let id: UUID
    let date: Date
    let state: ImprovementState
    let note: String
    let targetBuild: Int?
}
struct Improvement: Codable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let text: String
    let context: String
    let version: String
    let build: String
    let source: String
    var updates: [ImprovementUpdate] = []
    var runs: [ImprovementRun]? = nil
    var state: ImprovementState { updates.last?.state ?? .queued }
    var revision: Int { updates.count }
    func status(runningBuild: Int?) -> String {
        if let run = runs?.last, run.active {return run.phase == "launching" ? "Starting agent…" : "Agent running"}
        guard state == .implemented else { return state.title }
        if let target = updates.last?.targetBuild, let runningBuild, runningBuild >= target {
            return "Available in this build"
        }
        return "Implemented; awaiting build \(updates.last?.targetBuild.map(String.init) ?? "unknown")"
    }
}
struct ImprovementSummary: Codable {
    let id: UUID, createdAt: Date
    let excerpt: String, state: ImprovementState, revision: Int, status: String
}
private struct ImprovementCatalog: Codable {
    var schemaVersion = 1
    var requests: [Improvement] = []
}

// One writer: the running app, on its main actor. CLI and UI share this owner.
// Reload before every operation; a corrupt/unsupported file is never overwritten.
@MainActor
final class ImprovementStore {
    let url: URL
    let version: String, build: String
    var changed: (() -> Void)?
    init(url: URL, version: String, build: String) {
        self.url = url; self.version = version; self.build = build
    }
    nonisolated static func validateText(_ text: String, context: String) throws {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 8000, context.utf8.count <= 1000 else {
            throw AgentFailure("invalid_improvement", "Enter a request up to 8,000 UTF-8 bytes and context up to 1,000 bytes.")
        }
    }
    nonisolated static func validateUpdate(state: ImprovementState, note: String, targetBuild: Int?) throws {
        guard !note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, note.utf8.count <= 8000,
              (state == .implemented) == (targetBuild != nil), targetBuild.map({$0 > 0}) ?? true else {
            throw AgentFailure("invalid_improvement", "Include an outcome up to 8,000 bytes; implemented requires a positive target build, other states omit it.")
        }
    }
    private func load() throws -> ImprovementCatalog {
        guard FileManager.default.fileExists(atPath:url.path) else { return ImprovementCatalog() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(ImprovementCatalog.self, from:Data(contentsOf:url))
        guard catalog.schemaVersion == 1, Set(catalog.requests.map(\.id)).count == catalog.requests.count else {
            throw AgentFailure("improvements_unreadable", "Unsupported or duplicate improvement records; the file was preserved.")
        }
        return catalog
    }
    private func save(_ catalog: ImprovementCatalog) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(), withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        // Foundation's atomic replacement preserves the private temporary file's mode.
        try data.write(to:url, options:[.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:url.path)
        changed?()
    }
    func all() throws -> [Improvement] { try load().requests }
    func get(_ id: UUID) throws -> Improvement {
        guard let value = try all().first(where:{$0.id == id}) else {
            throw AgentFailure("improvement_not_found", "No improvement has that ID.")
        }
        return value
    }
    @discardableResult
    func submit(id: UUID = UUID(), text: String, context: String, source: String) throws -> Improvement {
        try Self.validateText(text, context:context)
        var catalog = try load()
        if let existing = catalog.requests.first(where:{$0.id == id}) {
            guard existing.text == text, existing.context == context, existing.source == source else {
                throw AgentFailure("request_conflict", "This request ID already has different content.")
            }
            return existing
        }
        let value = Improvement(id:id, createdAt:Date(), text:text, context:context, version:version, build:build, source:source)
        catalog.requests.append(value); try save(catalog); return value
    }
    @discardableResult
    func update(_ id: UUID, operationID: UUID, revision: Int, state: ImprovementState, note: String, targetBuild: Int?) throws -> Improvement {
        try Self.validateUpdate(state:state, note:note, targetBuild:targetBuild)
        var catalog = try load()
        guard let index = catalog.requests.firstIndex(where:{$0.id == id}) else {
            throw AgentFailure("improvement_not_found", "No improvement has that ID.")
        }
        if let previous = catalog.requests[index].updates.firstIndex(where:{$0.id == operationID}) {
            let value = catalog.requests[index].updates[previous]
            guard previous == revision, value.state == state, value.note == note, value.targetBuild == targetBuild else {
                throw AgentFailure("request_conflict", "This update ID already has different content.")
            }
            return catalog.requests[index]
        }
        guard catalog.requests[index].revision == revision else {
            throw AgentFailure("revision_conflict", "The request changed; read its current revision before updating.")
        }
        catalog.requests[index].updates.append(ImprovementUpdate(id:operationID, date:Date(), state:state, note:note, targetBuild:targetBuild))
        try save(catalog); return catalog.requests[index]
    }
    func beginRun(_ id: UUID, run: ImprovementRun) throws -> Improvement {
        var catalog = try load()
        guard let index = catalog.requests.firstIndex(where:{$0.id == id}) else {throw AgentFailure("improvement_not_found", "No improvement has that ID.")}
        guard !catalog.requests.contains(where:{$0.runs?.contains(where:{$0.active}) == true}) else {
            throw AgentFailure("agent_busy", "An improvement agent is already active. Wait for its result before sending another request.")
        }
        catalog.requests[index].runs = (catalog.requests[index].runs ?? []) + [run]
        catalog.requests[index].updates.append(ImprovementUpdate(id:UUID(),date:Date(),state:.working,note:"Launching Codex subscription agent in the selected repository.",targetBuild:nil))
        try save(catalog); return catalog.requests[index]
    }
    func markRunStarted(_ requestID: UUID, runID: UUID, sessionID: String?) throws {
        var catalog = try load()
        guard let index = catalog.requests.firstIndex(where:{$0.id == requestID}),
              let runIndex = catalog.requests[index].runs?.firstIndex(where:{$0.id == runID}),
              catalog.requests[index].runs?[runIndex].active == true else {return}
        if catalog.requests[index].runs?[runIndex].phase == "running",
           catalog.requests[index].runs?[runIndex].sessionID == sessionID {return}
        catalog.requests[index].runs![runIndex].phase = "running"
        catalog.requests[index].runs![runIndex].sessionID = sessionID
        try save(catalog)
    }
    func finishRun(_ requestID: UUID, runID: UUID, receipt: ImprovementWorkerReceipt) throws {
        var catalog = try load()
        guard let index = catalog.requests.firstIndex(where:{$0.id == requestID}),
              let runIndex = catalog.requests[index].runs?.firstIndex(where:{$0.id == runID}),
              catalog.requests[index].runs?[runIndex].active == true else {return}
        let startRevision = catalog.requests[index].runs![runIndex].revision
        catalog.requests[index].runs![runIndex].finishedAt = receipt.finishedAt
        catalog.requests[index].runs![runIndex].sessionID = receipt.sessionID
        catalog.requests[index].runs![runIndex].phase = receipt.succeeded ? "finished" : "failed"
        let changedMeanwhile = catalog.requests[index].revision != startRevision + 1
        let state = changedMeanwhile ? catalog.requests[index].state : receipt.result.state
        let target = changedMeanwhile ? catalog.requests[index].updates.last?.targetBuild : receipt.result.targetBuild
        let note = (changedMeanwhile ? "Agent finished after the request was updated; current status retained.\n" : "") + receipt.result.note
        catalog.requests[index].updates.append(ImprovementUpdate(id:UUID(),date:receipt.finishedAt,state:state,note:note,targetBuild:target))
        try save(catalog)
    }
    func handle(_ request: AgentRequest) throws -> AgentToolResult {
        switch request.command {
        case .improvements:
            if let id = request.improvementID { return AgentToolResult(improvement:try get(id)) }
            let values = try all(), offset = request.offset ?? 0
            let summaries = values.dropFirst(offset).prefix(100).map {
                ImprovementSummary(id:$0.id, createdAt:$0.createdAt, excerpt:String($0.text.prefix(160)), state:$0.state, revision:$0.revision, status:$0.status(runningBuild:Int(build)))
            }
            return AgentToolResult(improvements:summaries, improvementCount:values.count)
        case .improvementSubmit:
            return AgentToolResult(improvement:try submit(id:request.id, text:request.text!, context:request.context ?? "", source:"cli"))
        case .improvementUpdate:
            return AgentToolResult(improvement:try update(request.improvementID!, operationID:request.id, revision:request.revision!, state:ImprovementState(rawValue:request.state!)!, note:request.note!, targetBuild:request.targetBuild))
        default: throw AgentFailure("invalid_command", "Not an improvement command.")
        }
    }
}
