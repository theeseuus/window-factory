import Foundation

// Ported from this repository's MIT-licensed TheseusWindow helpers. All
// arithmetic is independent of AppKit/AX so the Lua implementation can serve
// as the compatibility oracle in tests.
enum GeometryCommand: String, CaseIterable, Codable {
    case sizeNext, sizePrevious, positionNext, positionPrevious
    case halvesNext, halvesPrevious, thirdsNext, thirdsPrevious
    case quartersNext, quartersPrevious, eighthsNext, eighthsPrevious
    case centeredHalf, restoreFrame, centerHorizontally, narrower, wider, maximize, minimize
    var title: String {
        switch self {
        case .sizeNext: "Next size"; case .sizePrevious: "Previous size"
        case .positionNext: "Next position"; case .positionPrevious: "Previous position"
        case .halvesNext: "Next half"; case .halvesPrevious: "Previous half"
        case .thirdsNext: "Next third"; case .thirdsPrevious: "Previous third"
        case .quartersNext: "Next quarter"; case .quartersPrevious: "Previous quarter"
        case .eighthsNext: "Next eighth"; case .eighthsPrevious: "Previous eighth"
        case .centeredHalf: "Centred half width"; case .restoreFrame: "Restore previous frame"
        case .centerHorizontally: "Centre horizontally"; case .narrower: "Narrower"; case .wider: "Wider"
        case .maximize: "Maximize"; case .minimize: "Minimize"
        }
    }
    var reverse: Bool { rawValue.hasSuffix("Previous") }
}
struct GeometryShortcut {
    let command: GeometryCommand
    let keyCode: UInt32
    let shift: Bool
    let key: String
    var modifiers: UInt32 { 256 | 2048 | 4096 | (shift ? 512 : 0) }
    var label: String { "⌃⌥⌘" + (shift ? "⇧" : "") + key }
    static let all: [GeometryShortcut] = [
        .init(command:.sizeNext,keyCode:27,shift:false,key:"−"), .init(command:.sizePrevious,keyCode:27,shift:true,key:"−"),
        .init(command:.positionNext,keyCode:24,shift:false,key:"="), .init(command:.positionPrevious,keyCode:24,shift:true,key:"="),
        .init(command:.halvesNext,keyCode:19,shift:false,key:"2"), .init(command:.halvesPrevious,keyCode:19,shift:true,key:"2"),
        .init(command:.thirdsNext,keyCode:20,shift:false,key:"3"), .init(command:.thirdsPrevious,keyCode:20,shift:true,key:"3"),
        .init(command:.quartersNext,keyCode:21,shift:false,key:"4"), .init(command:.quartersPrevious,keyCode:21,shift:true,key:"4"),
        .init(command:.eighthsNext,keyCode:28,shift:false,key:"8"), .init(command:.eighthsPrevious,keyCode:28,shift:true,key:"8"),
        .init(command:.centeredHalf,keyCode:126,shift:false,key:"↑"), .init(command:.restoreFrame,keyCode:125,shift:false,key:"↓"),
        .init(command:.centerHorizontally,keyCode:36,shift:false,key:"↩"),
        .init(command:.narrower,keyCode:33,shift:false,key:"["), .init(command:.wider,keyCode:30,shift:false,key:"]"),
        .init(command:.maximize,keyCode:36,shift:true,key:"↩"), .init(command:.minimize,keyCode:2,shift:false,key:"D")]
}

