import AppKit

@MainActor
final class ImprovementsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    let store: ImprovementStore
    private let preferences: FactoryPreferences
    private let dispatcher: ImprovementDispatcher?
    private let projectPicker = NSPopUpButton(frame:.zero,pullsDown:false)
    private let agentLabel = NSTextField(wrappingLabelWithString:"")
    private let openChatButton = NSButton(title:"Open chat",target:nil,action:nil)
    private let sendSelectedButton = NSButton(title:"Copy selected & open…",target:nil,action:nil)
    private let input = NSTextView()
    private let contextField = NSTextField(string:"")
    private let table = NSTableView()
    private let detail = NSTextView()
    private let message = NSTextField(wrappingLabelWithString:"Choose a destination, then copy the request. In Codex, select or create that project, start a new chat, paste and send.")
    private let copyButton = NSButton(title:"Copy selected request for agent", target:nil, action:nil)
    private var rows: [Improvement] = []
    private var draftID = UUID()
    init(store: ImprovementStore, preferences: FactoryPreferences, dispatcher: ImprovementDispatcher? = nil) {
        self.preferences = preferences
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
        let send = NSButton(title:"Copy & open Codex…",target:self,action:#selector(sendNow)); send.bezelStyle = .rounded
        send.isEnabled = dispatcher != nil
        let actions = NSStackView(views:[build,NSView(),save,send]); actions.spacing = 12
        agentLabel.textColor = .secondaryLabelColor; agentLabel.font = .systemFont(ofSize:12)
        projectPicker.target = self; projectPicker.action = #selector(destinationChosen)
        projectPicker.setAccessibilityLabel("Destination project")
        let projectLabel = NSTextField(labelWithString:"Destination:")
        let agentRow = NSStackView(views:[projectLabel,projectPicker,agentLabel]); agentRow.spacing = 8
        projectPicker.setContentHuggingPriority(.defaultHigh,for:.horizontal)
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
        openChatButton.target = self; openChatButton.action = #selector(openLinkedChat); openChatButton.bezelStyle = .rounded
        copyButton.title = "Copy prepared request"
        let footer = NSStackView(views:[openChatButton,sendSelectedButton,copyButton,refresh]); footer.spacing = 8
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
    func applyPreferences() { window.level = preferences.keepLibraryOnTop ? .floating : .normal }
    func show(context: String) {
        applyPreferences()
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
    @objc private func openLinkedChat() {
        guard let selected, let dispatcher else {return}
        do {try dispatcher.openChat(selected.id)} catch {message.stringValue = error.localizedDescription}
    }
    private func send(_ id: UUID) {
        guard let dispatcher else {return}
        do {
            if try dispatcher.configuration().repository == nil, !pickRepository() {
                message.stringValue = "Saved for later. Choose the app's source project before preparing a request."; return
            }
            _ = try dispatcher.openRequest(id)
            message.stringValue = "Copied. In Codex, select or create the destination project, start a NEW chat there, paste (⌘V), choose the model and press Send."
        } catch {message.stringValue = error.localizedDescription}
        reloadHistory()
    }
    @objc private func destinationChosen() {
        guard let dispatcher, !dispatcher.isCreatingProject else {return}
        let tag = projectPicker.selectedItem?.tag ?? 0
        do {
            switch tag {
            case 0:
                if try dispatcher.configuration().repository == nil, !pickRepository() {break}
                _ = try dispatcher.configureDestination(nil)
            case 10:
                if try dispatcher.configuration().repository == nil, !pickRepository() {break}
                _ = pickDestination()
            case 11:
                if try dispatcher.configuration().repository == nil, !pickRepository() {break}
                createProject()
            case 12: _ = pickRepository()
            default: break
            }
        } catch {message.stringValue = error.localizedDescription}
        reloadHistory()
    }
    private func pickRepository() -> Bool {
        guard let dispatcher else {return false}
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.title = "Choose the Window Factory source project"
        panel.prompt = "Use app project"
        if let path = try? dispatcher.configuration().repository {panel.directoryURL = URL(fileURLWithPath:path)}
        guard panel.runModal() == .OK, let url = panel.url else {return false}
        do {_ = try dispatcher.configure(repository:url.path); return true}
        catch {message.stringValue = error.localizedDescription; return false}
    }
    private func pickDestination() -> Bool {
        guard let dispatcher else {return false}
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.title = "Choose an existing destination project folder"
        panel.prompt = "Use destination"
        if let config = try? dispatcher.configuration(), let path = config.destinationRepository ?? config.repository {
            panel.directoryURL = URL(fileURLWithPath:path)
        }
        guard panel.runModal() == .OK, let url = panel.url else {return false}
        do {
            _ = try dispatcher.configureDestination(url.path)
            message.stringValue = "Destination selected. Select or add this folder as a project in Codex when you paste the request."
            return true
        } catch {message.stringValue = error.localizedDescription; return false}
    }
    private func createProject() {
        guard let dispatcher else {return}
        let alert = NSAlert(); alert.messageText = "Create a project"
        alert.informativeText = "Use an existing repository for a Codex project, or create a separate local folder and repository. Add/select the resulting folder in Codex; no chat starts here."
        alert.addButton(withTitle:"Existing repository…")
        alert.addButton(withTitle:"New folder & repository…")
        alert.addButton(withTitle:"Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: _ = pickDestination()
        case .alertSecondButtonReturn:
            let panel = NSSavePanel(); panel.title = "Create a separate project folder and repository"
            panel.prompt = "Create"; panel.nameFieldStringValue = "New project"
            panel.canCreateDirectories = true
            if let path = try? dispatcher.configuration().repository {panel.directoryURL = URL(fileURLWithPath:path).deletingLastPathComponent()}
            guard panel.runModal() == .OK, let url = panel.url else {return}
            message.stringValue = "Creating the local project repository…"
            Task { @MainActor [weak self] in
                do {
                    _ = try await dispatcher.createProject(url.path)
                    self?.message.stringValue = "Local repository created. Add/select its folder as a project in Codex, then paste and send the prepared request."
                } catch {self?.message.stringValue = error.localizedDescription}
                self?.reloadHistory()
            }
        default: break
        }
    }
    @objc func refreshHistory() {
        do {try dispatcher?.reconcile()} catch {message.stringValue = "Agent status could not be refreshed: \(error.localizedDescription)"}
        reloadHistory()
    }
    private func reloadHistory() {
        let selectedID = selected?.id
        do {
            let config = try dispatcher?.configuration()
            projectPicker.removeAllItems()
            func item(_ title: String, tag: Int) {projectPicker.addItem(withTitle:title); projectPicker.lastItem?.tag = tag}
            item("Window Factory (app project)",tag:0)
            if let destination = config?.destinationRepository {
                item(URL(fileURLWithPath:destination).lastPathComponent,tag:1)
                projectPicker.selectItem(withTag:1)
            } else {projectPicker.selectItem(withTag:0)}
            projectPicker.menu?.addItem(.separator())
            item("Choose existing project…",tag:10)
            item("Create project…",tag:11)
            item("Set app source project…",tag:12)
            projectPicker.menu?.autoenablesItems = false
            projectPicker.isEnabled = dispatcher != nil && dispatcher?.isCreatingProject == false
            let destination = config?.destinationRepository ?? config?.repository
            agentLabel.stringValue = dispatcher?.isCreatingProject == true ? "Creating…" : "Select/create it in Codex · paste & send"
            agentLabel.toolTip = destination ?? "Choose the app's source project"
            projectPicker.toolTip = destination ?? "App project has not been configured"
            rows = try store.all().reversed(); table.reloadData()
            if let selectedID, let index = rows.firstIndex(where:{$0.id == selectedID}) {table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)}
            showDetail()
        } catch {
            rows = []; table.reloadData(); detail.string = "History could not be read: \(error.localizedDescription)\nThe stored file has been preserved."
            copyButton.isEnabled = false; sendSelectedButton.isEnabled = false; openChatButton.isEnabled = false
        }
    }
    private var selected: Improvement? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func description(_ value: Improvement) -> String {
        var text = "\(value.status(runningBuild:Int(store.build)))\n\(value.createdAt.formatted()) · Build \(value.build)\n\n\(value.text)"
        if !value.context.isEmpty {text += "\n\nContext: \(value.context)"}
        for update in value.updates {text += "\n\n\(update.date.formatted()) — \(update.state.title)\n\(update.note)"}
        for handoff in value.handoffs ?? [] {
            text += "\n\nCodex handoff · \(handoff.phase)\nRepository: \(handoff.repository)"
            if let threadID = handoff.threadID {text += "\nChat: \(ImprovementHandoffLink.chatURL(threadID).absoluteString)"}
            else if handoff.phase == "prepared" {text += "\nSelect/create this project in Codex, start a new chat, paste the copied request and send. The chat links back when the agent starts."}
            else if handoff.phase == "opened" {text += "\nEarlier automatic handoff. Prepare this request again for manual paste/send."}
            if let origin = handoff.originRepository, origin != handoff.repository {text += "\nOrigin app project: \(origin)"}
        }
        for run in value.runs ?? [] {
            text += "\n\nAgent run \(run.id.uuidString) · \(run.phase)\nRepository: \(run.repository)"
            if let session = run.sessionID {text += "\nCodex session: \(session)"}
            if let dispatcher {text += "\nRun files: \(dispatcher.directory.appendingPathComponent(run.id.uuidString).path)"}
        }
        return text + "\n\nRequest \(value.id.uuidString) · Revision \(value.revision)"
    }
    private func showDetail() {
        copyButton.isEnabled = dispatcher != nil && selected.map {![.implemented,.declined].contains($0.state) && !($0.handoffs?.contains(where:{$0.threadID != nil}) ?? false) && !($0.runs?.last?.active ?? false)} == true
        openChatButton.isEnabled = dispatcher != nil && selected?.handoffs?.contains(where:{$0.threadID != nil}) == true
        sendSelectedButton.isEnabled = dispatcher != nil && selected.map {value in
            ![.implemented,.declined].contains(value.state) && !(value.runs?.last?.active ?? false) && !(value.handoffs?.contains(where:{$0.threadID != nil}) ?? false)
        } == true
        detail.string = selected.map(description) ?? (rows.isEmpty ? "No requests yet." : "Select a request to see its context and outcome.")
    }
    @objc private func copyRequest() {
        guard let selected, let dispatcher else {return}
        do {
            _ = try dispatcher.prepareRequest(selected.id)
            message.stringValue = "Prepared request copied. In Codex, select/create the destination project, start a new chat, paste (⌘V) and send."
        } catch {message.stringValue = error.localizedDescription}
        reloadHistory()
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
