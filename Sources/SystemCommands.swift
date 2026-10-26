import AppKit
import ApplicationServices

// The native Finder search shortcut is dispatched once, after the user's held
// modifiers are released. This preserves their input rather than releasing keys.
@MainActor
struct NativeFileSearch {
    var allowed: () -> Bool = { CGPreflightPostEventAccess() }
    var modifiersHeld: () -> Bool = {
        !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand,.maskAlternate,.maskControl,.maskShift]).isEmpty
    }
    var post: () throws -> Void = {
        guard let source=CGEventSource(stateID:.privateState),
              let down=CGEvent(keyboardEventSource:source,virtualKey:49,keyDown:true),
              let up=CGEvent(keyboardEventSource:source,virtualKey:49,keyDown:false) else {
            throw FactoryError("Finder search could not create its keyboard request.")
        }
        down.flags=[.maskCommand,.maskAlternate];up.flags=[.maskCommand,.maskAlternate]
        down.post(tap:.cghidEventTap);up.post(tap:.cghidEventTap)
    }
    var pause: () async throws -> Void = { try await Task.sleep(for:.milliseconds(25)) }
    func show() async throws {
        guard allowed() else { throw FactoryError("Finder search needs Window Factory’s existing Accessibility access.") }
        for _ in 0..<40 {
            try Task.checkCancellation()
            if !modifiersHeld() { try post();return }
            try await pause()
        }
        throw FactoryError("Release the shortcut keys, then try Search Files again.")
    }
}

@MainActor
struct SystemCommandBackend {
    var perform: (OptionalCommand) async throws -> Void
    static var live: Self { Self { command in
        switch command {
        case .emoji: NSApp.orderFrontCharacterPalette(nil)
        case .fileSearch: try await NativeFileSearch().show()
        case .keyboardViewer: try await showKeyboardViewer()
        case .sleep: try await sleepSystem()
        default: throw FactoryError("Not a system command.")
        }
    } }
    private static func sleepSystem() async throws {
        // Fixed system executable and argument; no shell, sudo or power-setting changes.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/pmset");process.arguments=["sleepnow"]
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing:FactoryError("macOS did not accept the sleep request.")) }
            }
            do { try process.run() } catch { continuation.resume(throwing:error) }
        }
    }
    private static func showKeyboardViewer() async throws {
        // Older systems expose a standalone app; current systems use the input menu.
        if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.KeyboardViewer") {
            let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
            _ = try await NSWorkspace.shared.openApplication(at:url,configuration:configuration);return
        }
        guard AXIsProcessTrusted(),let agent=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.TextInputMenuAgent").first else {
            throw FactoryError("Show the Input menu in macOS Keyboard settings to use Keyboard Viewer.")
        }
        let root=AXUIElementCreateApplication(agent.processIdentifier);AXUIElementSetMessagingTimeout(root,0.1)
        let bars=[kAXExtrasMenuBarAttribute,kAXMenuBarAttribute].compactMap{axElement(attribute(root,$0))}
        let deadline=CFAbsoluteTimeGetCurrent()+2
        for bar in bars {
            AXUIElementSetMessagingTimeout(bar,0.1)
            for item in children(bar).prefix(8) where CFAbsoluteTimeGetCurrent()<deadline {
                AXUIElementSetMessagingTimeout(item,0.1)
                guard AXUIElementPerformAction(item,kAXPressAction as CFString) == .success else {continue}
                try await Task.sleep(for:.milliseconds(80))
                var queue=children(item),visited=0
                while !queue.isEmpty && visited<64 && CFAbsoluteTimeGetCurrent()<deadline {
                    let node=queue.removeFirst();visited += 1;AXUIElementSetMessagingTimeout(node,0.1)
                    let title=attribute(node,kAXTitleAttribute) as? String ?? ""
                    if title == "Hide Keyboard Viewer" { _ = AXUIElementPerformAction(item,kAXCancelAction as CFString);return }
                    if title == "Show Keyboard Viewer" {
                        guard AXUIElementPerformAction(node,kAXPressAction as CFString) == .success else {throw FactoryError("Keyboard Viewer did not accept the menu request.")}
                        return
                    }
                    queue += children(node)
                }
                _ = AXUIElementPerformAction(item,kAXCancelAction as CFString)
            }
        }
        throw FactoryError("Keyboard Viewer was not found in the Input menu. Enable that menu in macOS Keyboard settings; this command currently requires English menu titles.")
    }
}

@MainActor
final class SystemCommands: NSObject {
    private let preferences: FactoryPreferences
    private let backend: SystemCommandBackend
    private(set) var shortcuts: [OptionalCommandShortcut]=[]
    private(set) var active=false
    private(set) var isBusy=false
    private var task: Task<Void,Never>?
    var changed: (() -> Void)?
    var failed: ((String) -> Void)?
    var blocked: () -> Bool = { false }
    var reserved: [(String,ShortcutChord)] { shortcuts.flatMap(\.reserved) }
    init(preferences: FactoryPreferences,store: KeybindingStore,defaults: UserDefaults = .standard,backend: SystemCommandBackend = .live,live: Bool = true,others: @escaping () -> [(String,ShortcutChord)]) {
        self.preferences=preferences;self.backend=backend;super.init()
        for command in OptionalCommand.allCases where command.definition.group == .system {
            let key=OptionalCommandShortcut(command:command,defaults:defaults,store:store,live:live,others:{[weak self] in others()+(self?.shortcuts.filter{$0.command != command}.flatMap(\.reserved) ?? [])})
            key.action = { [weak self] in self?.run(command) }
            key.changed = { [weak self] in self?.changed?() }
            shortcuts.append(key)
        }
    }
    func restorePreference() throws { try setEnabled(preferences.systemCommandsEnabled) }
    func setEnabled(_ value: Bool) throws {
        let previous=active
        do { for key in shortcuts {try key.setOwnerEnabled(value)} }
        catch { for key in shortcuts {try? key.setOwnerEnabled(previous)};throw error }
        active=value;preferences.systemCommandsEnabled=value;changed?()
    }
    func run(_ command: OptionalCommand) {
        guard command.definition.group == .system,!isBusy,!blocked() else {return}
        isBusy=true
        task=Task { @MainActor [weak self] in
            guard let self else{return}
            defer {isBusy=false;task=nil;changed?()}
            do {try Task.checkCancellation();try await backend.perform(command)}
            catch is CancellationError {} catch {failed?(error.localizedDescription)}
        }
    }
    func makeMenu() -> NSMenu {
        let menu=NSMenu(title:"System Commands")
        for key in shortcuts {
            let item=menu.addItem(withTitle:key.definition.title,action:#selector(invoke(_:)),keyEquivalent:"")
            item.target=self;item.representedObject=key.command.rawValue;MenuShortcut.apply(key.chord,to:item)
        }
        return menu
    }
    @objc private func invoke(_ sender: NSMenuItem) {if let raw=sender.representedObject as? String,let command=OptionalCommand(rawValue:raw){run(command)}}
    func stop() {task?.cancel();task=nil;for key in shortcuts{key.stop()};active=false}
}
