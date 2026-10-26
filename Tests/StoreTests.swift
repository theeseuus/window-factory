import Foundation

@main
enum StoreTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("window-factory-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("native/layouts.json")
        let store = try LayoutStore(url:url)
        var assertions = 0
        func check(_ condition: Bool,_ message: String) { precondition(condition,message); assertions += 1 }
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("Expected rejection") } catch { assertions += 1 }
        }
        check(!FileManager.default.fileExists(atPath:directory.path),"Opening empty library creates no state")
        let recipe = Recipe(name:"Work",capturedAt:"test",windows:[Slot(bundleID:"test.app",appName:"Test",ordinal:1,frame:Frame(x:0,y:0,w:1,h:1))])
        try store.save(recipe,replace:false)
        check(try LayoutStore(url:url).catalog.recipes["Work"] == recipe,"Saved catalog reopens")
        rejects { try store.save(recipe,replace:false) }
        var changed = recipe; changed.windows[0].frame.w = 0.5
        try store.save(changed,replace:true)
        let previousURL = url.deletingLastPathComponent().appendingPathComponent("layouts.previous.json")
        check(try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:previousURL)).recipes["Work"] == recipe,"Replacement preserves prior catalog")
        let importedURL = directory.appendingPathComponent("import.json")
        var imported = Catalog(); imported.recipes["Work"] = recipe
        try imported.encoded().write(to:importedURL)
        let before = try Data(contentsOf:url)
        rejects { try store.importCatalog(importedURL) }
        check(try Data(contentsOf:url) == before,"Conflicting import leaves catalog untouched")
        check(try Data(contentsOf:importedURL) == imported.encoded(),"Import source unchanged")
        var external = Catalog(); external.recipes["Other"] = Recipe(name:"Other",capturedAt:"external",windows:recipe.windows)
        try external.encoded().write(to:url)
        rejects { try store.delete("Work") }
        check(try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:url)) == external,"External edit preserved")
        let reopened = try LayoutStore(url:url); try reopened.delete("Other")
        check(reopened.catalog.recipes.isEmpty,"Deletion persists empty catalog")
        check(try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:previousURL)) == external,"Deletion retains recoverable prior catalog")
        try reopened.save(recipe,replace:false)
        try reopened.rename("Work",to:"Renamed")
        check(reopened.catalog.recipes["Work"]==nil && reopened.catalog.recipes["Renamed"]?.name=="Renamed","rename preserves recipe identity and removes old name")
        check(try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:previousURL)).recipes["Work"]==recipe,"rename keeps recoverable catalog")
        rejects { try reopened.rename("Missing",to:"Other") }
        rejects { try reopened.merge(external);try reopened.rename("Renamed",to:"Other") }
        let beforeConflict=try Data(contentsOf:url)
        var conflict=Catalog();conflict.recipes["Other"]=Recipe(name:"Other",capturedAt:"different",windows:recipe.windows)
        rejects {try reopened.merge(conflict)}
        check(try Data(contentsOf:url)==beforeConflict,"inline conflicting merge preserves all bytes")
        print("native store: \(assertions) assertions passed; temporary state cleaned")
    }
}
