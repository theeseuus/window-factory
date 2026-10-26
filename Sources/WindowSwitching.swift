import Foundation

struct SwitcherSelection {
    let ids: [UInt32]
    private(set) var index: Int
    var selected: UInt32? { ids.isEmpty ? nil : ids[index] }
    init(ids: [UInt32],current: UInt32?,direction: Int) {
        var seen = Set<UInt32>(); self.ids = ids.filter{seen.insert($0).inserted}
        index = 0
        let start = current.flatMap{self.ids.firstIndex(of:$0)} ?? (direction>0 ? -1 : 0)
        if !self.ids.isEmpty { index = (start+direction%self.ids.count+self.ids.count)%self.ids.count }
    }
    mutating func select(_ id: UInt32) {
        if let found = ids.firstIndex(of:id) { index = found }
    }
    mutating func advance(_ direction: Int) {
        guard !ids.isEmpty else { return }
        index = (index+direction%ids.count+ids.count)%ids.count
    }
}
struct WindowRecency {
    private(set) var ids: [UInt32] = []
    mutating func note(_ id: UInt32) {
        guard id != 0 else { return }; ids.removeAll{$0 == id}; ids.insert(id,at:0)
        if ids.count>512 { ids.removeLast(ids.count-512) }
    }
    func ordered(_ candidates: [UInt32],current: UInt32?) -> [UInt32] {
        let allowed = Set(candidates); var seen = Set<UInt32>()
        return ([current].compactMap{$0}+ids+candidates).filter{allowed.contains($0) && seen.insert($0).inserted}
    }
}

// An unseen ordinary desktop can have real windows absent from AXWindows.
// Use compositor presence for discovery; require exact AX identity at landing.
enum SwitcherDiscovery {
    static func accepts(space: UInt64,membership: [UInt64],kind: Int32,shown: Bool,
                        isUp: Bool,standardAX: Bool,rejectedAX: Bool) -> Bool {
        guard space != 0,membership == [space],isUp,!rejectedAX else { return false }
        if standardAX { return kind == 0 || kind == 4 }
        return !shown && kind == 0
    }
}

struct SwitcherDesktopLocation: Equatable {
    let display: UInt32, space: UInt64
    let displayNumber: Int, desktopNumber: Int?, spaceOrder: Int
    let isCurrent: Bool, isFullscreen: Bool
    func label(showDisplay: Bool) -> String {
        let desktop = isFullscreen ? "Full-screen Space" : desktopNumber.map{"Desktop \($0)"} ?? "Desktop unavailable"
        let prefix = showDisplay ? (displayNumber>0 && displayNumber != Int.max ? "Display \(displayNumber) · " : "Display unavailable · ") : ""
        return prefix+desktop+(isCurrent ? " · Current" : "")
    }
}
struct SwitcherDesktopGroup {
    let location: SwitcherDesktopLocation
    var indices: [Int]
}
enum SwitcherDesktopGrouping {
    static func groups(_ locations: [SwitcherDesktopLocation]) -> [SwitcherDesktopGroup] {
        var groups: [SwitcherDesktopGroup] = []
        for (index,location) in locations.enumerated() {
            if let group = groups.firstIndex(where:{$0.location.display == location.display && $0.location.space == location.space}) {
                groups[group].indices.append(index)
            } else { groups.append(SwitcherDesktopGroup(location:location,indices:[index])) }
        }
        return groups.sorted {
            if $0.location.displayNumber != $1.location.displayNumber { return $0.location.displayNumber<$1.location.displayNumber }
            if $0.location.spaceOrder != $1.location.spaceOrder { return $0.location.spaceOrder<$1.location.spaceOrder }
            return $0.indices[0]<$1.indices[0]
        }
    }
    static func nextGroupIndex(_ locations: [SwitcherDesktopLocation],selected: Int,direction: Int) -> Int? {
        let groups = groups(locations)
        guard let current = groups.firstIndex(where:{$0.indices.contains(selected)}) else { return groups.first?.indices.first }
        guard groups.count>1 else { return selected }
        let next = (current+direction%groups.count+groups.count)%groups.count
        return groups[next].indices.first
    }
}

enum SwitcherNavigationAction: Equatable {
    case previousWindow, nextWindow, previousDesktop, nextDesktop, select, cancel
    static func key(_ code: UInt16) -> Self? {
        switch code {
        case 126: .previousWindow
        case 125: .nextWindow
        case 123: .previousDesktop
        case 124: .nextDesktop
        case 36,76: .select
        case 53: .cancel
        default: nil
        }
    }
}
