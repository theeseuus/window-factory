import AppKit

@MainActor
final class ImprovementsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    let store: ImprovementStore
    private let dispatcher: ImprovementDispatcher?
    private let agentLabel = NSTextField(wrappingLabelWithString:"")
    private let sendSelectedButton = NSButton(title:"Send selected now",target:nil,action:nil)
    private let input = NSTextView()
    private let contextField = NSTextField(string:"")
    private let table = NSTableView()
    private let detail = NSTextView()
    private let message = NSTextField(wrappingLabelWithString:"Save for later, or send to Codex to start work in the repository now.")
    private let copyButton = NSButton(title:"Copy selected request for agent", target:nil, action:nil)
    private var rows: [Improvement] = []
    private var draftID = UUID()
    init(store: ImprovementStore, dispatcher: ImprovementDispatcher? = nil) {
        self.store = store; self.dispatcher = dispatcher
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:840), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
        super.init()
        window.title = "Improve Window Factory"; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]; window.minSize = NSSize(width:700,height:800)
        let prompt = NSTextField(labelWithString:"What should work differently?")
        prompt.font = .systemFont(ofSize:16,weight:.semibold)
        let hint = NSTextField(wrappingLabelWithString:"Describe the friction or the result you want. Rough ideas are welcome.")
        hint.textColor = .secondaryLabelColor
        let inputScroll = scroll(input, editable:true)
        input.setAccessibilityLabel("Improvement request")
        contextField.placeholderString = "Optional context"; contextField.setAccessibilityLabel("Included context, editable")
        let contextLabel = NSTextField(labelWithString:"Included context (edit or clear):")
        let build = NSTextField(labelWithString:"Window Factory \(store.version) · Build \(store.build)")
        build.textColor = .secondaryLabelColor
        let save = NSButton(title:"Save for later",target:self,action:#selector(saveForLater)); save.bezelStyle = .rounded
        let send = NSButton(title:"Send to agent now",target:self,action:#selector(sendNow)); send.bezelStyle = .rounded
        send.isEnabled = dispatcher != nil
        let actions = NSStackView(views:[build,NSView(),save,send]); actions.spacing = 12
        agentLabel.textColor = .secondaryLabelColor; agentLabel.font = .systemFont(ofSize:12)
        let choose = NSButton(title:"Repository…",target:self,action:#selector(chooseRepository)); choose.bezelStyle = .rounded
        choose.isEnabled = dispatcher != nil
        let agentRow = NSStackView(views:[agentLabel,NSView(),choose]); agentRow.spacing = 8
        let historyLabel = NSTextField(labelWithString:"Previous requests")
        historyLabel.font = .systemFont(ofSize:14,weight:.semibold)
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("request"))
        column.title = "Request and status"; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 48; table.delegate = self; table.dataSource = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.allowsEmptySelection = true
        table.setAccessibilityLabel("Previous improvement requests")
        let history = NSScrollView(); history.hasVerticalScroller = true; history.borderType = .bezelBorder; history.documentView = table
        let detailScroll = scroll(detail,editable:false); detail.setAccessibilityLabel("Selected request and outcome")
        copyButton.target = self; copyButton.action = #selector(copyRequest); copyButton.bezelStyle = .rounded
        let refresh = NSButton(title:"Refresh",target:self,action:#selector(refreshHistory)); refresh.bezelStyle = .rounded
        sendSelectedButton.target = self; sendSelectedButton.action = #selector(sendSelected); sendSelectedButton.bezelStyle = .rounded
        let footer = NSStackView(views:[sendSelectedButton,copyButton,refresh]); footer.spacing = 8
        let stack = NSStackView(views:[prompt,hint,inputScroll,contextLabel,contextField,actions,agentRow,message,historyLabel,history,detailScroll,footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),
            stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),
            stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),
            stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-16),
            inputScroll.heightAnchor.constraint(equalToConstant:100), history.heightAnchor.constraint(equalToConstant:120),
            detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:100)
        ])
        for view in [inputScroll,contextField,actions,agentRow,message,history,detailScroll] {
            view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        }
        store.changed = { [weak self] in self?.reloadHistory() }
        dispatcher?.changed = { [weak self] in self?.reloadHistory() }
        refreshHistory()
    }
    private func scroll(_ text: NSTextView, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        text.isEditable = editable; text.isSelectable = true; text.isRichText = false
        text.font = .systemFont(ofSize:13); text.textContainerInset = NSSize(width:10,height:10)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; return scroll
    }
    func show(context: String) {
        // Preserve an unfinished draft and the context from when it was started.
        if input.string.isEmpty { contextField.stringValue = context }
        refreshHistory(); window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input); NSApp.activate(ignoringOtherApps:true)
    }
    private func saveDraft() throws -> Improvement {
        let value = try store.submit(id:draftID,text:input.string,context:contextField.stringValue,source:"ui")
        input.string = ""; draftID = UUID(); reloadHistory()
        if let index = rows.firstIndex(where:{$0.id == value.id}) {
            table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false); table.scrollRowToVisible(index)
        }
        return value
    }
    @objc private func saveForLater() {
        do {_ = try saveDraft(); message.stringValue = "Saved for later. No agent has been started."}
        catch {message.stringValue = "Could not save: \(error.localizedDescription)"}
    }
    @objc private func sendNow() {
        do {let value = try saveDraft(); send(value.id)}
        catch {message.stringValue = "Could not save: \(error.localizedDescription)"}
    }
    @objc private func sendSelected() {if let selected {send(selected.id)}}
    private func send(_ id: UUID) {
        guard let dispatcher else {return}
        do {
            if try dispatcher.configuration().repository == nil, !pickRepository() {
                message.stringValue = "Saved for later. Choose a repository to start an agent."; return
            }
            _ = try dispatcher.dispatch(id)
            message.stringValue = "Agent launch started. Its progress and outcome will appear below."
        } catch {message.stringValue = "Request saved; no new agent started: \(error.localizedDescription)"}
        reloadHistory()
    }
    @objc private func chooseRepository() {_ = pickRepository(); reloadHistory()}
    private func pickRepository() -> Bool {
        guard let dispatcher else {return false}
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.title = "Choose the Window Factory source repository"
        panel.prompt = "Use repository"
        if let path = try? dispatcher.configuration().repository {panel.directoryURL = URL(fileURLWithPath:path)}
        guard panel.runModal() == .OK, let url = panel.url else {return false}
        do {_ = try dispatcher.configure(repository:url.path); return true}
        catch {message.stringValue = error.localizedDescription; return false}
    }
    @objc func refreshHistory() {
        do {try dispatcher?.reconcile()} catch {message.stringValue = "Agent status could not be refreshed: \(error.localizedDescription)"}
        reloadHistory()
    }
    private func reloadHistory() {
        let selectedID = selected?.id
        do {
            let config = try dispatcher?.configuration()
            agentLabel.stringValue = "Codex subscription · Default model · " + (config?.repository.map {URL(fileURLWithPath:$0).lastPathComponent} ?? "Choose repository")
            agentLabel.toolTip = "Uses codex-ai. Repository: \(config?.repository ?? "not selected"). Agent continues in the background; implemented changes await installation."
            rows = try store.all().reversed(); table.reloadData()
            if let selectedID, let index = rows.firstIndex(where:{$0.id == selectedID}) {table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)}
            showDetail()
        } catch {
            rows = []; table.reloadData(); detail.string = "History could not be read: \(error.localizedDescription)\nThe stored file has been preserved."
            copyButton.isEnabled = false; sendSelectedButton.isEnabled = false
        }
    }
    private var selected: Improvement? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func description(_ value: Improvement) -> String {
        var text = "\(value.status(runningBuild:Int(store.build)))\n\(value.createdAt.formatted()) · Build \(value.build)\n\n\(value.text)"
        if !value.context.isEmpty {text += "\n\nContext: \(value.context)"}
        for update in value.updates {text += "\n\n\(update.date.formatted()) — \(update.state.title)\n\(update.note)"}
        for run in value.runs ?? [] {
            text += "\n\nAgent run \(run.id.uuidString) · \(run.phase)\nRepository: \(run.repository)"
            if let session = run.sessionID {text += "\nCodex session: \(session)"}
            if let dispatcher {text += "\nRun files: \(dispatcher.directory.appendingPathComponent(run.id.uuidString).path)"}
        }
        return text + "\n\nRequest \(value.id.uuidString) · Revision \(value.revision)"
    }
    private func showDetail() {
        copyButton.isEnabled = selected != nil
        sendSelectedButton.isEnabled = dispatcher != nil && selected.map {value in
            ![.implemented,.declined].contains(value.state) && !(value.runs?.last?.active ?? false)
        } == true
        detail.string = selected.map(description) ?? (rows.isEmpty ? "No requests yet." : "Select a request to see its context and outcome.")
    }
    @objc private func copyRequest() {
        guard let selected else {return}
        let text = "Window Factory improvement request\n\n" + description(selected) + "\n\nUse the repository's improvement workflow (docs/improvements.md). Investigate this intended outcome under existing repository and machine authority."
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string)
        message.stringValue = "Copied. Paste into the Window Factory development chat to pick it up now."
    }
    func numberOfRows(in tableView: NSTableView) -> Int {rows.count}
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else {return nil}
        let value = rows[row], label = NSTextField(wrappingLabelWithString:"")
        let excerpt = value.text.replacingOccurrences(of:"\n",with:" ")
        label.stringValue = "\(String(excerpt.prefix(100)))\n\(value.status(runningBuild:Int(store.build)))"
        label.maximumNumberOfLines = 2; label.font = .systemFont(ofSize:12)
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {showDetail()}
}
