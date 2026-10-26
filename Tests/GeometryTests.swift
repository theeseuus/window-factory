import Foundation

struct GeometryCase: Decodable { let command: GeometryCommand; let frame,screen,expected: Frame }
@main enum GeometryTests {
    static func main() throws {
        let cases = try JSONDecoder().decode([GeometryCase].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        var assertions = 0
        func check(_ condition: Bool,_ message: String) { precondition(condition,message); assertions += 1 }
        for item in cases {
            let actual = DirectGeometry.canonicalCycle(item.command,frame:item.frame,screen:item.screen)
            check(actual.matches(item.expected,tolerance:0.00001),"Lua geometry compatibility: \(item.command.rawValue) at \(item.frame)")
        }
        check(GeometryShortcut.all.count == 19,"Complete geometry shortcut group")
        check(Set(GeometryShortcut.all.map { "\($0.keyCode):\($0.modifiers)" }).count == 19,"No duplicate shortcuts")
        check(Set(GeometryShortcut.all.map(\.command)) == Set(GeometryCommand.allCases),"Every command has one binding")
        check(DirectGeometry.nextIndex(nil,count:8,reverse:false) == 0,"Fresh forward starts first")
        check(DirectGeometry.nextIndex(nil,count:8,reverse:true) == 7,"Fresh reverse starts last")
        check(DirectGeometry.nextIndex(0,count:8,reverse:true) == 7,"Reverse wraps")
        // The Lua legacy engine intentionally shares its index across sizes.
        check(DirectGeometry.nextIndex(1,count:3,reverse:false) == 2,"Changing legacy cycle keeps shared index")
        let screen = Frame(x:100,y:40,w:1200,h:800), frame = Frame(x:150,y:250,w:400,h:300)
        check(DirectGeometry.centerHorizontally(frame,in:screen) == Frame(x:500,y:250,w:400,h:300),"Horizontal centre preserves y and size")
        check(DirectGeometry.adjustWidth(frame,in:screen,direction:1) == Frame(x:110,y:250,w:480,h:300),"Width grows by 80 around centre")
        check(DirectGeometry.adjustWidth(frame,in:screen,direction:-1) == Frame(x:170,y:250,w:360,h:300),"Width minimum 360")
        check(DirectGeometry.adjustWidth(Frame(x:500,y:50,w:1190,h:500),in:screen,direction:1).w == 1200,"Width bounded by screen")
        check(DirectGeometry.legacySlots(.halvesNext)?.count == 2 && DirectGeometry.legacySlots(.thirdsNext)?.count == 3,"Legacy halves and thirds")
        check(DirectGeometry.legacySlots(.eighthsNext)?.last == Frame(x:0,y:0.5,w:0.25,h:0.5),"Eighth clockwise perimeter")
        print("native geometry: \(assertions) assertions passed, including \(cases.count) comparisons against existing Lua geometry")
    }
}
