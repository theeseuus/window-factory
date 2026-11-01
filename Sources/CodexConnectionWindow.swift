import AppKit

/// Explicit setup/re-run setup. Lists actual provider records; folder names are not IDs.
@MainActor
final class CodexConnectionWindow:NSObject {
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:340),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    let dispatcher:ImprovementDispatcher
    var connected:(()->Void)?
    private let projects=NSPopUpButton(),chats=NSPopUpButton()
    private let status=NSTextField(wrappingLabelWithString:"Connect using Codex desktop’s current sign-in. Choose its project and the chat that should receive requests.")
    private let path=NSTextField(wrappingLabelWithString:"")
    private let use=NSButton(title:"Use this chat",target:nil,action:nil)
    private let newChat=NSButton(title:"New chat…",target:nil,action:nil)
    private var projectRows:[CodexProject]=[],chatRows:[CodexChat]=[]
    private var generation=UUID()
    init(dispatcher:ImprovementDispatcher) {
        self.dispatcher=dispatcher;super.init();window.title="Improvements · Codex connection";window.isReleasedWhenClosed=false
        let title=NSTextField(labelWithString:"Where should improvement requests go?");title.font = .systemFont(ofSize:16,weight:.semibold)
        let load=NSButton(title:"Load / refresh projects",target:self,action:#selector(loadProjects));load.bezelStyle = .rounded
        let create=NSButton(title:"Create project…",target:self,action:#selector(createProject));create.bezelStyle = .rounded
        projects.target=self;projects.action=#selector(projectChanged);projects.setAccessibilityLabel("Codex project")
        chats.target=self;chats.action=#selector(chatChanged);chats.setAccessibilityLabel("Codex coding chat")
        projects.isEnabled=false;chats.isEnabled=false
        use.target=self;use.action=#selector(connect);use.bezelStyle = .rounded;use.isEnabled=false
        newChat.target=self;newChat.action=#selector(createChat);newChat.bezelStyle = .rounded;newChat.isEnabled=false
        let cancel=NSButton(title:"Close",target:self,action:#selector(close));cancel.bezelStyle = .rounded
        let projectRow=NSStackView(views:[NSTextField(labelWithString:"Project:"),projects,newChat]);projectRow.spacing=8
        let chatRow=NSStackView(views:[NSTextField(labelWithString:"Chat:"),chats]);chatRow.spacing=8
        let controls=NSStackView(views:[load,create,NSView(),cancel,use]);controls.spacing=8
        let stack=NSStackView(views:[title,status,projectRow,chatRow,path,NSView(),controls]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12
        stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)])
        for view in [status,projectRow,chatRow,path,controls] {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
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
                if rows.isEmpty {status.stringValue="No Codex projects found. Create a project to continue.";chats.removeAllItems();chatRows=[]}
                else {projectChanged()}
            } catch {guard generation==token else {return};status.stringValue=error.localizedDescription}
        }
    }
    @objc private func projectChanged() {
        guard let project else {return};let token=UUID();generation=token
        status.stringValue="Reading chats in \(project.name)…";use.isEnabled=false;newChat.isEnabled=true;chats.isEnabled=false
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
        status.stringValue=chat == nil ? "No chats yet. Create a new chat in this project." : "Requests will be sent directly to this chat. Its existing model is used."
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
    @objc private func createChat() {
        guard let project else {return}
        let alert=NSAlert();alert.messageText="Create a chat in \(project.name)"
        let roots=NSPopUpButton(frame:NSRect(x:0,y:0,width:500,height:26));roots.addItems(withTitles:project.roots);alert.accessoryView=roots
        alert.informativeText="Choose the repository for the new coding chat. Creating it starts no model work."
        alert.addButton(withTitle:"Create chat");alert.addButton(withTitle:"Cancel")
        guard !project.roots.isEmpty,alert.runModal() == .alertFirstButtonReturn,let repository=roots.selectedItem?.title else {return}
        newChat.isEnabled=false;use.isEnabled=false;status.stringValue="Creating a project chat…"
        Task { @MainActor in
            do {
                let chat=try await dispatcher.createDesktopChat(projectID:project.id,repository:repository,operationID:UUID())
                chatRows.insert(chat,at:0);chats.insertItem(withTitle:chat.name,at:0);chats.selectItem(at:0);chats.isEnabled=true
                _ = dispatcher.openURL(ImprovementHandoffLink.chatURL(UUID(uuidString:chat.id)!));chatChanged()
            } catch {status.stringValue=error.localizedDescription}
            newChat.isEnabled=true
        }
    }
    @objc private func createProject() {
        let alert=NSAlert();alert.messageText="Create a Codex project"
        alert.informativeText="Use an existing repository, or create a separate local folder and repository."
        alert.addButton(withTitle:"Existing repository…");alert.addButton(withTitle:"New folder & repository…");alert.addButton(withTitle:"Cancel")
        let choice=alert.runModal();var folder:URL?
        if choice == .alertFirstButtonReturn {
            let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
            if panel.runModal() == .OK {folder=panel.url}
        } else if choice == .alertSecondButtonReturn {
            let panel=NSSavePanel();panel.title="New project folder";panel.nameFieldStringValue="New project";panel.canCreateDirectories=true
            if let origin=try? dispatcher.configuration().repository {panel.directoryURL=URL(fileURLWithPath:origin).deletingLastPathComponent()}
            if panel.runModal() == .OK {folder=panel.url}
        }
        guard let folder else {return}
        let namePrompt=NSAlert();namePrompt.messageText="Project name"
        let name=NSTextField(frame:NSRect(x:0,y:0,width:360,height:26));name.stringValue=folder.lastPathComponent;namePrompt.accessoryView=name
        namePrompt.addButton(withTitle:"Create project");namePrompt.addButton(withTitle:"Cancel");guard namePrompt.runModal() == .alertFirstButtonReturn else {return}
        let projectName=name.stringValue,operationID=UUID();status.stringValue="Creating the project…"
        Task { @MainActor in
            do {
                if choice == .alertSecondButtonReturn {_ = try await dispatcher.createProject(folder.path,operationID:operationID,selectAsDestination:false)}
                let created=try await dispatcher.desktopCreate(projectName,folder.path,operationID)
                projectRows.append(created);projects.addItem(withTitle:created.name);projects.selectItem(at:projectRows.count-1);projects.isEnabled=true
                projectChanged()
            } catch {status.stringValue=error.localizedDescription}
        }
    }
}
