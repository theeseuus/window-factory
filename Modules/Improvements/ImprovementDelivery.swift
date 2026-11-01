import Foundation

public struct ImprovementDelivery: Codable, Equatable, Sendable {
    public let id: UUID, destination: CodexDestination, messageID: UUID
    public var phase: String
    public var receipt: CodexSendReceipt?
}

/// Single store owner; transport can suspend while callbacks update the same request.
@MainActor
public enum ImprovementDeliveryCoordinator {
    public static func send(requestID: UUID,operationID: UUID,destination: CodexDestination,
                            originRepository: String,store: ImprovementStore,application: ImprovementApplication,
                            transmit: (String,CodexDestination,UUID) async throws -> CodexSendReceipt) async throws -> CodexSendReceipt {
        let delivery=try store.prepareDelivery(requestID,destination:destination,operationID:operationID,originRepository:originRepository)
        if let receipt=delivery.receipt {return receipt}
        let request=try store.get(requestID)
        let handoff=request.handoffs!.first(where:{$0.id==delivery.id})!
        let prompt=try ImprovementHandoffLink.prompt(request:request,handoff:handoff,application:application)
        _ = try store.beginDelivery(requestID) // Durable write-ahead marker before any send.
        do {
            let receipt=try await transmit(prompt,destination,delivery.messageID)
            try store.finishDelivery(requestID,receipt:receipt);return receipt
        } catch {
            // Never auto-repeat an uncertain send, including after process restart.
            try? store.finishDelivery(requestID,receipt:nil);throw error
        }
    }
}
