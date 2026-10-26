import Foundation

struct AccordionRecord {
    let id: UInt32
    let frame: Frame
}
enum AccordionGeometry {
    // Raising farthest first leaves each nearer window above it; anchor is last.
    static func raiseOrder(anchor: UInt32,fan: [AccordionRecord]) -> [UInt32] {
        fan.isEmpty ? [] : fan.reversed().map(\.id)+[anchor]
    }

    static func plan(anchor: AccordionRecord,others: [AccordionRecord],screen: Frame) -> [AccordionRecord] {
        let ordered = others.filter{$0.id != anchor.id}.sorted {
            if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
            if $0.frame.x != $1.frame.x { return $0.frame.x < $1.frame.x }
            return $0.id < $1.id
        }
        return ordered.enumerated().map { index,record in
            let step = Double(index+1),base = anchor.frame
            // Match the existing Lua clamp, including oversized anchor frames.
            let x = min(max(base.x+step*28,screen.x),screen.x+screen.w-base.w)
            let y = min(max(base.y+step*22,screen.y),screen.y+screen.h-base.h)
            return AccordionRecord(id:record.id,frame:Frame(x:x,y:y,w:base.w,h:base.h))
        }
    }
}
