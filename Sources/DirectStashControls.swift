import AppKit

@MainActor
final class DirectStashControls {
    private struct Saved { let window: LiveWindow; let context: Context }
    private let preferences: FactoryPreferences
    private let hud = GeometryHUD()
    private var saved: [String:Saved] = [:]
    private var order: [String] = []
    private var task: Task<Void,Never>?
    private var serial = 0
    var isBusy: Bool { task != nil }
    var active = false
    var lastResult = "Native stash/restore is disabled."
    var workspaceBusy: () -> Bool = { false }
    var changed: (() -> Void)?
    var tilingTransition: ((UInt32,Bool)->Void)?
    var count: Int { saved.count }
    var windowIDs: Set<UInt32> { Set(saved.values.map { $0.window.id }) }
    init(preferences: FactoryPreferences) { self.preferences = preferences }
    func enable() throws {
        guard AXIsProcessTrusted() else { throw FactoryError("Accessibility access is required for stash/restore.") }
        let status = WFRegisterStashHotKey({ _,context in
            MainActor.assumeIsolated { Unmanaged<DirectStashControls>.fromOpaque(context).takeUnretainedValue().toggle() }
        },Unmanaged.passUnretained(self).toOpaque())
        guard status == 0 else { active = false; lastResult = "Stash registration failed (status \(status)); other groups are unchanged."; changed?(); throw FactoryError(lastResult) }
        active = true; preferences.stashEnabled = true
        lastResult = "Native stash/restore enabled: Tab + S."; changed?()
    }
    func disable() {
        WFUnregisterStashHotKey(); task?.cancel(); active = false; preferences.stashEnabled = false
        lastResult = "Stash shortcut released. Saved windows can still be restored from Keyboard Shortcuts."; changed?()
    }
    func restorePreference() {
        if preferences.stashEnabled { do { try enable() } catch { preferences.stashEnabled = false; lastResult = error.localizedDescription; changed?() } }
    }
    private func key(_ window: LiveWindow) -> String { "\(window.pid):\(window.id)" }
    private func check(_ entry: Saved) throws {
        try entry.context.check()
        let w = entry.window
        guard WFWindowID(w.element) == w.id, NSRunningApplication(processIdentifier:w.pid)?.bundleIdentifier == w.bundleID,
              WFWindowSpaces(w.id)?.map(\.uint64Value) == [entry.context.space],
              attribute(w.element,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              (attribute(w.element,kAXMinimizedAttribute) as? Bool) != true,
              (attribute(w.element,"AXFullScreen") as? Bool) != true,
              NSRunningApplication(processIdentifier:w.pid)?.isHidden == false else { throw FactoryError("Saved window is closed, hidden, minimized or on another desktop.") }
    }
    private func read(_ window: LiveWindow) throws -> Frame {
        var rect = CGRect.zero
        guard WFReadFrame(window.element,&rect) else { throw FactoryError("Window frame unavailable.") }
        return Frame(x:rect.minX,y:rect.minY,w:rect.width,h:rect.height)
    }
    private func focused() throws -> LiveWindow {
        guard AXIsProcessTrusted(),let app = NSWorkspace.shared.frontmostApplication,let bundle = app.bundleIdentifier,
              app.activationPolicy == .regular,bundle != Bundle.main.bundleIdentifier,
              !bundle.lowercased().contains("1password"),!bundle.lowercased().contains("onepassword"),
              bundle != "com.apple.Passwords",bundle != "com.apple.keychainaccess" else { throw FactoryError("Focus a regular application window first.") }
        let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root,0.15)
        guard let element = axElement(attribute(root,kAXFocusedWindowAttribute)),
              attribute(element,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { throw FactoryError("No focused standard window.") }
        let window = LiveWindow(id:WFWindowID(element),pid:app.processIdentifier,bundleID:bundle,
            appName:app.localizedName ?? bundle,element:element,frame:Frame(x:0,y:0,w:1,h:1))
        guard window.id != 0 else { throw FactoryError("Window identity unavailable.") }
        let frame = try read(window)
        return LiveWindow(id:window.id,pid:window.pid,bundleID:bundle,appName:window.appName,element:element,frame:frame)
    }
    private func context(for frame: Frame) throws -> Context {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let rect = CGRect(x:frame.x,y:frame.y,width:frame.w,height:frame.h)
        let screens = NSScreen.screens.sorted { a,b in
            func area(_ s: NSScreen) -> Double {
                let f = s.frame, i = rect.intersection(CGRect(x:f.minX,y:top-f.maxY,width:f.width,height:f.height))
                return i.isNull ? 0 : i.width*i.height
            }
            return area(a)>area(b)
        }
        guard let screen = screens.first else { throw FactoryError("Display unavailable.") }
        return try Context(screen:screen)
    }
    func toggle() {
        guard active,!workspaceBusy() else { return }
        do {
            let window = try focused(), identity = key(window)
            if let entry = saved[identity] { launch(entry,restoring:true,bringForward:false) }
            else {
                let context = try context(for:window.frame); try window.eligible(in:context)
                guard saved.count<512 else { throw FactoryError("Restore saved windows before stashing more.") }
                let destination = StashGeometry.destination(window.frame,on:context.frame)
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                for screen in NSScreen.screens where screen !== context.screen {
                    let f = screen.frame
                    if destination.isVisible(in:Frame(x:f.minX,y:top-f.maxY,w:f.width,h:f.height)) { throw FactoryError("Right-edge stash would enter another display; window left in place.") }
                }
                let entry = Saved(window:window,context:context)
                saved[identity] = entry; order.append(identity)
                launch(entry,restoring:false,bringForward:false)
            }
        } catch { lastResult = error.localizedDescription; hud.show(lastResult); changed?() }
    }
    func restoreLast() {
        guard !workspaceBusy() else { return }
        while let identity = order.last,let entry = saved[identity] {
            if NSRunningApplication(processIdentifier:entry.window.pid)?.bundleIdentifier != entry.window.bundleID
                || WFWindowID(entry.window.element) != entry.window.id {
                saved.removeValue(forKey:identity); order.removeLast(); continue
            }
            launch(entry,restoring:true,bringForward:true); return
        }
        lastResult = "No saved stashed windows remain."; changed?()
    }
    private func launch(_ entry: Saved,restoring: Bool,bringForward: Bool) {
        tilingTransition?(entry.window.id,restoring)
        task?.cancel(); serial += 1; let current = serial
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if serial == current { task = nil; changed?() } }
            do {
                try await perform(entry,restoring:restoring,bringForward:bringForward,front:front,requireFocus:true,showHUD:true)
            } catch is CancellationError { }
            catch { if serial == current { lastResult = error.localizedDescription; hud.show(lastResult) } }
        }
    }
    private func perform(_ entry: Saved,restoring: Bool,bringForward: Bool,front: pid_t?,requireFocus: Bool,showHUD: Bool) async throws {
                try check(entry)
                let w = entry.window
                @MainActor func guardFocus() throws {
                    try self.check(entry)
                    if !requireFocus{return}
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front else { throw FactoryError("Focus changed; stash operation stopped.") }
                    if !bringForward {
                        let root = AXUIElementCreateApplication(w.pid); AXUIElementSetMessagingTimeout(root,0.15)
                        guard let focused = axElement(attribute(root,kAXFocusedWindowAttribute)),WFWindowID(focused) == w.id else { throw FactoryError("Focused window changed; stash operation stopped.") }
                    }
                }
                if restoring {
                    let actual = try await DirectFrameApplication.apply(target:w.frame,from:read(w),check:guardFocus,read:{try self.read(w)},write:{kind,f in
                        let status = kind == .position ? WFSetPosition(w.element,CGPoint(x:f.x,y:f.y)) : WFSetSize(w.element,CGSize(width:f.w,height:f.h))
                        guard status == .success else { throw FactoryError("Application rejected stash restoration.") }
                    },submit:{
                        guard WFApplyDirectFrame(w.element,CGRect(x:w.frame.x,y:w.frame.y,width:w.frame.w,height:w.frame.h)) == .success else { throw FactoryError("Application rejected stash restoration.") }
                    })
                    guard actual.matches(w.frame) else { throw FactoryError("Saved frame not reached; restoration remains available.") }
                    saved.removeValue(forKey:key(w)); order.removeAll{$0 == key(w)}
                    if bringForward { var main: Int32 = 0, raised: Int32 = 0; _ = WFRequestWindowFocus(w.element,w.pid,&main,&raised) }
                    lastResult = "Restored \(w.appName)."; if showHUD{hud.show("RESTORED",on:entry.context.screen)}
                } else {
                    try guardFocus()
                    let destination = StashGeometry.destination(w.frame,on:entry.context.frame)
                    guard WFSetPosition(w.element,CGPoint(x:destination.x,y:destination.y)) == .success else { throw FactoryError("Application rejected stash; original frame is retained for recovery.") }
                    var confirmed = false
                    for _ in 0..<15 {
                        try await Task.sleep(for:.milliseconds(40)); try check(entry)
                        if StashGeometry.confirmed(try read(w),original:w.frame,screen:entry.context.frame) { confirmed = true; break }
                    }
                    guard confirmed else { throw FactoryError("Stash position not confirmed; original frame is retained for recovery.") }
                    lastResult = "Stashed \(w.appName). Press Tab + S again to restore."; if showHUD{hud.show("STASH",on:entry.context.screen)}
                }
    }
    func forAgent(id: UInt32,restoring: Bool,window: LiveWindow?,context: Context) async throws->Frame {
        guard !isBusy else{throw AgentFailure("busy","Stash owner is busy.")}
        let entry: Saved
        if restoring {
            guard let value=saved.values.first(where:{$0.window.id==id && $0.context.display==context.display && $0.context.space==context.space}) else{throw AgentFailure("stash_not_found","No saved stash matches that window and desktop.")};entry=value
        }else{
            if let prior=saved.values.first(where:{$0.window.id==id && $0.context.display==context.display && $0.context.space==context.space}){return try read(prior.window)}
            guard let window,window.id==id else{throw AgentFailure("window_not_found","Window is not eligible here.")}
            if saved[key(window)] != nil{return try read(window)}
            try window.eligible(in:context)
            guard saved.count<512 else{throw AgentFailure("stash_full","Restore saved windows before adding another stash.")}
            let destination=StashGeometry.destination(window.frame,on:context.frame),top=NSScreen.screens.first?.frame.maxY ?? 0
            for screen in NSScreen.screens where screen !== context.screen {let f=screen.frame;if destination.isVisible(in:Frame(x:f.minX,y:top-f.maxY,w:f.width,h:f.height)){throw FactoryError("Stash would enter another display.")}}
            entry=Saved(window:window,context:context);saved[key(window)]=entry;order.append(key(window))
        }
        tilingTransition?(id,restoring);defer{changed?()}
        try await perform(entry,restoring:restoring,bringForward:false,front:nil,requireFocus:false,showHUD:false)
        return try read(entry.window)
    }
    func agentStashes()->[UInt32] {windowIDs.sorted()}
    func stop() { WFUnregisterStashHotKey(); task?.cancel(); active = false; hud.stop() }
}
