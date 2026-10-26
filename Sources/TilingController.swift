import Foundation

@MainActor
final class TilingOptions {
  private let defaults: UserDefaults
  var changed: (() -> Void)?
  var gap: Double {
    didSet {
      defaults.set(gap, forKey: "tiling.gap")
      changed?()
    }
  }
  var margin: Double {
    didSet {
      defaults.set(margin, forKey: "tiling.margin")
      changed?()
    }
  }
  var axis: TileAxis {
    didSet {
      defaults.set(axis.rawValue, forKey: "tiling.axis")
      changed?()
    }
  }
  var excluded: Set<String> {
    didSet {
      defaults.set(excluded.sorted(), forKey: "tiling.excluded")
      changed?()
    }
  }
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    func bounded(_ key: String, _ fallback: Double) -> Double {
      guard let number = defaults.object(forKey: key) as? NSNumber else { return fallback }
      let value = number.doubleValue
      return value.isFinite ? min(48, max(0, value)) : fallback
    }
    gap = bounded("tiling.gap", 8)
    margin = bounded("tiling.margin", 8)
    axis = TileAxis(rawValue: defaults.string(forKey: "tiling.axis") ?? "") ?? .columns
    excluded = Set(defaults.stringArray(forKey: "tiling.excluded") ?? [])
  }
}

