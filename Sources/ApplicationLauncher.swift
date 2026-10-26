import AppKit

struct ApplicationEntry: Codable, Equatable, Identifiable {
  let id: UUID
  let slot: UInt32
  var bundleID: String, name: String, path: String
  var shortcut: ShortcutChord?
  var enabled: Bool
  var isSearch: Bool = false
}
struct ApplicationEnvelope: Codable {
  let version: Int
  let entries: [ApplicationEntry]
}

// Launch Services owns the cooperative activation/reopen handoff for both
// running and stopped apps. Injected requests let tests exercise both routes
// without launching apps or changing desktop focus.
@MainActor
struct ApplicationOpening {
  var running: (String) -> [NSRunningApplication] = {
    NSRunningApplication.runningApplications(withBundleIdentifier: $0).filter { !$0.isTerminated }
  }
  var request: (URL, NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication = {
    try await NSWorkspace.shared.openApplication(at: $0, configuration: $1)
  }
  var frontmostPID: () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
  var hide: (NSRunningApplication) -> Bool = { $0.hide() }
  private func selectedRunningApp(_ entry: ApplicationEntry, url: URL) throws -> NSRunningApplication? {
    let applications = running(entry.bundleID)
    let selected = applications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
      ?? (applications.count == 1 ? applications.first : nil)
    guard applications.isEmpty || selected != nil else {
      throw FactoryError("Multiple copies of \(entry.name) are running. Select the intended app first.")
    }
    return selected
  }
  // Only an app-launch hotkey opts into hiding. Search and agent open remain explicit opens.
  func toggle(_ entry: ApplicationEntry, url: URL) async throws -> Bool {
    if let selected = try selectedRunningApp(entry,url:url), selected.processIdentifier == frontmostPID() {
      guard hide(selected) else { throw FactoryError("\(entry.name) could not be hidden.") }
      return true
    }
    _ = try await open(entry,url:url)
    return false
  }
  func open(_ entry: ApplicationEntry, url: URL) async throws -> NSRunningApplication {
    _ = try selectedRunningApp(entry,url:url)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.createsNewApplicationInstance = false
    return try await request(url, configuration)
  }
}

@MainActor
final class ApplicationLauncher {
  private let defaults: UserDefaults
  private let shortcuts: KeybindingStore
  private let live: Bool
  private let opening: ApplicationOpening
  private(set) var entries: [ApplicationEntry] = []
  private(set) var active: Set<UUID> = []
  private(set) var failures: [UUID: String] = [:]
  private(set) var loadError: String?
  var additionalShortcuts: () -> [(String, ShortcutChord)] = { [] }
  var changed: (() -> Void)?
  var searchRequested: (() -> Void)?
  var launchFailed: ((String) -> Void)?
  var blocked: () -> Bool = { false }
  private(set) var isLaunching = false
  private(set) var lastResult = ""
  init(defaults: UserDefaults = .standard, shortcuts: KeybindingStore, live: Bool = true,
       opening: ApplicationOpening = ApplicationOpening()) {
    self.defaults = defaults
    self.shortcuts = shortcuts
    self.live = live
    self.opening = opening
    if let data = defaults.data(forKey: "applicationLaunchers.v1") {
      do {
        let value = try JSONDecoder().decode(ApplicationEnvelope.self, from: data)
        guard value.version == 1 else { throw FactoryError("Unknown application shortcut format.") }
        try Self.validateEntries(value.entries, overrides: shortcuts.overrides)
        entries = value.entries
      } catch {
        loadError = "Application shortcuts could not be loaded: \(error.localizedDescription)"
      }
    }
    if loadError == nil && !entries.contains(where: { $0.isSearch }) {
      entries.insert(
        ApplicationEntry(
          id: UUID(uuidString: "B058B132-1FA6-4BF4-83F7-88EE0312B070")!, slot: 0,
          bundleID: "local.windowfactory.native", name: "Applications Search",
          path: "/Applications/Window Factory.app", enabled: false, isSearch: true), at: 0)
    }
  }
  static func readApplication(_ url: URL, slot: UInt32) throws -> ApplicationEntry {
    guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
      let id = bundle.bundleIdentifier, !id.isEmpty
    else { throw FactoryError("Choose an application bundle.") }
    let name =
      (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? url.deletingPathExtension().lastPathComponent
    return ApplicationEntry(
      id: UUID(), slot: slot, bundleID: id, name: name, path: url.standardizedFileURL.path,
      enabled: false)
  }
  static func validateEntries(_ entries: [ApplicationEntry], overrides: [String: ShortcutChord])
    throws
  {
    guard entries.count <= 65, Set(entries.map(\.id)).count == entries.count,
      Set(entries.map(\.slot)).count == entries.count,
      Set(entries.filter({ !$0.isSearch }).map(\.bundleID)).count
        == entries.filter({ !$0.isSearch }).count,
      entries.allSatisfy({
        ($0.isSearch ? $0.slot == 0 : ($0.slot > 0 && $0.slot <= 64)) && !$0.bundleID.isEmpty
          && !$0.name.isEmpty && $0.name.count <= 256 && $0.path.hasPrefix("/")
          && (!$0.enabled || $0.shortcut != nil)
      })
    else { throw FactoryError("Invalid or duplicate application shortcuts.") }
    for entry in entries {
      if let chord = entry.shortcut { try ShortcutValidation.validateLocalCommand(chord) }
    }
    try ShortcutValidation.validate(
      overrides,
      additional: entries.compactMap { entry in
        entry.shortcut.map { (entry.isSearch ? "Applications search" : "Launch " + entry.name, $0) }
      })
  }
  var reservedShortcuts: [(String, ShortcutChord)] {
    entries.compactMap { entry in
      entry.shortcut.map { (entry.isSearch ? "Applications search" : "Launch " + entry.name, $0) }
    }
  }
  func restore() {
    guard live else { return }
    for entry in entries where entry.enabled {
      do { try register(entry) } catch { failures[entry.id] = error.localizedDescription }
    }
    changed?()
  }
  private func register(_ entry: ApplicationEntry) throws {
    guard live else { return }
    var rollback: Int32 = 0
    let status = WFConfigureApplicationHotKey(
      entry.slot, entry.shortcut?.key ?? 0, entry.shortcut?.modifiers ?? 0, entry.enabled,
      { slot, context in
        MainActor.assumeIsolated {
          let owner = Unmanaged<ApplicationLauncher>.fromOpaque(context).takeUnretainedValue()
          if slot == 0 {
            owner.searchRequested?()
          } else if let entry = owner.entries.first(where: { $0.slot == slot }) {
            owner.launch(entry,toggleIfFrontmost:true)
          }
        }
      }, Unmanaged.passUnretained(self).toOpaque(), &rollback)
    guard status == 0 else {
      if rollback != 0 { active.remove(entry.id) }
      throw FactoryError(
        rollback == 0
          ? "\(entry.shortcut?.label ?? "Shortcut") is unavailable (macOS \(status)). Previous bindings remain unchanged."
          : "The previous application shortcut could not be restored. Disable/re-enable that app binding; window controls were not changed."
      )
    }
    if entry.enabled { active.insert(entry.id) } else { active.remove(entry.id) }
  }
  private func commit(_ draft: [ApplicationEntry], changed entry: ApplicationEntry) throws {
    guard loadError == nil else { throw FactoryError(loadError!) }
    try Self.validateEntries(draft, overrides: shortcuts.overrides)
    try ShortcutValidation.validate(
      shortcuts.overrides,
      additional: draft.compactMap { e in e.shortcut.map { (e.name, $0) } } + additionalShortcuts())
    let data = try JSONEncoder().encode(ApplicationEnvelope(version: 1, entries: draft))
    try register(entry)
    entries = draft
    defaults.set(data, forKey: "applicationLaunchers.v1")
    failures.removeValue(forKey: entry.id)
    changed?()
  }
  @discardableResult func add(_ url: URL) throws -> UUID {
    if let id = Bundle(url: url)?.bundleIdentifier,
      let existing = entries.first(where: { !$0.isSearch && $0.bundleID == id })
    {
      let selected = try Self.readApplication(url, slot: existing.slot)
      if existing.path != selected.path || existing.name != selected.name {
        var updated = existing
        updated.path = selected.path
        updated.name = selected.name
        try commit(entries.map { $0.id == existing.id ? updated : $0 }, changed: updated)
      }
      return existing.id
    }
    guard
      let slot = (UInt32(1)...64).first(where: { candidate in
        !entries.contains { $0.slot == candidate }
      })
    else { throw FactoryError("All 64 application shortcut slots are in use.") }
    let entry = try Self.readApplication(url, slot: slot)
    try commit(entries + [entry], changed: entry)
    return entry.id
  }
  func configureSearchShortcut(_ chord: ShortcutChord, enabled: Bool) throws {
    var entry =
      entries.first { $0.isSearch }
      ?? ApplicationEntry(
        id: UUID(), slot: 0, bundleID: "local.windowfactory.native", name: "Applications Search",
        path: "/Applications/Window Factory.app", enabled: false, isSearch: true)
    entry.shortcut = chord
    entry.enabled = enabled
    var draft = entries.filter { !$0.isSearch }
    draft.insert(entry, at: 0)
    try commit(draft, changed: entry)
  }
  func setShortcut(_ chord: ShortcutChord?, id: UUID) throws {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    var draft = entries
    draft[index].shortcut = chord
    if chord == nil { draft[index].enabled = false }
    try commit(draft, changed: draft[index])
  }
  func setEnabled(_ enabled: Bool, id: UUID) throws {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    var draft = entries
    draft[index].enabled = enabled
    try commit(draft, changed: draft[index])
  }
  func remove(_ id: UUID) throws {
    guard var entry = entries.first(where: { $0.id == id }) else { return }
    guard !entry.isSearch else {
      throw FactoryError(
        "Disable or clear the Applications Search shortcut instead of removing it.")
    }
    entry.enabled = false
    try commit(entries.filter { $0.id != id }, changed: entry)
  }
  func resolvedURL(_ entry: ApplicationEntry) -> URL? {
    let selected = URL(fileURLWithPath: entry.path)
    if FileManager.default.fileExists(atPath: selected.path),
      Bundle(url: selected)?.bundleIdentifier == entry.bundleID
    {
      return selected
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID)
  }
  func launch(_ entry: ApplicationEntry, toggleIfFrontmost: Bool = false) {
    guard live else { return }
    if entry.isSearch {
      searchRequested?()
      return
    }
    guard !blocked(), !isLaunching else {
      lastResult = "Finish the current Window Factory operation first."
      changed?()
      return
    }
    guard let url = resolvedURL(entry) else {
      launchFailed?(
        "\(entry.name) is no longer available. Choose it again in Applications settings.")
      return
    }
    isLaunching = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        isLaunching = false
        changed?()
      }
      do {
        if toggleIfFrontmost, try await opening.toggle(entry,url:url) {
          lastResult = "Hidden \(entry.name)."
        } else {
          if !toggleIfFrontmost { _ = try await open(entry,url:url) }
          lastResult = "Opened \(entry.name)."
        }
      } catch {
        lastResult = error.localizedDescription
        launchFailed?(lastResult)
      }
    }
  }
  private func open(_ entry: ApplicationEntry, url: URL) async throws -> NSRunningApplication {
    try await opening.open(entry, url: url)
  }

  func forAgent(_ bundleID: String) async throws -> Int32 {
    guard live, !isLaunching, TilingEvents.allowed(bundleID),
      bundleID != Bundle.main.bundleIdentifier
    else {
      throw AgentFailure(
        "app_unavailable", "This application is not available through Agent access.")
    }
    guard
      let entry = ApplicationsWindow.inventory(extra: entries).first(where: {
        $0.bundleID == bundleID
      }), let url = resolvedURL(entry)
    else { throw AgentFailure("app_not_found", "No installed application has that bundle ID.") }
    isLaunching = true
    defer { isLaunching = false }
    let app = try await open(entry, url: url)
    for _ in 0..<20 {
      try Task.checkCancellation()
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
        return app.processIdentifier
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw AgentFailure(
      "activation_unconfirmed",
      "Application activation was dispatched once but focus was not confirmed.")
  }
  func stop() {
    if live { WFStopApplicationHotKeys() }
    active = []
  }
}
