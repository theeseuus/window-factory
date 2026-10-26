import AppKit
import ApplicationServices

@MainActor
func attribute(_ element: AXUIElement,_ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value : nil
}
@MainActor
func children(_ element: AXUIElement,_ key: String = kAXChildrenAttribute) -> [AXUIElement] {
    attribute(element,key) as? [AXUIElement] ?? []
}
@MainActor
func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value,to:AXUIElement.self)
}

@MainActor
struct Context {
    let screen: NSScreen
    let space: UInt64
    let display: CGDirectDisplayID
    let frame: Frame
    init(screen: NSScreen) throws {
        self.screen = screen
        display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        var sid: UInt64 = 0, type: Int32 = -1
        guard WFContext(display,&sid,&type), type == 0 else {
            throw FactoryError("An ordinary desktop with readable Space membership is required.")
        }
        space = sid
        let visible = screen.visibleFrame
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        frame = Frame(x:visible.minX,y:top-visible.maxY,w:visible.width,h:visible.height)
    }
    func check() throws {
        try Task.checkCancellation()
        var sid: UInt64 = 0, type: Int32 = -1
        guard WFContext(display,&sid,&type), sid == space, type == 0 else {
            throw FactoryError("Desktop changed. Operation stopped.")
        }
    }
}

@MainActor
struct LiveWindow {
    let id: UInt32, pid: pid_t, bundleID: String, appName: String
    let element: AXUIElement
    let frame: Frame
    func eligible(in context: Context) throws {
        try context.check()
        guard WFWindowID(element) == id, WFWindowSpaces(id)?.map(\.uint64Value) == [context.space],
              (attribute(element,kAXMinimizedAttribute) as? Bool) != true,
              (attribute(element,"AXFullScreen") as? Bool) != true else {
            throw FactoryError("\(appName): window is no longer eligible here.")
        }
        guard NSRunningApplication(processIdentifier:pid)?.bundleIdentifier == bundleID else {
            throw FactoryError("\(appName): application identity changed.")
        }
        guard NSRunningApplication(processIdentifier:pid)?.isHidden == false,
              let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow,id) as? [[String:Any]],
              infos.contains(where:{ ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
                  && ($0[kCGWindowIsOnscreen as String] as? Bool) == true }) else {
            throw FactoryError("\(appName): window is no longer visible.")
        }
    }
}

