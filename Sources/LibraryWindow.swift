import AppKit
import UniformTypeIdentifiers

@MainActor
final class PreviewView: NSView {
    var recipe: Recipe? { didSet { needsDisplay = true } }
    var aspectRatio: Double = 1.6 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let canvas = LibraryPresentation.canvas(in:bounds,inset:12,aspect:aspectRatio)
        NSColor.separatorColor.setStroke(); NSBezierPath(rect:canvas).stroke()
        guard let recipe else { return }
        for (index,slot) in recipe.windows.enumerated() {
            let f = slot.frame
            let rect = NSRect(x:canvas.minX+f.x*canvas.width,y:canvas.minY+f.y*canvas.height,
                              width:f.w*canvas.width,height:f.h*canvas.height).intersection(canvas)
            guard !rect.isEmpty else { continue }
            NSColor.controlAccentColor.withAlphaComponent(0.12+Double(index%3)*0.06).setFill()
            let path = NSBezierPath(roundedRect:rect.insetBy(dx:1,dy:1),xRadius:3,yRadius:3)
            path.fill(); NSColor.controlAccentColor.setStroke(); path.stroke()
            (slot.appName as NSString).draw(in:rect.insetBy(dx:5,dy:5),withAttributes:[
                .font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.labelColor])
        }
    }
}

@MainActor
final class LayoutTableView: NSTableView {
    var menuForRow: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        menuForRow?(row(at:convert(event.locationInWindow,from:nil)))
    }
}

