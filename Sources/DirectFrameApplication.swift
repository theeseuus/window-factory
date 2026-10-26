import Foundation

// Submit immediately. Verification/repair is cancellable and never delays the
// first write; a newer shortcut supersedes this command rather than being lost.
@MainActor
enum DirectFrameApplication {
    enum Change { case position, size }
    static func apply(target: Frame, from original: Frame,
                      check: () throws -> Void,
                      read: () throws -> Frame,
                      write: (Change, Frame) throws -> Void,
                      submit: (() throws -> Void)? = nil,
                      pause: () async throws -> Void = { try await Task.sleep(for:.milliseconds(40)) }) async throws -> Frame {
        func change(_ kind: Change) throws {
            try Task.checkCancellation(); try check(); try write(kind,target)
        }
        let resizing = abs(original.w-target.w)>2 || abs(original.h-target.h)>2
        if let submit {
            try Task.checkCancellation(); try check(); try submit()
        } else {
            if resizing { try change(.size) }
            try change(.position)
            if resizing { try change(.size) }
        }
        // Only repair a component after the application has finished its current
        // animation. Do not overlap another position and size animation here.
        var actual = original
        for _ in 0..<4 {
            for _ in 0..<10 { try await pause(); try Task.checkCancellation(); try check() }
            actual = try read()
            if actual.matches(target) { return actual }
            if abs(actual.x-target.x)>2 || abs(actual.y-target.y)>2 {
                try change(.position)
            } else if abs(actual.w-target.w)>2 || abs(actual.h-target.h)>2 {
                try change(.size)
            }
        }
        for _ in 0..<10 { try await pause(); try Task.checkCancellation(); try check() }
        return try read()
    }
}
