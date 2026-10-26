import Foundation

struct SpaceMoveEntry { let id: UInt64; let kind: Int }
struct SpaceMovePlan: Equatable {
    let source: UInt64,destination: UInt64
    let ordinal: Int
}
enum SpaceMovePhase { case beforeMove,membership,beforeFollow,following,finish }
enum SpaceMovement {
    static func plan(_ entries: [SpaceMoveEntry],current: UInt64,direction: Int) throws -> SpaceMovePlan {
        guard direction == -1 || direction == 1 else { throw FactoryError("Invalid Space direction.") }
        guard Set(entries.map(\.id)).count == entries.count,entries.allSatisfy({$0.id != 0}),
              entries.first(where:{$0.id == current})?.kind == 0 else { throw FactoryError("An ordinary desktop with unambiguous membership is required.") }
        let users = entries.filter{$0.kind == 0}.map(\.id)
        guard let index = users.firstIndex(of:current) else { throw FactoryError("Current desktop is unavailable.") }
        let next = index+direction
        guard users.indices.contains(next) else { throw FactoryError(direction<0 ? "Already at the first desktop." : "Already at the last desktop.") }
        return SpaceMovePlan(source:current,destination:users[next],ordinal:next+1)
    }
    // AXFocusedWindow can still name a background app's last window. Require
    // the real foreground window to remain focused across transition samples.
    @MainActor static func restoreFocus(check: () throws -> Void,request: () throws -> Void,
        focused: () -> Bool,pause: () async throws -> Void = { try await Task.sleep(for:.milliseconds(40)) }) async throws {
        var stable = 0
        for attempt in 0..<25 {
            try Task.checkCancellation(); try check()
            if attempt == 0 || (stable == 0 && (attempt == 8 || attempt == 16)) { try request() }
            try await pause(); try Task.checkCancellation(); try check()
            stable = focused() ? stable+1 : 0
            if stable == 6 { return }
        }
        throw FactoryError("Moved and followed, but stable foreground window focus was not confirmed.")
    }
    @MainActor static func perform(_ plan: SpaceMovePlan,
        check: (SpaceMovePhase) throws -> Void,move: () -> Bool,
        membership: () throws -> [UInt64],follow: () -> Bool,
        destinationVisible: () throws -> Bool,finish: () async throws -> Void,
        pause: () async throws -> Void = { try await Task.sleep(for:.milliseconds(40)) }) async throws {
        try Task.checkCancellation(); try check(.beforeMove)
        guard move() else { throw FactoryError("Space move was not dispatched; no follow requested.") }
        var matches = 0
        for _ in 0..<40 {
            try Task.checkCancellation(); try check(.membership)
            let ids = try membership()
            guard ids == [plan.source] || ids == [plan.destination] else { throw FactoryError("Window membership changed unexpectedly; follow stopped.") }
            matches = ids == [plan.destination] ? matches+1 : 0
            if matches == 2 { break }
            try await pause()
        }
        guard matches == 2 else { throw FactoryError("Window move was not confirmed; desktop left unchanged.") }
        try check(.beforeFollow)
        guard follow() else { throw FactoryError("Window moved, but following the destination was not dispatched.") }
        matches = 0
        for _ in 0..<40 {
            try Task.checkCancellation(); try check(.following)
            guard try membership() == [plan.destination] else { throw FactoryError("Moved window left the destination; follow verification stopped.") }
            matches = try destinationVisible() ? matches+1 : 0
            if matches == 2 { break }
            try await pause()
        }
        guard matches == 2 else { throw FactoryError("Window moved, but the destination desktop was not visibly confirmed.") }
        try check(.finish); try await finish()
    }
}
