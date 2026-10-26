import AppKit

@MainActor
final class DirectFocusControls {
    private let preferences: FactoryPreferences
    private let hud = GeometryHUD()
    private var task: Task<Void,Never>?
    var isBusy: Bool { task != nil }
    var active = false
    var lastResult = "Native directional focus is disabled."
    var workspaceBusy: () -> Bool = { false }
    var changed: (() -> Void)?
    private let directions = FocusDirection.allCases
    init(preferences: FactoryPreferences) { self.preferences = preferences }
    func enable() throws {
        guard AXIsProcessTrusted() else { throw FactoryError("Accessibility access is required for directional focus.") }
        let keys: [UInt32] = [4,38,40,37] // H J K L, Hyper (no Shift).
        var failed: UInt32 = 0
        let status = WFRegisterFocusHotKeys(keys,UInt32(keys.count),{ index,context in
            MainActor.assumeIsolated {
                let owner = Unmanaged<DirectFocusControls>.fromOpaque(context).takeUnretainedValue()
                guard Int(index)<owner.directions.count else { return }
                owner.run(owner.directions[Int(index)])
            }
        },Unmanaged.passUnretained(self).toOpaque(),&failed)
        guard status == 0 else {
            active = false; lastResult = "Directional focus registration failed at H/J/K/L index \(failed) (status \(status)); geometry remains registered."
            changed?(); throw FactoryError(lastResult)
        }
        active = true; preferences.focusEnabled = true
        lastResult = "Native directional focus enabled: 4 exclusive shortcuts."; changed?()
    }
    func disable() {
        WFUnregisterFocusHotKeys(); task?.cancel(); active = false; preferences.focusEnabled = false
        lastResult = "Directional focus shortcuts released; the Hammerspoon focus fallback can be enabled."; changed?()
    }
    func restorePreference() {
        if preferences.focusEnabled { do { try enable() } catch { preferences.focusEnabled = false; lastResult = error.localizedDescription; changed?() } }
    }
    private func allowed(_ bundle: String) -> Bool {
        bundle != Bundle.main.bundleIdentifier && bundle != "org.hammerspoon.Hammerspoon"
            && !bundle.lowercased().contains("1password") && !bundle.lowercased().contains("onepassword")
            && bundle != "com.apple.Passwords" && bundle != "com.apple.keychainaccess"
    }
    private func screen(for frame: Frame) -> NSScreen? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.max { a,b in
            func area(_ s: NSScreen) -> Double {
                let f = s.frame, r = CGRect(x:frame.x,y:frame.y,width:frame.w,height:frame.h)
                    .intersection(CGRect(x:f.minX,y:top-f.maxY,width:f.width,height:f.height))
                return r.isNull ? 0 : r.width*r.height
            }
            return area(a)<area(b)
        }
    }
    private func window(_ element: AXUIElement,_ app: NSRunningApplication) -> LiveWindow? {
        guard let bundle = app.bundleIdentifier,allowed(bundle),app.activationPolicy == .regular,!app.isHidden,
              attribute(element,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { return nil }
        var rect = CGRect.zero
        guard WFReadFrame(element,&rect),rect.width>0,rect.height>0 else { return nil }
        let id = WFWindowID(element)
        guard id != 0 else { return nil }
        return LiveWindow(id:id,pid:app.processIdentifier,bundleID:bundle,appName:app.localizedName ?? bundle,
            element:element,frame:Frame(x:rect.minX,y:rect.minY,w:rect.width,h:rect.height))
    }
    private func focused() throws -> (LiveWindow,Context) {
        guard AXIsProcessTrusted(),let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier,allowed(bundle) else { throw FactoryError("Focus a regular application window first.") }
        let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root,0.15)
        guard let element = axElement(attribute(root,kAXFocusedWindowAttribute)),let source = window(element,app),
              let display = screen(for:source.frame) else { throw FactoryError("No focused standard window.") }
        let context = try Context(screen:display); try source.eligible(in:context)
        return (source,context)
    }
    private func checkSource(_ source: LiveWindow,_ context: Context) throws {
        try source.eligible(in:context)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else { throw FactoryError("Focus changed; directional command stopped.") }
        let root = AXUIElementCreateApplication(source.pid); AXUIElementSetMessagingTimeout(root,0.15)
        guard let focused = axElement(attribute(root,kAXFocusedWindowAttribute)),WFWindowID(focused) == source.id else {
            throw FactoryError("Focused window changed; directional command stopped.")
        }
    }
    func run(_ direction: FocusDirection) {
        guard active,task == nil,!workspaceBusy() else { return }
        let snapshot: (LiveWindow,Context)
        do { snapshot = try focused() } catch { lastResult = error.localizedDescription; changed?(); return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { task = nil; changed?() }
            do { try await perform(direction,source:snapshot.0,context:snapshot.1) }
            catch is CancellationError { lastResult = "Directional focus cancelled." }
            catch { lastResult = error.localizedDescription; hud.show(lastResult) }
        }
    }
    private func perform(_ direction: FocusDirection,source: LiveWindow,context: Context) async throws {
        try checkSource(source,context)
        // Snapshot each visible display's ordinary Space; never switch a Space.
        let contexts = NSScreen.screens.compactMap { try? Context(screen:$0) }
        let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
        let visible = infos.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        let ids = Set(visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        let pids = visible.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
        var visited = Set<pid_t>(), candidates: [(LiveWindow,Context)] = []
        for pid in pids where visited.insert(pid).inserted {
            try checkSource(source,context); await Task.yield()
            guard let app = NSRunningApplication(processIdentifier:pid),let bundle = app.bundleIdentifier,allowed(bundle),
                  app.activationPolicy == .regular,!app.isHidden else { continue }
            let root = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root,0.1)
            for element in children(root,kAXWindowsAttribute) {
                guard let candidate = window(element,app),candidate.id != source.id,ids.contains(candidate.id),
                      let display = screen(for:candidate.frame),
                      let targetContext = contexts.first(where:{$0.screen === display}),candidate.frame.isVisible(in:targetContext.frame),
                      (try? candidate.eligible(in:targetContext)) != nil else { continue }
                candidates.append((candidate,targetContext))
            }
        }
        // Preserve visible stacking order for exact score ties.
        let order = visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        candidates.sort { (order.firstIndex(of:$0.0.id) ?? Int.max)<(order.firstIndex(of:$1.0.id) ?? Int.max) }
        let current = FocusRecord(id:source.id,display:context.display,frame:source.frame)
        let records = candidates.map { FocusRecord(id:$0.0.id,display:$0.1.display,frame:$0.0.frame) }
        guard let selected = DirectionalFocus.nearest(current,records,direction),
              let (target,targetContext) = candidates.first(where:{$0.0.id == selected.id}) else {
            lastResult = "No window \(direction.rawValue)."; return
        }
        try checkSource(source,context); try target.eligible(in:targetContext)
        var mainStatus: Int32 = 0, raiseStatus: Int32 = 0
        let activationStatus = WFRequestWindowFocus(target.element,target.pid,&mainStatus,&raiseStatus)
        // API dispatch is evidence, not proof of focus. Confirm the exact
        // target independently, including apps that reject optional AXRaise.
        for _ in 0..<8 {
            try await Task.sleep(for:.milliseconds(30)); try context.check(); try target.eligible(in:targetContext)
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == source.pid || front == target.pid else { throw FactoryError("User focus changed; verification stopped.") }
            let root = AXUIElementCreateApplication(target.pid); AXUIElementSetMessagingTimeout(root,0.1)
            if front == target.pid,let focused = axElement(attribute(root,kAXFocusedWindowAttribute)),WFWindowID(focused) == target.id {
                lastResult = "Focus \(direction.rawValue): \(target.appName), verified."; return
            }
        }
        throw FactoryError("\(target.appName): exact focus was not confirmed (main \(mainStatus), raise \(raiseStatus), activation \(activationStatus)).")
    }
    func stop() { WFUnregisterFocusHotKeys(); task?.cancel(); active = false; hud.stop() }
}
