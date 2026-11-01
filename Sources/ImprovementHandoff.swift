import Foundation

// Application-owned configuration; the prompt and URL builder live in Improvements.
extension ImprovementHandoffLink {
    static let windowFactory = ImprovementApplication(name:"Window Factory",callbackCommand:"scripts/window-factory")
    static func prompt(request: Improvement, handoff: ImprovementHandoff) throws -> String {
        try prompt(request:request,handoff:handoff,application:windowFactory)
    }
    static func newChatURL(request: Improvement, handoff: ImprovementHandoff, projectID: String) throws -> URL {
        try newChatURL(request:request,handoff:handoff,application:windowFactory,projectID:projectID)
    }
}
