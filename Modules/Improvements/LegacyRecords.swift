import Foundation

public struct ImprovementRun: Codable, Equatable {
    public init(id: UUID, startedAt: Date, repository: String, revision: Int) {self.id=id; self.startedAt=startedAt; self.repository=repository; self.revision=revision}
    public let id: UUID, startedAt: Date, repository: String, revision: Int
    public var phase = "launching"
    public var finishedAt: Date?, sessionID: String?
    public var active: Bool { finishedAt == nil }
}
public struct ImprovementAgentResult: Codable {
    public init(state: ImprovementState, note: String, targetBuild: Int?) {self.state=state; self.note=note; self.targetBuild=targetBuild}
    public let state: ImprovementState, note: String, targetBuild: Int?
    public func validate() throws {
        guard [.implemented,.needsInput,.declined].contains(state) else {
            throw ImprovementFailure("invalid_agent_result", "Agent must report implemented, needs-input or declined.")
        }
        try ImprovementStore.validateUpdate(state:state,note:note,targetBuild:targetBuild)
    }
}
public struct ImprovementWorkerReceipt: Codable {
    public init(finishedAt: Date, succeeded: Bool, result: ImprovementAgentResult, sessionID: String?) {self.finishedAt=finishedAt; self.succeeded=succeeded; self.result=result; self.sessionID=sessionID}
    public let finishedAt: Date, succeeded: Bool, result: ImprovementAgentResult, sessionID: String?
    public static func failure(_ note: String) -> Self {
        Self(finishedAt:Date(),succeeded:false,result:ImprovementAgentResult(state:.needsInput,note:note,targetBuild:nil),sessionID:nil)
    }
}
