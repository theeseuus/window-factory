import Foundation

enum StashGeometry {
    static func destination(_ frame: Frame,on screen: Frame) -> Frame {
        Frame(x:screen.x+screen.w+40,y:frame.y,w:frame.w,h:frame.h)
    }
    static func confirmed(_ actual: Frame,original: Frame,screen: Frame) -> Bool {
        // AppKit can constrain an offscreen request to a 40-point visible strip.
        actual.valid && original.valid && screen.valid && actual.x >= screen.x+screen.w-42
            && abs(actual.y-original.y)<=2 && abs(actual.w-original.w)<=2 && abs(actual.h-original.h)<=2
    }
}
