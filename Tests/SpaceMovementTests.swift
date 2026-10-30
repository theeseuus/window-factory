import Foundation
@main enum SpaceMovementTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ value: Bool,_ label: String) { precondition(value,label); assertions += 1 }
        let entries = [SpaceMoveEntry(id:100,kind:0),SpaceMoveEntry(id:999,kind:4),SpaceMoveEntry(id:20,kind:0),SpaceMoveEntry(id:5,kind:0)]
        let right = try SpaceMovement.plan(entries,current:100,direction:1)
        check(right == SpaceMovePlan(source:100,destination:20,ordinal:2),"native order, not private ID sorting; skip fullscreen")
        let left = try SpaceMovement.plan(entries,current:20,direction:-1)
        check(left == SpaceMovePlan(source:20,destination:100,ordinal:1),"left user adjacency")
        for (current,direction) in [(UInt64(100),-1),(5,1),(999,1),(88,1),(100,0)] {
            do { _ = try SpaceMovement.plan(entries,current:current,direction:direction); check(false,"invalid/boundary plan must fail") } catch { check(true,"reject invalid or wrapping plan") }
        }
        for bad in [[SpaceMoveEntry(id:0,kind:0)], [SpaceMoveEntry(id:100,kind:0),SpaceMoveEntry(id:100,kind:0)]] {
            do { _ = try SpaceMovement.plan(bad,current:100,direction:1); check(false,"ambiguous IDs must fail") } catch { check(true,"invalid topology rejected") }
        }
        for mode in ["success","move-fails","membership-timeout","ambiguous","follow-fails","visible-timeout","focus-fails","user-change","cancel"] {
            var events: [String] = [],reads = 0,visibleReads = 0,pauses = 0
            var failed = false
            do {
                try await SpaceMovement.perform(right,check:{ phase in
                    switch phase {
                    case .beforeMove: events.append("check-start")
                    case .membership: if mode == "user-change" { throw FactoryError("user changed focus") }
                    case .beforeFollow: events.append("check-follow")
                    case .following: break
                    case .finish: events.append("check-finish")
                    }
                },move:{events.append("move"); return mode != "move-fails"},membership:{
                    reads += 1
                    if mode == "membership-timeout" { return [100] }
                    if mode == "ambiguous" { return [100,20] }
                    return [20]
                },follow:{events.append("follow"); return mode != "follow-fails"},destinationVisible:{
                    visibleReads += 1; return mode != "visible-timeout"
                },finish:{
                    events.append("finish")
                    if mode == "focus-fails" { throw FactoryError("exact focus not reached") }
                },pause:{
                    pauses += 1
                    if mode == "cancel" { throw CancellationError() }
                })
            } catch { failed = true }
            check(events.filter{$0 == "move"}.count == 1,"one move dispatch, never an automatic retry")
            check(events.filter{$0 == "follow"}.count <= 1,"at most one follow dispatch")
            check(failed == (mode != "success"),"truthful result for \(mode)")
            if ["move-fails","membership-timeout","ambiguous","user-change","cancel"].contains(mode) {
                check(!events.contains("follow") && !events.contains("finish"),"never follow unconfirmed/aborted movement")
            }
            if mode == "success" {
                check(events == ["check-start","move","check-follow","follow","check-finish","finish"],"strict move-membership-follow-visible-focus sequence")
                check(reads == 4 && visibleReads == 2 && pauses == 2,"two independent membership and compositor samples")
            }
            if mode == "membership-timeout" { check(reads == 40 && pauses == 40,"membership polling is bounded") }
            if mode == "visible-timeout" { check(visibleReads == 40 && !events.contains("finish"),"no focus writes before compositor confirmation") }
        }
        for mode in ["stable","late-loss","never","input-change","cancel","request-fails"] {
            var samples = 0,requests = 0,checks = 0,failed = false
            do {
                try await SpaceMovement.restoreFocus(check:{
                    checks += 1
                    if mode == "input-change" && checks == 5 { throw FactoryError("new user input") }
                },request:{
                    requests += 1
                    if mode == "request-fails" { throw FactoryError("activation rejected") }
                },focused:{
                    samples += 1
                    if mode == "never" { return false }
                    if mode == "late-loss" { return samples<=2 || samples>=9 }
                    return true
                },pause:{ if mode == "cancel" { throw CancellationError() } })
            } catch { failed = true }
            check(failed == !["stable","late-loss"].contains(mode),"focus result is truthful for \(mode)")
            check(requests<=3,"focus restoration never retries without a bound")
            if mode == "stable" { check(samples == 6 && requests == 1,"single focus request must remain foreground for six samples") }
            if mode == "late-loss" { check(samples == 14 && requests == 2,"transient focus success must reset after late transition focus loss") }
            if mode == "never" { check(samples == 25 && requests == 3,"stale/background focus fails with a bounded retry budget") }
            if mode == "input-change" { check(requests == 1 && samples == 2,"new input stops restoration before any retry") }
        }
        for mode in ["single-before-follow","rapid-input","focus-loss"] {
            let trace=SpaceMoveDiagnostics(direction:1,invocation:"fixture",appBuild:"fixture")
            trace.report.sourceSpace=100;trace.report.destinationSpace=20
            do {
                try await SpaceMovement.perform(right,check:{phase in
                    trace.mark(String(describing:phase))
                    if mode == "single-before-follow", case .beforeFollow = phase {throw FactoryError("Fixture context changed")}
                    if mode == "rapid-input",case .membership = phase {
                        trace.report.inputDeltas=[1,0,0,0];trace.report.failedCheck="new_input"
                        throw FactoryError("Fixture new input")
                    }
                },move:{trace.report.moveDispatched=true;if mode == "rapid-input"{trace.report.ignoredMoveRequests += 1};return true},membership:{trace.report.membershipReads += 1;trace.report.lastWindowSpaces=[20];return [20]},follow:{trace.report.followDispatched=true;return true},destinationVisible:{true},finish:{
                    trace.mark("focusRestoration");trace.report.focusRequests=1
                    throw FactoryError("Fixture focus not confirmed")
                },pause:{})
                check(false,"diagnostic fixture must stop at its selected stage")
            } catch {trace.finish("failed",detail:error.localizedDescription)}
            let report=trace.report
            check(report.moveDispatched && report.outcome == "failed","report records a partial move truthfully")
            if mode == "single-before-follow" {check(!report.followDispatched && report.phase == "beforeFollow" && report.ignoredMoveRequests == 0,"single-press pre-follow failure is distinct from rapid input")}
            if mode == "rapid-input" {check(!report.followDispatched && report.failedCheck == "new_input" && report.ignoredMoveRequests == 1,"rapid repeat and input cancellation are recorded separately")}
            if mode == "focus-loss" {check(report.followDispatched && report.phase == "focusRestoration" && report.focusRequests == 1,"arrival/focus failure is distinct from no follow")}
            let encoded=try JSONEncoder().encode(report),decoded=try JSONDecoder().decode(SpaceMoveDiagnosticReport.self,from:encoded)
            check(decoded.attemptID == report.attemptID && decoded.phase == report.phase,"diagnostic report is structured and round trips")
            let object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
            check(object["title"] == nil && object["path"] == nil && object["keys"] == nil,"diagnostics contain no window title, path or pressed key values")
        }
        print("native Space movement: \(assertions) assertions passed; no desktop queries or mutations")
    }
}