// Session ownership and transitions. Backend is injectable; UI never writes frames.
@MainActor
final class TilingController {
  let options: TilingOptions
  private let backend: TilingBackend
  private let events: TilingEvents?
  private(set) var desktop: TilingDesktop?
  private(set) var tree: TileNode?
  private(set) var known: [UInt32: TilingWindow] = [:], originals: [UInt32: TilingWindow] = [:]
  private(set) var floating: Set<UInt32> = [], suspended: Set<UInt32> = []
  private(set) var selected: UInt32?
  private(set) var paused = false
  private(set) var message = "Tiling off"
  private var task: Task<Void, Never>?, pending: Task<Void, Never>?
  private var replay = false
  private var serial = 0
  private var touched: Set<UInt32> = []
  var agentOperation = false
  var hasPendingWork: Bool { task != nil || pending != nil }
  var changed: (() -> Void)?
  var externalBusy: () -> Bool = { false }
  var parkedWindows: () -> Set<UInt32> = { [] }
  var enabled: Bool { desktop != nil }
  var isBusy: Bool { task != nil }
  var visible: Set<UInt32> = []
  var effectiveTree: TileNode? {
    tree?.pruning(to: visible.subtracting(floating).subtracting(suspended))
  }
  init(backend: TilingBackend, options: TilingOptions, events: TilingEvents? = nil) {
    self.backend = backend
    self.options = options
    self.events = events
    events?.event = { [weak self] id, moved in self?.event(id, moved: moved) }
    options.changed = { [weak self] in self?.schedule() }
  }
  func plan() throws -> TilePlan {
    guard let desktop else { return TilePlan() }
    return try TileLayout.plan(
      effectiveTree, in: desktop.frame, gap: options.gap, margin: options.margin)
  }
  func select(_ id: UInt32) {
    guard known[id] != nil else { return }
    selected = id
    changed?()
  }
  private func finished(_ generation: Int) {
    guard serial == generation else { return }
    task = nil
    changed?()
    if replay {
      replay = false
      schedule()
    }
  }
  func yieldForControl() {
    guard enabled else { return }
    invalidate()
    schedule()
  }
  private func invalidate() {
    replay = false
    serial += 1
    task?.cancel()
    task = nil
    pending?.cancel()
    pending = nil
  }
  func enable() {
    guard !enabled, !isBusy, !externalBusy() else { return }
    invalidate()
    let generation = serial
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { finished(generation) }
      do {
        let target = try backend.current()
        let windows = try await backend.snapshot(target)
        try Task.checkCancellation()
        guard generation == serial else { return }
        desktop = target
        known = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        visible = Set(known.keys)
        floating = Set(windows.filter { options.excluded.contains($0.bundleID) }.map(\.id))
        suspended = parkedWindows()
        originals = known.filter { !floating.contains($0.key) && !suspended.contains($0.key) }
        let focus = backend.focused()
        let ordered = windows.sorted { a, b in
          if a.id == focus { return true }
          if b.id == focus { return false }
          return Frame.precedes(a.frame, b.frame)
        }.map(\.id)
        tree = TileNode.balanced(ordered, axis: options.axis)
        selected = focus ?? ordered.first
        paused = false
        // Check capacity before starting observers or issuing a single frame write.
        _ = try plan()
        events?.start()
        try await apply(generation)
      } catch is CancellationError {} catch {
        guard serial == generation else { return }
        paused = enabled
        message = error.localizedDescription
        if enabled { events?.start() }
      }
    }
  }
  func pause(_ reason: String = "Tiling paused") {
    guard enabled else { return }
    invalidate()
    paused = true
    message = reason
    changed?()
  }
  func disable() {
    invalidate()
    events?.stop()
    desktop = nil
    tree = nil
    known = [:]
    originals = [:]
    visible = []
    floating = []
    suspended = []
    selected = nil
    paused = false
    message = "Tiling off"
    changed?()
  }
  func resume() {
    guard enabled, !externalBusy() else { return }
    do {
      let current = try backend.current()
      guard let desktop, current.display == desktop.display, current.space == desktop.space else {
        throw FactoryError("Return to the tiled desktop to resume.")
      }
      self.desktop = current
      paused = false
      message = "Tiling resumed"
      schedule()
    } catch {
      message = error.localizedDescription
      changed?()
    }
  }
  func floatForGeometry(_ id: UInt32) {
    guard enabled, known[id] != nil else { return }
    invalidate()
    floating.insert(id)
    message = "Window floating"
    changed?()
    schedule()
  }
  func stashTransition(_ id: UInt32, restoring: Bool) {
    guard enabled, known[id] != nil else { return }
    invalidate()
    if restoring { suspended.remove(id) } else { suspended.insert(id) }
    schedule()
  }
  func event(_ id: UInt32, moved: Bool) {
    guard enabled else { return }
    if let focus = backend.focused(), known[focus] != nil { selected = focus }
    if moved, !isBusy, id != 0 { touched.insert(id) }
    schedule()
  }
  func schedule() {
    guard enabled, !paused else {
      changed?()
      return
    }
    if isBusy {
      replay = true
      return
    }
    pending?.cancel()
    pending = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      guard let self else { return }
      pending = nil
      // A bounded deferred check, not desktop polling: busy owners call schedule on completion.
      guard !isBusy, !externalBusy() else { return }
      reconcile()
    }
  }
  func reconcile() {
    guard let desktop, !paused, !isBusy, !externalBusy() else { return }
    let generation = serial
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { finished(generation) }
      do {
        let current = try backend.current()
        guard current.display == desktop.display, current.space == desktop.space else {
          message = "Tiling on another desktop"
          return
        }
        guard current.frame.matches(desktop.frame) else {
          throw FactoryError("Display dimensions changed. Resume to reflow.")
        }
        let windows = try await backend.snapshot(desktop)
        try Task.checkCancellation()
        guard serial == generation else { return }
        let found = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let oldPlan = (try? plan()) ?? TilePlan()
        for (id, record) in known {
          if let replacement = found[id],
            replacement.pid != record.pid || replacement.bundleID != record.bundleID
          {
            remove(id)
          } else if found[id] == nil, try !backend.existsHere(record, desktop) {
            remove(id)
          }
        }
        // Manual pointer moves float too; own placement notifications never request another frame.
        for id in touched {
          if let frame = found[id]?.frame, let expected = oldPlan.frames[id],
            !frame.matches(expected)
          {
            floating.insert(id)
          }
        }
        touched = []
        suspended.formUnion(parkedWindows())
        visible = Set(found.keys)
        for record in windows {
          if known[record.id] == nil {
            if !options.excluded.contains(record.bundleID), !suspended.contains(record.id) {
              originals[record.id] = record
            }
            if options.excluded.contains(record.bundleID) { floating.insert(record.id) }
            if let old = tree,
              let anchor = (selected.flatMap { old.ids.contains($0) ? $0 : nil } ?? old.ids.last)
            {
              tree = old.inserting(record.id, beside: anchor, axis: options.axis)
            } else {
              tree = .leaf(record.id)
            }
          }
          known[record.id] = record
          if options.excluded.contains(record.bundleID) { floating.insert(record.id) }
        }
        if selected == nil { selected = effectiveTree?.ids.first ?? found.keys.sorted().first }
        events?.refresh()
        try await apply(generation)
      } catch is CancellationError {} catch {
        paused = true
        message = error.localizedDescription
      }
    }
  }
  private func remove(_ id: UInt32) {
    tree = tree?.removing(id)
    known.removeValue(forKey: id)
    floating.remove(id)
    suspended.remove(id)
    if selected == id { selected = tree?.ids.first }
  }
  private func apply(_ generation: Int) async throws {
    guard let desktop else { return }
    let planned = try plan()
    for id in (effectiveTree?.ids ?? []) {
      try Task.checkCancellation()
      guard serial == generation, !paused, !externalBusy() else { throw CancellationError() }
      guard let record = known[id], let frame = planned.frames[id], !record.frame.matches(frame)
      else { continue }
      try await backend.place(record, frame, desktop)
      guard serial == generation else { throw CancellationError() }
      known[id] = TilingWindow(
        id: record.id, pid: record.pid, bundleID: record.bundleID, name: record.name, frame: frame)
    }
    message = "\(planned.frames.count) tiled · \(floating.count) floating"
  }
  func editSplit(_ id: UUID, ratio: Double? = nil, axis: TileAxis? = nil) {
    guard enabled, !isBusy else { return }
    tree = tree?.editing(id, ratio: ratio, axis: axis)
    schedule()
    changed?()
  }
  func resizeSelected(_ amount: Double) {
    guard let selected, let parent = effectiveTree?.parent(of: selected) else { return }
    editSplit(parent.0, ratio: parent.2 + (parent.3 ? amount : -amount))
  }
  func splitSelected(_ axis: TileAxis) {
    options.axis = axis
    if let selected, let parent = effectiveTree?.parent(of: selected) {
      editSplit(parent.0, axis: axis)
    }
    changed?()
  }
  func balance() {
    guard !isBusy else { return }
    tree = tree?.balanced()
    schedule()
    changed?()
  }
  func toggleFloat() {
    guard !isBusy, let selected else { return }
    invalidate()
    if floating.contains(selected) { floating.remove(selected) } else { floating.insert(selected) }
    schedule()
    changed?()
  }
  func swapNext() {
    guard !isBusy, let selected, let ids = effectiveTree?.ids,
      let index = ids.firstIndex(of: selected), ids.count > 1
    else { return }
    tree = tree?.swapping(selected, ids[(index + 1) % ids.count])
    schedule()
    changed?()
  }
  func restoreOriginals() {
    guard let desktop, !externalBusy(), !isBusy else { return }
    pause("Previous positions restored; tiling paused")
    let generation = serial
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { finished(generation) }
      do {
        let windows = try await backend.snapshot(desktop)
        for current in windows
        where !suspended.contains(current.id) && !parkedWindows().contains(current.id)
          && !options.excluded.contains(current.bundleID)
        {
          try Task.checkCancellation()
          guard serial == generation else { return }
          if let old = originals[current.id], old.pid == current.pid,
            old.bundleID == current.bundleID
          {
            try await backend.place(current, old.frame, desktop)
          }
        }
      } catch { message = error.localizedDescription }
    }
  }
  func stop() {
    invalidate()
    events?.stop()
  }
}
