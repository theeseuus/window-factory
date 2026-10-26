import AppKit

@MainActor
final class FactoryPreferences {
    private let defaults: UserDefaults
    let shortcuts: KeybindingStore
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcuts = KeybindingStore(defaults:defaults)
        defaults.register(defaults:["showShortcutHints":true,"keepLibraryOnTop":false,"launcherEnabled":true,"showDockIcon":true])
    }
    var layoutOrder: [String] {
        get { defaults.stringArray(forKey:"layoutOrder.v1") ?? [] }
        set { defaults.set(newValue,forKey:"layoutOrder.v1") }
    }
    var agentAccessEnabled: Bool {
        get { defaults.bool(forKey:"agentAccessEnabled") }
        set { defaults.set(newValue,forKey:"agentAccessEnabled") }
    }
    var showShortcutHints: Bool {
        get { defaults.bool(forKey:"showShortcutHints") }
        set { defaults.set(newValue,forKey:"showShortcutHints") }
    }
    var showDockIcon: Bool {
        get { defaults.bool(forKey:"showDockIcon") }
        set { defaults.set(newValue,forKey:"showDockIcon") }
    }
    var spaceIndicatorEnabled: Bool {
        get { defaults.bool(forKey:"nativeSpaceIndicatorEnabled") }
        set { defaults.set(newValue,forKey:"nativeSpaceIndicatorEnabled") }
    }
    var launcherEnabled: Bool {
        get { defaults.bool(forKey:"launcherEnabled") }
        set { defaults.set(newValue,forKey:"launcherEnabled") }
    }
    var geometryEnabled: Bool {
        get { defaults.bool(forKey:"nativeGeometryEnabled") }
        set { defaults.set(newValue,forKey:"nativeGeometryEnabled") }
    }
    var focusEnabled: Bool {
        get { defaults.bool(forKey:"nativeFocusEnabled") }
        set { defaults.set(newValue,forKey:"nativeFocusEnabled") }
    }
    var stashEnabled: Bool {
        get { defaults.bool(forKey:"nativeStashEnabled") }
        set { defaults.set(newValue,forKey:"nativeStashEnabled") }
    }
    var spaceMoveEnabled: Bool {
        get { defaults.bool(forKey:"nativeSpaceMoveEnabled") }
        set { defaults.set(newValue,forKey:"nativeSpaceMoveEnabled") }
    }
    var accordionEnabled: Bool {
        get { defaults.bool(forKey:"nativeAccordionEnabled") }
        set { defaults.set(newValue,forKey:"nativeAccordionEnabled") }
    }
    var switcherEnabled: Bool {
        get { defaults.bool(forKey:"nativeSwitcherEnabled") }
        set { defaults.set(newValue,forKey:"nativeSwitcherEnabled") }
    }
    var keepLibraryOnTop: Bool {
        get { defaults.bool(forKey:"keepLibraryOnTop") }
        set { defaults.set(newValue,forKey:"keepLibraryOnTop") }
    }
}

