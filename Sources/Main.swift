import AppKit

@MainActor
final class FactoryApp: NSObject, NSApplicationDelegate {
    var systemCommands: SystemCommands?
    var tilingShortcut: OptionalCommandShortcut?
    var newWindowShortcut: OptionalCommandShortcut?
    var newWindow: NewWindowAction?
    private let newWindowHUD = GeometryHUD()
    var tiling: TilingFeature?
    var applications: ApplicationLauncher?
    var applicationSearch: ApplicationsWindow?
    var library: LibraryWindow?
    var settings: SettingsWindow?
    var shortcutReference: ShortcutReferenceWindow?
    var agent: AgentService?
    var agentTools: AgentTools?
    var agentWindows: AgentDirectWindows?
    var keybindings: KeybindingManager?
    var launcher: LauncherControls?
    private var backgroundLaunch = false
    func applicationWillFinishLaunching(_ notification: Notification) { backgroundLaunch = LauncherControls.isBackgroundLaunch(NSAppleEventManager.shared().currentAppleEvent) }
    var spaceIndicator: SpaceIndicator?
    var spaceMove: DirectSpaceMoveControls?
    var accordion: DirectAccordionControls?
    var switcher: DirectSwitcherControls?
    var stash: DirectStashControls?
    var focus: DirectFocusControls?
    var geometry: DirectWindowControls?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let args = CommandLine.arguments
            let preview = args.contains("--preview")
            let dataIndex = args.firstIndex(of:"--data-dir")
            // Product data location; refuse a silent empty store when an old installation needs migration.
            let directory = dataIndex.flatMap { args.indices.contains($0+1) ? args[$0+1] : nil }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/window-factory").path
            if dataIndex == nil && !preview {
                let old = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/window-factory-native")
                guard !FileManager.default.fileExists(atPath:old.path) else {
                    throw FactoryError("Legacy Window Factory data exists. Quit and run the data-folder migration before continuing; no catalog was opened.")
                }
            }
            let store = try LayoutStore(url:URL(fileURLWithPath:directory).appendingPathComponent("layouts.json"))
            guard let registryURL = Bundle.main.url(forResource:"adapters",withExtension:"json") else { throw FactoryError("Bundled adapter registry missing.") }
            let registry = try JSONDecoder().decode(AdapterRegistry.self,from:Data(contentsOf:registryURL)); try registry.validate()
            if preview {
                let slots = registry.adapters.prefix(3).enumerated().map { index,adapter in
                    Slot(bundleID:adapter.bundleID,appName:adapter.name,ordinal:1,
                         frame:Frame(x:Double(index)/3,y:0,w:1.0/3,h:1))
                }
                let recipe = Recipe(name:"Native preview",capturedAt:"preview",windows:slots)
                store.catalog.recipes[recipe.name] = recipe
                store.catalog.recipes["Two-window preview"] = Recipe(name:"Two-window preview",capturedAt:"preview",windows:Array(slots.prefix(2)))
                store.catalog.recipes["Single-window preview"] = Recipe(name:"Single-window preview",capturedAt:"preview",windows:Array(slots.prefix(1)))
            }
            let preferences = FactoryPreferences()
            let bindings = preview ? nil : KeybindingManager(store:preferences.shortcuts)
            keybindings = bindings
            let appLauncher = ApplicationLauncher(shortcuts:preferences.shortcuts,live:!preview);applications=appLauncher
            let creationKey = preview ? nil : OptionalCommandShortcut(store:preferences.shortcuts,others:{[weak self,weak appLauncher] in (appLauncher?.reservedShortcuts ?? [])+(self?.tilingShortcut?.reserved ?? [])+(self?.systemCommands?.reserved ?? [])});newWindowShortcut=creationKey
            let tilingKey = preview ? nil : OptionalCommandShortcut(command:.tilingControls,store:preferences.shortcuts,others:{[weak self,weak creationKey,weak appLauncher] in (appLauncher?.reservedShortcuts ?? [])+(creationKey?.reserved ?? [])+(self?.systemCommands?.reserved ?? [])});tilingShortcut=tilingKey
            let system = preview ? nil : SystemCommands(preferences:preferences,store:preferences.shortcuts,others:{[weak self,weak appLauncher] in (appLauncher?.reservedShortcuts ?? [])+(self?.newWindowShortcut?.reserved ?? [])+(self?.tilingShortcut?.reserved ?? [])})
            systemCommands=system
            let optionalKeys=[creationKey,tilingKey].compactMap{$0}+(system?.shortcuts ?? [])
            creationKey?.action = { [weak self] in self?.newCodexWindow(nil) }
            tilingKey?.action = { [weak self] in self?.showTiling(nil) }
            appLauncher.additionalShortcuts = { [weak self] in (self?.newWindowShortcut?.reserved ?? [])+(self?.tilingShortcut?.reserved ?? [])+(self?.systemCommands?.reserved ?? []) }
            bindings?.additionalShortcuts = { [weak self,weak appLauncher] in (appLauncher?.reservedShortcuts ?? [])+(self?.newWindowShortcut?.reserved ?? [])+(self?.tilingShortcut?.reserved ?? [])+(self?.systemCommands?.reserved ?? []) }
            try bindings?.restore()
            shortcutReference = ShortcutReferenceWindow(preferences:preferences)
            settings = SettingsWindow(store:store,preferences:preferences,keybindings:bindings)
            settings?.systemCommands=system;shortcutReference?.systemCommands=system
            settings?.shortcutEditor.optionalCommands=optionalKeys;shortcutReference?.optionalCommands=optionalKeys
            library = LibraryWindow(store:store,registry:registry,preview:preview,preferences:preferences)
            settings?.onImport = { [weak self] in self?.library?.show(); self?.library?.importLayouts() }
            settings?.onExport = { [weak self] in self?.library?.show(); self?.library?.exportLayouts() }
            settings?.onReport = { [weak self] in self?.library?.showReport() }
            settings?.layoutActionsAvailable = { [weak self] in self?.library?.task == nil && self?.library?.frozen == nil }
            bindings?.changed = { [weak self] in self?.shortcutReference?.refresh(); self?.settings?.refresh(); self?.library?.applyPreferences(); self?.spaceIndicator?.refreshMenuShortcuts() }
            bindings?.recoverRegistrations = { [weak self] in self?.restoreShortcutOwners() }
            library?.onShortcuts = { [weak self] in self?.showShortcuts(nil) }
            settings?.onShortcuts = { [weak self] in self?.showShortcuts(nil) }
            library?.onSettings = { [weak self] in self?.showSettings(nil) }
            settings?.changed = { [weak self] in self?.library?.applyPreferences() }
            if !preview {
                let search = ApplicationsWindow(launcher:appLauncher);applicationSearch=search
                appLauncher.searchRequested = { [weak self] in self?.toggleApplications() }
                appLauncher.launchFailed = { [weak search] in search?.showError($0) }
                appLauncher.blocked = { [weak self] in self?.library?.task != nil || self?.library?.frozen != nil || NSApp.modalWindow != nil }
                appLauncher.changed = { [weak self] in self?.settings?.refresh();self?.shortcutReference?.refresh() }
                for key in optionalKeys where key.definition.group == .library {key.changed = { [weak self] in self?.refreshOptionalCommandMenus() }}
                settings?.applicationsEditor.connect(appLauncher);shortcutReference?.applications=appLauncher
                library?.onApplications = { [weak self] in self?.showApplications(nil) };library?.applyPreferences()
                appLauncher.restore()
                let launchControls = LauncherControls(preferences:preferences); launcher = launchControls
                launchControls.toggleLibrary = { [weak self] in self?.toggleLibrary() }
                launchControls.toggleShortcuts = { [weak self] in self?.toggleShortcuts() }
                launchControls.changed = { [weak self,weak launchControls] in
                    for key in optionalKeys where key.definition.group == .library {do {try key.setOwnerEnabled(launchControls?.active == true)}catch{self?.library?.status.stringValue=error.localizedDescription}}
                    self?.settings?.refresh(); self?.shortcutReference?.refresh()
                }
                settings?.launcher = launchControls; shortcutReference?.launcher = launchControls
                launchControls.restorePreference()
                system?.blocked = appLauncher.blocked
                system?.failed = { message in let alert=NSAlert();alert.messageText="System command could not run";alert.informativeText=message;alert.runModal() }
                system?.changed = { [weak self] in self?.refreshOptionalCommandMenus();self?.settings?.refresh() }
                do { try system?.restorePreference() } catch { library?.status.stringValue=error.localizedDescription }
                let indicator = SpaceIndicator(preferences:preferences); spaceIndicator = indicator
                indicator.openLibrary = { [weak self] in self?.library?.show() }
                indicator.openSettings = { [weak self] in self?.showSettings(nil) }
                indicator.openShortcuts = { [weak self] in self?.showShortcuts(nil) }
                indicator.changed = { [weak self] in self?.settings?.refresh(); self?.shortcutReference?.refresh() }
                indicator.systemMenu = { [weak system] in system?.makeMenu() ?? NSMenu() }
                settings?.spaceIndicator = indicator; shortcutReference?.spaceIndicator = indicator; indicator.restorePreference()
                let controls = DirectWindowControls(preferences:preferences); geometry = controls
                controls.workspaceBusy = { [weak self] in self?.library?.task != nil || self?.library?.frozen != nil || self?.spaceMove?.isMoving == true }
                controls.changed = { [weak self] in self?.settings?.refresh(); self?.shortcutReference?.refresh() }
                settings?.geometry = controls
                controls.restorePreference()
                let focusControls = DirectFocusControls(preferences:preferences); focus = focusControls
                focusControls.workspaceBusy = controls.workspaceBusy
                focusControls.changed = { [weak self] in self?.settings?.refresh(); self?.shortcutReference?.refresh(); self?.spaceIndicator?.scheduleRefresh() }
                settings?.focus = focusControls; focusControls.restorePreference()
                let stashControls = DirectStashControls(preferences:preferences); stash = stashControls
                stashControls.workspaceBusy = controls.workspaceBusy
                stashControls.changed = { [weak self] in self?.settings?.refresh(); self?.shortcutReference?.refresh() }
                settings?.stash = stashControls; stashControls.restorePreference()
                let switcherControls = DirectSwitcherControls(preferences:preferences); switcher = switcherControls
                switcherControls.workspaceBusy = controls.workspaceBusy
                switcherControls.changed = { [weak self] in self?.settings?.refresh(); self?.shortcutReference?.refresh(); self?.spaceIndicator?.scheduleRefresh() }
                settings?.switcher = switcherControls; switcherControls.restorePreference()
                let pickerOrWorkspaceBusy: () -> Bool = { [weak self] in
                    self?.library?.task != nil || self?.library?.frozen != nil || self?.switcher?.isOpen == true || self?.spaceMove?.isMoving == true
                }
                controls.workspaceBusy = pickerOrWorkspaceBusy
                focusControls.workspaceBusy = pickerOrWorkspaceBusy
                stashControls.workspaceBusy = pickerOrWorkspaceBusy
                let accordionControls = DirectAccordionControls(preferences:preferences); accordion = accordionControls
                accordionControls.workspaceBusy = pickerOrWorkspaceBusy
                accordionControls.changed = { [weak self] in self?.settings?.refresh(); self?.shortcutReference?.refresh() }
                settings?.accordion = accordionControls; shortcutReference?.accordion = accordionControls
                accordionControls.restorePreference()
                let spaceControls = DirectSpaceMoveControls(preferences:preferences); spaceMove = spaceControls
                spaceControls.workspaceBusy = { [weak self] in self?.library?.task != nil || self?.library?.frozen != nil || self?.switcher?.isOpen == true }
                spaceControls.changed = { [weak self] in self?.settings?.refresh(); self?.shortcutReference?.refresh(); self?.spaceIndicator?.scheduleRefresh() }
                settings?.spaceMove = spaceControls; shortcutReference?.spaceMove = spaceControls
                spaceControls.restorePreference()
                shortcutReference?.switcher = switcherControls
                shortcutReference?.geometry = controls; shortcutReference?.focus = focusControls; shortcutReference?.stash = stashControls
            }
            if !preview,let library {
                let feature=TilingFeature(library:library,geometry:geometry,stash:stash,accordion:accordion,spaceMove:spaceMove,switcher:switcher);tiling=feature
                settings?.addTiling(feature.settings.view)
                spaceIndicator?.openTiling = {[weak feature] in feature?.toggle()}
                spaceIndicator?.tilingChord = { [weak tilingKey] in tilingKey?.chord }
                let creator=NewWindowAction(adapters:library.coordinator.adapters,backend:.live(library.coordinator.services));newWindow=creator
                creator.blocked = { [weak self] in self?.library?.task != nil || self?.library?.frozen != nil || self?.tiling?.controller.isBusy == true || self?.geometry?.isBusy == true || self?.stash?.isBusy == true || self?.accordion?.isBusy == true || self?.spaceMove?.isMoving == true || self?.switcher?.isOpen == true || ShortcutRecorder.current?.isRecording == true }
                creator.changed = { [weak self,weak creator] in guard let creator,!creator.isBusy else{return};self?.newWindowHUD.show(creator.lastResult) }
                spaceIndicator?.newCodexWindow = { [weak self] in self?.newCodexWindow(nil) }
                spaceIndicator?.newCodexChord = { [weak creationKey] in creationKey?.chord }
                spaceIndicator?.newCodexAvailable = { [weak creator] in creator?.available("com.openai.codex") == true }
                let service=AgentService(preferences:preferences,library:library);agent=service;settings?.agent=service
                service.extraBusy = { [weak self] in self?.geometry?.isBusy == true || self?.focus?.isBusy == true || self?.stash?.isBusy == true || self?.accordion?.isBusy == true || self?.spaceMove?.isMoving == true || self?.switcher?.isOpen == true || self?.tiling?.controller.isBusy == true || self?.newWindow?.isBusy == true || self?.applications?.isLaunching == true || self?.systemCommands?.isBusy == true }
                let tools=AgentTools(library:library,apps:appLauncher,creation:creator,tiling:feature.controller);agentTools=tools
                let direct=AgentDirectWindows(geometry:geometry!,stash:stash!,move:spaceMove!,accordion:accordion!);agentWindows=direct
                tools.windowOperation={ [weak direct] request,context,window in guard let direct else{throw AgentFailure("unavailable","Window owners unavailable.")};return try await direct.perform(request,context:context,window:window)}
                service.spaceMoveDiagnostic = {[weak self] in self?.spaceMove?.lastDiagnostic}
                service.stashedWindowIDs = {[weak stash] in stash?.agentStashes() ?? []}
                service.connectTools(query:{[weak tools] in guard let tools else{throw AgentFailure("unavailable","Tools unavailable.")};return try await tools.query($0)},mutate:{[weak tools] in guard let tools else{throw AgentFailure("unavailable","Tools unavailable.")};return try await tools.mutate($0)})
                service.changed = { [weak self] in self?.settings?.refresh();self?.tiling?.controller.schedule() }
                do {try service.restorePreference()} catch {preferences.agentAccessEnabled=false;library.status.stringValue="Agent access: \(error.localizedDescription)"}
                settings?.refresh()
            }
            let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
            let settingsItem = appMenu.addItem(withTitle:"Settings…",action:#selector(showSettings(_:)),keyEquivalent:",")
            settingsItem.target = self; appMenu.addItem(.separator())
            appMenu.addItem(withTitle:"Quit Window Factory",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
            item.submenu = appMenu; menu.addItem(item)
            let editItem = NSMenuItem(), edit = NSMenu(title:"Edit")
            edit.addItem(withTitle:"Undo",action:Selector(("undo:")),keyEquivalent:"z")
            let redo = edit.addItem(withTitle:"Redo",action:Selector(("redo:")),keyEquivalent:"z")
            redo.keyEquivalentModifierMask = [.command,.shift]
            edit.addItem(.separator())
            edit.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
            edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
            edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
            edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
            editItem.submenu = edit; menu.addItem(editItem)
            let layoutItem = NSMenuItem(), layoutMenu = NSMenu(title:"Layout")
            let commands: [(String,Selector,String,NSEvent.ModifierFlags)] = [
                ("Capture…",#selector(LibraryWindow.startCapture),"n",.command),
                ("Restore",#selector(LibraryWindow.restoreLayout),"\r",[]),
                ("Establish here",#selector(LibraryWindow.establishLayout),"\r",.command),
                ("Search",#selector(LibraryWindow.focusSearch),"f",.command),
                ("Move Layout Up",#selector(LibraryWindow.moveLayoutUp),"\u{f700}",.option),
                ("Move Layout Down",#selector(LibraryWindow.moveLayoutDown),"\u{f701}",.option),
                ("Import…",#selector(LibraryWindow.importLayouts),"i",.command),
                ("Export…",#selector(LibraryWindow.exportLayouts),"e",[.command,.shift]),
                ("Delete…",#selector(LibraryWindow.deleteLayout),"\u{8}",.command),
                ("Last report",#selector(LibraryWindow.showReport),"",[])]
            for (title,action,key,modifiers) in commands {
                let command = layoutMenu.addItem(withTitle:title,action:action,keyEquivalent:key)
                command.keyEquivalentModifierMask = modifiers; command.target = library
            }
            layoutItem.submenu = layoutMenu; menu.addItem(layoutItem)
            let windowItem = NSMenuItem(), windowMenu = NSMenu(title:"Window")
            windowMenu.addItem(withTitle:"Close Window",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
            let switcherItem = windowMenu.addItem(withTitle:"Switch Windows",action:#selector(showSwitcher(_:)),keyEquivalent:"")
            switcherItem.target = self
            let shortcutItem = windowMenu.addItem(withTitle:"Keyboard Shortcuts",action:#selector(showShortcuts(_:)),keyEquivalent:"")
            shortcutItem.target = self
            let appsItem = windowMenu.addItem(withTitle:"Applications",action:#selector(showApplications(_:)),keyEquivalent:"a")
            appsItem.keyEquivalentModifierMask = [.command,.shift]; appsItem.target = self
            let tilingItem=windowMenu.addItem(withTitle:"Tiling…",action:#selector(showTiling(_:)),keyEquivalent:"");tilingItem.target=self;tilingItem.identifier=NSUserInterfaceItemIdentifier("tiling.controls");MenuShortcut.apply(tilingKey?.chord,to:tilingItem)
            let newCodex=windowMenu.addItem(withTitle:"New Codex Window",action:#selector(newCodexWindow(_:)),keyEquivalent:"");newCodex.target=self;newCodex.identifier=NSUserInterfaceItemIdentifier("codex.new-window");MenuShortcut.apply(creationKey?.chord,to:newCodex)
            windowItem.submenu = windowMenu; menu.addItem(windowItem)
            if let system { let systemItem=NSMenuItem();systemItem.identifier=NSUserInterfaceItemIdentifier("system");systemItem.submenu=system.makeMenu();menu.addItem(systemItem) }
            NSApp.mainMenu = menu
            backgroundLaunch = backgroundLaunch || LauncherControls.isBackgroundLaunch(NSAppleEventManager.shared().currentAppleEvent)
            if FactoryLaunchPolicy.showsLibrary(arguments:args,loginLaunch:backgroundLaunch) { library?.show() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Window Factory could not start"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil)
        }
    }
    private func restoreShortcutOwners() {
        if geometry?.active == true { try? geometry?.enable() }
        if focus?.active == true { try? focus?.enable() }
        if stash?.active == true { try? stash?.enable() }
        if switcher?.active == true { try? switcher?.enable() }
        if accordion?.active == true { try? accordion?.enable() }
        if spaceMove?.active == true { try? spaceMove?.enable() }
        if launcher?.active == true { try? launcher?.enable() }
        settings?.refresh(); shortcutReference?.refresh()
    }
    func toggleLibrary() {
        guard let library else { return }
        switch FactoryLaunchPolicy.libraryAction(visible:library.window.isVisible,key:library.window.isKeyWindow,active:NSApp.isActive,onActiveSpace:library.window.isOnActiveSpace,modal:NSApp.modalWindow != nil || library.window.attachedSheet != nil) {
        case .show: library.show()
        case .close: library.window.close()
        case .ignore: break
        }
    }
    func toggleShortcuts() {
        guard let reference = shortcutReference else { return }
        let window = reference.window
        switch FactoryLaunchPolicy.libraryAction(visible:window.isVisible,key:window.isKeyWindow,active:NSApp.isActive,onActiveSpace:window.isOnActiveSpace,modal:NSApp.modalWindow != nil || window.attachedSheet != nil) {
        case .show: reference.show()
        case .close: window.close()
        case .ignore: break
        }
    }
    func toggleApplications() {
        guard let search=applicationSearch else{return};let window=search.window
        switch FactoryLaunchPolicy.libraryAction(visible:window.isVisible,key:window.isKeyWindow,active:NSApp.isActive,onActiveSpace:window.isOnActiveSpace,modal:NSApp.modalWindow != nil || window.attachedSheet != nil) {
        case .show:search.show()
        case .close:window.close()
        case .ignore:break
        }
    }
    private func refreshOptionalCommandMenus() {
        shortcutReference?.refresh();spaceIndicator?.refreshMenuShortcuts()
        if let systemCommands,let item=NSApp.mainMenu?.items.first(where:{$0.identifier?.rawValue == "system"}) {item.submenu=systemCommands.makeMenu()}
        guard let menu=NSApp.mainMenu?.items.first(where:{$0.submenu?.title == "Window"})?.submenu else{return}
        for key in [newWindowShortcut,tilingShortcut].compactMap({$0}) {
            if let item=menu.items.first(where:{$0.identifier?.rawValue == key.definition.id}) {MenuShortcut.apply(key.chord,to:item)}
        }
    }
    func applicationDockMenu(_ sender: NSApplication)->NSMenu? {
        WindowCreationMenus.dock(target:self,open:#selector(openFromDock(_:)),create:#selector(newCodexWindow(_:)),available:newWindow?.available("com.openai.codex") == true,chord:newWindowShortcut?.chord)
    }
    @objc func openFromDock(_ sender: Any?) { library?.show() }
    @objc func newCodexWindow(_ sender: Any?) { newWindow?.run("com.openai.codex") }
    @objc func showTiling(_ sender: Any?) { tiling?.toggle() }
    @objc func showApplications(_ sender: Any?) { applicationSearch?.show() }
    @objc func showSwitcher(_ sender: Any?) { switcher?.toggle() }
    @objc func showShortcuts(_ sender: Any?) { shortcutReference?.show() }
    @objc func showSettings(_ sender: Any?) { settings?.show() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool {
        // Reboot/session restoration is not a deliberate request to open the UI.
        guard !LauncherControls.isBackgroundLaunch(NSAppleEventManager.shared().currentAppleEvent) else {return false}
        library?.show();return true
    }
    func applicationDidBecomeActive(_ notification: Notification) { library?.updateButtons(); launcher?.refreshLoginState(); settings?.refresh() }
    func applicationWillTerminate(_ notification: Notification) { systemCommands?.stop(); tilingShortcut?.stop();newWindowShortcut?.stop();newWindow?.stop();newWindowHUD.stop();tiling?.stop();applications?.stop();applicationSearch?.stop();agent?.stop(); launcher?.stop(); spaceIndicator?.stop(); spaceMove?.stop(); accordion?.stop(); switcher?.stop(); stash?.stop(); shortcutReference?.stop(); focus?.stop(); geometry?.stop(); library?.stop(); settings?.stop() }
}

@main
enum FactoryMain {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--cli" { AgentCLI.run(Array(CommandLine.arguments.dropFirst(2))) }
        if let index = CommandLine.arguments.firstIndex(of:"--validate-catalog") {
            do {
                guard CommandLine.arguments.indices.contains(index+1) else { throw FactoryError("Catalog path required.") }
                let catalog = try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[index+1])))
                print("Validated \(catalog.recipes.count) layouts."); return
            } catch { fputs("Catalog validation failed.\n",stderr); exit(1) }
        }
        let app = NSApplication.shared
        let showDockIcon = UserDefaults.standard.object(forKey:"showDockIcon") as? Bool ?? true
        app.setActivationPolicy(showDockIcon ? .regular : .accessory)
        let delegate = FactoryApp(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
