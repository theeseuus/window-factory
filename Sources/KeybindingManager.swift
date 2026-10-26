import AppKit

@MainActor
final class KeybindingManager {
    let store: KeybindingStore
    var additionalShortcuts: ()->[(String,ShortcutChord)] = { [] }
    var changed: (() -> Void)?
    var recoverRegistrations: (() -> Void)?
    init(store: KeybindingStore) { self.store = store }
    func configure(_ draft: [String:ShortcutChord]) throws {
        try ShortcutValidation.validate(draft,additional:additionalShortcuts())
        let definitions = ShortcutDefinition.all
        let signatures = definitions.map{$0.group.signature},indices = definitions.map(\.index)
        let chords = definitions.map{draft[$0.id] ?? $0.standard}
        var failed: UInt32 = 0,rollback: Int32 = 0
        let status = WFUpdateShortcutConfiguration(signatures,indices,chords.map(\.key),chords.map(\.modifiers),UInt32(definitions.count),&failed,&rollback)
        guard status == 0 else {
            if rollback != 0 { recoverRegistrations?() }
            let index = min(Int(failed),definitions.count-1)
            throw FactoryError(rollback == 0 ? "\(chords[index].label) is unavailable. Your previous shortcuts are still active." : "Shortcuts could not be fully restored. Check the enabled groups or restart Window Factory.")
        }
    }
    func restore() throws { try configure(store.overrides) }
    func set(_ chord: ShortcutChord?,for definition: ShortcutDefinition) throws {
        var draft = store.overrides
        if let chord,chord != definition.standard { draft[definition.id] = chord } else { draft.removeValue(forKey:definition.id) }
        try commit(draft)
    }
    func reset() throws { try commit([:]) }
    private func commit(_ draft: [String:ShortcutChord]) throws {
        // Encode before changing live registrations; persistence has no throwing
        // work left after the operating system accepts the complete draft.
        try ShortcutValidation.validate(draft,additional:additionalShortcuts())
        let data = try JSONEncoder().encode(ShortcutEnvelope(version:1,overrides:draft))
        try configure(draft); store.commit(draft,data:data); changed?()
    }
}

@MainActor
final class ShortcutRecorder: NSButton {
    static weak var current: ShortcutRecorder?
    let definition: ShortcutDefinition
    private weak var manager: KeybindingManager?
    private let readChord: (() -> ShortcutChord?)?
    private let saveChord: ((ShortcutChord) throws -> Void)?
    private var monitor: Any?,observer: NSObjectProtocol?
    private var recording = false,accepted = false
    var isRecording: Bool { recording }
    var finished: (() -> Void)?
    init(_ definition: ShortcutDefinition,manager: KeybindingManager?,read: (() -> ShortcutChord?)? = nil,save: ((ShortcutChord) throws -> Void)? = nil) {
        self.definition = definition; self.manager = manager; self.readChord = read; self.saveChord = save
        super.init(frame:.zero)
        bezelStyle = .rounded; target = self; action = #selector(start)
        setAccessibilityLabel("\(definition.title) shortcut"); displayChord()
        toolTip = "Change \(definition.title.lowercased()) shortcut"
    }
    private func caption(_ value: String,modifierCount: Int = 0) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .right
        let text = NSMutableAttributedString(string:value,attributes:[.font:font ?? NSFont.systemFont(ofSize:NSFont.systemFontSize),.foregroundColor:NSColor.controlTextColor,.paragraphStyle:paragraph])
        if modifierCount>1 { text.addAttribute(.kern,value:ShortcutChord.modifierTracking,range:NSRange(location:0,length:modifierCount-1)) }
        alignment = .right; attributedTitle = text
    }
    private func displayChord() {
        let value = readChord.map{$0()} ?? (manager?.store.chord(definition) ?? definition.standard)
        guard let chord = value else { caption("Record…");setAccessibilityValue("No shortcut");return }
        caption(chord.label,modifierCount:chord.modifierLabel.utf16.count); setAccessibilityValue(chord.label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    @objc private func start() {
        guard manager != nil || saveChord != nil,let window else { return }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        Self.current?.cancel(); Self.current = self
        window.makeFirstResponder(self); recording = true; accepted = false; caption("Press shortcut"); setAccessibilityValue("Recording")
        WFSetShortcutCapture({ key,modifiers,context in
            MainActor.assumeIsolated {
                guard let context else { return }
                Unmanaged<ShortcutRecorder>.fromOpaque(context).takeUnretainedValue().receive(key,modifiers)
            }
        },Unmanaged.passUnretained(self).toOpaque())
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp,.flagsChanged,.leftMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self,self.recording else { return false }
                if event.type == .leftMouseDown { self.cancel(); return false }
                guard event.window === self.window else { return false }
                if self.accepted {
                    if event.type == .keyUp || (event.type == .flagsChanged && event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty) { self.cancel() }
                    return event.type == .keyDown
                }
                if event.type == .keyDown {
                    self.receive(UInt32(event.keyCode),Self.modifiers(event.modifierFlags)); return true
                }
                return false
            }
            return handled ? nil : event
        }
        observer = NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
    }
    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        (flags.contains(.command) ? ShortcutChord.command : 0)|(flags.contains(.option) ? ShortcutChord.option : 0)|(flags.contains(.control) ? ShortcutChord.control : 0)|(flags.contains(.shift) ? ShortcutChord.shift : 0)
    }
    private func receive(_ key: UInt32,_ modifiers: UInt32) {
        guard recording,!accepted,window?.isKeyWindow == true,NSApp.isActive else { return }
        if key == 53 { cancel(); return }
        do {
            let chord = ShortcutChord(key:key,modifiers:modifiers,name:ShortcutChord.keyName(key))
            if let saveChord { try saveChord(chord) } else { try manager?.set(chord,for:definition) }
            accepted = true; displayChord()
        } catch {
            let owner = window; cancel()
            let alert = NSAlert(); alert.messageText = "Shortcut not changed"; alert.informativeText = error.localizedDescription
            if let owner { alert.beginSheetModal(for:owner) } else { alert.runModal() }
        }
    }
    func cancel() {
        guard recording else { return }; recording = false
        if Self.current === self { Self.current = nil }
        WFSetShortcutCapture(nil,nil)
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        displayChord()
        finished?()
    }
    override func resignFirstResponder() -> Bool { cancel(); return super.resignFirstResponder() }
}
