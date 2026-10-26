import AppKit

@MainActor
struct SwitcherDesktop {
    let display: UInt32, space: UInt64
    init(_ screen: NSScreen) throws {
        display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        var sid: UInt64 = 0, kind: Int32 = -1
        guard WFContext(display,&sid,&kind) else { throw FactoryError("Desktop membership unavailable.") }
        space = sid
    }
    func check() throws {
        try Task.checkCancellation(); var sid: UInt64 = 0,kind: Int32 = -1
        guard WFContext(display,&sid,&kind),sid == space else { throw FactoryError("Desktop changed; switcher cancelled.") }
    }
}
@MainActor
struct SwitcherOrigin {
    let pid: pid_t
    let windowID: UInt32?
    let desktops: [SwitcherDesktop]
    func check() throws {
        for desktop in desktops { try desktop.check() }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw FactoryError("Focus changed; switcher cancelled.") }
        if let windowID {
            let root = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root,0.1)
            guard let focused = axElement(attribute(root,kAXFocusedWindowAttribute)),WFWindowID(focused) == windowID else { throw FactoryError("Focused window changed; switcher cancelled.") }
        }
    }
}
@MainActor
struct SwitcherWindowIdentity {
    let id: UInt32, pid: pid_t, bundleID: String, appName: String
    let element: AXUIElement?
    let frame: Frame
}
@MainActor
struct SwitcherWindowRecord {
    let window: SwitcherWindowIdentity
    let space: UInt64, display: UInt32
    let title: String
    let icon: NSImage?
    let location: SwitcherDesktopLocation?
    init(window: SwitcherWindowIdentity,space: UInt64,display: UInt32,title: String,icon: NSImage?,location: SwitcherDesktopLocation? = nil) {
        self.window = window; self.space = space; self.display = display; self.title = title; self.icon = icon; self.location = location
    }
    var desktopLocation: SwitcherDesktopLocation {
        location ?? SwitcherDesktopLocation(display:display,space:space,displayNumber:Int.max,desktopNumber:nil,spaceOrder:Int.max,isCurrent:false,isFullscreen:false)
    }
    func check() throws {
        try Task.checkCancellation(); let w = window
        guard NSRunningApplication(processIdentifier:w.pid)?.bundleIdentifier == w.bundleID,
              NSRunningApplication(processIdentifier:w.pid)?.isHidden == false,
              WFWindowSpaces(w.id)?.map(\.uint64Value) == [space],[0,4].contains(WFSpaceKind(space)),
              let up = WFSwitcherSpaceWindows(space,true),up.contains(NSNumber(value:w.id)),
              let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow,w.id) as? [[String:Any]],
              infos.contains(where:{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == w.id
                  && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == w.pid
                  && ($0[kCGWindowLayer as String] as? Int) == 0}) else {
            throw FactoryError("Selected window is closed, parked or no longer eligible; switch cancelled.")
        }
    }
}
extension SwitcherWindowRecord {
    init(window: LiveWindow,space: UInt64,display: UInt32,title: String,icon: NSImage?) {
        self.init(window:SwitcherWindowIdentity(id:window.id,pid:window.pid,bundleID:window.bundleID,
            appName:window.appName,element:window.element,frame:window.frame),space:space,display:display,title:title,icon:icon)
    }
}
@MainActor
final class SwitcherServices {
    private var titles: [String:String] = [:]
    func allowed(_ bundle: String) -> Bool {
        bundle != Bundle.main.bundleIdentifier && bundle != "org.hammerspoon.Hammerspoon"
        && !bundle.lowercased().contains("1password") && !bundle.lowercased().contains("onepassword")
        && bundle != "com.apple.Passwords" && bundle != "com.apple.keychainaccess"
    }
    func origin() throws -> SwitcherOrigin {
        guard AXIsProcessTrusted(),let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier,!bundle.lowercased().contains("1password"),!bundle.lowercased().contains("onepassword"),
              bundle != "com.apple.Passwords",bundle != "com.apple.keychainaccess" else { throw FactoryError("Focus a regular application first.") }
        let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root,0.1)
        let focused = axElement(attribute(root,kAXFocusedWindowAttribute))
        let id = focused.map{WFWindowID($0)}.flatMap{$0 == 0 ? nil : $0}
        return SwitcherOrigin(pid:app.processIdentifier,windowID:id,desktops:try NSScreen.screens.map{try SwitcherDesktop($0)})
    }
    private func elements(_ pid: pid_t) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root,0.1)
        var result = children(root,kAXWindowsAttribute)
        for key in [kAXMainWindowAttribute,kAXFocusedWindowAttribute] {
            if let element = axElement(attribute(root,key)) { result.append(element) }
        }
        return result
    }
    func collect(_ origin: SwitcherOrigin) async throws -> [SwitcherWindowRecord] {
        try origin.check()
        if titles.count>512 { titles.removeAll() }
        let infos = CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []
        let regular = infos.filter{($0[kCGWindowLayer as String] as? Int) == 0}
        let order = regular.compactMap{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value}
        var metadata: [UInt32:[String:Any]] = [:], apps: [pid_t:NSRunningApplication] = [:]
        for info in regular {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let app = NSRunningApplication(processIdentifier:pid),let bundle = app.bundleIdentifier,
                  allowed(bundle),app.activationPolicy == .regular,!app.isHidden else { continue }
            metadata[id] = info; apps[pid] = app
        }
        var result: [SwitcherWindowRecord] = [], seen = Set<UInt32>(), axByPID: [pid_t:[UInt32:AXUIElement]] = [:]
        for (displayIndex,desktop) in origin.desktops.enumerated() {
            guard let spaces = WFSwitcherSpaces(desktop.display) as? [[String:Any]] else { throw FactoryError("All-Space inventory unavailable; no partial switcher list was substituted.") }
            for (spaceIndex,descriptor) in spaces.enumerated() {
                try origin.check(); await Task.yield()
                guard let sid = (descriptor["id"] as? NSNumber)?.uint64Value,
                      let kind = (descriptor["kind"] as? NSNumber)?.int32Value,[0,4].contains(kind),
                      let shown = descriptor["shown"] as? Bool else { continue }
                guard let up = WFSwitcherSpaceWindows(sid,true) else { throw FactoryError("Desktop window inventory unavailable.") }
                let ordinal = (descriptor["ordinal"] as? NSNumber)?.intValue ?? 0
                for number in up {
                    let id = number.uint32Value
                    guard !seen.contains(id),let info = metadata[id],let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                          let app = apps[pid],let bundle = app.bundleIdentifier,
                          let bounds = info[kCGWindowBounds as String] as? [String:Any],
                          let rect = CGRect(dictionaryRepresentation:bounds as CFDictionary),rect.width>0,rect.height>0,
                          let membership = WFWindowSpaces(id)?.map(\.uint64Value) else { continue }
                    if shown && axByPID[pid] == nil {
                        var map: [UInt32:AXUIElement] = [:]
                        for element in elements(pid) { let wid = WFWindowID(element); if wid != 0 { map[wid] = element } }
                        axByPID[pid] = map
                    }
                    let element = axByPID[pid]?[id]
                    let standard = element.map { attribute($0,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
                        && (attribute($0,kAXMinimizedAttribute) as? Bool) != true } ?? false
                    guard SwitcherDiscovery.accepts(space:sid,membership:membership,kind:kind,shown:shown,
                        isUp:true,standardAX:standard,rejectedAX:element != nil && !standard) else { continue }
                    let key = "\(pid):\(id)"
                    if let element,let title = attribute(element,kAXTitleAttribute) as? String,!title.isEmpty { titles[key] = title }
                    let title = titles[key] ?? (info[kCGWindowName as String] as? String)
                        ?? (kind == 0 ? "Window on Desktop \(ordinal)" : "Full-screen window")
                    let frame = Frame(x:rect.minX,y:rect.minY,w:rect.width,h:rect.height)
                    let identity = SwitcherWindowIdentity(id:id,pid:pid,bundleID:bundle,appName:app.localizedName ?? bundle,element:element,frame:frame)
                    let location = SwitcherDesktopLocation(display:desktop.display,space:sid,displayNumber:displayIndex+1,
                        desktopNumber:kind == 0 ? ordinal : nil,spaceOrder:spaceIndex,isCurrent:shown,isFullscreen:kind == 4)
                    result.append(SwitcherWindowRecord(window:identity,space:sid,display:desktop.display,title:title,icon:app.icon,location:location)); seen.insert(id)
                }
            }
        }
        try origin.check()
        result.sort{(order.firstIndex(of:$0.window.id) ?? Int.max)<(order.firstIndex(of:$1.window.id) ?? Int.max)}
        return result
    }
    private func resolve(_ target: SwitcherWindowRecord) -> AXUIElement? {
        elements(target.window.pid).first {
            WFWindowID($0) == target.window.id
                && attribute($0,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
                && (attribute($0,kAXMinimizedAttribute) as? Bool) != true
        }
    }
    func activate(_ target: SwitcherWindowRecord,from origin: SwitcherOrigin) async throws {
        try origin.check(); try target.check()
        var current: UInt64 = 0,kind: Int32 = -1
        guard WFContext(target.display,&current,&kind) else { throw FactoryError("Target display unavailable.") }
        var element: AXUIElement?
        if current != target.space && kind == 0 && WFSpaceKind(target.space) == 0 {
            // Only after user selection: reveal the desktop, then resolve the
            // exact existing AX window. Never fabricate an element or move it.
            guard WFSwitcherSelectSpace(target.display,current,target.space) else { throw FactoryError("Native desktop selection unavailable; no window was moved.") }
            let deadline = ContinuousClock.now.advanced(by:.milliseconds(1500))
            while ContinuousClock.now<deadline {
                try Task.checkCancellation(); try target.check()
                for desktop in origin.desktops where desktop.display != target.display { try desktop.check() }
                var sid: UInt64 = 0,type: Int32 = -1
                guard WFContext(target.display,&sid,&type),sid == current || sid == target.space else { throw FactoryError("Desktop changed during switching; exact focus stopped.") }
                if sid == target.space,let resolved = resolve(target) { element = resolved; break }
                try await Task.sleep(for:.milliseconds(30))
            }
        } else { element = resolve(target) }
        guard let element,WFWindowID(element) == target.window.id else {
            throw FactoryError("Selected desktop reached, but the exact standard window was not available; no replacement window was focused.")
        }
        try target.check()
        var main: Int32 = 0, raised: Int32 = 0
        let status = WFRequestWindowFocus(element,target.window.pid,&main,&raised)
        let deadline = ContinuousClock.now.advanced(by:.milliseconds(1200)), sent = ContinuousClock.now
        while ContinuousClock.now<deadline {
            try await Task.sleep(for:.milliseconds(30)); try target.check()
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front != origin.pid && front != target.window.pid && ContinuousClock.now-sent > .milliseconds(300) {
                throw FactoryError("User focus changed; switch verification stopped.")
            }
            let root = AXUIElementCreateApplication(target.window.pid); AXUIElementSetMessagingTimeout(root,0.1)
            var sid: UInt64 = 0,type: Int32 = -1
            if front == target.window.pid,let focused = axElement(attribute(root,kAXFocusedWindowAttribute)),
               WFWindowID(focused) == target.window.id,WFContext(target.display,&sid,&type),sid == target.space { return }
        }
        throw FactoryError("Switch not confirmed for \(target.window.appName) (main \(main), raise \(raised), activation \(status)).")
    }
}
