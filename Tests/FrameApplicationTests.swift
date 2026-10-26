import Foundation

@MainActor
private final class AnimatedWindow {
    var frame: Frame
    var pending: Frame?
    var ticks = 0
    var writes = 0
    var minimumWidth = 0.0
    var samples = 0
    let screen = Frame(x:0,y:30,w:1200,h:800)
    init(_ frame: Frame) { self.frame = frame }
    func write(_ change: DirectFrameApplication.Change,_ target: Frame) {
        // A queued animation is based on the currently observed frame. A second
        // write before completion can therefore overwrite the first operation.
        var next = frame
        switch change {
        case .position:
            next.x = min(max(target.x,screen.x),screen.x+screen.w-next.w)
            next.y = min(max(target.y,screen.y),screen.y+screen.h-next.h)
        case .size:
            next.w = max(minimumWidth,min(target.w,screen.x+screen.w-next.x))
            next.h = min(target.h,screen.y+screen.h-next.y)
        }
        pending = next; ticks = 8; writes += 1
    }
    func tick() {
        samples += 1
        if ticks>0 { ticks -= 1; if ticks == 0, let pending { frame = pending; self.pending = nil } }
    }
}
private enum Interrupted: Error { case focus }
@main enum FrameApplicationTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ condition: Bool,_ message: String) { precondition(condition,message); assertions += 1 }
        let origins = [Frame(x:0,y:30,w:300,h:240),Frame(x:900,y:590,w:300,h:240),Frame(x:400,y:300,w:300,h:240),Frame(x:0,y:30,w:1200,h:800)]
        let goals = [Frame(x:0,y:30,w:400,h:800),Frame(x:400,y:30,w:400,h:800),Frame(x:800,y:30,w:400,h:800),Frame(x:0,y:30,w:1200,h:800),Frame(x:300,y:30,w:600,h:800),Frame(x:600,y:430,w:600,h:400),Frame(x:340,y:30,w:520,h:800),Frame(x:260,y:30,w:680,h:800)]
        for origin in origins { for goal in goals {
            let window = AnimatedWindow(origin)
            var immediate = true
            let result = try await DirectFrameApplication.apply(target:goal,from:origin,
                check:{},read:{window.frame},write:{
                    if window.writes == 0 { immediate = window.samples == 0 }
                    window.write($0,$1)
                },pause:{window.tick()})
            check(result.matches(goal),"Settled resize from \(origin) to \(goal)")
            check(immediate,"First write has no wait")
            check(window.samples<=50,"Bounded settling")
        } }
        let low = origins[1], goal = goals[0]
        let old = AnimatedWindow(low)
        old.write(.size,goal); old.write(.position,goal)
        for _ in 0..<20 { old.tick() }
        check(!old.frame.matches(goal),"Fixture reproduces the previous overlapping-write failure")
        let constrained = AnimatedWindow(low); constrained.minimumWidth = 500
        let actual = try await DirectFrameApplication.apply(target:goal,from:low,
            check:{},read:{constrained.frame},write:{constrained.write($0,$1)},pause:{constrained.tick()})
        check(!actual.matches(goal),"A genuine minimum-size constraint remains observable")
        let interrupted = AnimatedWindow(low)
        do {
            _ = try await DirectFrameApplication.apply(target:goal,from:low,
                check:{if interrupted.samples>0 {throw Interrupted.focus}},read:{interrupted.frame},
                write:{interrupted.write($0,$1)},pause:{interrupted.tick()})
            preconditionFailure("Focus change must stop placement")
        } catch Interrupted.focus { check(interrupted.writes == 3,"No subsequent write after focus changes") }
        let cancelled = AnimatedWindow(low)
        do {
            _ = try await DirectFrameApplication.apply(target:goal,from:low,
                check:{},read:{cancelled.frame},write:{cancelled.write($0,$1)},pause:{throw CancellationError()})
            preconditionFailure("Cancellation must stop placement")
        } catch is CancellationError { check(cancelled.writes == 3,"No subsequent write after cancellation") }
        print("native frame application: \(assertions) assertions passed")
    }
}