@MainActor
final class ShortcutEditor: NSObject,NSTableViewDataSource,NSTableViewDelegate {
    let view = NSView()
    let groups = NSPopUpButton()
    let enabled = NSSwitch()
    private let table = NSTableView()
    private var recorders: [ShortcutRecorder] = []
    private let manager: KeybindingManager?
    var optionalCommands: [OptionalCommandShortcut] = [] { didSet { changeGroup() } }
    var isEnabled: ((ShortcutGroup)->Bool)?
    var changeEnabled: ((ShortcutGroup,Bool)->Void)?
    private var definitions: [ShortcutDefinition] = []
    init(manager: KeybindingManager?) {
        self.manager = manager
        super.init()
        for group in ShortcutGroup.allCases { groups.addItem(withTitle:group.title) }
        groups.setAccessibilityLabel("Shortcut group"); groups.target = self; groups.action = #selector(changeGroup)
        enabled.target = self; enabled.action = #selector(toggleGroup)
        let header = NSStackView(views:[groups,NSView(),enabled]); header.spacing = 12
        let command = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("command")); command.title = "Command"; command.width = 360
        let key = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("key")); key.title = "Shortcut"; key.width = 190
        table.addTableColumn(command); table.addTableColumn(key); table.rowHeight = 36
        table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = false
        table.style = .fullWidth; table.setAccessibilityLabel("Configurable shortcuts")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table; scroll.borderType = .bezelBorder
        let reset = NSButton(title:"Reset All…",target:self,action:#selector(resetAll)); reset.bezelStyle = .rounded
        let actions = NSStackView(views:[NSView(),reset])
        for child in [header,scroll,actions] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20),header.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20),header.topAnchor.constraint(equalTo:view.topAnchor,constant:20),
            scroll.leadingAnchor.constraint(equalTo:header.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:header.trailingAnchor),scroll.topAnchor.constraint(equalTo:header.bottomAnchor,constant:16),
            actions.leadingAnchor.constraint(equalTo:header.leadingAnchor),actions.trailingAnchor.constraint(equalTo:header.trailingAnchor),actions.topAnchor.constraint(equalTo:scroll.bottomAnchor,constant:14),actions.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-20)])
        reset.isEnabled = manager != nil; changeGroup()
    }
    var group: ShortcutGroup { ShortcutGroup.allCases[max(0,groups.indexOfSelectedItem)] }
    @objc private func changeGroup() { cancelRecording(); definitions = ShortcutDefinition.all.filter{$0.group == group}; definitions += optionalCommands.filter{$0.definition.group == group}.map(\.definition); table.reloadData(); refresh() }
    func refresh() { enabled.state = isEnabled?(group) == true ? .on : .off; enabled.isEnabled = manager != nil && changeEnabled != nil; enabled.setAccessibilityLabel("\(group.title) shortcuts") }
    @objc private func toggleGroup() { changeEnabled?(group,enabled.state == .on); refresh() }
    var isRecording: Bool { ShortcutRecorder.current?.isRecording == true }
    func cancelRecording() { ShortcutRecorder.current?.cancel(); let old = recorders; recorders = []; old.forEach{$0.cancel()} }
    func numberOfRows(in tableView: NSTableView) -> Int { definitions.count }
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? {
        let definition = definitions[row]
        if column?.identifier.rawValue == "command" {
            let label = NSTextField(labelWithString:definition.title); label.font = .systemFont(ofSize:13); label.lineBreakMode = .byTruncatingTail
            let cell = NSTableCellView(); label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:4),label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        let custom = optionalCommands.first{$0.definition.id == definition.id}
        let recorder: ShortcutRecorder
        if let custom {
            recorder=ShortcutRecorder(definition,manager:nil,read:{[weak custom] in custom?.chord},save:{[weak custom] chord in try custom?.set(chord)})
        }else{recorder=ShortcutRecorder(definition,manager:manager)}
        if let issue=custom?.error {recorder.toolTip=issue}
        recorder.isEnabled = manager != nil
        let reset = NSButton(image:NSImage(systemSymbolName:"arrow.uturn.backward",accessibilityDescription:"Reset \(definition.title) shortcut")!,target:self,action:#selector(resetRow(_:)))
        reset.tag = row; reset.bezelStyle = .inline; reset.isEnabled = custom != nil ? custom?.chord != nil : manager?.store.overrides[definition.id] != nil
        let stack = NSStackView(views:[recorder,reset]); stack.spacing = 8
        recorder.widthAnchor.constraint(equalToConstant:140).isActive = true
        recorders.append(recorder)
        recorder.finished = { [weak self,weak reset,weak custom] in reset?.isEnabled = custom != nil ? custom?.chord != nil : self?.manager?.store.overrides[definition.id] != nil }
        return stack
    }
    @objc private func resetRow(_ sender: NSButton) {
        cancelRecording()
        do { if let command=optionalCommands.first(where:{$0.definition.id == definitions[sender.tag].id}) {try command.set(nil)}else{try manager?.set(nil,for:definitions[sender.tag])}; table.reloadData() } catch { showError(error) }
    }
    @objc private func resetAll() {
        cancelRecording()
        let alert = NSAlert(); alert.messageText = "Reset all shortcuts?"; alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Reset All")
        if alert.runModal() == .alertSecondButtonReturn {
            do { try manager?.reset(); for command in optionalCommands {try command.set(nil)}; table.reloadData() } catch { showError(error) }
        }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "Shortcuts not changed"; alert.informativeText = error.localizedDescription
        if let window = view.window { alert.beginSheetModal(for:window) } else { alert.runModal() }
    }
}

