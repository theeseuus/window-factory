import AppKit

struct TilingDesktop: Equatable {
  let display: UInt32, space: UInt64
  let frame: Frame
}
struct TilingWindow: Equatable {
  let id: UInt32, pid: Int32
  let bundleID: String, name: String
  let frame: Frame
}
// Only this adapter knows AX elements and macOS Space APIs. Tests inject closures.
@MainActor
struct TilingBackend {
  var current: () throws -> TilingDesktop
  var snapshot: (TilingDesktop) async throws -> [TilingWindow]
  var existsHere: (TilingWindow, TilingDesktop) throws -> Bool
  var focused: () -> UInt32?
  var place: (TilingWindow, Frame, TilingDesktop) async throws -> Void
  static func live(services: MacServices) -> Self {
    func context(_ desktop: TilingDesktop) throws -> Context {
      guard
        let screen = NSScreen.screens.first(where: {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            == desktop.display
        })
      else { throw FactoryError("Tiling display is unavailable.") }
      let value = try Context(screen: screen)
      guard value.space == desktop.space, value.frame.matches(desktop.frame) else {
        throw FactoryError("Tiling desktop or display changed. Resume on the intended desktop.")
      }
      return value
    }
    func live(_ record: TilingWindow, _ target: TilingDesktop) throws -> LiveWindow {
      let app = NSRunningApplication(processIdentifier: record.pid)
      guard app?.bundleIdentifier == record.bundleID else {
        throw FactoryError("Tiled application changed.")
      }
      let root = AXUIElementCreateApplication(record.pid)
      AXUIElementSetMessagingTimeout(root, 0.15)
      guard
        let element = children(root, kAXWindowsAttribute).first(where: {
          WFWindowID($0) == record.id
        })
      else { throw FactoryError("Tiled window closed.") }
      let window = LiveWindow(
        id: record.id, pid: record.pid, bundleID: record.bundleID, appName: record.name,
        element: element, frame: record.frame)
      try window.eligible(in: context(target))
      return window
    }
    return Self(
      current: {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
          throw FactoryError("No display available.")
        }
        let ctx = try Context(screen: screen)
        return TilingDesktop(display: ctx.display, space: ctx.space, frame: ctx.frame)
      },
      snapshot: { desktop in
        try await services.collect(context(desktop)).map {
          TilingWindow(
            id: $0.id, pid: $0.pid, bundleID: $0.bundleID, name: $0.appName, frame: $0.frame)
        }
      },
      existsHere: { record, desktop in
        _ = try context(desktop)
        guard
          NSRunningApplication(processIdentifier: record.pid)?.bundleIdentifier == record.bundleID
        else { return false }
        // Missing membership is uncertain: pause rather than discarding a tree.
        guard let spaces = WFWindowSpaces(record.id) else {
          let root = AXUIElementCreateApplication(record.pid)
          AXUIElementSetMessagingTimeout(root, 0.15)
          guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] else {
            throw FactoryError("Window inventory temporarily unavailable. Tiling paused.")
          }
          return windows.contains { WFWindowID($0) == record.id }
        }
        return spaces.map(\.uint64Value) == [desktop.space]
      },
      focused: {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
          TilingEvents.allowed(bundle), bundle != Bundle.main.bundleIdentifier
        else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        return axElement(attribute(root, kAXFocusedWindowAttribute)).map { WFWindowID($0) }
      },
      place: { record, target, desktop in
        let ctx = try context(desktop)
        let window = try live(record, desktop)
        let actual = try await DirectFrameApplication.apply(
          target: target, from: record.frame, check: { try window.eligible(in: ctx) },
          read: {
            var f = CGRect.zero
            guard WFReadFrame(window.element, &f) else {
              throw FactoryError("Tiled frame unavailable.")
            }
            return Frame(x: f.minX, y: f.minY, w: f.width, h: f.height)
          },
          write: { change, goal in
            let status =
              change == .position
              ? WFSetPosition(window.element, CGPoint(x: goal.x, y: goal.y))
              : WFSetSize(window.element, CGSize(width: goal.w, height: goal.h))
            guard status == .success else {
              throw FactoryError("Application refused a tile size or position.")
            }
          },
          submit: {
            guard
              WFApplyDirectFrame(
                window.element, CGRect(x: target.x, y: target.y, width: target.w, height: target.h))
                == .success
            else { throw FactoryError("Application refused tiling.") }
          })
        guard actual.matches(target) else {
          throw FactoryError(
            "\(record.name) constrained its tile. Tiling paused; float that window or enlarge its split."
          )
        }
      })
  }
}

// Event-driven, installed only while a desktop session exists. No polling timer.
@MainActor
final class TilingEvents {
  var event: ((UInt32, Bool) -> Void)?
  private var observers: [pid_t: AXObserver] = [:]
  private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
  static func allowed(_ id: String) -> Bool {
    let key = id.lowercased()
    return !key.contains("1password") && !key.contains("onepassword") && id != "com.apple.Passwords"
      && id != "com.apple.keychainaccess" && id != "org.hammerspoon.Hammerspoon"
  }
  func start() {
    stop()
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
      NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
    ] {
      let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.event?(0, false) }
      }
      notifications.append((workspace, token))
    }
    let token = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.event?(0, false) } }
    notifications.append((NotificationCenter.default, token))
    refresh()
  }
  func refresh() {
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular
        && $0.bundleIdentifier.map { Self.allowed($0) && $0 != Bundle.main.bundleIdentifier }
          == true
    }
    let pids = Set(apps.map(\.processIdentifier))
    for pid in Array(observers.keys) where !pids.contains(pid) {
      if let observer = observers.removeValue(forKey: pid) {
        CFRunLoopRemoveSource(
          CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
      }
    }
    for app in apps {
      let pid = app.processIdentifier
      if observers[pid] == nil {
        var created: AXObserver?
        let status = AXObserverCreate(
          pid,
          { _, element, notification, context in
            guard let context else { return }
            MainActor.assumeIsolated {
              let owner = Unmanaged<TilingEvents>.fromOpaque(context).takeUnretainedValue()
              let name = notification as String
              owner.event?(
                WFWindowID(element), name == kAXMovedNotification || name == kAXResizedNotification)
            }
          }, &created)
        if status == .success, let created {
          observers[pid] = created
          CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
      }
      guard let observer = observers[pid] else { continue }
      let root = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(root, 0.1)
      let pointer = Unmanaged.passUnretained(self).toOpaque()
      for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
        AXObserverAddNotification(observer, root, name as CFString, pointer)
      }
      for window in children(root, kAXWindowsAttribute) {
        for name in [
          kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
          kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        ] { AXObserverAddNotification(observer, window, name as CFString, pointer) }
      }
    }
  }
  func stop() {
    for (_, observer) in observers {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    observers = [:]
    for (center, token) in notifications { center.removeObserver(token) }
    notifications = []
  }
}