@MainActor
final class LibraryWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    let window: NSWindow
    let store: LayoutStore
    let coordinator: Coordinator
    let preview: Bool
    let preferences: FactoryPreferences
    var onShortcuts: (() -> Void)?
    var onSettings: (() -> Void)?
    var onApplications: (() -> Void)?
    let applicationsButton = NSButton(title:"Applications",target:nil,action:nil)
    let shortcutHints = NSTextField(labelWithString:"↑↓ Select   ↩ Restore   ⌘↩ Establish   ⌘N Capture   ⌘F Search   ⎋ Cancel/Close")
    let search = NSSearchField(), table = LayoutTableView(), drawing = PreviewView()
    let status = NSTextField(wrappingLabelWithString:"")
    let name = NSTextField(), nameLabel = NSTextField(labelWithString:"Layout name")
    let save = NSButton(title:"Save",target:nil,action:nil)
    let capture = NSButton(title:"Capture…",target:nil,action:nil)
    let restore = NSButton(title:"Restore",target:nil,action:nil)
    let establish = NSButton(title:"Establish here",target:nil,action:nil)
    let delete = NSButton(title:"Delete…",target:nil,action:nil)
    let cancel = NSButton(title:"Cancel",target:nil,action:nil)
    let shortcuts = NSButton(title:"Shortcuts…",target:nil,action:nil)
    var filtered: [Recipe] = [], frozen: Recipe?, task: Task<Void,Never>?, monitor: Any?
    private let naming = NSStackView()
    let quickLook = NSPopover()
    private var dragOrder: [String]?
    private let dragType = NSPasteboard.PasteboardType("local.windowfactory.layout-row")
    private var appIcons: [String:NSImage] = [:]
    var lastReceipt: Receipt?
    init(store: LayoutStore,registry: AdapterRegistry,preview: Bool,preferences: FactoryPreferences) {
        self.store = store; self.coordinator = Coordinator(registry:registry); self.preview = preview; self.preferences = preferences
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:560),
            styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init()
        window.title = preview ? "Window Factory — Preview" : "Window Factory"
        window.minSize = NSSize(width:560,height:440); window.delegate = self
        window.isReleasedWhenClosed = false
        // A summoned library belongs on the user's selected desktop. AppKit
        // otherwise activates the retained window's old Space on Dock reopen.
        window.collectionBehavior = [.moveToActiveSpace]
        search.placeholderString = "Search layouts or applications"; search.delegate = self
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("layout"))
        column.title = "Layouts"; table.addTableColumn(column); table.headerView = nil
        table.rowHeight = 68; table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes([dragType]); table.setDraggingSourceOperationMask(.move,forLocal:true)
        table.menuForRow = { [weak self] row in self?.contextMenu(for:row) }
        table.target = self; table.doubleAction = #selector(restoreLayout)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let previewController = NSViewController(); previewController.view = drawing
        quickLook.contentViewController = previewController; quickLook.behavior = .semitransient
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:240).isActive = true
        for (button,action) in [(capture,#selector(startCapture)),(restore,#selector(restoreLayout)),
                                (establish,#selector(establishLayout)),(delete,#selector(deleteLayout)),(save,#selector(saveCapture)),(cancel,#selector(cancelAction))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        let permission = NSButton(image:NSImage(systemSymbolName:"gearshape",accessibilityDescription:"Settings")!,target:self,action:#selector(openSettings))
        permission.bezelStyle = .inline; permission.toolTip = "Settings — ⌘,"; permission.setAccessibilityLabel("Settings")
        shortcuts.target = self; shortcuts.action = #selector(openShortcuts); shortcuts.bezelStyle = .inline
        shortcuts.image = NSImage(systemSymbolName:"keyboard",accessibilityDescription:"Keyboard Shortcuts")
        shortcuts.imagePosition = .imageOnly; shortcuts.setAccessibilityLabel("Keyboard Shortcuts")
        delete.image = NSImage(systemSymbolName:"trash",accessibilityDescription:"Delete layout")
        delete.imagePosition = .imageOnly; delete.bezelStyle = .inline; delete.setAccessibilityLabel("Delete layout")
        name.placeholderString = "Name the captured layout"; name.target = self; name.action = #selector(saveCapture)
        for view in [nameLabel,name,save,cancel] { naming.addArrangedSubview(view) }; naming.orientation = .horizontal
        name.widthAnchor.constraint(greaterThanOrEqualToConstant:180).isActive = true
        applicationsButton.target = self; applicationsButton.action = #selector(openApplications); applicationsButton.bezelStyle = .rounded
        let header = NSStackView(views:[search,applicationsButton,capture]); header.spacing = 10
        search.setContentHuggingPriority(.defaultLow,for:.horizontal)
        search.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        for icon in [permission,shortcuts,delete] {
            icon.widthAnchor.constraint(equalToConstant:24).isActive = true
            icon.heightAnchor.constraint(equalToConstant:24).isActive = true
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let footer = NSStackView(views:[permission,shortcuts,delete,spacer,restore,establish]); footer.spacing = 12
        let stack = NSStackView(views:[header,scroll,naming,status,footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top:16,left:16,bottom:14,right:16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo:content.trailingAnchor),stack.topAnchor.constraint(equalTo:content.topAnchor),
            stack.bottomAnchor.constraint(equalTo:content.bottomAnchor),
            header.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-32),
            scroll.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-32),
            footer.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-32),
            status.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-32)])
        status.font = .systemFont(ofSize:12); status.textColor = .secondaryLabelColor
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window || (self.quickLook.isShown && event.window === self.drawing.window) else { return false }
                return self.handle(event)
            }
            return handled ? nil : event
        }
        applyPreferences(); reload()
        status.stringValue = preview ? "Preview only. Window operations and catalog changes are disabled."
            : "" + (AXIsProcessTrusted() ? "" : "Accessibility access is needed for capture and placement.")
        updateButtons()
    }
    var selected: Recipe? { filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil }
    func show() { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); window.makeFirstResponder(search) }
    func applyPreferences() {
        window.level = preferences.keepLibraryOnTop ? .floating : .normal
        shortcutHints.isHidden = true
        applicationsButton.isEnabled = onApplications != nil
        let reference = ShortcutDefinition.all.first{$0.id == "library.1"}!
        shortcuts.title = ""; shortcuts.imagePosition = .imageOnly
        shortcuts.toolTip = "Keyboard Shortcuts — " + preferences.shortcuts.chord(reference).actionHint
        delete.toolTip = "Delete layout — ⌘⌫"
        updatePreviewAspect()
        capture.title = preferences.showShortcutHints ? "Capture…  ⌘N" : "Capture…"
        restore.title = preferences.showShortcutHints ? "Restore  ↩" : "Restore"
        establish.title = preferences.showShortcutHints ? "Establish here  ⌘↩" : "Establish here"
        save.title = preferences.showShortcutHints ? "Save  ↩" : "Save"
        cancel.title = preferences.showShortcutHints ? "Cancel  ⎋" : "Cancel"
    }
    @objc func toggleQuickLook() {
        if quickLook.isShown { quickLook.close(); window.makeFirstResponder(table); return }
        guard task == nil, frozen == nil, let selected,window.isVisible else { return }
        drawing.recipe = selected; updatePreviewAspect()
        quickLook.contentSize = NSSize(width:480,height:456/drawing.aspectRatio+24)
        quickLook.show(relativeTo:table.rect(ofRow:table.selectedRow),of:table,preferredEdge:.maxX)
    }
    var canQuickLookFromKeyboard: Bool {
        task == nil && frozen == nil && selected != nil &&
            (quickLook.isShown || window.firstResponder === table || search.stringValue.isEmpty)
    }
    func updatePreviewAspect() {
        if let screen = window.screen ?? NSScreen.main { drawing.aspectRatio = screen.visibleFrame.width/screen.visibleFrame.height }
    }
    func windowDidChangeScreen(_ notification: Notification) { updatePreviewAspect(); table.reloadData() }
    @objc func openShortcuts() { onShortcuts?() }
    @objc func openApplications() { onApplications?() }
    @objc func openSettings() { onSettings?() }
    @objc func focusSearch() { if task == nil && frozen == nil { window.makeFirstResponder(search) } }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard window.isKeyWindow else { return false }
        if menuItem.action == #selector(showReport) { return true }
        guard task == nil && frozen == nil else { return false }
        switch menuItem.action {
        case #selector(startCapture): return capture.isEnabled
        case #selector(restoreLayout), #selector(establishLayout): return restore.isEnabled
        case #selector(deleteLayout): return !preview && selected != nil
        case #selector(moveLayoutUp): return canMoveSelectedLayout(-1)
        case #selector(moveLayoutDown): return canMoveSelectedLayout(1)
        case #selector(importLayouts), #selector(exportLayouts): return !preview
        case #selector(focusSearch): return true
        default: return false
        }
    }
    func updateButtons() {
        let access = !preview && AXIsProcessTrusted(), idle = task == nil && frozen == nil
        capture.isEnabled = access && idle; restore.isEnabled = access && idle && selected != nil
        establish.isEnabled = access && idle && selected != nil
        delete.isEnabled = !preview && idle && selected != nil
        naming.isHidden = frozen == nil && task == nil
        name.isHidden = frozen == nil; nameLabel.isHidden = frozen == nil; save.isHidden = frozen == nil
        save.isEnabled = !preview && frozen != nil && task == nil
        cancel.isHidden = task == nil && frozen == nil
        search.isEnabled = task == nil && frozen == nil
        status.isHidden = status.stringValue.isEmpty
        if quickLook.isShown {
            if task != nil || frozen != nil || selected == nil { quickLook.close() }
            else { quickLook.positioningRect = table.rect(ofRow:table.selectedRow) }
        }
        for row in 0..<table.numberOfRows {
            (table.view(atColumn:0,row:row,makeIfNecessary:false) as? LayoutRowView)?.setReorderingAvailable(canReorder)
        }
    }
    func contextMenu(for row: Int) -> NSMenu? {
        guard !preview, task == nil, frozen == nil, filtered.indices.contains(row) else { return nil }
        table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        drawing.recipe = selected; updateButtons()
        let menu = NSMenu()
        for (title,action) in [("Restore",#selector(restoreLayout)),("Establish here",#selector(establishLayout)),("Delete…",#selector(deleteLayout))] {
            if action == #selector(deleteLayout) { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle:title,action:action,keyEquivalent:"")
            item.target = self
        }
        return menu
    }
    func reload(select wanted: String? = nil) {
        let query = search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        filtered = LibraryPresentation.ordered(Array(store.catalog.recipes.values),savedOrder:preferences.layoutOrder,query:query)
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer:filtered.firstIndex(where:{ $0.name == wanted }) ?? 0),byExtendingSelection:false) }
        drawing.recipe = selected; updateButtons()
    }
    var canReorder: Bool { !preview && task == nil && frozen == nil && search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    func moveLayout(_ name: String,to row: Int) -> Bool {
        guard canReorder,let order = LibraryPresentation.moving(filtered.map(\.name),name:name,to:row) else { return false }
        preferences.layoutOrder = order; reload(select:name); return true
    }
    func canMoveSelectedLayout(_ direction: Int) -> Bool {
        canReorder && [-1,1].contains(direction) && selected != nil && filtered.indices.contains(table.selectedRow+direction)
    }
    @discardableResult func moveSelectedLayout(_ direction: Int) -> Bool {
        guard canMoveSelectedLayout(direction),let name = selected?.name else { return false }
        let insertion = table.selectedRow + (direction>0 ? 2 : -1)
        guard moveLayout(name,to:insertion) else { return false }
        table.scrollRowToVisible(table.selectedRow); return true
    }
    @objc func moveLayoutUp() { moveSelectedLayout(-1) }
    @objc func moveLayoutDown() { moveSelectedLayout(1) }
    func tableView(_ tableView: NSTableView,pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard canReorder,filtered.indices.contains(row) else { return nil }
        dragOrder = filtered.map(\.name)
        let item = NSPasteboardItem(); item.setString(filtered[row].name,forType:dragType); return item
    }
    func tableView(_ tableView: NSTableView,validateDrop info: NSDraggingInfo,proposedRow row: Int,proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard canReorder,info.draggingSource as? NSTableView === table,dragOrder == filtered.map(\.name),row>=0,row<=filtered.count,
              info.draggingPasteboard.pasteboardItems?.count == 1,info.draggingPasteboard.string(forType:dragType) != nil else { return [] }
        tableView.setDropRow(row,dropOperation:.above); return .move
    }
    func tableView(_ tableView: NSTableView,acceptDrop info: NSDraggingInfo,row: Int,dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === table,dragOrder == filtered.map(\.name),
              info.draggingPasteboard.pasteboardItems?.count == 1,let name = info.draggingPasteboard.string(forType:dragType) else { return false }
        return moveLayout(name,to:row)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        LayoutRowView(recipe:filtered[row],aspectRatio:drawing.aspectRatio,canReorder:canReorder) { [self] bundleID in
            if let cached = appIcons[bundleID] { return cached }
            let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID).map { NSWorkspace.shared.icon(forFile:$0.path) }
                ?? NSImage(systemSymbolName:"app",accessibilityDescription:"Application")
            appIcons[bundleID] = image
            return image
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { drawing.recipe = selected; updateButtons() }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === search { reload() } }
    func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            if quickLook.isShown { quickLook.close(); window.makeFirstResponder(table) } else { cancelAction() }
            return true
        }
        if frozen != nil || task != nil { return false }
        if event.keyCode == 49 && event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty && canQuickLookFromKeyboard {
            if !event.isARepeat { toggleQuickLook() }; return true
        }
        if event.keyCode == 125 || event.keyCode == 126 {
            let modifiers = event.modifierFlags.intersection([.command,.option,.control,.shift])
            if modifiers == .option { moveSelectedLayout(event.keyCode == 125 ? 1 : -1); return true }
            guard modifiers.isEmpty else { return false }
            if !filtered.isEmpty {
                let next = max(0,min(filtered.count-1,table.selectedRow+(event.keyCode == 125 ? 1 : -1)))
                table.selectRowIndexes(IndexSet(integer:next),byExtendingSelection:false); table.scrollRowToVisible(next); window.makeFirstResponder(table)
            }
            return true
        }
        if event.keyCode == 36 { event.modifierFlags.contains(.command) ? establishLayout() : restoreLayout(); return true }
        if event.keyCode == 51 && event.modifierFlags.contains(.command) { deleteLayout(); return true }
        return false
    }
    func context() throws -> Context {
        guard let screen = window.screen ?? NSScreen.main else { throw FactoryError("No screen available.") }
        return try Context(screen:screen)
    }
    func run(_ status: String,operation: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        self.status.stringValue = status
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { task = nil; updateButtons() }
            do { try await Task.sleep(for:.milliseconds(40)); try await operation() }
            catch is CancellationError { self.status.stringValue = "Cancelled. Completed changes are retained." }
            catch { self.status.stringValue = error.localizedDescription }
        }
        updateButtons()
    }
    @objc func startCapture() {
        guard !preview, task == nil, frozen == nil else { return }
        run("Capturing windows…") { [self] in
            let recipe = try await coordinator.services.capture(context())
            try Task.checkCancellation(); frozen = recipe; name.stringValue = ""
            status.stringValue = "Captured \(recipe.windows.count) windows. Name the frozen layout."
            updateButtons(); window.makeFirstResponder(name)
        }
    }
    @objc func saveCapture() {
        guard !preview, task == nil, var recipe = frozen else { return }
        do {
            recipe.name = try Recipe.normalizedName(name.stringValue)
            if store.catalog.recipes[recipe.name] != nil && !confirm("Replace “\(recipe.name)”?",detail:"The native copy of this layout will be replaced.") { return }
            try store.save(recipe,replace:true); frozen = nil; search.stringValue = ""; reload(select:recipe.name)
            status.stringValue = "Saved \(recipe.name)."; window.makeFirstResponder(search)
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc func restoreLayout() { apply(establish:false) }
    @objc func establishLayout() { apply(establish:true) }
    func apply(establish: Bool) {
        guard !preview, task == nil, frozen == nil, let recipe = selected else { return }
        run(establish ? "ESTABLISHING…" : "RESTORING…") { [self] in
            let report = try await coordinator.apply(recipe,establish:establish,context:context()) { [weak self] in self?.status.stringValue = $0 }
            lastReceipt = report; status.stringValue = report.summary
        }
    }
    @objc func cancelAction() {
        if let task { task.cancel(); status.stringValue = "Cancelling…" }
        else if frozen != nil { frozen = nil; status.stringValue = "Capture cancelled."; updateButtons(); window.makeFirstResponder(search) }
        else { window.close() }
    }
    @objc func importLayouts() {
        guard !preview, task == nil, frozen == nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.importCatalog(url); reload(); status.stringValue = "Imported a validated copy; the source catalog is unchanged." }
            catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc func exportLayouts() {
        guard !preview, task == nil else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "window-factory-layouts.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.catalog.encoded().write(to:url,options:.atomic); status.stringValue = "Catalog exported." }
            catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc func deleteLayout() {
        guard !preview, task == nil, frozen == nil, let recipe = selected else { return }
        if confirm("Delete “\(recipe.name)”?",detail:"The previous catalog copy is retained for recovery.",actionTitle:"Delete") {
            do { try store.delete(recipe.name); reload(); status.stringValue = "Layout deleted." }
            catch { status.stringValue = error.localizedDescription }
        }
    }
    func confirm(_ message: String,detail: String,actionTitle: String = "Continue") -> Bool {
        let alert = NSAlert(); alert.messageText = message; alert.informativeText = detail
        alert.addButton(withTitle:actionTitle); alert.addButton(withTitle:"Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc func showReport() {
        let alert = NSAlert(); alert.messageText = "Last operation"
        alert.informativeText = lastReceipt?.summary ?? "No operation has run."; alert.runModal()
    }
    @objc func openAccessSettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func windowWillClose(_ notification: Notification) { quickLook.close(); task?.cancel() }
    func stop() { quickLook.close(); task?.cancel(); if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
