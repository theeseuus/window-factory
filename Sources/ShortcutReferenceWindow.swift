import AppKit

@MainActor
final class ShortcutReferenceWindow: NSObject {
    let window: NSWindow
    private let preferences: FactoryPreferences
    private let text = NSTextView()
    private let restore = NSButton(title:"Restore last stashed window",target:nil,action:nil)
    var optionalCommands: [OptionalCommandShortcut] = []
    var systemCommands: SystemCommands?
    weak var launcher: LauncherControls?
    weak var spaceIndicator: SpaceIndicator?
    weak var spaceMove: DirectSpaceMoveControls?
    weak var accordion: DirectAccordionControls?
    weak var geometry: DirectWindowControls?
    weak var focus: DirectFocusControls?
    weak var switcher: DirectSwitcherControls?
    weak var stash: DirectStashControls?
    private var monitor: Any?
    init(preferences: FactoryPreferences) {
        self.preferences = preferences
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:720),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init()
        window.title = "Window Factory Keyboard Shortcuts"; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]; window.minSize = NSSize(width:560,height:420)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        text.textContainerInset = NSSize(width:14,height:14); text.autoresizingMask = [.width]
        text.minSize = NSSize(width:0,height:0); text.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true; scroll.documentView = text
        restore.target = self; restore.action = #selector(restoreLast); restore.bezelStyle = .rounded
        let close = NSButton(title:"Close  ⎋",target:self,action:#selector(closeWindow)); close.bezelStyle = .rounded
        let actions = NSStackView(views:[restore,close]); actions.spacing = 12
        let stack = NSStackView(views:[scroll,actions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),
            stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),
            stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),
            stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-16),
            scroll.widthAnchor.constraint(equalTo:stack.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:260)])
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { guard let self,event.window === self.window,event.keyCode == 53 else { return false }; self.window.close(); return true }
            return handled ? nil : event
        }
    }
    var applications: ApplicationLauncher?
    func refresh() {
        let states: [ShortcutGroup:Bool] = [.geometry:geometry?.active == true,.focus:focus?.active == true,.stash:stash?.active == true,.switcher:switcher?.active == true,.accordion:accordion?.active == true,.spaces:spaceMove?.active == true,.library:launcher?.active == true,.system:systemCommands?.active == true]
        func row(_ modifiers: String,_ key: String,_ action: String) -> String {
            "\t"+modifiers+"\t"+key+"\t"+action
        }
        var sections = ["WINDOW FACTORY KEYBOARD SHORTCUTS"]
        for group in ShortcutGroup.allCases {
            let rows = ShortcutDefinition.all.filter{$0.group == group}.map {
                let chord = preferences.shortcuts.chord($0)
                return row(chord.modifierLabel,chord.name,$0.title)
            }
            var shownRows=rows
            for command in optionalCommands where command.definition.group == group {
                let value=command.chord
                shownRows.append(row(value?.modifierLabel ?? "",value?.name ?? "—",command.definition.title+(command.active ? "" : " [Off]")))
            }
            sections.append("\(group.title.uppercased())  [\(states[group] == true ? "On" : "Off")]\n"+shownRows.joined(separator:"\n"))
        }
        if let applications {
            let rows = ApplicationListOrder.sorted(applications.entries).compactMap { entry -> String? in
                guard let chord=entry.shortcut else{return nil}
                let state=applications.active.contains(entry.id) ? "" : " [Off]"
                return row(chord.modifierLabel,chord.name,(entry.isSearch ? "Applications search" : "Open / hide "+entry.name)+state)
            }
            sections.append("APPLICATIONS\n"+(rows.isEmpty ? "No application shortcuts" : rows.joined(separator:"\n")))
        }
        sections.append("Stashed windows in this app session: \(stash?.count ?? 0)")
        func section(_ title: String,_ rows: [(String,String,String)]) -> String {
            title+"\n"+rows.map{row($0.0,$0.1,$0.2)}.joined(separator:"\n")
        }
        sections.append(section("SWITCHER NAVIGATION",[("","↑ / ↓","Previous / next window"),("","← / →","Previous / next desktop"),("","Return / Enter","Select window"),("","Escape","Close")]))
        sections.append(section("LAYOUT LIBRARY",[("","↑ / ↓","Select layout"),("","Space","Show / hide layout preview"),("⌥","↑ / ↓","Move layout up / down"),("","Return","Restore"),("⌘","Return","Establish"),("⌘","N","Capture"),("⌘","F","Search"),("⌘","I","Import"),("⇧⌘","E","Export"),("⌘","Delete","Delete layout"),("","Escape","Cancel or close"),("⌘",",","Settings"),("⌘","W","Close window"),("⌘","Q","Quit Window Factory")]))
        sections.append(section("TILING PANEL",[("","↑ / ↓","Select window"),("","− / +","Resize selected split"),("","V / H","Side by side / top-bottom"),("","B","Balance"),("","S","Swap with next tile"),("","F","Float / rejoin"),("","P","Pause / resume"),("","Escape","Close panel")]))
        sections.append(section("MACOS DESKTOP NAVIGATION",[("⌃","← / →","Switch desktop (macOS)")]))
        text.string = sections.joined(separator:"\n\n")
        let body = NSMutableAttributedString(string:text.string,attributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.labelColor])
        let columns = NSMutableParagraphStyle()
        columns.tabStops = [NSTextTab(textAlignment:.right,location:55),NSTextTab(textAlignment:.left,location:72),NSTextTab(textAlignment:.left,location:210)]
        columns.defaultTabInterval = 210; columns.headIndent = 210
        (body.string as NSString).enumerateSubstrings(in:NSRange(location:0,length:body.length),options:.byParagraphs) { line,range,_,_ in
            if let line,line.contains("\t") {
                body.addAttribute(.paragraphStyle,value:columns,range:range)
                let fields = line.components(separatedBy:"\t")
                if fields.count>=4 {
                    let count = fields[1].utf16.count
                    if count>1 { body.addAttribute(.kern,value:ShortcutChord.modifierTracking,range:NSRange(location:range.location+1,length:count-1)) }
                }
            }
        }
        text.textStorage?.setAttributedString(body)
        restore.isEnabled = (stash?.count ?? 0)>0
    }
    func show() {
        refresh(); window.level = preferences.keepLibraryOnTop ? .floating : .normal
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    @objc func restoreLast() { stash?.restoreLast(); refresh() }
    @objc func closeWindow() { window.close() }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
