import AppKit

struct NewWindowTarget: Equatable {
  let display: UInt32, space: UInt64
  let frame: Frame
}
struct NewWindowReceipt: Equatable {
  let windowID: UInt32, target: NewWindowTarget
}

// A standalone creation command, not a Coordinator/layout operation. It never
// places frames, activates another app or pauses/rejoins a tiling session.
@MainActor
struct NewWindowBackend {
  var target: () throws -> NewWindowTarget
  var prepare: (Adapter, NewWindowTarget) throws -> Void
  var inventory: (Adapter, NewWindowTarget) async throws -> Set<UInt32>
  var create: (Adapter, NewWindowTarget) async throws -> Void
  var wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
  static func live(_ services: MacServices) -> Self {
    func context(_ target: NewWindowTarget) throws -> Context {
      guard
        let screen = NSScreen.screens.first(where: {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            == target.display
        })
      else { throw FactoryError("The selected display is unavailable.") }
      let value = try Context(screen: screen)
      guard value.space == target.space, value.frame.matches(target.frame) else {
        throw FactoryError("Desktop changed. The window request was not retried.")
      }
      return value
    }
    return Self(
      target: {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
          throw FactoryError("No display is available.")
        }
        let value = try Context(screen: screen)
        return NewWindowTarget(display: value.display, space: value.space, frame: value.frame)
      },
      prepare: { adapter, target in
        _ = try context(target)
        try services.requireAccess()
        try services.checkInstalled(adapter)
        guard try services.running(adapter) != nil else {
          throw FactoryError("Open the application first, then request a new window here.")
        }
      },
      inventory: { adapter, target in
        Set(
          try await services.collect(context(target)).filter { $0.bundleID == adapter.bundleID }
            .map(\.id))
      },
      create: { adapter, target in
        try await services.create(adapter, context(target))
      })
  }
}

@MainActor
final class NewWindowAction {
  private let adapters: [String: Adapter], backend: NewWindowBackend
  private var task: Task<Void, Never>?
  private(set) var lastResult = ""
  private(set) var receipt: NewWindowReceipt?
  private(set) var dispatched = false
  var blocked: () -> Bool = { false }
  var changed: (() -> Void)?
  private var agentBusy = false
  var isBusy: Bool { task != nil || agentBusy }
  init(adapters: [String: Adapter], backend: NewWindowBackend) {
    self.adapters = adapters
    self.backend = backend
  }
  func available(_ bundleID: String) -> Bool {
    !isBusy && !blocked() && adapters[bundleID].map { $0.kind != "launch-only" } == true
  }
  func run(_ bundleID: String) {
    guard available(bundleID), let adapter = adapters[bundleID] else { return }
    receipt = nil
    dispatched = false
    lastResult = "Opening a new window here…"
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        task = nil
        changed?()
      }
      do {
        receipt = try await perform(adapter, target: backend.target())
        lastResult = "New window created here."
      } catch is CancellationError {
        lastResult = "Window request stopped; any window already created is left open."
      } catch { lastResult = error.localizedDescription }
    }
    changed?()
  }
  private func perform(_ adapter: Adapter, target: NewWindowTarget) async throws -> NewWindowReceipt
  {
    try backend.prepare(adapter, target)
    let before = try await backend.inventory(adapter, target)
    try Task.checkCancellation()
    try backend.prepare(adapter, target)
    // Mark uncertainty before dispatch. Never resend after an error or timeout.
    dispatched = true
    try await backend.create(adapter, target)
    for _ in 0..<50 {
      try Task.checkCancellation()
      let fresh = try await backend.inventory(adapter, target).subtracting(before)
      guard fresh.count <= 1 else {
        throw FactoryError("Multiple new windows appeared. The request was not retried.")
      }
      if let id = fresh.first {
        return NewWindowReceipt(windowID: id, target: target)
      }
      try await backend.wait()
    }
    throw FactoryError(
      "The new window was not confirmed on this desktop. The request was not retried.")
  }
  func forAgent(_ bundleID: String, target: NewWindowTarget) async throws -> NewWindowReceipt {
    guard !isBusy, let adapter = adapters[bundleID], adapter.kind != "launch-only" else {
      throw AgentFailure("unavailable", "No reviewed window creation operation is available.")
    }
    agentBusy = true
    dispatched = false
    defer { agentBusy = false }
    let result = try await perform(adapter, target: target)
    receipt = result
    return result
  }
  func stop() { task?.cancel() }
}

@MainActor
enum WindowCreationMenus {
  static func dock(
    target: AnyObject?, open: Selector, create: Selector, available: Bool,
    chord: ShortcutChord? = nil
  ) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let library = menu.addItem(withTitle: "Open Window Factory", action: open, keyEquivalent: "")
    library.target = target
    let window = menu.addItem(withTitle: "New Codex Window", action: create, keyEquivalent: "")
    window.target = target
    window.isEnabled = available
    MenuShortcut.apply(chord, to: window)
    return menu
  }
}
