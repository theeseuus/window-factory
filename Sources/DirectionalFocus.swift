import Foundation

enum FocusDirection: String, CaseIterable, Codable { case left, down, up, right }
struct FocusRecord: Codable, Equatable {
    let id: UInt32
    let display: UInt32
    let frame: Frame
}
// Exact axis/score ordering from TheseusWindow's spatial_focus_logic.lua.
enum DirectionalFocus {
    static let epsilon = 0.000001
    static func score(_ current: Frame,_ candidate: Frame,_ direction: FocusDirection) -> [Double]? {
        guard [current,candidate].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.w.isFinite && $0.h.isFinite && $0.w>epsilon && $0.h>epsilon }) else { return nil }
        let horizontal = direction == .left || direction == .right
        let sign = direction == .right || direction == .down ? 1.0 : -1.0
        let a = horizontal ? current.x : current.y, b = horizontal ? candidate.x : candidate.y
        let al = horizontal ? current.w : current.h, bl = horizontal ? candidate.w : candidate.h
        let ac = horizontal ? current.y : current.x, bc = horizontal ? candidate.y : candidate.x
        let acl = horizontal ? current.h : current.w, bcl = horizontal ? candidate.h : candidate.w
        let distance = sign*((b+bl/2)-(a+al/2))
        let overlap = min(ac+acl,bc+bcl)-max(ac,bc)
        guard distance>epsilon,overlap>epsilon else { return nil }
        let gap = sign>0 ? b-(a+al) : a-(b+bl)
        return [max(0,gap),abs(ac+acl/2-bc-bcl/2),-overlap,distance]
    }
    static func nearest(_ current: FocusRecord,_ candidates: [FocusRecord],_ direction: FocusDirection) -> FocusRecord? {
        func choose(_ records: [FocusRecord]) -> FocusRecord? {
            var winner: FocusRecord?, best: [Double]?
            for candidate in records where candidate.id != current.id {
                guard let value = score(current.frame,candidate.frame,direction) else { continue }
                var better = best == nil
                if let best {
                    for (a,b) in zip(value,best) {
                        if a < b-epsilon { better = true; break }
                        if a > b+epsilon { break }
                    }
                }
                if better { winner = candidate; best = value }
            }
            return winner
        }
        return choose(candidates.filter{$0.display == current.display}) ?? choose(candidates)
    }
}
