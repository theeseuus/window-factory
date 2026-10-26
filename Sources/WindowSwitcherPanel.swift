import AppKit

@MainActor
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor
final class WindowSwitcherPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let preview = NSImageView()
    private let desktopTitle = NSTextField(labelWithString:"")
    private let appTitle = NSTextField(labelWithString:"")
    private let title = NSTextField(wrappingLabelWithString:"")
    private let position = NSTextField(labelWithString:"")
    private let scroll = NSScrollView()
    private var rows: [Int:NSButton] = [:]
    private var selectedRow: Int?
    private var monitor: Any?
    private var showing = false, keyboardReady = false
    var choose: ((Int) -> Void)?
    var navigate: ((SwitcherNavigationAction) -> Void)?
    var dismiss: (() -> Void)?
    var hasKeyboardFocus: Bool { panel.isKeyWindow }
    override init() {
        panel = SwitcherPanel(contentRect:NSRect(x:0,y:0,width:780,height:570),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isOpaque = false
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.transient,.ignoresCycle]
        panel.title = "Window Factory Window Switcher"; panel.delegate = self
        let content = NSView(frame:NSRect(x:0,y:0,width:780,height:570)); content.wantsLayer = true
        content.layer?.cornerRadius = 14; content.layer?.masksToBounds = true
        preview.frame = NSRect(x:20,y:350,width:320,height:190); preview.imageScaling = .scaleProportionallyUpOrDown
        desktopTitle.frame = NSRect(x:362,y:508,width:398,height:32)
        desktopTitle.font = .systemFont(ofSize:20,weight:.semibold); desktopTitle.textColor = .controlAccentColor
        appTitle.frame = NSRect(x:362,y:477,width:398,height:26); appTitle.font = .systemFont(ofSize:17,weight:.semibold)
        title.frame = NSRect(x:362,y:393,width:398,height:72); title.font = .systemFont(ofSize:14)
        title.maximumNumberOfLines = 3
        position.frame = NSRect(x:362,y:360,width:398,height:22); position.font = .systemFont(ofSize:12); position.textColor = .secondaryLabelColor
        scroll.frame = NSRect(x:20,y:20,width:740,height:314); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        for view in [preview,desktopTitle,appTitle,title,position,scroll] { content.addSubview(view) }
        panel.contentView = content
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self,event.window === self.panel,let action = SwitcherNavigationAction.key(event.keyCode) else { return false }
                self.navigate?(action); return true
            }
            return handled ? nil : event
        }
    }
    func loading() {
        showing = true; keyboardReady = false
        desktopTitle.stringValue = "Window switcher"; appTitle.stringValue = "Collecting windows…"; title.stringValue = ""; position.stringValue = ""
        preview.image = nil; rows = [:]; selectedRow = nil; scroll.documentView = NSView()
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame; panel.setFrameOrigin(NSPoint(x:f.midX-390,y:f.midY-285))
        }
        panel.orderFrontRegardless()
    }
    func focusForNavigation() {
        keyboardReady = true
        panel.makeKeyAndOrderFront(nil)
    }
    func render(_ records: [SwitcherWindowRecord],selected: Int,origin: SwitcherOrigin) {
        guard records.indices.contains(selected) else { return }
        let groups = SwitcherDesktopGrouping.groups(records.map(\.desktopLocation))
        let displays = Set(records.map(\.display)).count>1
        // Records are fixed for an open picker. Retain its document and viewport
        // while navigating; replacing the document resets scrolling on every key.
        if rows.isEmpty {
            let height = max(scroll.contentSize.height,CGFloat(records.count*48+groups.count*36))
            let document = NSView(frame:NSRect(x:0,y:0,width:720,height:height)); rows = [:]
            var offset: CGFloat = 0
            for group in groups {
                let label = group.location.label(showDisplay:displays)
                let header = NSTextField(labelWithString:"\(label)  ·  \(group.indices.count) \(group.indices.count == 1 ? "window" : "windows")")
                header.font = .systemFont(ofSize:13,weight:.semibold)
                header.textColor = group.location.isCurrent ? .controlAccentColor : .secondaryLabelColor
                header.frame = NSRect(x:12,y:height-offset-29,width:700,height:25)
                document.addSubview(header); offset += 36
                for i in group.indices {
                    let record = records[i], text = record.title.replacingOccurrences(of:"\n",with:" ")
                    let button = NSButton(title:"  \(record.window.appName) — \(text.isEmpty ? "Untitled window" : text)",target:self,action:#selector(clickRow(_:)))
                    button.tag = i; button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize:13)
                    button.cell?.lineBreakMode = .byTruncatingMiddle
                    button.toolTip = "\(label)\n\(record.window.appName)\n\(text)"
                    button.image = record.icon; button.imagePosition = .imageLeft; button.imageScaling = .scaleProportionallyDown
                    button.frame = NSRect(x:14,y:height-offset-46,width:700,height:44); offset += 48
                    button.wantsLayer = true; button.layer?.cornerRadius = 7
                    button.layer?.backgroundColor = NSColor.clear.cgColor
                    document.addSubview(button); rows[i] = button
                }
            }
            scroll.documentView = document
            scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,height-scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if let previous = selectedRow { rows[previous]?.layer?.backgroundColor = NSColor.clear.cgColor }
        rows[selected]?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        selectedRow = selected
        if let row = rows[selected],let document = scroll.documentView {
            // Move immediately and only far enough to expose the selected row.
            // Pulling the group heading into view on each step causes extra travel.
            let clip = scroll.contentView, visible = clip.bounds
            var y = visible.minY
            if row.frame.minY < visible.minY { y = row.frame.minY }
            else if row.frame.maxY > visible.maxY { y = row.frame.maxY-visible.height }
            y = max(0,min(y,max(0,document.bounds.height-visible.height)))
            if y != visible.minY {
                clip.scroll(to:NSPoint(x:visible.minX,y:y))
                scroll.reflectScrolledClipView(clip)
            }
        }
        let record = records[selected], group = groups.first{$0.indices.contains(selected)}
        desktopTitle.stringValue = record.desktopLocation.label(showDisplay:displays)
        appTitle.stringValue = record.window.appName
        title.stringValue = record.title.isEmpty ? "Untitled window" : record.title
        let local = group?.indices.firstIndex(of:selected).map{$0+1} ?? 1
        position.stringValue = "\(local) of \(group?.indices.count ?? 1) windows in group  ·  \(selected+1) of \(records.count) total"
        preview.image = record.icon
    }
    func showPreview(_ image: NSImage) { preview.image = image }
    @objc private func clickRow(_ sender: NSButton) { choose?(sender.tag) }
    func windowDidResignKey(_ notification: Notification) { if showing && keyboardReady { dismiss?() } }
    func hide() { showing = false; keyboardReady = false; panel.orderOut(nil); rows = [:]; selectedRow = nil; scroll.documentView = NSView(); preview.image = nil }
    func stop() { hide(); if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
