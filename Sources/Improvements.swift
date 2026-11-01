import Foundation

enum ImprovementState: String, Codable, CaseIterable {
    case queued, working, needsInput = "needs-input", implemented, declined
    var title: String {
        switch self {
        case .queued: "Queued"
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
    var state: ImprovementState { updates.last?.state ?? .queued }
    var revision: Int { updates.count }
    func status(runningBuild: Int?) -> String {
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
