import AppKit

@main
struct NewWindowTests {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ message: String) {
      count += 1
      precondition(value, message)
    }
    let registry = try JSONDecoder().decode(
      AdapterRegistry.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let adapters = Dictionary(uniqueKeysWithValues: registry.adapters.map { ($0.bundleID, $0) })
    let target = NewWindowTarget(display: 1, space: 7, frame: Frame(x: 0, y: 30, w: 1800, h: 1100))
    var here = target
    var ids: Set<UInt32> = [1, 2]
    var creates = 0
    var prepares = 0
    var waits = 0
    var blocked = false
    var mode = "success"
    let backend = NewWindowBackend(
      target: { here },
      prepare: { _, expected in
        prepares += 1
        guard here == expected, mode != "prepare-fail" else {
          throw FactoryError("context or permission changed")
        }
      },
      inventory: { _, expected in
        guard here == expected else { throw FactoryError("context changed") }
        return ids
      },
      create: { adapter, _ in
        check(
          adapter.bundleID == "com.openai.codex" && adapter.menu == ["File", "New Window"],
          "exact canonical Codex adapter reused")
        creates += 1
        if mode == "success" { ids.insert(UInt32(100 + creates)) }
        if mode == "late-error" {
          ids.insert(200)
          throw FactoryError("uncertain dispatch")
        }
        if mode == "multiple" { ids.formUnion([300, 301]) }
        if mode == "space-change" {
          here = NewWindowTarget(display: 1, space: 8, frame: target.frame)
        }
      },
      wait: {
        waits += 1
        try Task.checkCancellation()
      })
    let action = NewWindowAction(adapters: adapters, backend: backend)
    action.blocked = { blocked }
    func settle() async throws {
      for _ in 0..<100 {
        if !action.isBusy { return }
        try await Task.sleep(for: .milliseconds(5))
      }
      preconditionFailure("new-window fixture did not settle")
    }
    check(creates == 0, "construction never opens a window")
    blocked = true
    action.run("com.openai.codex")
    check(!action.isBusy && creates == 0, "busy owners prevent dispatch")
    blocked = false
    action.run("unknown.app")
    check(creates == 0, "unreviewed app rejected")
    action.run("com.openai.codex")
    action.run("com.openai.codex")
    try await settle()
    check(
      creates == 1 && action.receipt?.windowID == 101, "repeated trigger while busy dispatches once"
    )
    check(
      action.receipt?.target == target && ids.contains(1) && ids.contains(2),
      "receipt retains captured desktop and existing IDs")
    check(
      action.dispatched && !action.isBusy && prepares == 2,
      "checks occur before the single dispatch")
    mode = "prepare-fail"
    action.run("com.openai.codex")
    try await settle()
    check(
      creates == 1 && !action.dispatched && action.receipt == nil,
      "preflight failure leaves app untouched")
    mode = "late-error"
    action.run("com.openai.codex")
    try await settle()
    check(
      creates == 2 && action.dispatched && action.receipt == nil && ids.contains(200),
      "uncertain command is never retried or cleaned up")
    mode = "timeout"
    waits = 0
    action.run("com.openai.codex")
    try await settle()
    check(
      creates == 3 && waits == 50 && action.receipt == nil,
      "bounded discovery timeout does not repeat creation")
    mode = "space-change"
    action.run("com.openai.codex")
    try await settle()
    check(
      creates == 4 && action.receipt == nil,
      "desktop change stops confirmation without follow or retry")
    here = target
    mode = "multiple"
    action.run("com.openai.codex")
    try await settle()
    check(
      creates == 5 && action.receipt == nil,
      "ambiguous multiple arrivals are not claimed as one creation")
    action.stop()
    let dock = WindowCreationMenus.dock(
      target: nil, open: NSSelectorFromString("open:"), create: NSSelectorFromString("create:"),
      available: false)
    check(
      dock.items.map(\.title) == ["Open Window Factory", "New Codex Window"],
      "only Window Factory's own Dock menu is provided")
    check(
      !dock.autoenablesItems && !dock.items[1].isEnabled,
      "Dock command remains disabled when unavailable")
    let menu = SpaceIndicator.menu(target: nil)
    check(
      menu.items.contains {
        $0.identifier?.rawValue == "codex.new-window" && $0.title == "New Codex Window"
      }, "menu-bar action is discoverable")
    let suite = "local.windowfactory.new-window-shortcut.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let keys = KeybindingStore(defaults: defaults)
    let appChord = ShortcutChord(key: 17, modifiers: ShortcutChord.hyper, name: "T")
    let key = OptionalCommandShortcut(
      defaults: defaults, store: keys, live: false, others: { [("Rex", appChord)] })
    check(
      key.chord == nil && !key.active
        && defaults.object(forKey: "codexNewWindowShortcut.v1") == nil,
      "command starts unassigned without writing preferences")
    try key.setOwnerEnabled(true)
    let chosen = ShortcutChord(key: 16, modifiers: ShortcutChord.hyper, name: "Y")
    try key.set(chosen)
    let saved = defaults.data(forKey: "codexNewWindowShortcut.v1")!
    check(
      key.chord == chosen && key.active,
      "recording enables optional key only within enabled Library group")
    let reloaded = OptionalCommandShortcut(
      defaults: defaults, store: keys, live: false, others: { [("Rex", appChord)] })
    try reloaded.setOwnerEnabled(true)
    check(reloaded.chord == chosen && reloaded.active, "optional binding survives restart")
    for rejected in [
      appChord, ShortcutChord(key: 1, modifiers: ShortcutChord.hyper, name: "S"),
      ShortcutChord(key: 45, modifiers: ShortcutChord.command, name: "N"),
      ShortcutChord(key: 15, modifiers: ShortcutChord.hyper | ShortcutChord.shift, name: "R"),
    ] {
      do {
        try key.set(rejected)
        check(false, "clash must fail")
      } catch {
        check(
          key.chord == chosen && defaults.data(forKey: "codexNewWindowShortcut.v1") == saved,
          "failed edit preserves saved binding")
      }
    }
    let manager = KeybindingManager(store: keys)
    manager.additionalShortcuts = { key.reserved }
    do {
      try manager.set(chosen, for: ShortcutDefinition.all.first { $0.id == "library.0" }!)
      check(false, "reverse control clash must fail")
    } catch { check(keys.overrides.isEmpty, "fixed binding cannot steal optional command key") }
    let apps = ApplicationLauncher(defaults: defaults, shortcuts: keys, live: false)
    apps.additionalShortcuts = { key.reserved }
    do {
      try apps.configureSearchShortcut(chosen, enabled: false)
      check(false, "app binding clash must fail")
    } catch {
      check(
        apps.entries.first { $0.isSearch }?.shortcut == nil,
        "app binding cannot steal optional command key")
    }
    let editor = ShortcutEditor(manager: manager)
    editor.optionalCommands = [key]
    editor.groups.selectItem(withTitle: "Library")
    editor.groups.sendAction(editor.groups.action, to: editor.groups.target)
    func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap { descendants($0) }
    }
    let table = descendants(editor.view).compactMap { $0 as? NSTableView }.first!
    check(table.numberOfRows == 3, "Library editor contains optional New Codex Window row")
    let ref = ShortcutReferenceWindow(preferences: FactoryPreferences(defaults: defaults))
    ref.optionalCommands = [key]
    ref.refresh()
    let text = descendants(ref.window.contentView!).compactMap { $0 as? NSTextView }.first!
    check(
      text.string.contains("New Codex Window") && text.string.contains("\tY\tNew Codex Window"),
      "reference reads configured optional chord")
    let hinted = WindowCreationMenus.dock(
      target: nil, open: NSSelectorFromString("open:"), create: NSSelectorFromString("create:"),
      available: true, chord: chosen)
    check(
      hinted.items[1].keyEquivalent == "y" && hinted.items[1].toolTip == "Tab + Y",
      "menu hint reads chosen chord")
    try key.setOwnerEnabled(false)
    check(!key.active && key.chord == chosen, "Library off releases only the optional registration")
    try key.set(nil)
    check(
      key.chord == nil && !key.active
        && defaults.object(forKey: "codexNewWindowShortcut.v1") == nil,
      "clear restores the unassigned default")
    defaults.set(Data("bad".utf8), forKey: "codexNewWindowShortcut.v1")
    let corrupt = OptionalCommandShortcut(
      defaults: defaults, store: keys, live: false, others: { [] })
    try corrupt.setOwnerEnabled(true)
    check(
      corrupt.error != nil && corrupt.chord == nil
        && defaults.data(forKey: "codexNewWindowShortcut.v1") == Data("bad".utf8),
      "corrupt optional data does not activate or overwrite existing controls")
    let pairSuite = "local.windowfactory.optional-pair.\(UUID())"
    let pairDefaults = UserDefaults(suiteName: pairSuite)!
    defer { pairDefaults.removePersistentDomain(forName: pairSuite) }
    let pairStore = KeybindingStore(defaults: pairDefaults)
    let existing = OptionalCommandShortcut(
      defaults: pairDefaults, store: pairStore, live: false, others: { [] })
    try existing.setOwnerEnabled(true)
    try existing.set(chosen)
    let preserved = pairDefaults.data(forKey: "codexNewWindowShortcut.v1")!
    let access = OptionalCommandShortcut(
      command: .tilingControls, defaults: pairDefaults, store: pairStore, live: false,
      others: { existing.reserved })
    check(
      access.chord == nil && access.command.slot == 66, "tiling access is separately unassigned")
    do {
      try access.set(chosen)
      check(false, "two optional commands cannot share a chord")
    } catch {
      check(
        pairDefaults.data(forKey: "codexNewWindowShortcut.v1") == preserved,
        "tiling collision preserves Codex binding")
    }
    let accessChord = ShortcutChord(key: 32, modifiers: ShortcutChord.hyper, name: "U")
    try access.setOwnerEnabled(true)
    try access.set(accessChord)
    let accessReloaded = OptionalCommandShortcut(
      command: .tilingControls, defaults: pairDefaults, store: pairStore, live: false,
      others: { existing.reserved })
    try accessReloaded.setOwnerEnabled(true)
    check(
      accessReloaded.chord == accessChord && existing.chord == chosen
        && pairDefaults.data(forKey: "codexNewWindowShortcut.v1") == preserved,
      "new optional binding preserves the original preference format")
    editor.optionalCommands = [existing, access]
    check(table.numberOfRows == 4, "Library displays both optional commands")
    ref.optionalCommands = [existing, access]
    ref.refresh()
    check(
      text.string.contains("\tU\tOpen / close Tiling controls"),
      "reference follows tiling access binding")
    let tilingItem = NSMenuItem(title: "Tiling…", action: nil, keyEquivalent: "")
    MenuShortcut.apply(accessChord, to: tilingItem)
    check(
      tilingItem.keyEquivalent == "u" && tilingItem.toolTip == "Tab + U",
      "tiling menu hint uses shared formatter")
    access.stop()
    accessReloaded.stop()
    existing.stop()
    key.stop()
    reloaded.stop()
    corrupt.stop()
    ref.stop()
    here=target;mode="success";ids=[1,2];let beforeAgent=creates
    let agentReceipt=try await action.forAgent("com.openai.codex",target:target)
    check(creates==beforeAgent+1 && agentReceipt.target==target && !action.isBusy,"agent creation shares one-dispatch engine and explicit target")
    mode="prepare-fail";let beforeRejected=creates
    do{_ = try await action.forAgent("com.openai.codex",target:target);check(false,"agent preparation must fail")}catch{check(creates==beforeRejected,"agent preflight failure never dispatches")}
    print(
      "native new-window action: \(count) assertions passed; injected desktop only, no live app creation or UI activation"
    )
  }
}
