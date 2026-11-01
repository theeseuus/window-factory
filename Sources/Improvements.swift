import Foundation

extension ImprovementStore {
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