@MainActor
final class MacServices {
    let ownBundle = Bundle.main.bundleIdentifier ?? "local.windowfactory.native"
    func requireAccess() throws {
        guard AXIsProcessTrusted() else { throw FactoryError("Accessibility access is needed to capture and place windows.") }
    }
    func collect(_ context: Context) async throws -> [LiveWindow] {
        try requireAccess(); try context.check()
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly],kCGNullWindowID) as? [[String:Any]] ?? []
        let visible = Set(infos.compactMap { e -> UInt32? in
            guard (e[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (e[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
        var result: [LiveWindow] = []
        for app in NSWorkspace.shared.runningApplications where !app.isHidden && app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != ownBundle, bundleID != "org.hammerspoon.Hammerspoon",
                  !bundleID.lowercased().contains("1password"), !bundleID.lowercased().contains("onepassword"),
                  bundleID != "com.apple.Passwords", bundleID != "com.apple.keychainaccess" else { continue }
            try context.check(); await Task.yield()
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root,0.3)
            for window in children(root,kAXWindowsAttribute) {
                let id = WFWindowID(window)
                guard id != 0, visible.contains(id),
                      attribute(window,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                      (attribute(window,kAXMinimizedAttribute) as? Bool) != true,
                      (attribute(window,"AXFullScreen") as? Bool) != true,
                      WFWindowSpaces(id)?.map(\.uint64Value) == [context.space] else { continue }
                var rect = CGRect.zero
                guard WFReadFrame(window,&rect), rect.width > 0, rect.height > 0 else { continue }
                let frame = Frame(x:rect.minX,y:rect.minY,w:rect.width,h:rect.height)
                guard frame.isVisible(in:context.frame) else { continue }
                result.append(LiveWindow(id:id,pid:app.processIdentifier,bundleID:bundleID,
                    appName:app.localizedName ?? bundleID,element:window,frame:frame))
            }
        }
        try context.check()
        return result
    }
    func capture(_ context: Context) async throws -> Recipe {
        let records = try await collect(context)
        guard !records.isEmpty else { throw FactoryError("No eligible windows on this desktop.") }
        var counts: [String:Int] = [:]
        let ordered = records.sorted {
            if $0.bundleID != $1.bundleID { return $0.bundleID < $1.bundleID }
            if $0.frame != $1.frame { return Frame.precedes($0.frame,$1.frame) }
            return $0.id < $1.id
        }
        let slots = ordered.map { window -> Slot in
            counts[window.bundleID,default:0] += 1
            return Slot(bundleID:window.bundleID,appName:window.appName,ordinal:counts[window.bundleID]!,
                        frame:window.frame.normalized(in:context.frame))
        }
        return Recipe(name:"Untitled",capturedAt:ISO8601DateFormatter().string(from:Date()),windows:slots)
    }
    func running(_ adapter: Adapter) throws -> NSRunningApplication? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier:adapter.bundleID)
        guard apps.count <= 1 else { throw FactoryError("\(adapter.name): ambiguous application identity.") }
        return apps.first
    }
    func checkInstalled(_ adapter: Adapter) throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:adapter.bundleID) else {
            throw FactoryError("\(adapter.name) is not installed.")
        }
        if adapter.requirement == "ghostty-applescript-1.3" {
            let info = Bundle(url:url)?.infoDictionary ?? [:]
            let parts = (info["CFBundleShortVersionString"] as? String ?? "").split(separator:".").compactMap { Int($0) }
            guard parts.count >= 2, parts[0] > 1 || (parts[0] == 1 && parts[1] >= 3),
                  info["OSAScriptingDefinition"] != nil else { throw FactoryError("Ghostty needs AppleScript support from version 1.3 or later.") }
        }
    }
    func launch(_ adapter: Adapter,_ context: Context) async throws {
        try context.check(); try checkInstalled(adapter)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:adapter.bundleID) else { throw FactoryError("Application not installed.") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at:url,configuration:configuration)
        try context.check()
    }
    func create(_ adapter: Adapter,_ context: Context) async throws {
        try context.check(); try checkInstalled(adapter)
        if adapter.kind == "launch-only" { throw FactoryError("\(adapter.name): \(adapter.reason ?? "creation unavailable")") }
        if adapter.kind == "applescript", let script = adapter.script {
            // Exact reviewed registry source only. Recipe data never becomes code.
            let error = await Task.detached { () -> String? in
                let process = Process(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath:"/usr/bin/osascript")
                process.arguments = ["-e","with timeout of 8 seconds\n"+script+"\nend timeout"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = errors
                do { try process.run(); process.waitUntilExit() }
                catch { return "Apple Events could not be started." }
                // Do not log raw script errors or app document data.
                return process.terminationStatus == 0 ? nil : "Apple Events failed or permission was denied."
            }.value
            try context.check()
            if let error { throw FactoryError("\(adapter.name): \(error)") }
            return
        }
        var app: NSRunningApplication?
        for attempt in 0..<3 {
            app = try running(adapter)
            if app != nil { break }
            if attempt < 2 { try await Task.sleep(for:.milliseconds(100)); try context.check() }
        }
        guard let app, app.bundleIdentifier == adapter.bundleID else { throw FactoryError("\(adapter.name): application not readable.") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.5)
        guard let bar = axElement(attribute(root,kAXMenuBarAttribute)),
              let file = children(bar).first(where:{ attribute($0,kAXTitleAttribute) as? String == "File" }) else {
            throw FactoryError("\(adapter.name): File menu unavailable.")
        }
        let commands = children(file).flatMap { children($0) }
        var title = adapter.menu?.last
        if adapter.selector == "safari-default-profile" {
            let defaults = commands.filter {
                let id = attribute($0,kAXIdentifierAttribute) as? String ?? ""
                return id.range(of:"^New.*Window\\?isDefaultProfile=true$",options:.regularExpression) != nil
            }
            let ordinary = commands.filter { attribute($0,kAXIdentifierAttribute) as? String == "NewWindow"
                && attribute($0,kAXTitleAttribute) as? String == "New Window" }
            if defaults.count == 1 { title = attribute(defaults[0],kAXTitleAttribute) as? String }
            else if defaults.isEmpty && ordinary.count == 1 { title = "New Window" }
            else { throw FactoryError("Safari: default-profile window menu is ambiguous or absent.") }
        }
        guard let title, !title.isEmpty else { throw FactoryError("\(adapter.name): exact menu title unavailable.") }
        let found = commands.filter { attribute($0,kAXTitleAttribute) as? String == title }
        guard found.count == 1, attribute(found[0],kAXEnabledAttribute) as? Bool == true else {
            throw FactoryError("\(adapter.name): the exact New Window menu is unavailable.")
        }
        try context.check()
        guard AXUIElementPerformAction(found[0],kAXPressAction as CFString) == .success else {
            throw FactoryError("\(adapter.name): New Window request failed.")
        }
    }
    func place(_ window: LiveWindow,_ target: Frame,_ context: Context,new: Bool,policy: String?) async throws {
        func read() throws -> Frame {
            try window.eligible(in:context)
            var rect = CGRect.zero
            guard WFReadFrame(window.element,&rect) else { throw FactoryError("\(window.appName): frame unreadable.") }
            return Frame(x:rect.minX,y:rect.minY,w:rect.width,h:rect.height)
        }
        func pause() async throws { try await Task.sleep(for:.milliseconds(250)); try window.eligible(in:context) }
        var matches = 0
        var actual = try read()
        if actual.matches(target) {
            if new { try await pause(); actual = try read() }
            if actual.matches(target) { return }
        }
        if new && policy == "position-only-when-sized" && abs(actual.w-target.w)<=2 && abs(actual.h-target.h)<=2 {
            for _ in 0..<8 {
                if !actual.matches(target) { _ = WFSetPosition(window.element,CGPoint(x:target.x,y:target.y)) }
                try await pause(); actual = try read()
                matches = actual.matches(target) ? matches+1 : 0
                if matches >= 2 { return }
                if abs(actual.w-target.w)>2 || abs(actual.h-target.h)>2 { break }
            }
        }
        for _ in 0..<(new ? 3 : 1) {
            for staged in [false,false,true] {
                try window.eligible(in:context)
                _ = WFSetSize(window.element,CGSize(width:target.w,height:target.h))
                if staged { try await pause() }
                try window.eligible(in:context)
                _ = WFSetPosition(window.element,CGPoint(x:target.x,y:target.y))
                try await pause(); actual = try read()
                if actual.matches(target) {
                    if new { try await pause(); actual = try read() }
                    if actual.matches(target) { return }
                }
            }
        }
        throw FactoryError("\(window.appName): requested frame did not settle.")
    }
}
