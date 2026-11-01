import AppKit

/// Explicit setup/re-run setup. Lists actual provider records; folder names are not IDs.
@MainActor
final class CodexConnectionWindow:NSObject {
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:390),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    let dispatcher:ImprovementDispatcher
    var connected:(()->Void)?
    private let projects=NSPopUpButton(),chats=NSPopUpButton()
    private let status=NSTextField(wrappingLabelWithString:"Connect using Codex desktop’s current sign-in. Choose its project and the chat that should receive requests.")
    private let path=NSTextField(wrappingLabelWithString:"")
    private let use=NSButton(title:"Use this chat",target:nil,action:nil)
    private var projectRows:[CodexProject]=[],chatRows:[CodexChat]=[]
    private var generation=UUID()
    init(dispatcher:ImprovementDispatcher) {
        self.dispatcher=dispatcher;super.init();window.title="Improvements · Codex connection";window.isReleasedWhenClosed=false
        let title=NSTextField(labelWithString:"Where should improvement requests go?");title.font = .systemFont(ofSize:16,weight:.semibold)
        let load=NSButton(title:"Load / refresh projects",target:self,action:#selector(loadProjects));load.bezelStyle = .rounded
        let creation=NSTextField(wrappingLabelWithString:"Create the initial project and coding chat in Codex, then refresh here. Creation from Improvements is not available yet; subsequent requests send directly to your selected chat.");creation.textColor = .secondaryLabelColor
        projects.target=self;projects.action=#selector(projectChanged);projects.setAccessibilityLabel("Codex project")
        chats.target=self;chats.action=#selector(chatChanged);chats.setAccessibilityLabel("Codex coding chat")
        projects.isEnabled=false;chats.isEnabled=false
        use.target=self;use.action=#selector(connect);use.bezelStyle = .rounded;use.isEnabled=false
        let cancel=NSButton(title:"Close",target:self,action:#selector(close));cancel.bezelStyle = .rounded
        let projectRow=NSStackView(views:[NSTextField(labelWithString:"Project:"),projects]);projectRow.spacing=8
        let chatRow=NSStackView(views:[NSTextField(labelWithString:"Chat:"),chats]);chatRow.spacing=8
        let controls=NSStackView(views:[load,NSView(),cancel,use]);controls.spacing=8
        let stack=NSStackView(views:[title,status,projectRow,chatRow,path,creation,NSView(),controls]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12
        stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)])
        for view in [status,projectRow,chatRow,path,creation,controls] {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        projects.setContentHuggingPriority(.defaultLow,for:.horizontal);chats.setContentHuggingPriority(.defaultLow,for:.horizontal)
        path.textColor = .secondaryLabelColor;path.font = .systemFont(ofSize:11)
    }
    func show() {window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc private func close() {generation=UUID();window.orderOut(nil)}
    private var project:CodexProject? {projectRows.indices.contains(projects.indexOfSelectedItem) ? projectRows[projects.indexOfSelectedItem] : nil}
    private var chat:CodexChat? {chatRows.indices.contains(chats.indexOfSelectedItem) ? chatRows[chats.indexOfSelectedItem] : nil}
    @objc private func loadProjects() {
        let token=UUID();generation=token;status.stringValue="Reading Codex projects…";use.isEnabled=false
        Task { @MainActor in
            do {
                let rows=try await dispatcher.desktopProjects();guard generation==token else {return}
                projectRows=rows;projects.removeAllItems();projects.addItems(withTitles:rows.map(\.name));projects.isEnabled = !rows.isEmpty
                let config=try dispatcher.configuration()
                if let i=rows.firstIndex(where:{$0.id==config.desktopDestination?.projectID || (config.desktopDestination==nil && $0.roots.contains(config.repository ?? ""))}) {projects.selectItem(at:i)}
                if rows.isEmpty {status.stringValue="No Codex projects found. Create the initial project/chat in Codex, then refresh.";chats.removeAllItems();chatRows=[]}
                else {projectChanged()}
            } catch {guard generation==token else {return};status.stringValue=error.localizedDescription}
        }
    }
    @objc private func projectChanged() {
        guard let project else {return};let token=UUID();generation=token
        status.stringValue="Reading chats in \(project.name)…";use.isEnabled=false;chats.isEnabled=false
        chatRows=[];chats.removeAllItems()
        Task { @MainActor in
            do {
                let rows=try await dispatcher.desktopChats(project.id);guard generation==token else {return}
                chatRows=rows;chats.removeAllItems()
                chats.addItems(withTitles:rows.map {String($0.name.prefix(90))+($0.projectID==nil ? " · unfiled repository chat" : "")})
                if let selected=try dispatcher.configuration().desktopDestination,let i=rows.firstIndex(where:{$0.id==selected.chatID}) {chats.selectItem(at:i)}
                chats.isEnabled = !rows.isEmpty;chatChanged()
            } catch {guard generation==token else {return};status.stringValue=error.localizedDescription}
        }
    }
    @objc private func chatChanged() {
        use.isEnabled=chat != nil
        path.stringValue=chat?.repository ?? project?.roots.first ?? ""
        status.stringValue=chat == nil ? "No chats found. Create the initial coding chat in this project in Codex, then refresh." : "Requests will be sent directly to this chat. Its existing model is used."
    }
    @objc private func connect() {
        guard let project,let chat else {return}
        let assign=chat.projectID == nil
        if assign {
            let alert=NSAlert();alert.messageText="Assign this chat to \(project.name)?";alert.informativeText="Codex has not recorded a project for this repository chat. This will file the selected chat in this project before using it for improvements."
            alert.addButton(withTitle:"Assign & use chat");alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {return}
        }
        use.isEnabled=false;status.stringValue="Verifying and saving the connection…"
        Task { @MainActor in
            do {_ = try await dispatcher.connectDesktop(projectID:project.id,chatID:chat.id,assignUnfiled:assign);_ = dispatcher.openURL(ImprovementHandoffLink.chatURL(UUID(uuidString:chat.id)!));connected?();close()}
            catch {status.stringValue=error.localizedDescription;use.isEnabled=true}
        }
    }
}
