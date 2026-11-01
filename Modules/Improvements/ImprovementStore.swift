import Foundation

public enum ImprovementState: String, Codable, CaseIterable {
    case queued, working, needsInput = "needs-input", implemented, declined
    public var title: String {
        switch self {
        case .queued: "Saved for later"
        case .working: "In progress"
        case .needsInput: "Needs your input"
        case .implemented: "Implemented; awaiting build"
        case .declined: "Not proceeding"
        }
    }
}
public struct ImprovementUpdate: Codable, Equatable {
    public init(id: UUID, date: Date, state: ImprovementState, note: String, targetBuild: Int?) {self.id=id; self.date=date; self.state=state; self.note=note; self.targetBuild=targetBuild}
    public let id: UUID
    public let date: Date
    public let state: ImprovementState
    public let note: String
    public let targetBuild: Int?
}
public struct Improvement: Codable, Equatable, Identifiable {
    public init(id: UUID, createdAt: Date, text: String, context: String, version: String, build: String, source: String) {self.id=id; self.createdAt=createdAt; self.text=text; self.context=context; self.version=version; self.build=build; self.source=source}
    public let id: UUID
    public let createdAt: Date
    public let text: String
    public let context: String
    public let version: String
    public let build: String
    public let source: String
    public var updates: [ImprovementUpdate] = []
    public var runs: [ImprovementRun]? = nil
    public var handoffs: [ImprovementHandoff]? = nil
    public var delivery: ImprovementDelivery? = nil
    public var removedAt: Date? = nil
    public var state: ImprovementState { updates.last?.state ?? .queued }
    public var revision: Int { updates.count }
    public func status(runningBuild: Int?) -> String {
        if delivery?.phase == "prepared" {return "Ready to send to chosen Codex chat"}
        if delivery?.phase == "submitting" {return "Sending to Codex…"}
        if delivery?.phase == "unconfirmed" {return "Send unconfirmed — inspect chat"}
        if let run = runs?.last, run.active {return run.phase == "launching" ? "Starting agent…" : "Agent running"}
        if let handoff = handoffs?.last {
            if handoff.phase == "prepared", handoff.threadID == nil, ![.implemented,.declined].contains(state) {return "Prepared for Codex — paste and send"}
            if handoff.phase == "opened", handoff.threadID == nil, ![.implemented,.declined].contains(state) {return "Ready in Codex — press Send"}
            if handoff.threadID != nil, state == .working {return "In progress · reported by Codex"}
        }
        guard state == .implemented else { return state.title }
        if let handoff = handoffs?.last, let origin = handoff.originRepository, origin != handoff.repository {
            return "Implemented in destination project"
        }
        if let target = updates.last?.targetBuild, let runningBuild, runningBuild >= target {
            return "Available in this build"
        }
        return "Implemented; awaiting build \(updates.last?.targetBuild.map(String.init) ?? "unknown")"
    }
}
public struct ImprovementSummary: Codable {
    public init(id: UUID, createdAt: Date, excerpt: String, state: ImprovementState, revision: Int, status: String) {self.id=id; self.createdAt=createdAt; self.excerpt=excerpt; self.state=state; self.revision=revision; self.status=status}
    public let id: UUID, createdAt: Date
    public let excerpt: String, state: ImprovementState, revision: Int, status: String
}
private struct ImprovementCatalog: Codable {
    public var schemaVersion = 1
    public var requests: [Improvement] = []
}

