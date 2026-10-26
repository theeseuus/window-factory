import AppKit

extension ShortcutChord {
  var menuKeyEquivalent: String {
    let special: [UInt32: UInt32] = [
      36: 13, 48: 9, 49: 32, 51: 8, 53: 27, 76: 3, 115: 0xF729, 116: 0xF72C, 117: 0xF728,
      119: 0xF72B, 121: 0xF72D, 123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700,
    ]
    if let code = special[key], let scalar = UnicodeScalar(code) { return String(scalar) }
    let functionKeys: [UInt32] = [
      122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]
    if let index = functionKeys.firstIndex(of: key),
      let scalar = UnicodeScalar(0xF704 + UInt32(index))
    {
      return String(scalar)
    }
    if key == 27 { return "-" }
    let label = Self.keyName(key)
    return label.count == 1 ? label.lowercased() : ""
  }
  var menuModifiers: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if modifiers & Self.command != 0 { flags.insert(.command) }
    if modifiers & Self.control != 0 { flags.insert(.control) }
    if modifiers & Self.option != 0 { flags.insert(.option) }
    if modifiers & Self.shift != 0 { flags.insert(.shift) }
    return flags
  }
}

@MainActor
enum MenuShortcut {
  static func apply(_ chord: ShortcutChord?, to item: NSMenuItem) {
    item.keyEquivalent = chord?.menuKeyEquivalent ?? ""
    item.keyEquivalentModifierMask = chord?.menuModifiers ?? []
    item.toolTip = chord?.actionHint
  }
}
