import Foundation

struct IndicatorSpace {
    let id: UInt64
    let kind: Int
    let shown: Bool
}
struct SpaceIndicatorState: Equatable {
    let label: String
    let tooltip: String
    static func resolve(_ entries: [IndicatorSpace]?,display: String) -> Self {
        guard let entries,!entries.isEmpty,entries.allSatisfy({$0.id != 0}),
              Set(entries.map(\.id)).count == entries.count else {
            return Self(label:"?",tooltip:"Could not read active Space — \(display)")
        }
        let shown = entries.filter(\.shown)
        guard shown.count == 1,let current = shown.first else {
            return Self(label:"?",tooltip:"Active Space is unavailable or ambiguous — \(display)")
        }
        if current.kind == 4 { return Self(label:"—",tooltip:"Active Space is full-screen or tiled — \(display)") }
        let users = entries.filter{$0.kind == 0}
        guard current.kind == 0,let index = users.firstIndex(where:{$0.id == current.id}) else {
            return Self(label:"?",tooltip:"Active Space type is unavailable — \(display)")
        }
        return Self(label:String(index+1),tooltip:"Active user Space \(index+1) of \(users.count) — \(display)")
    }
}
