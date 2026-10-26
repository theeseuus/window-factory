import Foundation
@main enum SpaceIndicatorTests {
    static func main() {
        var assertions = 0
        func check(_ value: Bool,_ label: String) { precondition(value,label); assertions += 1 }
        for count in 1...32 {
            for current in 0..<count {
                var entries = (0..<count).map{IndicatorSpace(id:UInt64(10000-$0*7),kind:0,shown:$0 == current)}
                entries.insert(IndicatorSpace(id:20000,kind:4,shown:false),at:0)
                let state = SpaceIndicatorState.resolve(entries,display:"Test Display")
                check(state.label == String(current+1),"ordinal follows user desktop order, excluding fullscreen and opaque IDs")
                check(state.tooltip == "Active user Space \(current+1) of \(count) — Test Display","accurate count and display tooltip")
            }
        }
        for entries in [nil,[],[IndicatorSpace(id:0,kind:0,shown:true)],
                        [IndicatorSpace(id:1,kind:0,shown:true),IndicatorSpace(id:1,kind:0,shown:false)],
                        [IndicatorSpace(id:1,kind:0,shown:false)],
                        [IndicatorSpace(id:1,kind:0,shown:true),IndicatorSpace(id:2,kind:0,shown:true)],
                        [IndicatorSpace(id:1,kind:99,shown:true)]] as [[IndicatorSpace]?] {
            check(SpaceIndicatorState.resolve(entries,display:"Display").label == "?","unavailable/ambiguous state must not invent a desktop number")
        }
        let full = SpaceIndicatorState.resolve([IndicatorSpace(id:1,kind:0,shown:false),IndicatorSpace(id:2,kind:4,shown:true)],display:"Display")
        check(full.label == "—" && full.tooltip.contains("full-screen or tiled"),"fullscreen/tiled marker")
        print("native Space indicator: \(assertions) assertions passed; no desktop queries or status items")
    }
}
