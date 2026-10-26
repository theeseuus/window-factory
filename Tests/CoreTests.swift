import Foundation

@main
enum CoreTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: Bool,_ message: String) {
            precondition(condition,message); assertions += 1
        }
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("Expected rejection") } catch { assertions += 1 }
        }
        let screen = Frame(x:100,y:40,w:1200,h:800)
        let rect = Frame(x:700,y:40,w:600,h:800)
        check(Frame(x:200,y:650,w:600,h:800).isVisible(in:screen),"Low window remains eligible with centre below screen")
        check(Frame(x:-450,y:80,w:600,h:500).isVisible(in:screen),"Partly visible side window remains eligible")
        check(!Frame(x:200,y:840,w:600,h:800).isVisible(in:screen),"Touching bottom edge has no visible area")
        check(!Frame(x:1400,y:80,w:600,h:500).isVisible(in:screen),"Window entirely on another display excluded")
        check(!Frame(x:200,y:950,w:600,h:800).isVisible(in:screen),"Entirely offscreen window excluded")
        check(!Frame(x:200,y:100,w:0,h:500).isVisible(in:screen),"Invalid geometry excluded")
        check(rect.normalized(in:screen).absolute(in:screen) == rect,"Coordinate round trip")
        check(Frame(x:2,y:-1,w:3,h:4).absolute(in:screen) == screen,"Clamp oversized/offscreen target")
        check(try Recipe.normalizedName("  Work  ") == "Work","Name trim")
        rejects { _ = try Recipe.normalizedName("\n") }
        rejects { _ = try Recipe.normalizedName("Bad\nName") }
        rejects { _ = try Recipe.normalizedName(String(repeating:"界",count:27)) }
        let left = Frame(x:0,y:0,w:0.5,h:1), right = Frame(x:0.5,y:0,w:0.5,h:1)
        let recipe = Recipe(name:"Work",capturedAt:"2026-10-23",windows:[
            Slot(bundleID:"app.a",appName:"A",ordinal:1,frame:left),
            Slot(bundleID:"app.a",appName:"A",ordinal:2,frame:right)])
        try recipe.validate()
        let matched = match(recipe,[Candidate(id:3,bundleID:"app.b",frame:left),
            Candidate(id:2,bundleID:"app.a",frame:right),Candidate(id:1,bundleID:"app.a",frame:left)])
        check(matched.assignments.map(\.candidate.id) == [1,2],"Nearest geometry, independent of candidate order")
        check(matched.extras.map(\.id) == [3],"Other app preserved as extra")
        let missing = match(recipe,[Candidate(id:1,bundleID:"app.a",frame:left)])
        check(missing.missing.count == 1 && missing.assignments.count == 1,"No candidate reused")
        var duplicate = recipe; duplicate.windows[1].ordinal = 1
        rejects { try duplicate.validate() }
        var invalid = recipe; invalid.windows[0].frame.w = 0
        rejects { try invalid.validate() }
        var catalog = Catalog(); catalog.recipes[recipe.name] = recipe
        check(try JSONDecoder().decode(Catalog.self,from:catalog.encoded()) == catalog,"Schema-v1 round trip")
        check(try JSONDecoder().decode(Catalog.self,from:Data(#"{"schemaVersion":1,"recipes":[]}"#.utf8)).recipes.isEmpty,"Lua empty-array catalog")
        rejects { _ = try JSONDecoder().decode(Catalog.self,from:Data(#"{"schemaVersion":2,"recipes":{}}"#.utf8)) }
        var mismatch = catalog; mismatch.recipes = ["Other":recipe]
        rejects { try mismatch.validate() }
        let url = URL(fileURLWithPath:CommandLine.arguments[1])
        let registry = try JSONDecoder().decode(AdapterRegistry.self,from:Data(contentsOf:url)); try registry.validate()
        check(registry.adapters.count == 16,"Full existing registry")
        check(registry.adapters.first(where:{$0.bundleID == "com.anthropic.claudefordesktop"})?.kind == "launch-only","Claude limitation retained")
        check(registry.adapters.first(where:{$0.bundleID == "com.apple.Safari"})?.selector == "safari-default-profile","Safari default profile retained")
        check(registry.adapters.first(where:{$0.bundleID == "com.superlogical.rex"})?.placementPolicy == "position-only-when-sized","Rex placement policy retained")
        check(registry.adapters.first(where:{$0.bundleID == "com.microsoft.Powerpoint"}) != nil,"Exact PowerPoint bundle identity")
        check(registry.adapters.first(where:{$0.bundleID == "com.apple.mail"})?.menu == ["File","New Viewer Window"],"Mail never creates compose window")
        check(registry.adapters.first(where:{$0.bundleID == "com.mitchellh.ghostty"})?.requirement == "ghostty-applescript-1.3","Ghostty version gate")
        print("native core: \(assertions) assertions passed; all 16 adapters decoded")
    }
}