@MainActor
final class SettingsWindow: NSObject,NSWindowDelegate,NSTabViewDelegate {
    let window: NSWindow
    let preferences: FactoryPreferences
    let store: LayoutStore
    let tabs = NSTabView()
    let applicationsEditor = ApplicationsEditor()
    let shortcutEditor: ShortcutEditor
    var changed: (() -> Void)?
    var onShortcuts: (() -> Void)?
    var onImport: (() -> Void)?,onExport: (() -> Void)?,onReport: (() -> Void)?
    var layoutActionsAvailable: (() -> Bool)?
    weak var agent: AgentService?
    weak var launcher: LauncherControls?
    weak var spaceIndicator: SpaceIndicator?
    weak var spaceMove: DirectSpaceMoveControls?
    weak var accordion: DirectAccordionControls?
    weak var switcher: DirectSwitcherControls?
    weak var stash: DirectStashControls?
    weak var focus: DirectFocusControls?
    weak var geometry: DirectWindowControls?
    private let agentAccess = NSSwitch()
    private let dockIcon = NSSwitch(),indicatorEnabled = NSSwitch(),loginEnabled = NSSwitch(),floating = NSSwitch(),hints = NSSwitch()
    private let loginSettings = NSButton(title:"Login Items…",target:nil,action:nil)
    private let access = NSTextField(labelWithString:"")
    private let importButton = NSButton(title:"Import…",target:nil,action:nil),exportButton = NSButton(title:"Export…",target:nil,action:nil),reportButton = NSButton(title:"Last Report…",target:nil,action:nil)
    private var monitor: Any?
    init(store: LayoutStore,preferences: FactoryPreferences,keybindings: KeybindingManager? = nil) {
        self.store = store; self.preferences = preferences; shortcutEditor = ShortcutEditor(manager:keybindings)
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:540),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init()
        window.title = "Window Factory Settings"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width:660,height:460); window.collectionBehavior = [.moveToActiveSpace]
        tabs.translatesAutoresizingMaskIntoConstraints = false; tabs.delegate = self; window.contentView!.addSubview(tabs)
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:12),tabs.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-12),tabs.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:12),tabs.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-12)])
        agentAccess.target = self; agentAccess.action = #selector(changeAgentAccess)
        dockIcon.target = self; dockIcon.action = #selector(changeDock)
        indicatorEnabled.target = self; indicatorEnabled.action = #selector(changeIndicator)
        loginEnabled.target = self; loginEnabled.action = #selector(changeLogin)
        floating.target = self; floating.action = #selector(changePreferences)
        hints.target = self; hints.action = #selector(changePreferences)
        loginSettings.target = self; loginSettings.action = #selector(openLoginSettings); loginSettings.bezelStyle = .rounded
        let permission = NSButton(title:"Accessibility Settings…",target:self,action:#selector(openAccess)); permission.bezelStyle = .rounded
        let shortcuts = NSButton(title:"Shortcut Reference",target:self,action:#selector(openShortcuts)); shortcuts.bezelStyle = .rounded
        let general = Self.page([Self.row("Dock icon",dockIcon),Self.row("Menu-bar indicator",indicatorEnabled),Self.row("Start at login",loginEnabled),loginSettings,Self.row("Keep library on top",floating),Self.row("Shortcuts on buttons",hints),Self.row("Agent access",agentAccess),Self.row("Accessibility",access),permission,shortcuts])
        addTab("General",general); addTab("Shortcuts",shortcutEditor.view); addTab("Applications",applicationsEditor.view)
        shortcutEditor.isEnabled = { [weak self] in self?.groupEnabled($0) ?? false }
        shortcutEditor.changeEnabled = { [weak self] in self?.changeGroup($0,enabled:$1) }
        for (button,action) in [(importButton,#selector(importLayouts)),(exportButton,#selector(exportLayouts)),(reportButton,#selector(lastReport))] { button.target = self; button.action = action; button.bezelStyle = .rounded }
        let folder = NSButton(title:"Show Layouts Folder",target:self,action:#selector(showFolder)); folder.bezelStyle = .rounded
        addTab("Layouts",Self.page([importButton,exportButton,reportButton,folder]))
        let title = NSTextField(labelWithString:"Window Factory"); title.font = .systemFont(ofSize:20,weight:.semibold)
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown",build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown"
        let release = NSTextField(labelWithString:"Version \(version) (\(build))")
        let diagnostics = NSButton(title:"Diagnostics…",target:self,action:#selector(showDiagnostics)); diagnostics.bezelStyle = .rounded
        addTab("About",Self.page([title,release,diagnostics]))
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { guard let self,event.window === self.window,event.keyCode == 53,!self.shortcutEditor.isRecording else { return false }; self.window.close(); return true }
            return handled ? nil : event
        }
        refresh()
    }
    func addTiling(_ view: NSView) { let item=NSTabViewItem(identifier:"Tiling");item.label="Tiling";item.view=view;let index=tabs.tabViewItems.firstIndex{$0.label == "About"} ?? tabs.numberOfTabViewItems;tabs.insertTabViewItem(item,at:index) }
    private static func row(_ title: String,_ control: NSView) -> NSView {
        let label = NSTextField(labelWithString:title); label.font = .systemFont(ofSize:13)
        control.setAccessibilityLabel(title)
        let row = NSStackView(views:[label,NSView(),control]); row.spacing = 20; row.alignment = .centerY
        row.heightAnchor.constraint(greaterThanOrEqualToConstant:30).isActive = true
        return row
    }
    private static func page(_ views: [NSView]) -> NSView {
        let page = NSView(),stack = NSStackView(views:views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; page.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:page.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:page.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:page.topAnchor,constant:24),stack.bottomAnchor.constraint(lessThanOrEqualTo:page.bottomAnchor,constant:-24)])
        for view in views where view is NSStackView { view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        return page
    }
    private func addTab(_ title: String,_ view: NSView) { let item = NSTabViewItem(identifier:title); item.label = title; item.view = view; tabs.addTabViewItem(item) }
    func tabView(_ tabView: NSTabView,didSelect tabViewItem: NSTabViewItem?) { shortcutEditor.cancelRecording(); refresh() }
    private func groupEnabled(_ group: ShortcutGroup) -> Bool {
        switch group { case .geometry:geometry?.active == true; case .focus:focus?.active == true; case .stash:stash?.active == true; case .switcher:switcher?.active == true; case .accordion:accordion?.active == true; case .spaces:spaceMove?.active == true; case .library:launcher?.active == true }
    }
    private func changeGroup(_ group: ShortcutGroup,enabled: Bool) {
        do {
            switch group {
            case .geometry: if enabled { try geometry?.enable() } else { geometry?.disable() }
            case .focus: if enabled { try focus?.enable() } else { focus?.disable() }
            case .stash: if enabled { try stash?.enable() } else { stash?.disable() }
            case .switcher: if enabled { try switcher?.enable() } else { switcher?.disable() }
            case .accordion: if enabled { try accordion?.enable() } else { accordion?.disable() }
            case .spaces: if enabled { try spaceMove?.enable() } else { spaceMove?.disable() }
            case .library: if enabled { try launcher?.enable() } else { launcher?.disable() }
            }
        } catch { let alert = NSAlert(); alert.messageText = "\(group.title) could not be enabled"; alert.informativeText = error.localizedDescription; alert.beginSheetModal(for:window) }
        refresh()
    }
    @objc private func changeAgentAccess() {
        do { try agent?.setEnabled(agentAccess.state == .on) }
        catch { let alert=NSAlert();alert.messageText="Agent access could not be enabled";alert.informativeText=error.localizedDescription;alert.beginSheetModal(for:window) }
        refresh()
    }
    @objc private func changeDock() {
        let show = dockIcon.state == .on
        if NSApp.setActivationPolicy(show ? .regular : .accessory) { preferences.showDockIcon = show }
        refresh()
    }
    @objc private func changeIndicator() { if indicatorEnabled.state == .on { spaceIndicator?.enable() } else { spaceIndicator?.disable() }; refresh() }
    @objc private func changeLogin() { launcher?.setLoginEnabled(loginEnabled.state == .on); refresh() }
    @objc private func openLoginSettings() { launcher?.openLoginSettings() }
    @objc private func changePreferences() { preferences.keepLibraryOnTop = floating.state == .on; preferences.showShortcutHints = hints.state == .on; window.level = preferences.keepLibraryOnTop ? .floating : .normal; changed?() }
    @objc private func importLayouts() { onImport?() }
    @objc private func exportLayouts() { onExport?() }
    @objc private func lastReport() { onReport?() }
    @objc private func openShortcuts() { onShortcuts?() }
    @objc private func openAccess() { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc private func showFolder() { if FileManager.default.fileExists(atPath:store.url.path) { NSWorkspace.shared.activateFileViewerSelecting([store.url]) } }
    @objc private func showDiagnostics() {
        let alert = NSAlert(); alert.messageText = "Window Factory Diagnostics"
        alert.informativeText = [preferences.shortcuts.loadError,launcher?.lastResult,spaceIndicator?.lastResult,geometry?.lastResult,focus?.lastResult,stash?.lastResult,switcher?.lastResult,accordion?.lastResult,spaceMove?.lastResult].compactMap{$0}.joined(separator:"\n")
        alert.addButton(withTitle:"Close"); alert.addButton(withTitle:"Copy")
        if alert.runModal() == .alertSecondButtonReturn { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(alert.informativeText,forType:.string) }
    }
    func refresh() {
        agentAccess.state = agent?.enabled == true ? .on : .off; agentAccess.isEnabled = agent != nil
        dockIcon.state = preferences.showDockIcon ? .on : .off
        indicatorEnabled.state = spaceIndicator?.active == true ? .on : .off; indicatorEnabled.isEnabled = spaceIndicator != nil
        loginEnabled.isEnabled = launcher?.loginAvailable == true
        loginEnabled.state = launcher?.loginState == .enabled || launcher?.loginState == .requiresApproval ? .on : .off
        loginSettings.isHidden = launcher?.loginState != .requiresApproval && launcher?.loginResult == nil
        floating.state = preferences.keepLibraryOnTop ? .on : .off; hints.state = preferences.showShortcutHints ? .on : .off
        access.stringValue = AXIsProcessTrusted() ? "Allowed" : "Not allowed"
        let available = layoutActionsAvailable?() == true
        importButton.isEnabled = available; exportButton.isEnabled = available; reportButton.isEnabled = onReport != nil
        shortcutEditor.refresh(); applicationsEditor.refresh()
    }
    func show() { launcher?.refreshLoginState(); window.level = preferences.keepLibraryOnTop ? .floating : .normal; refresh(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    func windowWillClose(_ notification: Notification) { shortcutEditor.cancelRecording() }
    func stop() { shortcutEditor.cancelRecording(); if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
