import Foundation
@main enum SwitcherTests {
 static func main() {
    var assertions = 0
    func check(_ condition: Bool,_ label: String) { precondition(condition,label); assertions += 1 }
    for count in 1...8 {
        let ids = (1...count).map{UInt32($0)}
        for current in 0..<count { for direction in [-1,1] {
            var selection = SwitcherSelection(ids:ids,current:ids[current],direction:direction)
            check(selection.selected == ids[(current+direction+count)%count],"Fresh forward/reverse selection matches original switcher")
            for step in 1...count*2 {
                selection.advance(direction)
                let expected = ((current+(step+1)*direction)%count+count)%count
                check(selection.selected == ids[expected],"Repeated cycle wraps")
            }
            let before = selection.selected
            selection.advance(-direction); selection.advance(direction)
            check(selection.selected == before,"Direction change is reversible in frozen session")
        } }
    }
    check(SwitcherSelection(ids:[],current:nil,direction:1).selected == nil,"Empty list")
    check(SwitcherSelection(ids:[2,3],current:nil,direction:1).selected == 2,"Absent source forward selects first")
    check(SwitcherSelection(ids:[2,3],current:99,direction:-1).selected == 3,"Absent source reverse selects last")
    check(SwitcherSelection(ids:[1,1,2],current:1,direction:1).selected == 2,"Deduplicate identities")
    var recency = WindowRecency(); recency.note(3); recency.note(2); recency.note(3)
    check(recency.ids == [3,2],"Latest focus promoted without duplicate")
    check(recency.ordered([1,2,3,4],current:1) == [1,3,2,4],"Current first, observed recency, initial stacking order")
    check(recency.ordered([1,4,4],current:99) == [1,4],"Closed candidates and absent source excluded")
    for id in 1...600 { recency.note(UInt32(id)) }
    check(recency.ids.count == 512 && recency.ids.first == 600,"Bounded memory-only history")
    check(SwitcherDiscovery.accepts(space:4,membership:[4],kind:0,shown:false,isUp:true,standardAX:false,rejectedAX:false),"Regression: live away window absent from AX is discoverable")
    check(!SwitcherDiscovery.accepts(space:4,membership:[4],kind:0,shown:false,isUp:false,standardAX:false,rejectedAX:false),"Parked or closed compositor windows excluded")
    check(!SwitcherDiscovery.accepts(space:4,membership:[4],kind:0,shown:true,isUp:true,standardAX:false,rejectedAX:false),"Shown desktop requires exact standard AX window")
    check(SwitcherDiscovery.accepts(space:4,membership:[4],kind:0,shown:true,isUp:true,standardAX:true,rejectedAX:false),"Shown standard window retained")
    check(!SwitcherDiscovery.accepts(space:4,membership:[4,5],kind:0,shown:false,isUp:true,standardAX:false,rejectedAX:false),"Ambiguous membership refused")
    check(!SwitcherDiscovery.accepts(space:4,membership:[],kind:0,shown:false,isUp:true,standardAX:false,rejectedAX:false),"Ghost metadata absent from live membership refused")
    check(!SwitcherDiscovery.accepts(space:4,membership:[5],kind:0,shown:false,isUp:true,standardAX:false,rejectedAX:false),"Wrong desktop membership refused")
    check(!SwitcherDiscovery.accepts(space:4,membership:[4],kind:0,shown:false,isUp:true,standardAX:true,rejectedAX:true),"Known nonstandard or minimized AX window refused")
    check(!SwitcherDiscovery.accepts(space:4,membership:[4],kind:2,shown:false,isUp:true,standardAX:false,rejectedAX:false),"Unsupported Space kind refused")
    check(!SwitcherDiscovery.accepts(space:4,membership:[4],kind:4,shown:false,isUp:true,standardAX:false,rejectedAX:false),"No unproven metadata-only fullscreen visit")
    check(SwitcherDiscovery.accepts(space:4,membership:[4],kind:4,shown:true,isUp:true,standardAX:true,rejectedAX:false),"Known fullscreen AX window retained")
    func place(_ desktop: Int,_ space: UInt64,_ shown: Bool = false,_ display: UInt32 = 1,_ displayNumber: Int = 1) -> SwitcherDesktopLocation {
        SwitcherDesktopLocation(display:display,space:space,displayNumber:displayNumber,desktopNumber:desktop,spaceOrder:desktop,isCurrent:shown,isFullscreen:false)
    }
    let locations = [place(3,900,true),place(1,700),place(3,900,true),place(2,800),place(1,700)]
    let groups = SwitcherDesktopGrouping.groups(locations)
    check(groups.map{$0.location.desktopNumber} == [1,2,3],"Desktop groups follow native desktop numbers, not private IDs or MRU")
    check(groups.flatMap(\.indices) == [1,4,3,0,2],"Within-desktop recency and exact source indices preserved")
    check(Set(groups.flatMap(\.indices)) == Set(locations.indices),"No duplicate or missing window from grouping")
    check(SwitcherDesktopGrouping.nextGroupIndex(locations,selected:0,direction:1) == 1,"Right arrow wraps to first desktop")
    check(SwitcherDesktopGrouping.nextGroupIndex(locations,selected:1,direction:-1) == 0,"Left arrow wraps to last desktop")
    check(SwitcherDesktopGrouping.nextGroupIndex([place(1,7),place(1,7)],selected:1,direction:1) == 1,"One desktop jump leaves selected window unchanged")
    check(SwitcherDesktopGrouping.groups([]).isEmpty,"Empty grouping")
    let multi = [place(1,7,false,2,2),place(2,8,false,1,1),place(1,9,false,1,1)]
    check(SwitcherDesktopGrouping.groups(multi).flatMap(\.indices) == [2,1,0],"Display then native desktop order")
    check(place(3,999,true).label(showDisplay:false) == "Desktop 3 · Current","Current desktop label uses ordinal")
    check(place(3,999,false,2,2).label(showDisplay:true) == "Display 2 · Desktop 3","Multiple displays disambiguated")
    let fullscreen = SwitcherDesktopLocation(display:1,space:333,displayNumber:1,desktopNumber:nil,spaceOrder:4,isCurrent:false,isFullscreen:true)
    check(fullscreen.label(showDisplay:false) == "Full-screen Space","Fullscreen never mislabeled as ordinary desktop")
    let unknown = SwitcherDesktopLocation(display:1,space:987654,displayNumber:Int.max,desktopNumber:nil,spaceOrder:Int.max,isCurrent:false,isFullscreen:false)
    check(unknown.label(showDisplay:true) == "Display unavailable · Desktop unavailable","Missing labels never expose sentinel or private Space IDs")
    var grouped = SwitcherSelection(ids:[20,21,30,40,41],current:40,direction:1)
    check(grouped.selected == 41,"Current window remains selection anchor after grouping")
    grouped.select(20); check(grouped.selected == 20,"Desktop jump selects exact row identity")
    grouped.advance(-1); check(grouped.selected == 41,"Up arrow wraps grouped rows")
    check(SwitcherNavigationAction.key(36) == .select && SwitcherNavigationAction.key(76) == .select,"Return and keypad Enter both select")
    check(SwitcherNavigationAction.key(53) == .cancel,"Escape dismisses")
    check(SwitcherNavigationAction.key(125) == .nextWindow && SwitcherNavigationAction.key(126) == .previousWindow,"Vertical arrows walk windows")
    check(SwitcherNavigationAction.key(123) == .previousDesktop && SwitcherNavigationAction.key(124) == .nextDesktop,"Horizontal arrows walk desktop groups")
    check(SwitcherNavigationAction.key(13) == nil,"Plain W is not mistaken for arrow or selection")
    print("native window switching: \(assertions) assertions passed")
 }
}
