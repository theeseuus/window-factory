import Foundation
@main enum StashTests {
 static func main() {
    var assertions = 0
    func check(_ condition: Bool,_ message: String) { precondition(condition,message); assertions += 1 }
    for screen in [Frame(x:0,y:30,w:3840,h:2130),Frame(x:-1600,y:-900,w:1600,h:1200),Frame(x:2000,y:400,w:900,h:1300)] {
        for frame in [Frame(x:screen.x+100,y:screen.y,w:640,h:452),Frame(x:screen.x+300,y:screen.y+800,w:400,h:900)] {
            let target = StashGeometry.destination(frame,on:screen)
            check(target == Frame(x:screen.x+screen.w+40,y:frame.y,w:frame.w,h:frame.h),"Original Lua right-edge request, unchanged y/size")
            check(StashGeometry.confirmed(target,original:frame,screen:screen),"Exact offscreen placement accepted")
            let constrained = Frame(x:screen.x+screen.w-40,y:frame.y,w:frame.w,h:frame.h)
            check(StashGeometry.confirmed(constrained,original:frame,screen:screen),"Observed macOS 40-point strip accepted")
            check(!StashGeometry.confirmed(frame,original:frame,screen:screen),"Unmoved window is not stashed")
            check(!StashGeometry.confirmed(Frame(x:target.x,y:frame.y,w:frame.w+80,h:frame.h),original:frame,screen:screen),"Size change is not reported as stash success")
            check(!StashGeometry.confirmed(Frame(x:target.x,y:frame.y+20,w:frame.w,h:frame.h),original:frame,screen:screen),"Unexpected vertical move is not accepted")
        }
    }
    check(!StashGeometry.confirmed(Frame(x:4000,y:30,w:0,h:100),original:Frame(x:0,y:30,w:100,h:100),screen:Frame(x:0,y:30,w:3840,h:2130)),"Invalid frame rejected")
    print("native stash geometry: \(assertions) assertions passed")
 }
}
