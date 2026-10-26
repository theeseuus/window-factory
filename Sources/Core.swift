import Foundation

struct FactoryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Frame: Codable, Equatable {
    var x: Double, y: Double, w: Double, h: Double
    var valid: Bool { [x,y,w,h].allSatisfy(\.isFinite) && w > 0 && h > 0 }
    func isVisible(in screen: Frame) -> Bool {
        guard valid, screen.valid else { return false }
        // A tall window can be dragged low enough that its centre is offscreen
        // while its title bar remains visible. It must still be restorable.
        return min(x+w,screen.x+screen.w) > max(x,screen.x)
            && min(y+h,screen.y+screen.h) > max(y,screen.y)
    }
    func normalized(in screen: Frame) -> Frame {
        Frame(x:(x-screen.x)/screen.w,y:(y-screen.y)/screen.h,w:w/screen.w,h:h/screen.h)
    }
    func absolute(in screen: Frame) -> Frame {
        let width = max(1,min(screen.w,w*screen.w)), height = max(1,min(screen.h,h*screen.h))
        return Frame(x:max(screen.x,min(screen.x+screen.w-width,screen.x+x*screen.w)),
                     y:max(screen.y,min(screen.y+screen.h-height,screen.y+y*screen.h)),w:width,h:height)
    }
    func matches(_ other: Frame, tolerance: Double = 2) -> Bool {
        zip([x,y,w,h],[other.x,other.y,other.w,other.h]).allSatisfy { abs($0-$1) <= tolerance }
    }
    func cost(to other: Frame) -> Double {
        let dx = x+w/2-other.x-other.w/2, dy = y+h/2-other.y-other.h/2
        return dx*dx+dy*dy+pow(w-other.w,2)+pow(h-other.h,2)
    }
    static func precedes(_ a: Frame,_ b: Frame) -> Bool {
        for (x,y) in zip([a.y,a.x,a.h,a.w],[b.y,b.x,b.h,b.w]) { if x != y { return x < y } }
        return false
    }
}

struct Slot: Codable, Equatable {
    var bundleID: String, appName: String
    var ordinal: Int
    var frame: Frame
}

struct Recipe: Codable, Equatable {
    var schemaVersion = 1
    var name: String, capturedAt: String
    var windows: [Slot]
    static func normalizedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 80,
              !name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {
            throw FactoryError("Use a name of 1–80 bytes without control characters.")
        }
        return name
    }
    func validate() throws {
        guard schemaVersion == 1, try Self.normalizedName(name) == name,
              !capturedAt.isEmpty, !windows.isEmpty else { throw FactoryError("Invalid layout or unsupported version.") }
        var seen = Set<String>()
        for slot in windows {
            guard !slot.bundleID.isEmpty, !slot.appName.isEmpty, slot.ordinal > 0, slot.frame.valid,
                  seen.insert("\(slot.bundleID)\0\(slot.ordinal)").inserted else {
                throw FactoryError("Invalid or duplicate application slot.")
            }
        }
    }
    var summary: String {
        Dictionary(grouping:windows,by:\.bundleID).values.map {
            $0[0].appName + ($0.count > 1 ? " × \($0.count)" : "")
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator:", ")
    }
}

struct Catalog: Codable, Equatable {
    var schemaVersion = 1
    var recipes: [String:Recipe] = [:]
    init() {}
    enum CodingKeys: String, CodingKey { case schemaVersion, recipes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion = try c.decode(Int.self,forKey:.schemaVersion)
        if let dictionary = try? c.decode([String:Recipe].self,forKey:.recipes) { recipes = dictionary }
        else {
            let array = try c.decode([Recipe].self,forKey:.recipes)
            guard array.isEmpty else { throw FactoryError("Expected layouts keyed by name.") }
        }
        try validate()
    }
    func validate() throws {
        guard schemaVersion == 1 else { throw FactoryError("Unsupported catalog version.") }
        for (key,recipe) in recipes {
            try recipe.validate()
            guard key == recipe.name else { throw FactoryError("Catalog name mismatch.") }
        }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try encoder.encode(self)
    }
}

struct Candidate: Equatable {
    let id: UInt32
    let bundleID: String
    let frame: Frame
}
struct Assignment { let slot: Slot; let candidate: Candidate }
struct Match {
    var assignments: [Assignment] = []
    var missing: [Slot] = []
    var extras: [Candidate] = []
}
func match(_ recipe: Recipe,_ candidates: [Candidate]) -> Match {
    let ordered = candidates.enumerated().sorted {
        if $0.element.bundleID != $1.element.bundleID { return $0.element.bundleID < $1.element.bundleID }
        if $0.element.frame != $1.element.frame { return Frame.precedes($0.element.frame,$1.element.frame) }
        return $0.offset < $1.offset
    }.map(\.element)
    var used = Set<UInt32>(), result = Match()
    for slot in recipe.windows {
        var best: Candidate?
        for candidate in ordered where candidate.bundleID == slot.bundleID && !used.contains(candidate.id) {
            if best == nil || slot.frame.cost(to:candidate.frame) < slot.frame.cost(to:best!.frame) { best = candidate }
        }
        if let best { used.insert(best.id); result.assignments.append(Assignment(slot:slot,candidate:best)) }
        else { result.missing.append(slot) }
    }
    result.extras = ordered.filter { !used.contains($0.id) }
    return result
}

struct Adapter: Codable {
    let bundleID: String, name: String, kind: String
    let menu: [String]?, script: String?, selector: String?, requirement: String?, reason: String?, placementPolicy: String?
}
struct AdapterRegistry: Codable {
    let schemaVersion: Int
    let adapters: [Adapter]
    func validate() throws {
        guard schemaVersion == 1, !adapters.isEmpty,
              Set(adapters.map(\.bundleID)).count == adapters.count else { throw FactoryError("Invalid adapter registry.") }
        for a in adapters {
            guard !a.bundleID.isEmpty, !a.name.isEmpty,
                  (a.kind == "menu" && ((a.menu?.count == 2) || a.selector == "safari-default-profile"))
                  || (a.kind == "applescript" && !(a.script ?? "").isEmpty)
                  || (a.kind == "launch-only" && !(a.reason ?? "").isEmpty) else {
                throw FactoryError("Invalid adapter: \(a.bundleID)")
            }
        }
    }
}