// One writer: the running app, on its main actor. CLI and UI share this owner.
// Reload before every operation; a corrupt/unsupported file is never overwritten.
@MainActor
public final class ImprovementStore {
    public let url: URL
    public let version: String, build: String
    public var changed: (() -> Void)?
    public init(url: URL, version: String, build: String) {
        self.url = url; self.version = version; self.build = build
    }
    public nonisolated static func validateText(_ text: String, context: String) throws {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 8000, context.utf8.count <= 1000 else {
            throw ImprovementFailure("invalid_improvement", "Enter a request up to 8,000 UTF-8 bytes and context up to 1,000 bytes.")
        }
    }
    public nonisolated static func validateUpdate(state: ImprovementState, note: String, targetBuild: Int?) throws {
        guard !note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, note.utf8.count <= 8000,
              (state == .implemented) == (targetBuild != nil), targetBuild.map({$0 > 0}) ?? true else {
            throw ImprovementFailure("invalid_improvement", "Include an outcome up to 8,000 bytes; implemented requires a positive target build, other states omit it.")
        }
    }
    private func load() throws -> ImprovementCatalog {
        guard FileManager.default.fileExists(atPath:url.path) else { return ImprovementCatalog() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(ImprovementCatalog.self, from:Data(contentsOf:url))
        guard catalog.schemaVersion == 1, Set(catalog.requests.map(\.id)).count == catalog.requests.count else {
            throw ImprovementFailure("improvements_unreadable", "Unsupported or duplicate improvement records; the file was preserved.")
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
    public func all(includeRemoved: Bool = false) throws -> [Improvement] { try load().requests.filter {includeRemoved || $0.removedAt == nil} }
    public func get(_ id: UUID) throws -> Improvement {
        guard let value = try load().requests.first(where:{$0.id == id}) else {
            throw ImprovementFailure("improvement_not_found", "No improvement has that ID.")
        }
        return value
    }
    @discardableResult
    public func submit(id: UUID = UUID(), text: String, context: String, source: String) throws -> Improvement {
        try Self.validateText(text, context:context)
        var catalog = try load()
        if let existing = catalog.requests.first(where:{$0.id == id}) {
            guard existing.text == text, existing.context == context, existing.source == source else {
                throw ImprovementFailure("request_conflict", "This request ID already has different content.")
            }
            return existing
        }
        let value = Improvement(id:id, createdAt:Date(), text:text, context:context, version:version, build:build, source:source)
        catalog.requests.append(value); try save(catalog); return value
    }
    @discardableResult
    public func update(_ id: UUID, operationID: UUID, revision: Int, state: ImprovementState, note: String, targetBuild: Int?) throws -> Improvement {
        try Self.validateUpdate(state:state, note:note, targetBuild:targetBuild)
        var catalog = try load()
        guard let index = catalog.requests.firstIndex(where:{$0.id == id}) else {
            throw ImprovementFailure("improvement_not_found", "No improvement has that ID.")
        }
        if let previous = catalog.requests[index].updates.firstIndex(where:{$0.id == operationID}) {
            let value = catalog.requests[index].updates[previous]
            guard previous == revision, value.state == state, value.note == note, value.targetBuild == targetBuild else {
                throw ImprovementFailure("request_conflict", "This update ID already has different content.")
            }
            return catalog.requests[index]
        }
        guard catalog.requests[index].revision == revision else {
            throw ImprovementFailure("revision_conflict", "The request changed; read its current revision before updating.")
        }
        catalog.requests[index].updates.append(ImprovementUpdate(id:operationID, date:Date(), state:state, note:note, targetBuild:targetBuild))
        try save(catalog); return catalog.requests[index]
    }
    public func prepareHandoff(_ id: UUID, handoffID: UUID, repository: String, manual: Bool = false, originRepository: String? = nil) throws -> ImprovementHandoff {
        var catalog = try load()
        guard let index = catalog.requests.firstIndex(where:{$0.id == id}) else {throw ImprovementFailure("improvement_not_found", "No improvement has that ID.")}
        if let owner = catalog.requests.first(where:{$0.handoffs?.contains(where:{$0.id == handoffID}) == true}) {
            guard owner.id == id else {throw ImprovementFailure("request_conflict", "This handoff ID belongs to another request.")}
            let position = catalog.requests[index].handoffs!.firstIndex(where:{$0.id == handoffID})!
            guard catalog.requests[index].handoffs![position].repository == repository else {throw ImprovementFailure("handoff_conflict", "This handoff belongs to another repository.")}
            if manual, catalog.requests[index].handoffs![position].phase == "opened" {
                catalog.requests[index].handoffs![position].phase = "prepared"
                catalog.requests[index].handoffs![position].originRepository = originRepository
                try save(catalog)
            }
            return catalog.requests[index].handoffs![position]
        }
        guard ![.implemented,.declined].contains(catalog.requests[index].state) else {
            throw ImprovementFailure("request_finished", "This request already has an outcome. Open its chat or save a new request.")
        }
        if let existing = catalog.requests[index].handoffs?.last, ["opened","prepared"].contains(existing.phase), existing.threadID == nil {
            guard existing.repository == repository else {throw ImprovementFailure("handoff_conflict", "The prepared request belongs to another repository. Resolve that handoff before changing its destination.")}
            if manual, existing.phase == "opened" {
                let position = catalog.requests[index].handoffs!.count - 1
                catalog.requests[index].handoffs![position].phase = "prepared"
                catalog.requests[index].handoffs![position].originRepository = originRepository
                try save(catalog)
                return catalog.requests[index].handoffs![position]
            }
            return existing
        }
        var handoff = ImprovementHandoff(id:handoffID,createdAt:Date(),repository:repository)
        if manual {handoff.phase = "prepared"; handoff.originRepository = originRepository}
        catalog.requests[index].handoffs = (catalog.requests[index].handoffs ?? []) + [handoff]
        try save(catalog); return handoff
    }
    public func failHandoff(_ id: UUID, handoffID: UUID) throws {
        var catalog = try load()
        guard let index = catalog.requests.firstIndex(where:{$0.id == id}),
              let link = catalog.requests[index].handoffs?.firstIndex(where:{$0.id == handoffID}) else {return}
        catalog.requests[index].handoffs![link].phase = "failed"
        catalog.requests[index].updates.append(ImprovementUpdate(id:UUID(),date:Date(),state:.needsInput,note:"Codex could not be opened. The request is saved; no model was started.",targetBuild:nil))
        try save(catalog)
    }
    @discardableResult
    public func linkChat(_ id: UUID, handoffID: UUID, threadID: UUID) throws -> Improvement {
        var catalog = try load()
        guard let index = catalog.requests.firstIndex(where:{$0.id == id}) else {throw ImprovementFailure("improvement_not_found", "No improvement has that ID.")}
        guard let link = catalog.requests[index].handoffs?.firstIndex(where:{$0.id == handoffID}) else {throw ImprovementFailure("handoff_not_found", "No prepared handoff has that ID.")}
        if let existing = catalog.requests[index].handoffs![link].threadID {
            guard existing == threadID else {throw ImprovementFailure("request_conflict", "Another chat is already linked to this handoff. Stop here and use that chat.")}
            return catalog.requests[index]
        }
        guard ["opened","prepared"].contains(catalog.requests[index].handoffs![link].phase),
              ![.implemented,.declined].contains(catalog.requests[index].state) else {
            throw ImprovementFailure("request_finished", "This handoff is no longer awaiting a chat. Do not start another implementation.")
        }
        if let delivery=catalog.requests[index].delivery {
            guard UUID(uuidString:delivery.destination.chatID) == threadID else {throw ImprovementFailure("request_conflict","This is not the selected destination chat.")}
        }
        guard catalog.requests[index].delivery != nil || !catalog.requests.contains(where:{$0.id != id && $0.handoffs?.contains(where:{$0.threadID == threadID}) == true}) else {
            throw ImprovementFailure("request_conflict", "This chat already belongs to another improvement request.")
        }
        catalog.requests[index].handoffs![link].threadID = threadID
        catalog.requests[index].handoffs![link].phase = "linked"
        if var delivery=catalog.requests[index].delivery,delivery.receipt == nil {
            delivery.phase="linked";catalog.requests[index].delivery=delivery
        }
        catalog.requests[index].updates.append(ImprovementUpdate(id:UUID(),date:Date(),state:.working,note:"Codex chat linked. Work was started there by the owner. Open chat to follow or discuss the work.",targetBuild:nil))
        try save(catalog); return catalog.requests[index]
    }
    /// Hide a note locally; keep its immutable request/history for late callbacks.
    public func removeFromList(_ id: UUID) throws {
        var catalog=try load()
        guard let i=catalog.requests.firstIndex(where:{$0.id==id}) else {throw ImprovementFailure("improvement_not_found","No improvement has that ID.")}
        if catalog.requests[i].removedAt == nil {catalog.requests[i].removedAt=Date();try save(catalog)}
    }
    public func prepareDelivery(_ id: UUID,destination: CodexDestination,operationID: UUID,originRepository: String) throws -> ImprovementDelivery {
        let original=try get(id)
        if let delivery=original.delivery {
            guard delivery.destination == destination else {throw ImprovementFailure("request_conflict","This request already has another destination.")}
            return delivery
        }
        guard original.removedAt == nil, original.handoffs?.contains(where:{$0.threadID != nil}) != true,
              original.runs?.contains(where:{$0.active}) != true else {throw ImprovementFailure("request_conflict","This request is removed, linked or already running.")}
        let handoff=try prepareHandoff(id,handoffID:operationID,repository:destination.repository,manual:true,originRepository:originRepository)
        var catalog=try load();let i=catalog.requests.firstIndex(where:{$0.id==id})!
        let delivery=ImprovementDelivery(id:handoff.id,destination:destination,messageID:operationID,phase:"prepared",receipt:nil)
        catalog.requests[i].delivery=delivery;try save(catalog);return delivery
    }
    public func beginDelivery(_ id: UUID) throws -> ImprovementDelivery {
        var catalog=try load()
        guard let i=catalog.requests.firstIndex(where:{$0.id==id}),var delivery=catalog.requests[i].delivery else {throw ImprovementFailure("handoff_not_found","Prepare this request first.")}
        guard delivery.phase == "prepared", catalog.requests[i].removedAt == nil, ![.implemented,.declined].contains(catalog.requests[i].state) else {throw ImprovementFailure("codex_delivery_unconfirmed","This send was already attempted. Inspect its existing chat; do not send it again.")}
        delivery.phase="submitting";catalog.requests[i].delivery=delivery;try save(catalog);return delivery
    }
    public func finishDelivery(_ id: UUID,receipt: CodexSendReceipt?) throws {
        var catalog=try load()
        guard let i=catalog.requests.firstIndex(where:{$0.id==id}),var delivery=catalog.requests[i].delivery else {throw ImprovementFailure("handoff_not_found","No delivery exists.")}
        if let receipt {
            guard receipt.messageID == delivery.messageID,receipt.chatID == delivery.destination.chatID else {throw ImprovementFailure("request_conflict","The delivery receipt does not match its request.")}
            if let prior=delivery.receipt {guard prior == receipt else {throw ImprovementFailure("request_conflict","A different receipt already exists.")};return}
            guard ["submitting","linked"].contains(delivery.phase) else {throw ImprovementFailure("request_conflict","This request is not being sent.")}
            delivery.phase="accepted";delivery.receipt=receipt
        } else if delivery.receipt == nil {
            delivery.phase = catalog.requests[i].handoffs?.contains(where:{$0.id==delivery.id && $0.threadID==UUID(uuidString:delivery.destination.chatID)}) == true ? "linked" : "unconfirmed"
        }
        catalog.requests[i].delivery=delivery;try save(catalog)
        if let receipt { _ = try linkChat(id,handoffID:delivery.id,threadID:UUID(uuidString:receipt.chatID)!)}
    }
    public func markRunStarted(_ requestID: UUID, runID: UUID, sessionID: String?) throws {
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
    public func finishRun(_ requestID: UUID, runID: UUID, receipt: ImprovementWorkerReceipt) throws {
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
}
