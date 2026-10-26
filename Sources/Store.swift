import Foundation

@MainActor
final class LayoutStore {
    let url: URL
    var catalog = Catalog()
    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath:url.path) { catalog = try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:url)) }
    }
    func replace(_ catalog: Catalog) throws {
        let data = try catalog.encoded()
        if FileManager.default.fileExists(atPath:url.path) {
            let previous = try Data(contentsOf:url)
            guard try JSONDecoder().decode(Catalog.self,from:previous) == self.catalog else {
                throw FactoryError("The native catalog changed on disk. Reopen before saving.")
            }
            try previous.write(to:url.deletingLastPathComponent().appendingPathComponent("layouts.previous.json"),options:.atomic)
        }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
        guard try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:url)) == catalog else {
            throw FactoryError("Saved catalog could not be verified.")
        }
        self.catalog = catalog
    }
    func save(_ recipe: Recipe,replace: Bool) throws {
        try recipe.validate()
        guard replace || catalog.recipes[recipe.name] == nil else { throw FactoryError("A layout with that name already exists.") }
        var copy = catalog; copy.recipes[recipe.name] = recipe; try self.replace(copy)
    }
    func rename(_ name: String,to newName: String) throws {
        guard let recipe=catalog.recipes[name],catalog.recipes[newName]==nil else{throw FactoryError("Source layout is missing or destination exists.")}
        var copy=catalog;copy.recipes.removeValue(forKey:name);var renamed=recipe;renamed.name=newName;try renamed.validate();copy.recipes[newName]=renamed;try replace(copy)
    }
    func delete(_ name: String) throws {
        var copy = catalog; copy.recipes.removeValue(forKey:name); try replace(copy)
    }
    func importCatalog(_ url: URL) throws {
        guard url.standardizedFileURL != self.url.standardizedFileURL else { return }
        let imported = try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:url))
        try merge(imported)
    }
    func merge(_ imported: Catalog) throws {
        try imported.validate()
        var copy = catalog
        for (name,recipe) in imported.recipes {
            guard copy.recipes[name] == nil || copy.recipes[name] == recipe else {
                throw FactoryError("Import stopped: \(name) conflicts with an existing layout.")
            }
            copy.recipes[name] = recipe
        }
        try replace(copy)
    }
}
