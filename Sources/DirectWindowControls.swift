import AppKit

@MainActor
final class GeometryHUD {
    private var panel: NSPanel?
    private var hide: Task<Void,Never>?
    func show(_ message: String,on screen: NSScreen? = nil) {
        hide?.cancel()
        if panel == nil {
            let window = NSPanel(contentRect:NSRect(x:0,y:0,width:460,height:54),
                styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            window.isOpaque = false; window.backgroundColor = .clear; window.level = .statusBar
            window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace,.transient,.ignoresCycle]
            let label = NSTextField(wrappingLabelWithString:""); label.alignment = .center
            label.font = .systemFont(ofSize:13,weight:.medium); label.textColor = .white
            let content = NSView(frame:NSRect(x:0,y:0,width:460,height:54)); content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor; content.layer?.cornerRadius = 10
            label.frame = NSRect(x:12,y:10,width:436,height:36); content.addSubview(label); window.contentView = content; panel = window
        }
        guard let panel, let label = panel.contentView?.subviews.first as? NSTextField,
              let frame = (screen ?? NSScreen.main)?.visibleFrame else { return }
        label.stringValue = message
        panel.setFrameOrigin(NSPoint(x:frame.midX-230,y:frame.minY+24)); panel.orderFrontRegardless()
        hide = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.seconds(1.4)) } catch { return }
            self?.panel?.orderOut(nil)
        }
    }
    func stop() { hide?.cancel(); panel?.orderOut(nil) }
}

