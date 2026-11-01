import Foundation

/// Trusted host configuration. Request text never supplies executable commands.
public struct ImprovementApplication: Sendable {
    public let name: String
    public let callbackCommand: String
    public let instructionsPath: String
    public init(name: String, callbackCommand: String, instructionsPath: String = "docs/improvements.md") {
        self.name = name; self.callbackCommand = callbackCommand; self.instructionsPath = instructionsPath
    }
}

public struct ImprovementFailure: Error, LocalizedError, Codable, Sendable {
    public let code: String, message: String
    public init(_ code: String, _ message: String) {self.code = code; self.message = message}
    public var errorDescription: String? {message}
}
