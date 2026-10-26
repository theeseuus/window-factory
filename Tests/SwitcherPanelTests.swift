import AppKit

@main enum SwitcherPanelTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let picker = WindowSwitcherPanel()
        let origin = SwitcherOrigin(pid:getpid(),windowID:nil,desktops:[])
        let records = (0..<18).map { i in
            let desktop = i/6+1
            return SwitcherWindowRecord(
                window:SwitcherWindowIdentity(id:UInt32(i+1),pid:getpid(),bundleID:"local.test",appName:"Test",element:nil,frame:Frame(x:0,y:0,w:100,h:100)),
                space:UInt64(desktop),display:1,title:"Window \(i+1)",icon:nil,
                location:SwitcherDesktopLocation(display:1,space:UInt64(desktop),displayNumber:1,desktopNumber:desktop,spaceOrder:desktop,isCurrent:desktop == 1,isFullscreen:false))
        }
        picker.render(records,selected:0,origin:origin)
        let panel = NSApplication.shared.windows.first{$0.title == "Window Factory Window Switcher"}!
        let scroll = panel.contentView!.subviews.compactMap{$0 as? NSScrollView}.first!
        let document = scroll.documentView!
        var assertions = 0
        func check(_ value: Bool,_ message: String) {
            assertions += 1
            guard value else { fatalError(message) }
        }
        func row(_ index: Int) -> NSButton { document.subviews.compactMap{$0 as? NSButton}.first{$0.tag == index}! }
        func select(_ index: Int) {
            picker.render(records,selected:index,origin:origin)
            check(scroll.documentView === document,"selection must retain the document")
            check(scroll.contentView.bounds.contains(row(index).frame),"selected row must be fully visible")
        }
        let top = scroll.contentView.bounds.origin
        select(1); select(2); select(3)
        check(scroll.contentView.bounds.origin == top,"visible rows must not move the viewport")
        for index in 4..<18 {
            let before = scroll.contentView.bounds
            let frame = row(index).frame
            select(index)
            let after = scroll.contentView.bounds
            let expected = frame.minY < before.minY ? frame.minY : before.minY
            check(abs(after.minY-expected)<0.01,"down navigation must scroll only to the row edge")
            check(abs(after.minY-before.minY)<=84,"one step must not sweep past multiple rows")
        }
        for index in stride(from:16,through:0,by:-1) {
            let before = scroll.contentView.bounds
            let frame = row(index).frame
            select(index)
            let expected = frame.maxY>before.maxY ? frame.maxY-before.height : before.minY
            check(abs(scroll.contentView.bounds.minY-expected)<0.01,"up navigation must scroll only to the row edge")
        }
        select(17); select(0); select(12); select(6)
        let still = scroll.contentView.bounds
        select(6)
        check(scroll.contentView.bounds == still,"repeated selection must not scroll")
        picker.hide()
        picker.render(Array(records.prefix(2)),selected:0,origin:origin)
        check(scroll.documentView !== document,"new session must rebuild its list")
        check(scroll.documentView!.bounds.height>=scroll.contentSize.height,"short lists must fill the viewport")
        picker.stop()
        for label in ["1","12","123","?","—"] {
            let image = SpaceIndicator.image(label)
            check(image.isTemplate,"indicator adapts to menu-bar appearance")
            check(image.size.height == 18 && image.size.width>=24,"compact outlined badge dimensions")
            let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
            check(bitmap.colorAt(x:0,y:0)!.alphaComponent == 0,"rounded badge corner stays transparent")
        }
        func event(_ id: AEEventID = AEEventID(kAEOpenApplication)) -> NSAppleEventDescriptor {
            NSAppleEventDescriptor(eventClass:AEEventClass(kCoreEventClass),eventID:id,targetDescriptor:nil,returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
        }
        check(!LauncherControls.isLoginLaunch(nil),"missing launch event is a normal launch")
        check(!LauncherControls.isLoginLaunch(event()),"ordinary open shows the library")
        let direct = event(); direct.setParam(NSAppleEventDescriptor(boolean:true),forKeyword:AEKeyword(keyAELaunchedAsLogInItem))
        check(LauncherControls.isLoginLaunch(direct),"login marker is recognized")
        let property = event(); property.setParam(NSAppleEventDescriptor(enumCode:OSType(keyAELaunchedAsLogInItem)),forKeyword:AEKeyword(keyAEPropData))
        check(LauncherControls.isLoginLaunch(property),"login property-data marker is recognized")
        let unrelated = event(AEEventID(kAEReopenApplication)); unrelated.setParam(NSAppleEventDescriptor(boolean:true),forKeyword:AEKeyword(keyAELaunchedAsLogInItem))
        check(!LauncherControls.isLoginLaunch(unrelated),"reopening the app is not a quiet login launch")
        check(!FactoryLaunchPolicy.showsLibrary(arguments:[],loginLaunch:LauncherControls.isLoginLaunch(property)),"login launches keep the library closed")
        let preferenceName = "WindowFactory.DockTest.\(UUID().uuidString)"
        let dockDefaults = UserDefaults(suiteName:preferenceName)!
        defer { dockDefaults.removePersistentDomain(forName:preferenceName) }
        let dockPreferences = FactoryPreferences(defaults:dockDefaults)
        check(dockPreferences.showDockIcon,"Dock icon starts visible")
        dockPreferences.showDockIcon = false
        check(!FactoryPreferences(defaults:dockDefaults).showDockIcon,"Dock visibility survives preference reload")
        dockPreferences.showDockIcon = true
        check(FactoryPreferences(defaults:dockDefaults).showDockIcon,"Dock visibility restores independently")
        let settingsStore = try LayoutStore(url:URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("wf-settings-\(UUID().uuidString).json"))
        let uiRegistry = AdapterRegistry(schemaVersion:1,adapters:[])
        let layoutUI = LibraryWindow(store:settingsStore,registry:uiRegistry,preview:false,preferences:dockPreferences)
        let rowA = Recipe(name:"A",capturedAt:"fixture",windows:[])
        let rowB = Recipe(name:"B",capturedAt:"fixture",windows:[])
        layoutUI.filtered = [rowA,rowB]; layoutUI.table.reloadData()
        layoutUI.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let rowMenu = layoutUI.contextMenu(for:1)!
        check(layoutUI.selected?.name == "B","context menu selects the clicked row, not the prior selection")
        check(rowMenu.items.filter{!$0.isSeparatorItem}.map(\.title) == ["Restore","Establish here","Delete…"],"layout context menu exposes existing actions")
        check(rowMenu.items.last?.action == #selector(LibraryWindow.deleteLayout) && rowMenu.items.last?.target === layoutUI,"context Delete uses existing confirmation path")
        check(layoutUI.delete.action == #selector(LibraryWindow.deleteLayout) && layoutUI.delete.isEnabled,"visible Delete uses same action without requiring Accessibility")
        check(layoutUI.contextMenu(for:-1) == nil && layoutUI.selected?.name == "B","blank right click cannot target an old selection")
        layoutUI.frozen = rowA; layoutUI.updateButtons()
        check(!layoutUI.delete.isEnabled && layoutUI.contextMenu(for:0) == nil,"capture naming prevents delete and context actions")
        layoutUI.frozen = nil; layoutUI.table.deselectAll(nil); layoutUI.updateButtons()
        check(!layoutUI.delete.isEnabled,"Delete disabled without selection")
        check(settingsStore.catalog.recipes.isEmpty,"menu tests do not mutate catalogs")
        let rowRecipe = Recipe(name:"Two windows",capturedAt:"fixture",windows:[
            Slot(bundleID:"test.app",appName:"Test",ordinal:1,frame:Frame(x:0,y:0,w:0.5,h:1)),
            Slot(bundleID:"test.app",appName:"Test",ordinal:2,frame:Frame(x:0.5,y:0,w:0.5,h:1))])
        var lookups: [String] = []
        let richRow = LayoutRowView(recipe:rowRecipe) { id in lookups.append(id); return nil }
        richRow.frame = NSRect(x:0,y:0,width:320,height:68); richRow.layoutSubtreeIfNeeded()
        check(richRow.apps.count == 1 && richRow.apps[0].count == 2,"one icon per app with an accurate saved-window count")
        check(lookups == ["test.app"],"icons resolve once per distinct app without querying window contents")
        check(richRow.icons.arrangedSubviews.count == 1,"repeated app windows do not duplicate icons")
        check(richRow.nameLabel.stringValue == rowRecipe.name && richRow.textField === richRow.nameLabel,"row retains a native accessible title")
        let rects = richRow.thumbnail.rectangles(in:NSRect(x:0,y:0,width:84,height:52))
        check(rects.count == 2 && abs(rects[0].width-rects[1].width)<0.001 && abs(rects[0].maxX-rects[1].minX)<0.001 && abs(rects[1].minX-42)<0.001,"thumbnail reflects normalized left/right layout geometry")
        check(rects.allSatisfy{NSRect(x:0,y:0,width:84,height:52).contains($0)},"thumbnail stays within its canvas")
        check((richRow.icons.arrangedSubviews[0] as! NSStackView).arrangedSubviews.compactMap{$0 as? NSImageView}.first?.image != nil,"missing apps retain a visible fallback icon")
        let manyRecipe = Recipe(name:"Many apps",capturedAt:"fixture",windows:(0..<8).map { index in
            Slot(bundleID:"test.\(index)",appName:"App \(index)",ordinal:1,frame:Frame(x:0,y:0,w:1,h:1)) })
        let manyRow = LayoutRowView(recipe:manyRecipe) { _ in nil }
        check(manyRow.icons.arrangedSubviews.count == 5 && (manyRow.icons.arrangedSubviews.last as? NSTextField)?.stringValue == "+4","many-app rows cap icons and expose the remainder")
        let rexName = Recipe(name:"Rex",capturedAt:"fixture",windows:rowRecipe.windows)
        let rexNamePart = Recipe(name:"Rex work",capturedAt:"fixture",windows:rowRecipe.windows)
        let containsRex = Recipe(name:"Alpha",capturedAt:"fixture",windows:[Slot(bundleID:"rex",appName:"Rex",ordinal:1,frame:Frame(x:0,y:0,w:1,h:1))])
        check(LibraryPresentation.ordered([containsRex,rexNamePart,rexName],savedOrder:["Alpha","Rex work","Rex"],query:"rex").map(\.name) == ["Rex","Rex work","Alpha"],"exact layout name, partial layout name, then app-only matches")
        check(LibraryPresentation.ordered([containsRex,rexName],savedOrder:["Rex","Rex","gone"],query:"").map(\.name) == ["Rex","Alpha"],"saved order tolerates stale/duplicate names and appends new layouts")
        check(LibraryPresentation.moving(["A","B","C"],name:"A",to:3) == ["B","C","A"],"drop below final row moves down correctly")
        check(LibraryPresentation.moving(["A","B","C"],name:"C",to:0) == ["C","A","B"],"drop above first row moves up correctly")
        check(LibraryPresentation.moving(["A"],name:"gone",to:0) == nil && LibraryPresentation.moving(["A"],name:"A",to:2) == nil,"invalid drops cannot change order")
        let wideCanvas = LibraryPresentation.canvas(in:NSRect(x:0,y:0,width:280,height:400),inset:12,aspect:16.0/9)
        check(abs(wideCanvas.width/wideCanvas.height-16.0/9)<0.001 && wideCanvas.midY == 200,"expanded preview letterboxes to display ratio")
        check(layoutUI.shortcuts.title.isEmpty && layoutUI.shortcuts.imagePosition == .imageOnly,"compact shortcut control has no overlapping title")
        check(!layoutUI.quickLook.isShown && layoutUI.quickLook.contentViewController?.view === layoutUI.drawing,"preview is a closed popover outside the main layout")
        check(layoutUI.quickLook.behavior == .semitransient,"Quick Look uses normal outside-dismissal behavior")
        layoutUI.filtered = [rowA,rowB];layoutUI.table.reloadData()
        check(layoutUI.moveLayout("B",to:0) && dockPreferences.layoutOrder == ["B","A"],"drop order is stored without changing recipes")
        check(FactoryPreferences(defaults:dockDefaults).layoutOrder == ["B","A"],"manual order survives preferences reload")
        layoutUI.search.stringValue = "A"
        check(!layoutUI.moveLayout("B",to:0),"reordering is disabled while search hides rows")
        layoutUI.search.stringValue = "";layoutUI.frozen = rowA
        check(!layoutUI.moveLayout("B",to:0),"reordering is disabled during capture naming")
        layoutUI.frozen = nil
        check(settingsStore.catalog.recipes.isEmpty,"presentation settings never alter layout catalog")
        layoutUI.search.stringValue = "two words"
        check(!layoutUI.canQuickLookFromKeyboard,"Space remains text input while editing a nonempty search")
        layoutUI.search.stringValue = ""

        let keyboardRecipes = ["A","B","C"].map { Recipe(name:$0,capturedAt:"fixture",windows:rowRecipe.windows) }
        settingsStore.catalog.recipes = Dictionary(uniqueKeysWithValues:keyboardRecipes.map{($0.name,$0)})
        let catalogBeforeOrdering = try settingsStore.catalog.encoded()
        dockPreferences.layoutOrder = ["A","B","C"];layoutUI.reload(select:"B")
        func arrow(_ code: UInt16,_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
        }
        check(layoutUI.handle(arrow(126,.option)) && layoutUI.filtered.map(\.name) == ["B","A","C"] && layoutUI.selected?.name == "B","Option Up moves and retains the selected layout")
        check(!layoutUI.moveSelectedLayout(-1),"moving above the first row is a no-op")
        check(layoutUI.handle(arrow(125,.option)) && layoutUI.filtered.map(\.name) == ["A","B","C"] && layoutUI.selected?.name == "B","Option Down moves down one row and keeps selection")
        let orderBeforeSelection = dockPreferences.layoutOrder
        check(layoutUI.handle(arrow(125,[])) && layoutUI.selected?.name == "C" && dockPreferences.layoutOrder == orderBeforeSelection,"plain arrows select without changing order")
        check(!layoutUI.moveSelectedLayout(1),"moving below the last row is a no-op")
        check(!layoutUI.handle(arrow(126,[.option,.command])) && layoutUI.selected?.name == "C","other modified arrow commands are not intercepted")
        layoutUI.search.stringValue = "A";layoutUI.reload()
        check(!layoutUI.moveSelectedLayout(1) && dockPreferences.layoutOrder == orderBeforeSelection,"keyboard ordering is disabled while filtering")
        layoutUI.search.stringValue = "";layoutUI.reload(select:"B");layoutUI.frozen = rowA
        check(!layoutUI.canQuickLookFromKeyboard,"capture naming cannot open Quick Look")
        check(!layoutUI.moveSelectedLayout(-1),"keyboard ordering is disabled during capture naming")
        layoutUI.frozen = nil;layoutUI.table.deselectAll(nil)
        check(!layoutUI.moveSelectedLayout(-1),"no selection cannot reorder")
        check(try settingsStore.catalog.encoded() == catalogBeforeOrdering,"keyboard ordering does not change recipe bytes")
        check(FactoryPreferences(defaults:dockDefaults).layoutOrder == orderBeforeSelection,"keyboard ordering uses the same persisted order as dragging")
        let settings = SettingsWindow(store:settingsStore,preferences:FactoryPreferences())
        settings.refresh(); settings.window.contentView!.layoutSubtreeIfNeeded()
        let settingsTabs = settings.window.contentView!.subviews.compactMap{$0 as? NSTabView}.first!
        check(settingsTabs.tabViewItems.map(\.label) == ["General","Shortcuts","Applications","Layouts","About"],"Settings separates preferences, shortcuts, data and app information")
        check(settings.window.frame.height<=(NSScreen.main?.visibleFrame.height ?? 2000),"Settings fits usable display height")
        try ShortcutValidation.validate([:])
        let definitions = ShortcutDefinition.all
        check(definitions.count == 31 && Set(definitions.map(\.id)).count == 31,"all 31 commands have stable distinct IDs")
        for (index,geometry) in GeometryShortcut.all.enumerated() {
            check(definitions[index].standard.key == geometry.keyCode && definitions[index].standard.modifiers == geometry.modifiers,"geometry defaults match working controls")
        }
        let referenceShortcut = definitions.first{$0.id == "library.1"}!
        check(referenceShortcut.standard.key == 44 && referenceShortcut.standard.modifiers == ShortcutChord.hyper,"Keyboard Shortcuts defaults to Hyper slash")
        check(referenceShortcut.standard.actionHint == "Tab + /","reference button uses the same global chord")
        let alternateHint = ShortcutChord(key:79,modifiers:ShortcutChord.hyper,name:"F18")
        check(alternateHint.actionHint == "Tab + F18","a custom global reference binding produces a current hint")
        let statusMenu = SpaceIndicator.menu(target:nil)
        check(statusMenu.items.last?.title == "Quit Window Factory" && statusMenu.items.last?.keyEquivalent == "q","badge menu offers Quit")
        check(statusMenu.items.last?.keyEquivalentModifierMask == .command,"badge Quit uses standard Command Q")
        SpaceIndicator.updateShortcuts(in:statusMenu,preferences:dockPreferences)
        let menuLibrary = statusMenu.items.first{$0.identifier?.rawValue == "library.0"}!
        let menuReference = statusMenu.items.first{$0.identifier?.rawValue == "library.1"}!
        check(menuLibrary.keyEquivalent == "r" && menuLibrary.keyEquivalentModifierMask == [.control,.option,.command],"badge library hint uses saved default chord")
        check(menuReference.keyEquivalent == "/" && statusMenu.items.first{$0.identifier?.rawValue == "settings"}?.keyEquivalent == ",","reference and Settings show their commands")
        let customMenuChord = ShortcutChord(key:79,modifiers:ShortcutChord.hyper,name:"F18")
        try dockPreferences.shortcuts.save(["library.0":customMenuChord])
        SpaceIndicator.updateShortcuts(in:statusMenu,preferences:dockPreferences)
        check(menuLibrary.keyEquivalent == String(UnicodeScalar(0xF715)!) && menuLibrary.toolTip == "Tab + F18","badge hint refreshes from a changed stored binding")
        try dockPreferences.shortcuts.save([:])
        SpaceIndicator.updateShortcuts(in:statusMenu,preferences:dockPreferences)
        check(menuLibrary.keyEquivalent == "r","reset restores the menu hint")
        check(ShortcutChord(key:123,modifiers:ShortcutChord.hyper,name:"←").menuKeyEquivalent == String(UnicodeScalar(0xF702)!),"special-key menu hints use native key equivalents")
        check(!richRow.dragGrip.isHidden && richRow.dragGrip.image != nil,"full rows expose a drag grip")
        let filteredRow = LayoutRowView(recipe:rowRecipe,canReorder:false) { _ in nil }
        check(filteredRow.dragGrip.isHidden,"filtered/busy rows do not advertise unavailable dragging")
        let library = definitions.first{$0.group == .library}!
        let custom = ShortcutChord(key:79,modifiers:ShortcutChord.hyper,name:"F18")
        let shortcutStore = KeybindingStore(defaults:dockDefaults)
        try shortcutStore.save([library.id:custom])
        check(KeybindingStore(defaults:dockDefaults).chord(library) == custom,"custom binding survives reload")
        check(shortcutStore.chord(library).label == "⌃⌥⌘ F18","display uses current binding")
        func rejects(_ draft: [String:ShortcutChord]) -> Bool { do { try ShortcutValidation.validate(draft); return false } catch { return true } }
        check(rejects([library.id:definitions[0].standard]),"duplicate default binding rejected")
        check(rejects([library.id:ShortcutChord(key:15,modifiers:ShortcutChord.hyper|ShortcutChord.shift,name:"R")]),"Hammerspoon fallback reserved")
        check(rejects([library.id:ShortcutChord(key:124,modifiers:ShortcutChord.control,name:"→")]),"macOS desktop navigation reserved")
        check(rejects(["unknown":custom]),"unknown command rejected")
        for (key,name) in ShortcutChord.functionKeys {
            for modifiers in [UInt32(0),ShortcutChord.shift] {
                let function = ShortcutChord(key:key,modifiers:modifiers,name:name)
                try shortcutStore.save([library.id:function])
                check(KeybindingStore(defaults:dockDefaults).chord(library) == function,"function-key modifier variants survive reload")
            }
        }
        for key in [UInt32(0),18,36,48,49,51,53,76,115,123] {
            for modifiers in [UInt32(0),ShortcutChord.shift] {
                check(rejects([library.id:ShortcutChord(key:key,modifiers:modifiers,name:"F13")]),"ordinary key cannot bypass modifier protection with a function-key label")
            }
        }
        let bareF13 = ShortcutChord(key:105,modifiers:0,name:"F13")
        let shiftedF13 = ShortcutChord(key:105,modifiers:ShortcutChord.shift,name:"F13")
        check(bareF13.label == "F13" && shiftedF13.label == "⇧ F13","function-key captions have no stray leading space")
        try ShortcutValidation.validate([library.id:bareF13],additional:[("New window",shiftedF13)])
        do {
            try ShortcutValidation.validate([library.id:bareF13],additional:[("App launch",bareF13)])
            check(false,"function-key collision must fail")
        } catch { check(true,"function-key collisions share existing validation") }

        try shortcutStore.save([:])
        check(KeybindingStore(defaults:dockDefaults).chord(library) == library.standard,"reset restores defaults")
        dockDefaults.set(Data("invalid".utf8),forKey:"shortcutOverrides.v1")
        let damaged = KeybindingStore(defaults:dockDefaults)
        check(damaged.loadError != nil && damaged.chord(library) == library.standard,"invalid saved data safely uses defaults")
        func allViews(_ root: NSView) -> [NSView] { [root]+root.subviews.flatMap{allViews($0)} }
        let general = settingsTabs.tabViewItems[0].view!,about = settingsTabs.tabViewItems[3].view!
        check(allViews(general).compactMap{$0 as? NSButton}.contains{$0.title == "Accessibility Settings…"},"Accessibility lives in General")
        check(allViews(general).compactMap{$0 as? NSButton}.contains{$0.title == "Shortcut Reference"},"shortcut reference lives in General")
        let aboutPageForButtons=settingsTabs.tabViewItems.first{$0.label == "About"}!.view!
        check(!allViews(aboutPageForButtons).compactMap{$0 as? NSButton}.contains{$0.title == "Shortcut Reference"},"About is limited to app information")
        settings.addTiling(NSView())
        check(settingsTabs.tabViewItems.map(\.label)==["General","Shortcuts","Applications","Layouts","Tiling","About"],"About remains far right after Tiling is attached")

        check(!allViews(about).compactMap{$0 as? NSButton}.contains{$0.title == "Accessibility Settings…"},"About does not duplicate permission controls")
        let reference = ShortcutReferenceWindow(preferences:dockPreferences)
        reference.refresh(); reference.window.contentView!.layoutSubtreeIfNeeded()
        let referenceText = allViews(reference.window.contentView!).compactMap{$0 as? NSTextView}.first!
        let layout = referenceText.layoutManager!,container = referenceText.textContainer!
        layout.ensureLayout(for:container)
        func commandX(_ title: String) -> CGFloat {
            let character = (referenceText.string as NSString).range(of:title).location
            let glyph = layout.glyphIndexForCharacter(at:character)
            return layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil).minX+layout.location(forGlyphAt:glyph).x
        }
        check(abs(commandX("Next size")-commandX("Previous size"))<0.1,"Shift modifiers must not shift the action column")
        check(abs(commandX("Next size")-commandX("Focus left"))<0.1,"action column aligns across shortcut groups")
        func glyphX(_ character: Int) -> CGFloat {
            let glyph = layout.glyphIndexForCharacter(at:character)
            return layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil).minX+layout.location(forGlyphAt:glyph).x
        }
        func mainKeyX(_ action: String) -> CGFloat {
            let source = referenceText.string as NSString
            let line = source.lineRange(for:source.range(of:action))
            let row = source.substring(with:line)
            let parts = row.components(separatedBy:"\t")
            return glyphX(line.location+(parts[0]+"\t"+parts[1]+"\t").utf16.count)
        }
        check(abs(mainKeyX("Next size")-mainKeyX("Previous size"))<0.1,"Shift must not shift the main-key column")
        check(abs(mainKeyX("Next size")-mainKeyX("Focus left"))<0.1,"main keys align across groups")
        check(abs(mainKeyX("Next size")-mainKeyX("Select window"))<0.1,"unmodified navigation keys use the same key column")
        check(abs(commandX("Next size")-commandX("Select window"))<0.1,"long navigation names must not push the action to another tab stop")
        let nextSize = ShortcutDefinition.all.first{$0.title == "Next size"}!
        try dockPreferences.shortcuts.save([nextSize.id:ShortcutChord(key:121,modifiers:ShortcutChord.hyper,name:"Page Down")])
        reference.refresh(); layout.ensureLayout(for:container)
        check(abs(mainKeyX("Next size")-mainKeyX("Previous size"))<0.1,"custom key names retain their column")
        check(abs(commandX("Next size")-commandX("Previous size"))<0.1,"custom key names retain the action column")
        let recorder = ShortcutRecorder(nextSize,manager:nil)
        check(recorder.alignment == .right,"Settings shortcut buttons align to the right")
        let attributes = recorder.attributedTitle
        check((attributes.attribute(.paragraphStyle,at:0,effectiveRange:nil) as? NSParagraphStyle)?.alignment == .right,"attributed button text preserves right alignment")
        check((attributes.attribute(.kern,at:0,effectiveRange:nil) as? NSNumber)?.doubleValue == ShortcutChord.modifierTracking,"Settings modifier symbols receive subtle tracking")
        check(attributes.attribute(.kern,at:nextSize.standard.modifierLabel.utf16.count-1,effectiveRange:nil) == nil,"no tracking trails the last modifier")
        check(recorder.title == nextSize.standard.label,"visual formatting preserves shortcut text")
        let appSuite = "WindowFactory.AppLaunchTest.\(UUID().uuidString)"
        let appDefaults = UserDefaults(suiteName:appSuite)!
        defer { appDefaults.removePersistentDomain(forName:appSuite) }
        let appRoot = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("wf-app-fixture-\(UUID().uuidString)")
        let appURL = appRoot.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at:appURL.appendingPathComponent("Contents"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:appRoot) }
        let appInfo = ["CFBundleIdentifier":"local.fixture.launch","CFBundleName":"Fixture App","CFBundleVersion":"1","CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList:appInfo,format:.xml,options:0).write(to:appURL.appendingPathComponent("Contents/Info.plist"))
        let appKeys = KeybindingStore(defaults:appDefaults)
        let apps = ApplicationLauncher(defaults:appDefaults,shortcuts:appKeys,live:false)
        check(apps.entries.count == 1 && apps.entries[0].isSearch && !apps.entries[0].enabled,"new Applications search command starts unassigned and disabled")
        let fixtureID = try apps.add(appURL)
        check(try apps.add(appURL) == fixtureID && apps.entries.count == 2,"app picker identity deduplicates by bundle ID")
        let rexChord = ShortcutChord(key:17,modifiers:ShortcutChord.hyper,name:"T")
        try apps.setShortcut(rexChord,id:fixtureID)
        check(!apps.entries.first{$0.id==fixtureID}!.enabled,"recording does not silently claim a shortcut")
        try apps.setEnabled(true,id:fixtureID)
        let savedApps = appDefaults.data(forKey:"applicationLaunchers.v1")!
        check(ApplicationLauncher(defaults:appDefaults,shortcuts:appKeys,live:false).entries == apps.entries,"selected app and chord/enabled state persist together")
        do {try apps.setShortcut(ShortcutChord(key:1,modifiers:ShortcutChord.hyper,name:"S"),id:fixtureID);check(false,"stash clash must fail")} catch {check(true,"app shortcuts reject existing window-command clashes")}
        check(appDefaults.data(forKey:"applicationLaunchers.v1") == savedApps && apps.entries.first{$0.id==fixtureID}!.shortcut == rexChord,"rejected app binding preserves old configuration")
        let fixedManager = KeybindingManager(store:appKeys);fixedManager.additionalShortcuts = {apps.reservedShortcuts}
        do {try fixedManager.set(rexChord,for:nextSize);check(false,"fixed command must reject app clash")}catch{check(true,"window-command editor rejects app-binding collisions before OS changes")}
        try apps.configureSearchShortcut(ShortcutChord(key:0,modifiers:ShortcutChord.hyper,name:"A"),enabled:false)
        do {try apps.setShortcut(ShortcutChord(key:0,modifiers:ShortcutChord.hyper,name:"A"),id:fixtureID);check(false,"search shortcut clash must fail")}catch{check(true,"search and app chords share collision validation")}
        reference.applications = apps;reference.refresh()
        check(referenceText.string.contains("APPLICATIONS") && referenceText.string.contains("Open Fixture App"),"shortcut reference reads current application records")
        try apps.setEnabled(false,id:fixtureID);try apps.setShortcut(nil,id:fixtureID)
        check(apps.entries.first{$0.id==fixtureID}!.shortcut == nil,"clearing a shortcut retains the app entry")
        let alternateURL = appRoot.appendingPathComponent("Moved Fixture.app")
        try FileManager.default.copyItem(at:appURL,to:alternateURL)
        check(try apps.add(alternateURL) == fixtureID && apps.entries.first{$0.id==fixtureID}!.path == alternateURL.path,"reselecting a relocated app refreshes its path without losing identity")
        try apps.remove(fixtureID)
        check(apps.entries.count == 1 && apps.entries[0].isSearch,"removing an app does not remove Applications search")
        check(try settingsStore.catalog.encoded() == catalogBeforeOrdering,"application configuration never changes saved layout recipes")
        appDefaults.set(Data("invalid".utf8),forKey:"applicationLaunchers.v1")
        let invalidApps = ApplicationLauncher(defaults:appDefaults,shortcuts:appKeys,live:false)
        check(invalidApps.loadError != nil,"invalid app configuration is explicit")
        do {_ = try invalidApps.add(appURL);check(false,"invalid saved state must not be overwritten")}catch{check(appDefaults.data(forKey:"applicationLaunchers.v1") == Data("invalid".utf8),"corrupt app settings are preserved for recovery")}
        let sortEntries = [
            ApplicationEntry(id:UUID(),slot:1,bundleID:"local.fixture.zeta",name:"Zeta",path:appURL.path,enabled:false),
            ApplicationEntry(id:UUID(),slot:2,bundleID:"local.fixture.beta",name:"beta",path:appURL.path,shortcut:shiftedF13,enabled:false),
            ApplicationEntry(id:UUID(),slot:3,bundleID:"local.fixture.alpha",name:"Alpha",path:appURL.path,shortcut:bareF13,enabled:true)
        ]
        check(ApplicationListOrder.sorted(sortEntries).map(\.name) == ["Alpha","beta","Zeta"],"app names sort alphabetically")
        check(ApplicationListOrder.sorted(sortEntries,column:"app",ascending:false).map(\.name) == ["Zeta","beta","Alpha"],"name sort reverses")
        check(ApplicationListOrder.sorted(sortEntries,column:"enabled",ascending:false).map(\.name) == ["Alpha","beta","Zeta"],"enabled-first groups retain alphabetic ties")
        check(ApplicationListOrder.sorted(sortEntries,column:"enabled",ascending:true).map(\.name) == ["beta","Zeta","Alpha"],"disabled-first reverses the state groups")
        check(ApplicationListOrder.sorted(sortEntries,column:"key",ascending:false).map(\.name) == ["Alpha","beta","Zeta"],"assigned-first groups retain alphabetic ties")
        check(ApplicationListOrder.sorted(sortEntries,column:"key",ascending:true).map(\.name) == ["Zeta","Alpha","beta"],"unassigned-first sorting")
        let sortSuite = "WindowFactory.AppSortTest.\(UUID().uuidString)"
        // Use an isolated domain; never read or write the production app catalog.
        let isolatedSortDefaults = UserDefaults(suiteName:sortSuite)!
        defer { isolatedSortDefaults.removePersistentDomain(forName:sortSuite) }
        let sortData = try JSONEncoder().encode(ApplicationEnvelope(version:1,entries:sortEntries))
        isolatedSortDefaults.set(sortData,forKey:"applicationLaunchers.v1")
        let sortKeys = KeybindingStore(defaults:isolatedSortDefaults)
        let sortLauncher = ApplicationLauncher(defaults:isolatedSortDefaults,shortcuts:sortKeys,live:false)
        let editor = ApplicationsEditor();editor.connect(sortLauncher)
        check(editor.displayedEntries.filter{!$0.isSearch}.map(\.name) == ["Alpha","beta","Zeta"],"editor defaults to name order")
        let alphaID = sortEntries[2].id,betaID = sortEntries[1].id
        editor.table.selectRowIndexes(IndexSet(integer:editor.displayedEntries.firstIndex{$0.id==alphaID}!),byExtendingSelection:false)
        editor.table.sortDescriptors = [NSSortDescriptor(key:"enabled",ascending:true)];editor.refresh()
        check(editor.displayedEntries[editor.table.selectedRow].id == alphaID,"sorting preserves selected app identity")
        check(isolatedSortDefaults.data(forKey:"applicationLaunchers.v1") == sortData,"sorting never writes the binding catalog")
        let betaRow = editor.displayedEntries.firstIndex{$0.id==betaID}!
        let enabledColumn = editor.table.tableColumns.first{$0.identifier.rawValue == "enabled"}!
        let enabledSwitch = editor.tableView(editor.table,viewFor:enabledColumn,row:betaRow) as! NSSwitch
        enabledSwitch.state = .on
        _ = NSApp.sendAction(enabledSwitch.action!,to:enabledSwitch.target,from:enabledSwitch)
        check(sortLauncher.entries.first{$0.id==betaID}!.enabled && sortLauncher.entries.first{$0.id==alphaID}!.enabled,"sorted-row toggle edits the intended UUID")
        reference.applications=sortLauncher;reference.refresh()
        let alphaRange=(referenceText.string as NSString).range(of:"Open Alpha"),betaRange=(referenceText.string as NSString).range(of:"Open beta")
        check(alphaRange.location != NSNotFound && alphaRange.location<betaRange.location,"shortcut reference alphabetizes app commands")
        editor.table.selectRowIndexes(IndexSet(integer:editor.displayedEntries.firstIndex{$0.id==alphaID}!),byExtendingSelection:false)
        _ = NSApp.sendAction(NSSelectorFromString("clearShortcut"),to:editor,from:nil)
        check(sortLauncher.entries.first{$0.id==alphaID}!.shortcut == nil && sortLauncher.entries.first{$0.id==betaID}!.shortcut == shiftedF13,"clear shortcut follows selected UUID after sort/reload")
        // Regression: running apps must receive the same Launch Services open
        // request as cold apps, including app-owned reopen handling.
        let currentProcess = NSRunningApplication.current
        for processCount in [0,1] {
            var requests = 0
            let opening = ApplicationOpening(running:{ _ in Array(repeating:currentProcess,count:processCount) },request:{ url,configuration in
                requests += 1
                check(url == appURL,"opening preserves the selected application URL")
                check(configuration.activates && !configuration.createsNewApplicationInstance && !configuration.hides,"open requests activation without extra process or hiding")
                await Task.yield()
                return currentProcess
            })
            let opened = try await opening.open(ApplicationEntry(id:UUID(),slot:1,bundleID:"local.fixture.launch",name:"Fixture App",path:appURL.path,enabled:false),url:appURL)
            check(requests == 1 && opened.processIdentifier == currentProcess.processIdentifier,"cold/running apps both dispatch exactly one workspace request")
        }
        var ambiguousRequests = 0
        let ambiguousOpening = ApplicationOpening(running:{ _ in [currentProcess,currentProcess] },request:{ _,_ in ambiguousRequests += 1;return currentProcess })
        let openingEntry = ApplicationEntry(id:UUID(),slot:1,bundleID:"local.fixture.launch",name:"Fixture App",path:appURL.path,enabled:false)
        do { _ = try await ambiguousOpening.open(openingEntry,url:appURL);check(false,"ambiguous app copies must be rejected") }
        catch { check(ambiguousRequests == 0,"ambiguous copies never dispatch an open") }
        var failedRequests = 0
        let failedOpening = ApplicationOpening(running:{ _ in [currentProcess] },request:{ _,_ in failedRequests += 1;throw FactoryError("Fixture open failed") })
        do { _ = try await failedOpening.open(openingEntry,url:appURL);check(false,"workspace failure must propagate") }
        catch { check(failedRequests == 1 && error.localizedDescription == "Fixture open failed","workspace errors propagate without duplicate retries") }
        reference.stop()
        settings.stop()
        print("native switcher panel: \(assertions) assertions passed; no windows shown or controlled")
    }
}