@MainActor
final class DirectWindowControls {
    private let preferences: FactoryPreferences
    private let hud = GeometryHUD()
    private var task: Task<Void,Never>?
    private var operationSerial = 0
    private var pendingFrame: (pid: pid_t, id: CGWindowID, frame: Frame)?
    private var cycles: [String:Int] = [:]
    private var restores: [String:Frame] = [:]
    var isBusy: Bool { task != nil }
    var active = false
    var lastResult = "Native geometry shortcuts are disabled."
    var workspaceBusy: () -> Bool = { false }
    var changed: (() -> Void)?
    var willChangeFrame: ((UInt32)->Void)?
    init(preferences: FactoryPreferences) { self.preferences = preferences }
    func forAgent(_ command: GeometryCommand,window: LiveWindow,context: Context) async throws {
        guard !isBusy else{throw AgentFailure("busy","Geometry owner is busy.")}
        willChangeFrame?(window.id);defer{pendingFrame=nil;changed?()}
        try await perform(command,window:window,context:context,frame:window.frame,requireFocus:false,showHUD:false)
    }
    func enable() throws {
        guard AXIsProcessTrusted() else { throw FactoryError("Accessibility access is required before enabling geometry shortcuts.") }
        let shortcuts = GeometryShortcut.all
        let keys = shortcuts.map(\.keyCode), modifiers = shortcuts.map(\.modifiers)
        var failed: UInt32 = 0
        let status = WFRegisterHotKeys(keys,modifiers,UInt32(keys.count),{ index,context in
            MainActor.assumeIsolated {
                let owner = Unmanaged<DirectWindowControls>.fromOpaque(context).takeUnretainedValue()
                guard Int(index)<GeometryShortcut.all.count else { return }
                owner.run(GeometryShortcut.all[Int(index)].command)
            }
        },Unmanaged.passUnretained(self).toOpaque(),&failed)
        guard status == 0 else {
            active = false
            lastResult = "No native geometry shortcuts registered. Conflict at \(shortcuts[min(Int(failed),shortcuts.count-1)].label) (status \(status))."
            changed?(); throw FactoryError(lastResult)
        }
        active = true; preferences.geometryEnabled = true
        lastResult = "Native geometry controls enabled: 19 exclusive shortcuts."
        changed?()
    }
    func disable() {
        WFUnregisterHotKeys(); active = false; preferences.geometryEnabled = false
        task?.cancel(); lastResult = "Native geometry shortcuts released. The managed Hammerspoon fallback can now be enabled."
        changed?()
    }
    func restorePreference() {
        if preferences.geometryEnabled {
            do { try enable() } catch { preferences.geometryEnabled = false; lastResult = error.localizedDescription; changed?() }
        }
    }
    func run(_ command: GeometryCommand) {
        guard active else { return }
        guard !workspaceBusy() else { hud.show("Finish the current Window Factory operation first."); return }
        // Capture the event's target now. An async task must never resolve a
        // different focused window after the user's focus has moved.
        let target: (LiveWindow,Context)
        do { target = try focused() }
        catch { lastResult = "\(command.title): \(error.localizedDescription)"; hud.show(lastResult); changed?(); return }
        willChangeFrame?(target.0.id)
        let frame = pendingFrame.flatMap { $0.pid == target.0.pid && $0.id == target.0.id ? $0.frame : nil } ?? target.0.frame
        task?.cancel()
        operationSerial += 1
        let serial = operationSerial
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if operationSerial == serial { task = nil; pendingFrame = nil; changed?() } }
            do { try await perform(command,window:target.0,context:target.1,frame:frame) }
            catch is CancellationError { if operationSerial == serial { lastResult = "Window command cancelled." } }
            catch { lastResult = "\(command.title): \(error.localizedDescription)"; hud.show(lastResult) }
        }
    }
    private func focused() throws -> (LiveWindow,Context) {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier,
              !bundle.lowercased().contains("1password"), !bundle.lowercased().contains("onepassword"),
              bundle != "com.apple.Passwords", bundle != "com.apple.keychainaccess" else {
            throw FactoryError("Focus a regular application window first.")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root,0.25)
        guard let element = axElement(attribute(root,kAXFocusedWindowAttribute)),
              attribute(element,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { throw FactoryError("No focused standard window.") }
        var rect = CGRect.zero
        guard WFReadFrame(element,&rect), rect.width>0,rect.height>0 else { throw FactoryError("Focused window frame unavailable.") }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screen = NSScreen.screens.max { a,b in
            func area(_ screen: NSScreen) -> CGFloat {
                let f = screen.frame, intersection = rect.intersection(CGRect(x:f.minX,y:top-f.maxY,width:f.width,height:f.height))
                return intersection.isNull ? 0 : intersection.width*intersection.height
            }
            return area(a)<area(b)
        }
        guard let screen else { throw FactoryError("Focused window display unavailable.") }
        let context = try Context(screen:screen)
        let window = LiveWindow(id:WFWindowID(element),pid:app.processIdentifier,bundleID:bundle,
            appName:app.localizedName ?? bundle,element:element,frame:Frame(x:rect.minX,y:rect.minY,w:rect.width,h:rect.height))
        guard window.id != 0 else { throw FactoryError("Focused window identity unavailable.") }
        try window.eligible(in:context); try sameFocus(window,context)
        return (window,context)
    }
    private func sameFocus(_ window: LiveWindow,_ context: Context) throws {
        try context.check()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { throw FactoryError("Focus changed; command stopped.") }
        let root = AXUIElementCreateApplication(window.pid); AXUIElementSetMessagingTimeout(root,0.25)
        guard let focused = axElement(attribute(root,kAXFocusedWindowAttribute)), WFWindowID(focused) == window.id else {
            throw FactoryError("Focused window changed; command stopped.")
        }
    }
    private func perform(_ command: GeometryCommand,window: LiveWindow,context: Context,frame: Frame,requireFocus: Bool = true,showHUD: Bool = true) async throws {
        func checkTarget() throws {try window.eligible(in:context);if requireFocus{try sameFocus(window,context)}}
        let screen = context.frame
        let identity = "\(window.pid):\(window.id)"
        if cycles.count+restores.count>512 { cycles.removeAll(); restores.removeAll() }
        if command == .minimize {
            try checkTarget()
            guard AXUIElementSetAttributeValue(window.element,kAXMinimizedAttribute as CFString,kCFBooleanTrue) == .success else { throw FactoryError("Minimize request rejected.") }
            try await Task.sleep(for:.milliseconds(160)); try context.check()
            guard WFWindowID(window.element) == window.id, attribute(window.element,kAXMinimizedAttribute) as? Bool == true else { throw FactoryError("Minimize was not confirmed.") }
        } else {
            let target: Frame
            if let slots = DirectGeometry.legacySlots(command) {
                let index = DirectGeometry.nextIndex(cycles[identity],count:slots.count,reverse:command.reverse)
                cycles[identity] = index; target = DirectGeometry.absolute(slots[index],screen)
            } else {
                switch command {
                case .sizeNext,.sizePrevious,.positionNext,.positionPrevious:
                    target = DirectGeometry.canonicalCycle(command,frame:frame,screen:screen)
                case .centeredHalf:
                    restores[identity] = frame; target = DirectGeometry.absolute(Frame(x:0.25,y:0,w:0.5,h:1),screen)
                case .restoreFrame:
                    target = restores[identity] ?? DirectGeometry.absolute(Frame(x:0.075,y:0.05,w:0.85,h:0.9),screen)
                case .centerHorizontally: target = DirectGeometry.centerHorizontally(frame,in:screen)
                case .narrower,.wider: target = DirectGeometry.adjustWidth(frame,in:screen,direction:command == .narrower ? -1 : 1)
                case .maximize: target = screen
                default: throw FactoryError("Unsupported geometry command.")
                }
            }
            pendingFrame = (window.pid,window.id,target)
            let actual = try await DirectFrameApplication.apply(target:target,from:frame,
                check: { try checkTarget() },
                read: {
                    var rect = CGRect.zero
                    guard WFReadFrame(window.element,&rect) else { throw FactoryError("Window frame unavailable during placement.") }
                    return Frame(x:rect.minX,y:rect.minY,w:rect.width,h:rect.height)
                },
                write: { change,goal in
                    let status: AXError
                    switch change {
                    case .position: status = WFSetPosition(window.element,CGPoint(x:goal.x,y:goal.y))
                    case .size: status = WFSetSize(window.element,CGSize(width:goal.w,height:goal.h))
                    }
                    guard status == .success else { throw FactoryError("Application rejected the frame change (Accessibility status \(status.rawValue)).") }
                },submit: {
                    let status = WFApplyDirectFrame(window.element,CGRect(x:target.x,y:target.y,width:target.w,height:target.h))
                    guard status == .success else { throw FactoryError("Application rejected the frame change (Accessibility status \(status.rawValue)).") }
                })
            guard actual.matches(target) else {
                throw FactoryError("Application did not reach the requested frame after settling (size or position may be constrained).")
            }
        }
        lastResult = "\(command.title): verified."; if showHUD{hud.show(command.title,on:context.screen)}
    }
    func stop() { WFUnregisterHotKeys(); active = false; task?.cancel(); hud.stop() }
}
