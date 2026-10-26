import AppKit
import UniformTypeIdentifiers

@MainActor
final class ApplicationsWindow: NSObject,NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate,NSSearchFieldDelegate {
    let window: NSWindow
    let search=NSSearchField(),table=NSTableView()
    private let launcher: ApplicationLauncher
    private var apps: [ApplicationEntry]=[],filtered: [ApplicationEntry]=[]
    private var monitor: Any?
    init(launcher: ApplicationLauncher) {
        self.launcher=launcher
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:420),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init();window.title="Window Factory Applications";window.isReleasedWhenClosed=false;window.collectionBehavior=[.moveToActiveSpace];window.delegate=self
        search.placeholderString="Search applications";search.delegate=self
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("app"));table.addTableColumn(column);table.headerView=nil;table.rowHeight=42;table.dataSource=self;table.delegate=self
        table.target=self;table.doubleAction=#selector(openSelected)
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true
        let stack=NSStackView(views:[search,scroll]);stack.orientation = .vertical;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-16),search.widthAnchor.constraint(equalTo:stack.widthAnchor),scroll.widthAnchor.constraint(equalTo:stack.widthAnchor)])
        monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
            let handled=MainActor.assumeIsolated { ()->Bool in
                guard let self,event.window===self.window else{return false}
                switch event.keyCode {
                case 53:self.window.close();return true
                case 36,76:self.openSelected();return true
                case 125,126:
                    if !self.filtered.isEmpty{let next=max(0,min(self.filtered.count-1,self.table.selectedRow+(event.keyCode==125 ? 1 : -1)));self.table.selectRowIndexes(IndexSet(integer:next),byExtendingSelection:false);self.table.scrollRowToVisible(next)};return true
                default:return false
                }
            }
            return handled ? nil : event
        }
    }
    static func inventory(extra: [ApplicationEntry]) -> [ApplicationEntry] {
        var found: [String:ApplicationEntry]=[:]
        for root in [URL(fileURLWithPath:"/Applications"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),URL(fileURLWithPath:"/System/Applications")] {
            guard let walk=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles]) else {continue}
            while let url=walk.nextObject() as? URL {
                if url.pathExtension.lowercased()=="app" {
                    walk.skipDescendants()
                    if let entry=try? ApplicationLauncher.readApplication(url,slot:1),found[entry.bundleID]==nil{found[entry.bundleID]=entry}
                }
            }
        }
        for entry in extra where !entry.isSearch{found[entry.bundleID]=entry}
        return found.values.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    func reload(){let query=search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);filtered=apps.filter{query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)};table.reloadData();if !filtered.isEmpty{table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)}}
    func show(){apps=Self.inventory(extra:launcher.entries);search.stringValue="";reload();window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);window.makeFirstResponder(search)}
    func controlTextDidChange(_ obj: Notification){reload()}
    func numberOfRows(in tableView: NSTableView)->Int{filtered.count}
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int)->NSView? {
        let entry=filtered[row],cell=NSTableCellView(),icon=NSImageView(),title=NSTextField(labelWithString:entry.name)
        if let url=launcher.resolvedURL(entry){icon.image=NSWorkspace.shared.icon(forFile:url.path)}
        title.lineBreakMode = .byTruncatingTail;cell.textField=title
        for view in [icon,title]{view.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(view)}
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:6),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:28),icon.heightAnchor.constraint(equalToConstant:28),title.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:10),title.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-8),title.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        return cell
    }
    @objc func openSelected(){guard filtered.indices.contains(table.selectedRow) else{return};let entry=filtered[table.selectedRow];window.close();launcher.launch(entry)}
    func showError(_ message: String){let alert=NSAlert();alert.messageText="Application could not open";alert.informativeText=message;alert.runModal()}
    func stop(){if let monitor{NSEvent.removeMonitor(monitor)};monitor=nil}
}

