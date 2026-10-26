import AppKit

@MainActor
final class SpaceIndicator: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let preferences: FactoryPreferences
    private var item: NSStatusItem?
    private var observers: [(NotificationCenter,NSObjectProtocol)] = []
    private var settling: Task<Void,Never>?
    private var images: [String:NSImage] = [:]
    private var descriptionItem: NSMenuItem?
    var active: Bool { item != nil }
    var lastResult = "Menu-bar Space indicator is disabled."
    var changed: (() -> Void)?
    var openLibrary: (() -> Void)?
    var openSettings: (() -> Void)?
    var tilingChord: (()->ShortcutChord?)?
    var newCodexChord: (()->ShortcutChord?)?
    var newCodexWindow: (()->Void)?
    var newCodexAvailable: (()->Bool)?
    var openTiling: (()->Void)?
    var openShortcuts: (() -> Void)?
    init(preferences: FactoryPreferences) { self.preferences = preferences; super.init() }
    func enable() {
        stop()
        let status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        status.button?.imagePosition = .imageOnly
        item = status; preferences.spaceIndicatorEnabled = true
        let menu = Self.menu(target:self); descriptionItem = menu.items.first
        status.menu = menu; refreshMenuShortcuts()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,NSWorkspace.didActivateApplicationNotification,NSWorkspace.didWakeNotification] {
            observe(workspace,name)
        }
        for name in [NSApplication.didChangeScreenParametersNotification,NSWindow.didBecomeKeyNotification] {
            observe(NotificationCenter.default,name)
        }
        scheduleRefresh()
    }
    static func menu(target: SpaceIndicator?) -> NSMenu {
        let menu = NSMenu(),description = NSMenuItem(title:"Reading active Space…",action:nil,keyEquivalent:"")
        menu.delegate = target
        description.isEnabled = false; menu.addItem(description); menu.addItem(.separator())
        for (title,selector,id) in [("Open Window Factory",#selector(showLibrary),"library.0"),("Settings…",#selector(showSettings),"settings"),("Keyboard Shortcuts…",#selector(showShortcuts),"library.1"),("Tiling…",#selector(showTiling),"tiling"),("New Codex Window",#selector(createCodexWindow),"codex.new-window")] {
            let entry = menu.addItem(withTitle:title,action:selector,keyEquivalent:""); entry.target = target; entry.identifier = NSUserInterfaceItemIdentifier(id)
        }
        let settings = menu.items.first{$0.identifier?.rawValue == "settings"}!
        settings.keyEquivalent = ","; settings.keyEquivalentModifierMask = .command
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle:"Quit Window Factory",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        quit.keyEquivalentModifierMask = [.command]; quit.target = NSApp
        return menu
    }
    static func updateShortcuts(in menu: NSMenu,preferences: FactoryPreferences) {
        for definition in ShortcutDefinition.all where definition.group == .library {
            guard let entry = menu.items.first(where:{$0.identifier?.rawValue == definition.id}) else { continue }
            let chord = preferences.shortcuts.chord(definition)
            entry.keyEquivalent = chord.menuKeyEquivalent; entry.keyEquivalentModifierMask = chord.menuModifiers
            entry.toolTip = chord.actionHint
        }
    }
    func refreshMenuShortcuts() { if let menu = item?.menu { Self.updateShortcuts(in:menu,preferences:preferences);if let entry=menu.items.first(where:{$0.identifier?.rawValue == "tiling"}){MenuShortcut.apply(tilingChord?(),to:entry)};if let entry=menu.items.first(where:{$0.identifier?.rawValue == "codex.new-window"}){MenuShortcut.apply(newCodexChord?(),to:entry)} } }
    func validateMenuItem(_ menuItem: NSMenuItem)->Bool { menuItem.identifier?.rawValue == "codex.new-window" ? newCodexAvailable?() == true : true }
    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenuShortcuts();menu.items.first{$0.identifier?.rawValue == "codex.new-window"}?.isEnabled = newCodexAvailable?() == true }
    private func observe(_ center: NotificationCenter,_ name: Notification.Name) {
        let token = center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        observers.append((center,token))
    }
    func disable() {
        stop(); preferences.spaceIndicatorEnabled = false
        lastResult = "Space indicator removed; the Hammerspoon indicator fallback can be enabled."; changed?()
    }
    func restorePreference() { if preferences.spaceIndicatorEnabled { enable() } }
    func scheduleRefresh() {
        guard active else { return }
        refresh(); settling?.cancel()
        settling = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
            self?.settling = nil; self?.refresh()
        }
    }
    private func screen() -> NSScreen? {
        // Match the active app's display where AX is already allowed. Do not
        // inspect credential apps, request access, or activate any application.
        if AXIsProcessTrusted(),let app = NSWorkspace.shared.frontmostApplication,let bundle = app.bundleIdentifier,
           !bundle.lowercased().contains("1password"),!bundle.lowercased().contains("onepassword"),
           bundle != "com.apple.Passwords",bundle != "com.apple.keychainaccess" {
            let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root,0.05)
            if let window = axElement(attribute(root,kAXFocusedWindowAttribute)) {
                var frame = CGRect.zero
                if WFReadFrame(window,&frame),frame.width>0,frame.height>0 {
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    var best: NSScreen?,bestArea: CGFloat = 0
                    for screen in NSScreen.screens {
                        let f = screen.frame,i = frame.intersection(CGRect(x:f.minX,y:top-f.maxY,width:f.width,height:f.height))
                        let area = i.isNull ? 0 : i.width*i.height
                        if area>bestArea { best = screen; bestArea = area }
                    }
                    if let best { return best }
                }
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
    private func refresh() {
        guard let item else { return }
        let state: SpaceIndicatorState
        if let screen = screen(),let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let raw = WFSwitcherSpaces(display.uint32Value) as? [[String:Any]]
            let entries = raw?.compactMap { value -> IndicatorSpace? in
                guard let id = value["id"] as? NSNumber,let kind = value["kind"] as? NSNumber,let shown = value["shown"] as? NSNumber else { return nil }
                return IndicatorSpace(id:id.uint64Value,kind:kind.intValue,shown:shown.boolValue)
            }
            state = SpaceIndicatorState.resolve(entries?.count == raw?.count ? entries : nil,display:screen.localizedName)
        } else { state = SpaceIndicatorState(label:"?",tooltip:"No active screen") }
        if images[state.label] == nil { images[state.label] = Self.image(state.label) }
        item.button?.image = images[state.label]
        item.button?.toolTip = state.tooltip
        item.button?.setAccessibilityLabel("Window Factory — \(state.tooltip)")
        descriptionItem?.title = state.tooltip
        lastResult = state.tooltip; changed?()
    }
    static func image(_ label: String) -> NSImage {
        let width = max(24,CGFloat(label.count)*8+8),height: CGFloat = 18
        let image = NSImage(size:NSSize(width:width,height:height),flipped:false) { _ in
            NSColor.black.setStroke()
            let border = NSBezierPath(roundedRect:NSRect(x:0.75,y:0.75,width:width-1.5,height:height-1.5),xRadius:4,yRadius:4)
            border.lineWidth = 1.25; border.stroke()
            let text = NSAttributedString(string:label,attributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.black])
            let size = text.size()
            text.draw(at:NSPoint(x:(width-size.width)/2,y:(height-size.height)/2))
            return true
        }
        image.isTemplate = true; return image
    }
    @objc private func createCodexWindow() { newCodexWindow?() }
    @objc private func showTiling() { openTiling?() }
    @objc private func showLibrary() { openLibrary?() }
    @objc private func showSettings() { openSettings?() }
    @objc private func showShortcuts() { openShortcuts?() }
    func stop() {
        settling?.cancel(); settling = nil
        for (center,token) in observers { center.removeObserver(token) }
        observers = []; images = [:]; descriptionItem = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil
    }
}
