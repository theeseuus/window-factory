import AppKit

@main
struct TilingTests {
  @MainActor static func main() async throws {
    _ = NSApplication.shared
    var assertions = 0
    func check(_ value: Bool, _ why: String) {
      assertions += 1
      precondition(value, why)
    }
    let screen = Frame(x: -900, y: 30, w: 1800, h: 1100)
    for count in 1...12 {
      let ids = (1...count).map { UInt32($0) }
      let tree = TileNode.balanced(ids)!
      check(tree.ids == ids, "stable balanced ordering")
      let plan = try TileLayout.plan(tree, in: screen, gap: 8, margin: 12)
      check(plan.frames.count == count, "every leaf placed once")
      for id in ids {
        let f = plan.frames[id]!
        check(
          f.x >= screen.x && f.y >= screen.y && f.x + f.w <= screen.x + screen.w
            && f.y + f.h <= screen.y + screen.h, "contained negative-origin frame")
        for other in ids where other > id {
          let g = plan.frames[other]!
          check(
            f.x + f.w <= g.x || g.x + g.w <= f.x || f.y + f.h <= g.y || g.y + g.h <= f.y,
            "no overlapping tiles")
        }
        let removed = tree.removing(id)
        check(
          removed?.ids == ids.filter { $0 != id } || count == 1 && removed == nil,
          "sibling collapse preserves order")
      }
      check(tree.pruning(to: []) == nil, "empty visible set has no geometry")
    }
    let tree = TileNode.balanced([1, 2, 3])!
    let parent = tree.parent(of: 1)!
    check(tree.editing(parent.0, ratio: 20).parent(of: 1)?.2 == 0.85, "split upper bound")
    check(tree.editing(parent.0, ratio: -20).parent(of: 1)?.2 == 0.15, "split lower bound")
    check(tree.swapping(1, 3).ids == [3, 2, 1], "swap preserves structure")
    check(tree.inserting(4, beside: 2, axis: .rows).ids == [1, 2, 4, 3], "focused insertion")
    check(
      tree.pruning(to: [1, 3])?.ids == [1, 3],
      "floating and parked leaves prune without deleting source")
    do {
      _ = try TileLayout.plan(
        .split(UUID(), .columns, 0.5, .leaf(1), .leaf(2)), in: Frame(x: 0, y: 0, w: 200, h: 200),
        gap: 8, margin: 0)
      preconditionFailure("undersized plan accepted")
    } catch { assertions += 1 }
    do {
      _ = try TileLayout.plan(
        .split(UUID(), .columns, 0.5, .leaf(1), .leaf(1)), in: screen, gap: 0, margin: 0)
      preconditionFailure("duplicate identity accepted")
    } catch { assertions += 1 }
    let domain = "local.windowfactory.tiling-tests.\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let options = TilingOptions(defaults: defaults)
    check(defaults.object(forKey: "tiling.gap") == nil, "reading defaults never writes settings")
    options.gap = 12
    options.margin = 10
    options.excluded = ["excluded.app"]
    check(TilingOptions(defaults: defaults).gap == 12, "gap persists")
    let target = TilingDesktop(display: 1, space: 7, frame: screen)
    var current = target
    var windows: [TilingWindow] = []
    var writes: [(UInt32, Frame)] = []
    var focus: UInt32? = 1
    var reject = false
    var busy = false
    var alive: Set<UInt32> = []
    func record(_ id: UInt32, _ pid: Int32 = 1, _ bundle: String = "test.app") -> TilingWindow {
      TilingWindow(
        id: id, pid: pid, bundleID: bundle, name: "Test \(id)",
        frame: Frame(x: 20 + Double(id) * 30, y: 80, w: 500, h: 400))
    }
    let backend = TilingBackend(
      current: { current },
      snapshot: { desktop in
        guard current == desktop else { throw FactoryError("context changed") }
        return windows
      }, existsHere: { record, _ in alive.contains(record.id) }, focused: { focus },
      place: { record, frame, desktop in
        guard current == desktop, !reject else { throw FactoryError("frame rejected") }
        writes.append((record.id, frame))
        windows = windows.map {
          $0.id == record.id
            ? TilingWindow(
              id: $0.id, pid: $0.pid, bundleID: $0.bundleID, name: $0.name, frame: frame) : $0
        }
      })
    let c = TilingController(backend: backend, options: options)
    c.externalBusy = { busy }
    func settled() async throws {
      for _ in 0..<120 {
        if !c.isBusy { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      preconditionFailure("tiling job did not settle")
    }
    check(!c.enabled && writes.isEmpty, "session off initially")
    c.enable()
    try await settled()
    check(c.enabled && writes.isEmpty, "fresh empty desktop arms without writes")
    windows = [record(1), record(2), record(3, 1, "excluded.app")]
    alive = [1, 2, 3]
    c.reconcile()
    try await settled()
    check(c.effectiveTree?.ids == [1, 2], "adopt new windows and honour exclusions")
    check(Set(writes.map { $0.0 }) == [1, 2], "excluded app never placed")
    let total = writes.count
    c.reconcile()
    try await settled()
    check(writes.count == total, "unchanged inventory does not resize again")
    c.floatForGeometry(1)
    check(c.floating.contains(1), "geometry handoff floats synchronously")
    c.reconcile()
    try await settled()
    check(c.effectiveTree?.ids == [2], "remaining sibling expands")
    c.select(1)
    c.toggleFloat()
    c.reconcile()
    try await settled()
    check(c.effectiveTree?.ids.contains(1) == true, "rejoin restores retained slot")
    c.stashTransition(1, restoring: false)
    c.reconcile()
    try await settled()
    check(c.effectiveTree?.ids == [2], "stash temporarily removes leaf")
    c.stashTransition(1, restoring: true)
    c.reconcile()
    try await settled()
    check(c.effectiveTree?.ids == [1, 2], "restore rejoins original slot")
    c.pause()
    let pausedWrites = writes.count
    windows.append(record(4))
    alive.insert(4)
    c.reconcile()
    try await settled()
    check(
      writes.count == pausedWrites && !c.known.keys.contains(4),
      "paused desktop admits no windows or writes")
    c.resume()
    c.reconcile()
    try await settled()
    check(c.known[4] != nil, "resume reconciles new windows")
    current = TilingDesktop(display: 1, space: 8, frame: screen)
    let oldWrites = writes.count
    c.reconcile()
    try await settled()
    check(writes.count == oldWrites, "inactive Space never moved")
    current = target
    windows.removeAll { $0.id == 2 }
    alive.remove(2)
    c.reconcile()
    try await settled()
    check(!c.tree!.ids.contains(2), "closed or departed window collapses branch")
    // User changes a window outside our own placement operation.
    if let index = windows.firstIndex(where: { $0.id == 1 }) { windows[index] = record(1) }
    c.event(1, moved: true)
    c.reconcile()
    try await settled()
    check(c.floating.contains(1), "manual pointer resize floats instead of fighting")
    c.select(1)
    c.toggleFloat()
    reject = true
    c.reconcile()
    try await settled()
    check(c.paused, "constrained app pauses instead of retry loop")
    reject = false
    c.restoreOriginals()
    try await settled()
    check(c.paused, "undo leaves tiling paused")
    check(windows.first { $0.id == 1 }?.frame == record(1).frame, "undo restores original frame")
    c.disable()
    check(!c.enabled && c.tree == nil, "off clears session, no persistent auto activation")
    busy = true
    let before = writes.count
    c.enable()
    try await settled()
    check(!c.enabled && writes.count == before, "busy owner blocks activation")
    c.stop()
    // Adopting an occupied Space is balanced and preserves the initial frames for undo.
    busy = false
    windows = [record(5), record(6)]
    alive = [5, 6]
    focus = 6
    c.enable()
    try await settled()
    check(c.tree?.ids.first == 6, "focused window leads initial arrangement")
    c.restoreOriginals()
    try await settled()
    check(windows.first { $0.id == 5 }?.frame == record(5).frame, "occupied desktop undo")
    c.select(5)
    let splitBefore = c.effectiveTree!.parent(of: 5)!
    c.resizeSelected(0.05)
    let splitAfter = c.effectiveTree!.parent(of: 5)!
    check(splitAfter.2 < splitBefore.2, "plus grows the selected second child, not its sibling")
    c.disable()
    c.parkedWindows = { [6] }
    let parkedBefore = writes.count
    c.enable()
    try await settled()
    check(c.effectiveTree?.ids == [5], "pre-existing stash is parked during adoption")
    check(!writes.dropFirst(parkedBefore).contains { $0.0 == 6 }, "pre-existing stash never placed")
    c.restoreOriginals()
    try await settled()
    check(
      !writes.dropFirst(parkedBefore).contains { $0.0 == 6 }, "undo leaves parked windows untouched"
    )
    let panel = TilingPanel(controller: c)
    check(!panel.window.isVisible, "panel construction never shows or activates UI")
    func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap { descendants($0) }
    }
    let buttons = descendants(panel.window.contentView!).compactMap { $0 as? NSButton }
    for key in ["p", "f", "v", "h", "b", "s", "-", "+"] {
      check(
        buttons.contains { $0.keyEquivalent == key && $0.keyEquivalentModifierMask.isEmpty },
        "local panel key \(key) is explicit and does not register a global shortcut")
    }
    c.disable()
    windows = []
    alive = []
    let tilingSettings = TilingSettings(options: options)
    tilingSettings.connect(c)
    c.changed = { [weak tilingSettings] in tilingSettings?.refreshSession() }
    check(tilingSettings.session.state == .off, "Settings switch mirrors off state")
    tilingSettings.session.state = .on
    tilingSettings.session.sendAction(
      tilingSettings.session.action, to: tilingSettings.session.target)
    try await settled()
    check(
      c.enabled && tilingSettings.session.state == .on,
      "Settings switch uses same empty-desktop enable path")
    c.pause()
    check(tilingSettings.session.state == .on, "pause preserves session enablement")
    tilingSettings.session.state = .off
    tilingSettings.session.sendAction(
      tilingSettings.session.action, to: tilingSettings.session.target)
    check(
      !c.enabled && tilingSettings.session.state == .off, "Settings off releases existing session")
    panel.stop()
    c.stop()
    print(
      "native tiling: \(assertions) assertions passed; injected desktop only, no live windows, hotkeys or observers"
    )
  }
}