@MainActor
final class ApplicationsEditor: NSObject,NSTableViewDataSource,NSTableViewDelegate {
    let view=NSView(),table=NSTableView()
    private var launcher: ApplicationLauncher?
    private var recorders: [ShortcutRecorder]=[]
    private let message=NSTextField(wrappingLabelWithString:"")
    override init(){
        super.init()
        for (id,title,width) in [("app","Application",240.0),("key","Shortcut",180.0),("enabled","Enabled",64.0)]{let c=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));c.title=title;c.width=width;table.addTableColumn(c)}
        table.rowHeight=40;table.dataSource=self;table.delegate=self
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true
        let add=NSButton(title:"Add Application…",target:self,action:#selector(addApplication)),remove=NSButton(title:"Remove",target:self,action:#selector(removeApplication)),clear=NSButton(title:"Clear Shortcut",target:self,action:#selector(clearShortcut))
        for button in [add,remove,clear]{button.bezelStyle = .rounded}
        let actions=NSStackView(views:[add,remove,clear]);actions.spacing=10
        let stack=NSStackView(views:[scroll,message,actions]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:view.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-20),scroll.widthAnchor.constraint(equalTo:stack.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200),message.widthAnchor.constraint(equalTo:stack.widthAnchor)])
        message.font = .systemFont(ofSize:12);message.textColor = .secondaryLabelColor
    }
    func connect(_ launcher: ApplicationLauncher){self.launcher=launcher;refresh()}
    func refresh(){guard ShortcutRecorder.current?.isRecording != true else{return};recorders=[];table.reloadData();message.stringValue=launcher?.loadError ?? launcher?.failures.values.sorted().joined(separator:"\n") ?? "";message.isHidden=message.stringValue.isEmpty}
    func numberOfRows(in tableView: NSTableView)->Int{launcher?.entries.count ?? 0}
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int)->NSView? {
        guard let launcher else{return nil};let entry=launcher.entries[row]
        switch column?.identifier.rawValue {
        case "key":
            let definition=ShortcutDefinition(id:"application.\(entry.id)",title:"Launch \(entry.name)",group:.library,index:entry.slot,standard:entry.shortcut ?? ShortcutChord(key:0,modifiers:ShortcutChord.hyper,name:"A"))
            let recorder=ShortcutRecorder(definition,manager:nil,read:{[weak launcher] in launcher?.entries.first{$0.id==entry.id}?.shortcut},save:{[weak launcher] chord in try launcher?.setShortcut(chord,id:entry.id)})
            recorder.finished={[weak self] in self?.refresh()};recorders.append(recorder);return recorder
        case "enabled":
            let toggle=NSSwitch();toggle.state=entry.enabled ? .on : .off;toggle.isEnabled=entry.shortcut != nil;toggle.tag=row;toggle.target=self;toggle.action=#selector(toggleApplication(_:));toggle.setAccessibilityLabel("Enable \(entry.name) shortcut");return toggle
        default:
            let text=NSTextField(labelWithString:entry.name);text.lineBreakMode = .byTruncatingTail;text.toolTip=entry.path;return text
        }
    }
    private func run(_ operation: ()throws->Void){do{try operation();refresh()}catch{refresh();let alert=NSAlert();alert.messageText="Application shortcut not changed";alert.informativeText=error.localizedDescription;if let window=view.window{alert.beginSheetModal(for:window)}}}
    @objc private func addApplication(){guard launcher != nil else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[.applicationBundle];panel.allowsMultipleSelection=false;panel.canChooseDirectories=false;if panel.runModal() == .OK,let url=panel.url{run{_ = try launcher?.add(url)}}}
    @objc private func removeApplication(){guard let launcher,launcher.entries.indices.contains(table.selectedRow) else{return};let id=launcher.entries[table.selectedRow].id;run{try launcher.remove(id)}}
    @objc private func clearShortcut(){guard let launcher,launcher.entries.indices.contains(table.selectedRow) else{return};let id=launcher.entries[table.selectedRow].id;run{try launcher.setShortcut(nil,id:id)}}
    @objc private func toggleApplication(_ sender: NSSwitch){guard let launcher,launcher.entries.indices.contains(sender.tag) else{return};let id=launcher.entries[sender.tag].id;run{try launcher.setEnabled(sender.state == .on,id:id)}}
}
