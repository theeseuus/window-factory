import AppKit
import CryptoKit

@MainActor
enum ImprovementHandoffTests {
    static func run(service: AgentService, root: URL) async throws {
        var assertions = 0
        func check(_ value: Bool, _ label: String) {assertions += 1; precondition(value,label)}
        func rejects(_ code: String, _ operation: () throws -> Void) {
            do {try operation(); check(false,"expected \(code)")} catch {check(((error as? AgentFailure)?.code ?? (error as? ImprovementFailure)?.code) == code,"expected \(code), got \(error)")}
        }
        let fixture = root.appendingPathComponent("manual-handoff"), repo = fixture.appendingPathComponent("repo with spaces & + symbols")
        try FileManager.default.createDirectory(at:repo.appendingPathComponent("Sources"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:repo.appendingPathComponent("docs"),withIntermediateDirectories:true)
        for path in [".git","AGENTS.md","Sources/Main.swift","docs/improvements.md"] {try Data().write(to:repo.appendingPathComponent(path))}
        let store = ImprovementStore(url:fixture.appendingPathComponent("requests.json"),version:"test",build:"69")
        let dispatcher = ImprovementDispatcher(store:store,watch:false,callbackCommand:"'/fixture/Installed App' --cli")
        defer {dispatcher.stop()}
        var opened: [URL] = [], copied: [String] = []
        dispatcher.openURL = {opened.append($0); return true}
        dispatcher.copyPrompt = {copied.append($0); return true}
        let first = try store.submit(text:"Keep A & B + C?\n$(do not execute) 😀",context:"Layout library",source:"ui")
        rejects("repository_required") {_ = try dispatcher.openRequest(first.id)}
        check(opened.isEmpty && copied.isEmpty,"no preparation without the app's source project")
        _ = try dispatcher.configure(repository:repo.path)
        _ = try dispatcher.openRequest(first.id)
        let prepared = try store.get(first.id), handoff = prepared.handoffs!.last!
        check(prepared.state == .queued && prepared.revision == 0 && prepared.runs == nil,"manual preparation starts no model or run")
        check(handoff.phase == "prepared" && handoff.repository == repo.resolvingSymlinksInPath().path && handoff.originRepository == handoff.repository,"app project is the default destination")
        check(prepared.status(runningBuild:69) == "Prepared for Codex — paste and send","preparation is not described as an already-sent task")
        let parts = URLComponents(url:opened[0],resolvingAgainstBaseURL:false)!
        check(parts.scheme == "codex" && parts.host == "threads" && parts.path == "/new","navigation opens a Codex composer")
        check(parts.queryItems?.count == 1 && parts.queryItems?.first?.name == "mode" && parts.queryItems?.first?.value == "codex","manual navigation carries no project, repository or request text")
        let prompt = copied.last!
        check(prompt.contains(handoff.id.uuidString) && prompt.contains(first.id.uuidString) && prompt.contains("CODEX_THREAD_ID"),"clipboard prompt carries actual callback IDs")
        check(prompt.contains("'/fixture/Installed App' --cli improvement-link"),"callback is usable from another repository")
        let bodyStart = prompt.range(of:"\n{\n")!.lowerBound
        let body = try JSONSerialization.jsonObject(with:Data(prompt[bodyStart...].utf8)) as! [String:String]
        check(body["text"] == first.text && body["repository"] == repo.resolvingSymlinksInPath().path,"request data survives clipboard JSON without shell execution")
        let route = dispatcher.lastPreparedRoute!
        let digest = SHA256.hash(data:Data(opened[0].absoluteString.utf8)).map {String(format:"%02x",$0)}.joined()
        check(route.appBuild == "69" && route.mode == "codex" && route.projectID == nil && route.repository == nil && route.urlSHA256 == digest,"route diagnostics honestly describe mode-only navigation")
        let retryPosition = prompt.range(of:"request normal tool approval/escalation")!.lowerBound
        let stopPosition = prompt.range(of:"If review is rejected")!.lowerBound
        let workPosition = prompt.range(of:"Investigate the intended outcome")!.lowerBound
        check(retryPosition < stopPosition && stopPosition < workPosition && prompt.contains("retry the same callback once"),"normal approval retry precedes product work and rejection stops")
        check(prompt.contains("without changing permission grants") && prompt.contains("Continue product work only after improvement-link returns a successful response") && prompt.contains("evade a rejection"),"successful link and grant boundaries remain intact")
        check(prompt.contains("applies to request reads and outcome callbacks") && prompt.contains("number of entries in improvement.updates") && prompt.contains("Do not claim the app received an unconfirmed note"),"outcome retries retain truthful revision/delivery guidance")
        let beforeCopyOnly = opened.count
        _ = try dispatcher.prepareRequest(first.id)
        check(try opened.count == beforeCopyOnly && store.get(first.id).handoffs?.count == 1 && copied.last == prompt,"copy-only retry preserves the token and opens no composer")
        let chat = UUID()
        _ = try store.linkChat(first.id,handoffID:handoff.id,threadID:chat)
        _ = try store.linkChat(first.id,handoffID:handoff.id,threadID:chat)
        check(try store.get(first.id).revision == 1 && store.get(first.id).state == .working,"pasted chat callback links once and starts reported work")
        rejects("request_conflict") {_ = try store.linkChat(first.id,handoffID:handoff.id,threadID:UUID())}
        rejects("chat_already_linked") {_ = try dispatcher.prepareRequest(first.id)}
        let beforeLinkedCopy = copied.count
        _ = try dispatcher.openRequest(first.id)
        check(opened.last == ImprovementHandoffLink.chatURL(chat) && copied.count == beforeLinkedCopy && dispatcher.lastPreparedRoute == nil,"linked requests reopen their chat without copying another task")
        let reopened = ImprovementStore(url:store.url,version:"test",build:"70")
        check(try reopened.get(first.id).handoffs?.last?.threadID == chat,"chat association persists")
        let external = fixture.appendingPathComponent("separate project")
        try FileManager.default.createDirectory(at:external,withIntermediateDirectories:true)
        _ = try dispatcher.configureDestination(external.path)
        check(try dispatcher.configuration().repository == repo.resolvingSymlinksInPath().path,"destination selection preserves origin app ownership")
        let second = try store.submit(text:"A separate program",context:"",source:"ui")
        _ = try dispatcher.prepareRequest(second.id)
        let secondHandoff = try store.get(second.id).handoffs!.last!
        check(secondHandoff.repository == external.resolvingSymlinksInPath().path && secondHandoff.originRepository == repo.resolvingSymlinksInPath().path,"separate destination is recorded with its origin")
        _ = try dispatcher.configureDestination(nil)
        rejects("handoff_conflict") {_ = try dispatcher.prepareRequest(second.id)}
        check(try store.get(second.id).handoffs!.last!.repository == secondHandoff.repository,"a prepared request cannot be silently retargeted")
        let copyFailure = try store.submit(text:"Retry copy",context:"",source:"ui")
        dispatcher.copyPrompt = {_ in false}
        let beforeFailure = opened.count
        rejects("clipboard_unavailable") {_ = try dispatcher.openRequest(copyFailure.id)}
        check(try opened.count == beforeFailure && store.get(copyFailure.id).state == .queued,"clipboard failure opens no UI and claims no work")
        dispatcher.copyPrompt = {copied.append($0); return true}
        dispatcher.openURL = {_ in false}
        let launchFailure = try store.submit(text:"Open manually if needed",context:"",source:"ui")
        rejects("codex_open_failed") {_ = try dispatcher.openRequest(launchFailure.id)}
        let launchRecord = try store.get(launchFailure.id)
        check(launchRecord.state == .queued && launchRecord.handoffs!.last!.phase == "prepared","navigation failure keeps copied request/token usable")
        _ = try store.linkChat(launchFailure.id,handoffID:launchRecord.handoffs!.last!.id,threadID:UUID())
        check(try store.get(launchFailure.id).state == .working,"owner can paste and link after opening Codex manually")
        dispatcher.openURL = {opened.append($0); return true}
        service.improvementOperation = {try await dispatcher.handle($0)}
        func call(_ args: [String]) async throws -> AgentResponse {
            let invocation = try AgentCLI.parse(args)
            return await service.handle(try JSONEncoder().encode(invocation.request))
        }
        let caps = await service.handle(try JSONEncoder().encode(AgentRequest(command:.capabilities))).result!.commands!
        check(caps.contains("improvement-prepare") && caps.contains("improvement-create-project") && !caps.contains("improvement-dispatch"),"manual setup/preparation have CLI parity without background dispatch")
        let destReply = try await call(["improvement-agent","--destination",external.path])
        check(destReply.result?.tools?.improvementAgent?.destinationRepository == external.resolvingSymlinksInPath().path,"CLI selects an existing destination")
        let countBeforeAPI = opened.count
        let copyReply = try await call(["improvement-prepare","--improvement",second.id.uuidString])
        check(copyReply.ok && opened.count == countBeforeAPI,"CLI copy-only uses the shared preparation owner")
        let linkReply = try await call(["improvement-link","--improvement",second.id.uuidString,"--handoff",secondHandoff.id.uuidString,"--thread",UUID().uuidString])
        check(linkReply.ok,"CLI links a manually prepared handoff")
        let outcome = try await call(["improvement-update","--improvement",second.id.uuidString,"--revision","1","--state","implemented","--note","Destination feature verified", "--target-build","1"])
        check(outcome.result?.tools?.improvement?.status(runningBuild:69) == "Implemented in destination project","a separate program's build is never reported installed in Window Factory")
        dispatcher.projectInitializer = { [weak dispatcher] path in
            guard let dispatcher else {throw AgentFailure("fixture_unavailable","Fixture dispatcher released")}
            check(dispatcher.isCreatingProject,"creation is marked busy before its asynchronous initializer")
            let before = copied.count
            rejects("project_creation_busy") {_ = try dispatcher.prepareRequest(copyFailure.id)}
            check(copied.count == before,"preparation cannot copy the old destination during project creation")
            return try await ImprovementProjectCreation.create(path)
        }
        let creationID = UUID(), newProject = fixture.appendingPathComponent("New local repository")
        let createArgs = ["improvement-create-project","--destination",newProject.path,"--request-id",creationID.uuidString]
        let createReply = try await call(createArgs)
        check(createReply.ok && FileManager.default.fileExists(atPath:newProject.appendingPathComponent(".git").path),"explicit local creation initializes Git through the configured owner tool")
        check(createReply.result?.tools?.improvementAgent?.destinationRepository == newProject.resolvingSymlinksInPath().path,"created local repo becomes the selected destination, without claiming Codex registration")
        check(try await call(createArgs).ok,"creation retry is idempotent in the running app")
        check(try await call(["improvement-create-project","--destination",external.path,"--request-id",creationID.uuidString]).code == "request_conflict","creation ID cannot be reused for another path")
        check(try await call(["improvement-create-project","--destination",newProject.path]).code == "project_exists","existing folders are never replaced")
        let partial = fixture.appendingPathComponent("partial-project")
        do {_ = try await ImprovementProjectCreation.create(partial.path,git:URL(fileURLWithPath:"/usr/bin/false")); check(false,"failing Git accepted")} catch {check((error as? AgentFailure)?.code == "project_initialization_failed","Git failure is reported")}
        check(FileManager.default.fileExists(atPath:partial.path),"partial creation is preserved for recovery")
        let absent = fixture.appendingPathComponent("not-created")
        do {_ = try await ImprovementProjectCreation.create(absent.path,git:URL(fileURLWithPath:"/not/a/git/tool")); check(false,"missing Git accepted")} catch {check(!FileManager.default.fileExists(atPath:absent.path),"missing initializer creates no folder")}
        _ = try await call(["improvement-agent","--destination","app"])
        check(try dispatcher.configuration().destinationRepository == nil,"CLI resets destination to the app project")
        let background = try await call(["improvement-dispatch","--improvement",second.id.uuidString])
        check(background.code == "background_dispatch_disabled","retired launcher cannot run a headless model")
        for args in [["improvement-prepare"],["improvement-create-project","--destination","app"],["improvement-agent","--destination","relative"],["improvements","--destination",external.path],["improvement-open","--improvement",first.id.uuidString,"--wait"]] {
            do {_ = try AgentCLI.parse(args); check(false,"invalid manual args accepted")} catch {check(true,"strict manual args rejected")}
        }
        // Hidden native UI actions use injected clipboard/opener; no real desktop or clipboard effects.
        let uiStore = ImprovementStore(url:fixture.appendingPathComponent("ui/requests.json"),version:"test",build:"69")
        let uiDispatcher = ImprovementDispatcher(store:uiStore,watch:false)
        _ = try uiDispatcher.configure(repository:repo.path)
        var uiURLs: [URL] = [], uiCopies: [String] = []
        uiDispatcher.openURL = {uiURLs.append($0); return true}; uiDispatcher.copyPrompt = {uiCopies.append($0); return true}
        let suite = "WindowFactory.ManualImprovementTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let ui = ImprovementsWindow(store:uiStore,preferences:FactoryPreferences(defaults:defaults),dispatcher:uiDispatcher)
        func descendants(_ view: NSView) -> [NSView] {view.subviews.flatMap {[$0] + descendants($0)}}
        let views = descendants(ui.window.contentView!), buttons = views.compactMap {$0 as? NSButton}
        let input = views.compactMap {$0 as? NSTextView}.first {$0.isEditable}!
        let picker = views.compactMap {$0 as? NSPopUpButton}.first!
        check(picker.selectedItem?.title == "Window Factory (app project)" && picker.itemTitles.contains("Create project…") && picker.itemTitles.contains("Choose existing project…"),"destination defaults to app and exposes existing/create choices")
        input.string = "Saved for later"; buttons.first {$0.title == "Save for later"}!.performClick(nil)
        check(try uiStore.all().count == 1 && uiURLs.isEmpty && uiCopies.isEmpty,"Save does not prepare, copy or open")
        buttons.first {$0.title == "Copy prepared request"}!.performClick(nil)
        check(uiCopies.count == 1 && uiURLs.isEmpty,"copy-only action prepares a callback-capable prompt")
        buttons.first {$0.title == "Copy selected & open…"}!.performClick(nil)
        check(uiURLs == [ImprovementHandoffLink.manualComposerURL()],"selected preparation opens mode-only navigation")
        let uiRequest = try uiStore.all()[0], uiChat = UUID()
        _ = try uiStore.linkChat(uiRequest.id,handoffID:uiRequest.handoffs!.last!.id,threadID:uiChat)
        let openChat = buttons.first {$0.title == "Open chat"}!
        check(openChat.isEnabled && !buttons.first {$0.title == "Copy prepared request"}!.isEnabled,"linked request offers its chat and prevents a duplicate prepared task")
        openChat.performClick(nil)
        check(uiURLs.last == ImprovementHandoffLink.chatURL(uiChat),"Open chat follows the actual callback link")
        input.string = "A new request"; buttons.first {$0.title == "Copy & open Codex…"}!.performClick(nil)
        check(try uiStore.all().count == 2 && input.string.isEmpty && uiStore.all().last!.state == .queued && uiStore.all().last!.handoffs!.last!.phase == "prepared","primary action saves/copies a new request without claiming it sent")
        ui.window.contentView!.layoutSubtreeIfNeeded()
        check(!ui.window.isVisible && !ui.window.contentView!.hasAmbiguousLayout,"manual UI lays out without activating real windows")
        uiDispatcher.stop(); service.improvementOperation = nil
        print("manual improvement handoff: \(assertions) assertions passed; destinations, copy/paste contract, creation, callbacks and native actions")
    }
}
