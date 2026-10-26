import AppKit

@MainActor final class WindowControlPilot: NSObject,NSApplicationDelegate,NSWindowDelegate {
    var window: NSWindow?
    private var accordionWindows: [NSWindow] = []
    let frameLabel = NSTextField(labelWithString:"")
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:420),
            styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Window Factory — Disposable Control Test"
        window.delegate = self
        window.minSize = NSSize(width:80,height:80); window.collectionBehavior = [.moveToActiveSpace]
        let text = NSTextField(wrappingLabelWithString:"Disposable window-control test\n\nKeep this window focused while trying the existing Tab-held shortcuts.\n\n2 / 3 / 4 / 8: position cycles (Shift reverses)\n− / =: canonical size / position (Shift reverses)\n↑ then ↓: centred half and previous frame\n↩: centre horizontally; ⇧↩: maximize\n[ / ]: narrow / widen; D: minimize\n\nClick this app in the Dock to bring it back after minimizing.\nClose its red button when finished. No documents or terminal sessions are involved.")
        text.font = .systemFont(ofSize:15); text.translatesAutoresizingMaskIntoConstraints = false
        frameLabel.font = .monospacedSystemFont(ofSize:12,weight:.medium)
        frameLabel.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(frameLabel)
        window.contentView!.addSubview(text)
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:18),
            text.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-18),
            frameLabel.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),
            frameLabel.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:18),
            frameLabel.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-18),
            text.topAnchor.constraint(equalTo:frameLabel.bottomAnchor,constant:12)])
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle:"Quit Window Control Test",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
        self.window = window; window.center()
        if Bundle.main.object(forInfoDictionaryKey:"WFSpacePilot") as? Bool == true {
            window.title = "Window Factory — Disposable Space Move Test"
            text.stringValue = "Disposable Space move-and-follow test\n\nClick this window, then hold Tab and press Right once. It should move to the next ordinary desktop and take you with it, keeping its frame and focus.\n\nUse Tab+Left to return. If already at the last desktop, start Left and return Right. There is no wrap at the ends.\n\nControl+Left/Right should still move only you.\nClose this test window when finished. No documents or terminal sessions are involved."
        }
        if (CommandLine.arguments.contains("--accordion") || Bundle.main.object(forInfoDictionaryKey:"WFAccordionPilot") as? Bool == true),let screen = NSScreen.main {
            window.title = "Accordion Test — Anchor (leave focused)"
            text.stringValue = "Accordion pilot: three disposable windows in this app.\n\nClick this anchor, then hold Tab + Shift and press S.\nThe anchor must stay still. The other two windows should match its size and fan right/down by 28 × 22 points per step.\n\nRepeat to check stability; try geometry, focus, stash/restore and switching afterwards.\nQuit this test app when finished. No documents or terminal sessions are involved."
            for index in 1...2 {
                let extra = NSWindow(contentRect:NSRect(x:screen.visibleFrame.minX+Double(index)*150,y:screen.visibleFrame.minY+Double(index)*100,width:360,height:260),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
                extra.title = "Accordion Test — Other \(index)"
                extra.isReleasedWhenClosed = false; extra.minSize = NSSize(width:80,height:80)
                extra.collectionBehavior = [.moveToActiveSpace]
                let label = NSTextField(labelWithString:"Disposable accordion window \(index)")
                label.frame = NSRect(x:15,y:100,width:320,height:25); extra.contentView!.addSubview(label)
                accordionWindows.append(extra); extra.orderFront(nil)
            }
        }
        reportFrame(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func reportFrame() {
        guard let window else { return }
        let f = window.frame, top = NSScreen.screens.first?.frame.maxY ?? 0
        frameLabel.stringValue = String(format:"Frame: x %.0f · y %.0f · width %.0f · height %.0f",f.minX,top-f.maxY,f.width,f.height)
    }
    func windowDidMove(_ notification: Notification) { reportFrame() }
    func windowDidResize(_ notification: Notification) { reportFrame() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool {
        window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil); return true
    }
}
@main enum PilotMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = WindowControlPilot(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
