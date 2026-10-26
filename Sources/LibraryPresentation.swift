import AppKit

enum LibraryPresentation {
    static func ordered(_ recipes: [Recipe],savedOrder: [String],query: String) -> [Recipe] {
        let ranks = Dictionary(savedOrder.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:{ first,_ in first })
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        func match(_ recipe: Recipe) -> Int {
            if query.isEmpty { return 0 }
            if recipe.name.compare(query,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame { return 0 }
            if recipe.name.localizedCaseInsensitiveContains(query) { return 1 }
            return 2
        }
        return recipes.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
            .sorted { a,b in
                if match(a) != match(b) { return match(a)<match(b) }
                let ar = ranks[a.name] ?? Int.max,br = ranks[b.name] ?? Int.max
                if ar != br { return ar<br }
                let comparison = a.name.localizedCaseInsensitiveCompare(b.name)
                return comparison == .orderedSame ? a.name<b.name : comparison == .orderedAscending
            }
    }
    static func moving(_ names: [String],name: String,to insertion: Int) -> [String]? {
        guard let source = names.firstIndex(of:name),insertion>=0,insertion<=names.count else { return nil }
        var result = names; result.remove(at:source)
        result.insert(name,at:insertion>source ? insertion-1 : insertion)
        return result
    }
    static func canvas(in bounds: NSRect,inset: CGFloat,aspect: Double) -> NSRect {
        let area = bounds.insetBy(dx:inset,dy:inset)
        guard area.width>0,area.height>0,aspect.isFinite,aspect>0 else { return .zero }
        let width = min(area.width,area.height*aspect),height = width/aspect
        return NSRect(x:area.midX-width/2,y:area.midY-height/2,width:width,height:height)
    }
}
