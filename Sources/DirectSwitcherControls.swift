import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor
final class DirectSwitcherControls {
    private let preferences: FactoryPreferences
    private let services = SwitcherServices()
    private let panel = WindowSwitcherPanel()
    private let hud = GeometryHUD()
    private var recency = WindowRecency()
    private var sessionTask: Task<Void,Never>?, activationTask: Task<Void,Never>?, previewTask: Task<Void,Never>?
    private var activationObserver: NSObjectProtocol?
    private var desktopObserver: NSObjectProtocol?
    private var generation = 0
    private var origin: SwitcherOrigin?
    private var sourceApplication: NSRunningApplication?
    private var records: [SwitcherWindowRecord] = []
    private var selection: SwitcherSelection?
    private var pending: [Int] = []
    var isOpen: Bool { origin != nil }
    var active = false
    var lastResult = "Native window switching is disabled."
    var workspaceBusy: () -> Bool = { false }
    var changed: (() -> Void)?
    init(preferences: FactoryPreferences) {
        self.preferences = preferences
        panel.choose = { [weak self] index in self?.commit(index:index) }
        panel.navigate = { [weak self] code in self?.navigate(code) }
        panel.dismiss = { [weak self] in self?.cancel() }
    }
    func enable() throws {
        guard AXIsProcessTrusted() else { throw FactoryError("Accessibility access is required for window switching.") }
        var failed: UInt32 = 0
        let status = WFRegisterSwitcherHotKeys({ index,context in
            MainActor.assumeIsolated {
                let owner = Unmanaged<DirectSwitcherControls>.fromOpaque(context).takeUnretainedValue()
                if index == 2 { owner.cancel(restoreFocus:true) } else if index == 0 { owner.toggle() } else { owner.cycle(-1) }
            }
        },Unmanaged.passUnretained(self).toOpaque(),&failed)
        guard status == 0 else { active = false; lastResult = "Switcher registration failed at W/Shift+W index \(failed) (status \(status)); other groups are unchanged."; changed?(); throw FactoryError(lastResult) }
        active = true; preferences.switcherEnabled = true
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteForeground() }
        }
        noteForeground(); lastResult = "Native window switching enabled: Tab + W / Tab + Shift + W."; changed?()
    }
    func disable() {
        cancel(); activationTask?.cancel(); WFUnregisterSwitcherHotKeys(); active = false; preferences.switcherEnabled = false
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver); self.activationObserver = nil }
        lastResult = "Switcher shortcuts released; the Hammerspoon switcher fallback can be enabled."; changed?()
    }
    func restorePreference() {
        if preferences.switcherEnabled { do { try enable() } catch { preferences.switcherEnabled = false; lastResult = error.localizedDescription; changed?() } }
    }
    private func noteForeground() {
        guard let app = NSWorkspace.shared.frontmostApplication,let bundle = app.bundleIdentifier,services.allowed(bundle) else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root,0.1)
        if let window = axElement(attribute(root,kAXFocusedWindowAttribute)) { recency.note(WFWindowID(window)) }
    }
    func toggle() {
        if isOpen { cancel(restoreFocus:true); lastResult = "Window switcher dismissed."; changed?() }
        else { cycle(1) }
    }
    private func navigate(_ action: SwitcherNavigationAction) {
        switch action {
        case .cancel: cancel(restoreFocus:true)
        case .select: commit()
        case .nextWindow,.previousWindow:
            selection?.advance(action == .nextWindow ? 1 : -1); render()
        case .nextDesktop,.previousDesktop:
            guard let selection,let next = SwitcherDesktopGrouping.nextGroupIndex(records.map(\.desktopLocation),selected:selection.index,direction:action == .nextDesktop ? 1 : -1) else { return }
            self.selection?.select(records[next].window.id); render()
        }
    }
    func cycle(_ direction: Int) {
        guard active,!workspaceBusy(),activationTask == nil else { return }
        if origin != nil {
            if selection == nil { pending.append(direction) }
            else { selection?.advance(direction); render() }
            return
        }
        do {
            let start = try services.origin(); origin = start
            sourceApplication = NSRunningApplication(processIdentifier:start.pid)
            if let id = start.windowID { recency.note(id) }
            pending = [direction]; generation += 1; let current = generation
            let escapeStatus = WFSetSwitcherEscape(true)
            guard escapeStatus == 0 else { throw FactoryError("Switcher Escape could not register (status \(escapeStatus)); selection cancelled.") }
            panel.loading()
            sessionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let candidates = try await services.collect(start)
                    try Task.checkCancellation(); try start.check()
                    let recentIDs = recency.ordered(candidates.map{$0.window.id},current:start.windowID)
                    let recent = recentIDs.compactMap { id in candidates.first{$0.window.id == id} }
                    let groups = SwitcherDesktopGrouping.groups(recent.map(\.desktopLocation))
                    records = groups.flatMap(\.indices).map{recent[$0]}
                    guard !records.isEmpty else { throw FactoryError("No eligible windows to switch to.") }
                    let moves = pending; pending = []
                    selection = SwitcherSelection(ids:records.map{$0.window.id},current:start.windowID,direction:moves.first ?? direction)
                    for move in moves.dropFirst() { selection?.advance(move) }
                    render()
                    for desktop in start.desktops { try desktop.check() }
                    desktopObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self,let origin = self.origin else { return }
                            if origin.desktops.contains(where:{(try? $0.check()) == nil}) { self.cancel() }
                        }
                    }
                    panel.focusForNavigation()
                    lastResult = "Window switcher open: arrows choose, Return/Enter selects, Tab+W or Escape closes."; changed?()
                } catch is CancellationError { }
                catch { if current == generation { cancel(); lastResult = error.localizedDescription; hud.show(lastResult); changed?() } }
            }
        } catch { cancel(); lastResult = error.localizedDescription; hud.show(lastResult); changed?() }
    }
    private func render() {
        previewTask?.cancel()
        guard let origin,let selection,records.indices.contains(selection.index) else { return }
        panel.render(records,selected:selection.index,origin:origin)
        let target = records[selection.index]
        let id = target.window.id, current = generation
        // This preflight does not request access. Icons are the permission-free fallback.
        guard CGPreflightScreenCaptureAccess() else { return }
        previewTask = Task { @MainActor [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
                try target.check()
                guard let window = content.windows.first(where:{$0.windowID == id && $0.owningApplication?.processID == target.window.pid}) else { return }
                let filter = SCContentFilter(desktopIndependentWindow:window)
                let configuration = SCStreamConfiguration(); configuration.width = 480
                configuration.height = max(1,Int(480*window.frame.height/max(1,window.frame.width)))
                let image = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:configuration)
                try Task.checkCancellation()
                guard let self,generation == current,self.selection?.selected == id else { return }
                panel.showPreview(NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height)))
            } catch { /* Keep the app icon if previews are unavailable. */ }
        }
    }
    func cancel(restoreFocus: Bool = false) {
        let source = origin, app = sourceApplication, ownedKeyboard = panel.hasKeyboardFocus
        generation += 1; sessionTask?.cancel(); sessionTask = nil; previewTask?.cancel(); previewTask = nil
        if let desktopObserver { NSWorkspace.shared.notificationCenter.removeObserver(desktopObserver); self.desktopObserver = nil }
        origin = nil; sourceApplication = nil; records = []; selection = nil; pending = []
        panel.hide(); _ = WFSetSwitcherEscape(false)
        // A nonactivating key panel normally returns keyboard focus itself.
        // Restore explicitly only if our app became frontmost; never undo an
        // outside click or a user's desktop change.
        if restoreFocus,ownedKeyboard,let source,let app,!app.isTerminated,
           let bundle = app.bundleIdentifier,services.allowed(bundle),
           NSRunningApplication(processIdentifier:source.pid)?.bundleIdentifier == bundle,
           source.desktops.allSatisfy({(try? $0.check()) != nil}),
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            if let id = source.windowID {
                let root = AXUIElementCreateApplication(source.pid); AXUIElementSetMessagingTimeout(root,0.1)
                let windows = children(root,kAXWindowsAttribute)+[axElement(attribute(root,kAXFocusedWindowAttribute)),axElement(attribute(root,kAXMainWindowAttribute))].compactMap{$0}
                if let window = windows.first(where:{WFWindowID($0) == id}),
                   let membership = WFWindowSpaces(id)?.map(\.uint64Value),membership.count == 1,
                   source.desktops.contains(where:{$0.space == membership[0]}) {
                    var main: Int32 = 0,raised: Int32 = 0; _ = WFRequestWindowFocus(window,source.pid,&main,&raised)
                }
            }
        }
    }
    private func commit(index: Int? = nil) {
        guard let start = origin,let chosen = index ?? selection?.index,records.indices.contains(chosen),!workspaceBusy() else { cancel(); return }
        let target = records[chosen]
        guard panel.hasKeyboardFocus,let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { cancel(); return }
        // The keyboard picker intentionally owns focus now. Keep captured desktop
        // guards, and authorize activation from this explicit picker selection.
        let activationOrigin = SwitcherOrigin(pid:front,windowID:nil,desktops:start.desktops)
        cancel()
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { activationTask = nil; changed?() }
            do {
                try await services.activate(target,from:activationOrigin)
                recency.note(target.window.id); lastResult = "Switched to \(target.window.appName): exact focus verified."
            } catch is CancellationError { }
            catch { lastResult = error.localizedDescription; hud.show(lastResult) }
        }
    }
    func stop() {
        cancel(); activationTask?.cancel(); WFUnregisterSwitcherHotKeys(); active = false; hud.stop(); panel.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver); self.activationObserver = nil }
    }
}