enum DirectGeometry {
    static let epsilon = 0.000001
    static var canonical: [[Frame]] {
        let half = [0.0,0.25,0.5].map { Frame(x:$0,y:0,w:0.5,h:1) }
        let quarter = [(0.0,0.0),(0.5,0.0),(0.5,0.5),(0.0,0.5)].map { Frame(x:$0.0,y:$0.1,w:0.5,h:0.5) }
        let eighth = (0..<4).map { Frame(x:Double($0)/4,y:0,w:0.25,h:0.5) }
            + (0..<4).reversed().map { Frame(x:Double($0)/4,y:0.5,w:0.25,h:0.5) }
        var sixteenth: [Frame] = []
        for row in 0..<4 {
            for sequenceColumn in 0..<4 {
                let column: Int = row % 2 == 0 ? sequenceColumn : 3-sequenceColumn
                sixteenth.append(Frame(x:Double(column)/4.0,y:Double(row)/4.0,w:0.25,h:0.25))
            }
        }
        return [half,quarter,eighth,sixteenth]
    }
    static func nextIndex(_ current: Int?,count: Int,reverse: Bool) -> Int {
        guard let current else { return reverse ? count-1 : 0 }
        return (current + (reverse ? -1 : 1) + count) % count
    }
    static func nearestSize(_ frame: Frame) -> Int {
        var best = 0, distance = Double.infinity
        for (index,slots) in canonical.enumerated() {
            let d = pow(frame.w-slots[0].w,2)+pow(frame.h-slots[0].h,2)
            if d < distance-epsilon { best = index; distance = d }
        }
        return best
    }
    static func nearestPosition(_ frame: Frame,slots: [Frame]) -> Int {
        let cx = frame.x+frame.w/2, cy = frame.y+frame.h/2
        var best = 0, distance = Double.infinity, outward = -Double.infinity
        for (index,slot) in slots.enumerated() {
            let sx = slot.x+slot.w/2, sy = slot.y+slot.h/2
            let d = pow(cx-sx,2)+pow(cy-sy,2)
            var o = 0.0
            if abs(cx-0.5)>epsilon { o += (sx-0.5)*(cx>0.5 ? 1 : -1) }
            if abs(cy-0.5)>epsilon { o += (sy-0.5)*(cy>0.5 ? 1 : -1) }
            if d < distance-epsilon || (abs(d-distance)<=epsilon && o > outward+epsilon) {
                best = index; distance = d; outward = o
            }
        }
        return best
    }
    static func absolute(_ slot: Frame,_ screen: Frame) -> Frame {
        Frame(x:screen.x+slot.x*screen.w,y:screen.y+slot.y*screen.h,w:slot.w*screen.w,h:slot.h*screen.h)
    }
    static func canonicalCycle(_ command: GeometryCommand,frame: Frame,screen: Frame) -> Frame {
        let normal = frame.normalized(in:screen), size = nearestSize(normal)
        if command == .sizeNext || command == .sizePrevious {
            let next = nextIndex(size,count:4,reverse:command.reverse), slots = canonical[next]
            return absolute(slots[nearestPosition(normal,slots:slots)],screen)
        }
        let slots = canonical[size], current = nearestPosition(normal,slots:slots)
        return absolute(slots[nextIndex(current,count:slots.count,reverse:command.reverse)],screen)
    }
    static func legacySlots(_ command: GeometryCommand) -> [Frame]? {
        switch command {
        case .halvesNext,.halvesPrevious: return [Frame(x:0,y:0,w:0.5,h:1),Frame(x:0.5,y:0,w:0.5,h:1)]
        case .thirdsNext,.thirdsPrevious: return (0..<3).map { Frame(x:Double($0)/3,y:0,w:1.0/3,h:1) }
        case .quartersNext,.quartersPrevious: return canonical[1]
        case .eighthsNext,.eighthsPrevious: return canonical[2]
        default: return nil
        }
    }
    static func centerHorizontally(_ frame: Frame,in screen: Frame) -> Frame {
        Frame(x:screen.x+(screen.w-frame.w)/2,y:frame.y,w:frame.w,h:frame.h)
    }
    static func adjustWidth(_ frame: Frame,in screen: Frame,direction: Double) -> Frame {
        let width = max(min(360,screen.w),min(screen.w,frame.w+direction*80))
        return Frame(x:max(screen.x,min(screen.x+screen.w-width,frame.x+frame.w/2-width/2)),y:frame.y,w:width,h:frame.h)
    }
}
