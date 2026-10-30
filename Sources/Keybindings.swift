import Foundation

struct ShortcutChord: Codable,Equatable,Hashable {
    let key: UInt32
    let modifiers: UInt32
    let name: String
    static let command: UInt32 = 256,shift: UInt32 = 512,option: UInt32 = 2048,control: UInt32 = 4096
    static let modifierTracking = 1.0
    static let hyper = command|option|control
    var identity: String { "\(key):\(modifiers)" }
    var modifierLabel: String {
        (modifiers&Self.control != 0 ? "⌃" : "") + (modifiers&Self.option != 0 ? "⌥" : "") +
        (modifiers&Self.shift != 0 ? "⇧" : "") + (modifiers&Self.command != 0 ? "⌘" : "")
    }
    var label: String { modifierLabel.isEmpty ? name : modifierLabel + " " + name }
    var actionHint: String {
        if modifiers == Self.hyper { return "Tab + " + name }
        if modifiers == Self.hyper|Self.shift { return "Tab + Shift + " + name }
        return label
    }
    // Hardware key codes, rather than editable display names, decide which keys
    // can be registered globally without Control, Option or Command.
    static let functionKeys: [UInt32:String] = [122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
    static func keyName(_ code: UInt32) -> String {
        if let functionName = functionKeys[code] { return functionName }
        let names: [UInt32:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"Space",50:"`",51:"⌫",53:"⎋",76:"Enter",115:"Home",116:"Page Up",117:"⌦",119:"End",121:"Page Down",123:"←",124:"→",125:"↓",126:"↑"]
        return names[code] ?? "Key \(code)"
    }
}
enum ShortcutGroup: String,CaseIterable,Codable {
    case geometry,focus,stash,switcher,accordion,spaces,library,system
    var title: String {
        switch self { case .geometry:"Geometry"; case .focus:"Focus"; case .stash:"Stash"; case .switcher:"Switcher"; case .accordion:"Accordion"; case .spaces:"Spaces"; case .library:"Library"; case .system:"System Commands" }
    }
    var signature: UInt32 {
        let value: String
        switch self { case .geometry:value="WFGC"; case .focus:value="WFFC"; case .stash:value="WFST"; case .switcher:value="WFSW"; case .accordion:value="WFAC"; case .spaces:value="WFSM"; case .library:value="WFLA"; case .system:value="WFSY" }
        return value.utf8.reduce(UInt32(0)){($0<<8)|UInt32($1)}
    }
}
struct ShortcutDefinition {
    let id: String,title: String,group: ShortcutGroup,index: UInt32,standard: ShortcutChord
    static var all: [Self] {
        let geometry = GeometryShortcut.all.enumerated().map { index,value in
            Self(id:"geometry.\(value.command.rawValue)",title:value.command.title,group:.geometry,index:UInt32(index),standard:ShortcutChord(key:value.keyCode,modifiers:value.modifiers,name:value.key))
        }
        let others: [(ShortcutGroup,[String],[UInt32])] = [
            (.focus,["Focus left","Focus down","Focus up","Focus right"],[4,38,40,37]),
            (.stash,["Stash / restore"],[1]),(.switcher,["Open / close switcher","Previous window"],[13,13]),
            (.accordion,["Accordion"],[1]),(.spaces,["Move and follow left","Move and follow right"],[123,124]),
            (.library,["Open / close library","Open / close Keyboard Shortcuts"],[15,44])]
        return geometry+others.flatMap { group,titles,keys in
            keys.enumerated().map { index,key in
                let shifted = group == .accordion || (group == .switcher && index == 1)
                return Self(id:"\(group.rawValue).\(index)",title:titles[index],group:group,index:UInt32(index),standard:ShortcutChord(key:key,modifiers:ShortcutChord.hyper|(shifted ? ShortcutChord.shift : 0),name:ShortcutChord.keyName(key)))
            }
        }
    }
}
struct ShortcutEnvelope: Codable { let version: Int; let overrides: [String:ShortcutChord] }
enum ShortcutValidation {
    static func validateLocalCommand(_ chord: ShortcutChord) throws {
        let local: [(UInt32,UInt32,String)] = [(45,ShortcutChord.command,"Capture"),(3,ShortcutChord.command,"Search"),(34,ShortcutChord.command,"Import"),(14,ShortcutChord.command|ShortcutChord.shift,"Export"),(51,ShortcutChord.command,"Delete layout"),(36,ShortcutChord.command,"Establish"),(0,ShortcutChord.command|ShortcutChord.shift,"Applications search"),(125,ShortcutChord.option,"Move layout down"),(126,ShortcutChord.option,"Move layout up")]
        if let command=local.first(where:{$0.0==chord.key && $0.1==chord.modifiers}) {throw FactoryError("\(chord.label) is used by \(command.2) inside Window Factory.")}
    }
    static func validate(_ overrides: [String:ShortcutChord],additional: [(String,ShortcutChord)] = []) throws {
        let definitions = ShortcutDefinition.all
        guard Set(overrides.keys).isSubset(of:Set(definitions.map(\.id))) else { throw FactoryError("Unknown shortcut command.") }
        var used: [String:String] = [:]
        for (title,chord) in definitions.map({ ($0.title,overrides[$0.id] ?? $0.standard) }) + additional {
            guard chord.key<=127,chord.modifiers & ~(ShortcutChord.hyper|ShortcutChord.shift) == 0,
                  (chord.modifiers&ShortcutChord.hyper != 0 || ShortcutChord.functionKeys[chord.key] != nil),chord.key != 53,
                  !chord.name.isEmpty,chord.name.count<=16,!chord.name.unicodeScalars.contains(where:{$0.value<32}) else { throw FactoryError("Use a function key, or another key with Control, Option or Command.") }
            if chord.key == 15 && chord.modifiers == ShortcutChord.hyper|ShortcutChord.shift { throw FactoryError("\(chord.label) is a historically reserved binding.") }
            if (chord.key == 123 || chord.key == 124 || chord.key == 125 || chord.key == 126) && chord.modifiers == ShortcutChord.control { throw FactoryError("\(chord.label) is reserved for macOS desktop navigation.") }
            if (chord.key == 48 || chord.key == 49) && (chord.modifiers == ShortcutChord.command || chord.modifiers == ShortcutChord.command|ShortcutChord.shift) { throw FactoryError("\(chord.label) is reserved by macOS.") }
            if [UInt32(12),13,43].contains(chord.key) && chord.modifiers == ShortcutChord.command { throw FactoryError("\(chord.label) is reserved for standard app commands.") }
            if let title = used[chord.identity] { throw FactoryError("\(chord.label) is already used by \(title).") }
            used[chord.identity] = title
        }
    }
}
@MainActor
final class KeybindingStore {
    private let defaults: UserDefaults
    private(set) var overrides: [String:ShortcutChord] = [:]
    private(set) var loadError: String?
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey:"shortcutOverrides.v1") {
            do {
                let envelope = try JSONDecoder().decode(ShortcutEnvelope.self,from:data)
                guard envelope.version == 1 else { throw FactoryError("Unknown shortcut format.") }
                try ShortcutValidation.validate(envelope.overrides); overrides = envelope.overrides
            } catch { loadError = "Saved shortcuts could not be read. Defaults are active." }
        }
    }
    func chord(_ definition: ShortcutDefinition) -> ShortcutChord { overrides[definition.id] ?? definition.standard }
    func commit(_ draft: [String:ShortcutChord],data: Data) { defaults.set(data,forKey:"shortcutOverrides.v1"); overrides = draft; loadError = nil }
    func save(_ draft: [String:ShortcutChord]) throws {
        try ShortcutValidation.validate(draft)
        let data = try JSONEncoder().encode(ShortcutEnvelope(version:1,overrides:draft))
        commit(draft,data:data)
    }
}
