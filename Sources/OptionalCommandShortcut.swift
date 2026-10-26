import AppKit

struct OptionalShortcutEnvelope: Codable {
  let version: Int
  let chord: ShortcutChord
}

enum OptionalCommand: CaseIterable {
  case newCodexWindow, tilingControls
  var definition: ShortcutDefinition {
    switch self {
    case .newCodexWindow:
      return ShortcutDefinition(
        id: "codex.new-window", title: "New Codex Window", group: .library, index: 2,
        standard: ShortcutChord(key: 45, modifiers: ShortcutChord.hyper, name: "N"))
    case .tilingControls:
      return ShortcutDefinition(
        id: "tiling.controls", title: "Open / close Tiling controls", group: .library, index: 3,
        standard: ShortcutChord(key: 35, modifiers: ShortcutChord.hyper, name: "P"))
    }
  }
  var preference: String {
    self == .newCodexWindow ? "codexNewWindowShortcut.v1" : "tilingControlsShortcut.v1"
  }
  var slot: UInt32 { self == .newCodexWindow ? 65 : 66 }
}

// Optional commands keep independent registrations and no assigned default chords.
@MainActor
final class OptionalCommandShortcut {
  let command: OptionalCommand
  var definition: ShortcutDefinition { command.definition }
  private let defaults: UserDefaults, store: KeybindingStore
  private let others: () -> [(String, ShortcutChord)]
  private let live: Bool
  private var ownerEnabled = false
  private(set) var chord: ShortcutChord?
  private(set) var active = false
  private(set) var error: String?
  var action: (() -> Void)?
  var changed: (() -> Void)?
  var reserved: [(String, ShortcutChord)] { chord.map { [(definition.title, $0)] } ?? [] }
  init(
    command: OptionalCommand = .newCodexWindow, defaults: UserDefaults = .standard,
    store: KeybindingStore, live: Bool = true,
    others: @escaping () -> [(String, ShortcutChord)]
  ) {
    self.command = command
    self.defaults = defaults
    self.store = store
    self.live = live
    self.others = others
    if let data = defaults.data(forKey: command.preference) {
      do {
        let value = try JSONDecoder().decode(OptionalShortcutEnvelope.self, from: data)
        guard value.version == 1 else {
          throw FactoryError("Unknown \(definition.title) shortcut format.")
        }
        try validate(value.chord)
        chord = value.chord
      } catch {
        self.error =
          "\(definition.title) shortcut could not be loaded: \(error.localizedDescription)"
      }
    }
  }
  private func validate(_ chord: ShortcutChord) throws {
    try ShortcutValidation.validateLocalCommand(chord)
    try ShortcutValidation.validate(
      store.overrides, additional: others() + [(definition.title, chord)])
  }
  private func register(_ chord: ShortcutChord?, enabled: Bool) throws {
    if live {
      var rollback: Int32 = 0
      let status = WFConfigureApplicationHotKey(
        command.slot, chord?.key ?? 0, chord?.modifiers ?? 0, enabled && chord != nil,
        { _, context in
          MainActor.assumeIsolated {
            let owner = Unmanaged<OptionalCommandShortcut>.fromOpaque(context).takeUnretainedValue()
            owner.action?()
          }
        }, Unmanaged.passUnretained(self).toOpaque(), &rollback)
      guard status == 0 else {
        if rollback != 0 { active = false }
        throw FactoryError(
          "\(definition.title) shortcut is unavailable (status \(status)). Previous settings were kept."
        )
      }
    }
    active = enabled && chord != nil
  }
  func set(_ value: ShortcutChord?) throws {
    let data: Data?
    if let value {
      try validate(value)
      data = try JSONEncoder().encode(OptionalShortcutEnvelope(version: 1, chord: value))
    } else {
      data = nil
    }
    try register(value, enabled: ownerEnabled)
    if let data {
      defaults.set(data, forKey: command.preference)
    } else {
      defaults.removeObject(forKey: command.preference)
    }
    chord = value
    error = nil
    changed?()
  }
  func setOwnerEnabled(_ enabled: Bool) throws {
    guard ownerEnabled != enabled else { return }
    if let chord { try validate(chord) }
    do {
      try register(chord, enabled: enabled)
      ownerEnabled = enabled
      if chord != nil || defaults.object(forKey: command.preference) == nil { error = nil }
      changed?()
    } catch {
      self.error = error.localizedDescription
      changed?()
      throw error
    }
  }
  func stop() {
    try? register(nil, enabled: false)
    ownerEnabled = false
  }
}
