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
        // Direct UI and CLI use the same injected provider: no live desktop, model or clipboard.
        let projectID=UUID().uuidString.lowercased(),directChat=UUID().uuidString.lowercased()
        let target=CodexDestination(projectID:projectID,projectName:"Fixture project",repository:repo.resolvingSymlinksInPath().path,chatID:directChat)
        let project=CodexProject(id:projectID,name:target.projectName,roots:[target.repository])
        let providerChat=CodexChat(id:directChat,name:"Fixture coding chat",repository:target.repository,projectID:projectID)
        var directSends=0,creationCalls=0
        dispatcher.desktopProjects = {[project]};dispatcher.desktopChats = {_ in [providerChat]}
        dispatcher.desktopSelect = {p,c,_ in check(p==projectID && c==directChat,"setup uses exact provider IDs");return target}
        dispatcher.desktopReady = {_ in}
        dispatcher.desktopTransmit = {prompt,destination,message in
            directSends+=1;check(destination==target && prompt.contains("destinationChatID"),"direct prompt carries its exact chat destination")
            return CodexSendReceipt(chatID:destination.chatID,turnID:UUID().uuidString,messageID:message)
        }
        dispatcher.desktopNewChat = {p,r in creationCalls+=1;check(p==projectID && r==target.repository,"chat creation is project-bound");return providerChat}
        check(try await call(["improvement-codex-projects"]).result?.tools?.codexProjects==[project],"CLI returns actual provider project records")
        check(try await call(["improvement-codex-chats","--codex-project",projectID]).result?.tools?.codexChats==[providerChat],"CLI returns chosen project/repository chats")
        check(try await call(["improvement-connect","--codex-project",projectID,"--thread",directChat]).result?.tools?.codexDestination==target,"CLI persists the verified project and chat")
        let preservedSetup=try dispatcher.configuration()
        let setupFolder=fixture.appendingPathComponent("new-setup-folder")
        dispatcher.projectInitializer = {path in try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:false);return URL(fileURLWithPath:path)}
        _ = try await dispatcher.createProject(setupFolder.path,selectAsDestination:false)
        check(try dispatcher.configuration()==preservedSetup,"creating a new setup folder preserves the existing connection until Use is chosen")
        let direct=try store.submit(text:"Direct request",context:"",source:"cli"),beforeCopies=copied.count
        let directArgs=["improvement-send","--improvement",direct.id.uuidString]
        check(try await call(directArgs).result?.tools?.codexReceipt?.chatID==directChat,"headless send returns an accepted chat receipt")
        check(try await call(directArgs).ok && directSends==1 && copied.count==beforeCopies,"direct send retry does not duplicate or use clipboard")
        let nextDirect=try store.submit(text:"Second request in the same chat",context:"",source:"cli")
        check(try await call(["improvement-send","--improvement",nextDirect.id.uuidString]).code=="codex_chat_busy","another in-progress request prevents chat interruption")
        _ = try store.update(direct.id,operationID:UUID(),revision:1,state:.declined,note:"Fixture finished",targetBuild:nil)
        check(try await call(["improvement-send","--improvement",nextDirect.id.uuidString]).ok && directSends==2,"chosen chat is reused after previous outcome")
        check(try await call(["improvement-remove","--improvement",direct.id.uuidString,"--confirm"]).ok,"CLI removes stale note from the visible list")
        check(try !store.all().contains(where:{$0.id==direct.id}) && store.get(direct.id).text==direct.text,"removal preserves the original and its callback history")
        let chatCreationID=UUID().uuidString
        let chatArgs=["improvement-codex-new-chat","--codex-project",projectID,"--repository",target.repository,"--request-id",chatCreationID]
        let createdOnce=try await call(chatArgs),createdTwice=try await call(chatArgs)
        check(createdOnce.ok && createdTwice.ok && creationCalls==1,"chat creation receipt survives retry without another create")
        check(try await call(["improvement-disconnect"]).ok && dispatcher.configuration().desktopDestination==nil,"CLI can reset setup anytime")
        for args in [["improvement-connect","--codex-project",projectID],["improvement-send"],["improvement-remove","--improvement",direct.id.uuidString],["improvement-codex-chats","--codex-project","folder-name"],["improvement-codex-projects","--display","1"]] {
            do {_ = try AgentCLI.parse(args);check(false,"invalid direct arguments accepted")}catch {check(true,"strict direct arguments rejected")}
        }
        let uiStore=ImprovementStore(url:fixture.appendingPathComponent("ui/requests.json"),version:"test",build:"70")
        let uiDispatcher=ImprovementDispatcher(store:uiStore,watch:false)
        _ = try uiDispatcher.configure(repository:repo.path)
        var uiURLs:[URL]=[],uiCopies:[String]=[],uiSends=0
        uiDispatcher.openURL={uiURLs.append($0);return true};uiDispatcher.copyPrompt={uiCopies.append($0);return true}
        uiDispatcher.desktopProjects={[project]};uiDispatcher.desktopChats={_ in [providerChat]}
        uiDispatcher.desktopSelect={_,_,_ in target};uiDispatcher.desktopReady={_ in}
        uiDispatcher.desktopTransmit={_,dest,id in uiSends+=1;return CodexSendReceipt(chatID:dest.chatID,turnID:UUID().uuidString,messageID:id)}
        let suite="WindowFactory.DirectImprovementTest.\(UUID().uuidString)",defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let ui=ImprovementsWindow(store:uiStore,preferences:FactoryPreferences(defaults:defaults),dispatcher:uiDispatcher)
        func descendants(_ view:NSView)->[NSView] {view.subviews.flatMap {[$0]+descendants($0)}}
        let views=descendants(ui.window.contentView!),buttons=views.compactMap {$0 as? NSButton}
        let input=views.compactMap {$0 as? NSTextView}.first {$0.isEditable}!
        check(buttons.contains(where:{$0.title=="Connection…"}) && buttons.contains(where:{$0.title=="Remove from list…"}),"setup can be reopened and stale notes removed")
        let setup=CodexConnectionWindow(dispatcher:uiDispatcher)
        let setupViews=descendants(setup.window.contentView!),setupButtons=setupViews.compactMap {$0 as? NSButton}
        setupButtons.first {$0.title=="Load / refresh projects"}!.performClick(nil)
        for _ in 0..<100 {if setupButtons.first(where:{$0.title=="Use this chat"})?.isEnabled == true {break};try await Task.sleep(for:.milliseconds(10))}
        let setupPickers=setupViews.compactMap {$0 as? NSPopUpButton}
        check(setupPickers.contains(where:{$0.itemTitles.contains(project.name)}) && setupPickers.contains(where:{$0.itemTitles.contains(providerChat.name)}),"setup lists actual project and chat records from the shared provider")
        setupButtons.first {$0.title=="Use this chat"}!.performClick(nil)
        for _ in 0..<100 {if try uiDispatcher.configuration().desktopDestination != nil {break};try await Task.sleep(for:.milliseconds(10))}
        check(try uiDispatcher.configuration().desktopDestination==target,"setup window persists the exact provider project/chat selection")
        setup.window.contentView!.layoutSubtreeIfNeeded()
        check(!setup.window.isVisible && !setup.window.contentView!.hasAmbiguousLayout,"setup fixture stays hidden and lays out without desktop activation")
        let beforeSaveURLs=uiURLs.count
        input.string="Saved for later";buttons.first {$0.title=="Save for later"}!.performClick(nil)
        check(try uiStore.all().count==1 && uiURLs.count==beforeSaveURLs && uiCopies.isEmpty && uiSends==0,"Save starts no model, clipboard or navigation")
        _ = try await uiDispatcher.connectDesktop(projectID:projectID,chatID:directChat,assignUnfiled:false)
        buttons.first {$0.title=="Send selected"}!.performClick(nil)
        for _ in 0..<150 {if try uiStore.all()[0].delivery?.receipt != nil {break};try await Task.sleep(for:.milliseconds(10))}
        let uiRequest=try uiStore.all()[0]
        check(uiSends==1 && uiCopies.isEmpty && uiRequest.delivery?.receipt?.chatID==directChat,"native selected Send delivers directly without copying")
        check(uiURLs.allSatisfy {$0==ImprovementHandoffLink.chatURL(UUID(uuidString:directChat)!)},"direct navigation opens only the exact chosen chat, never a composer")
        let openChat=buttons.first {$0.title=="Open chat"}!
        check(openChat.isEnabled && !buttons.first {$0.title=="Send selected"}!.isEnabled,"accepted request exposes its linked chat and prevents another send")
        openChat.performClick(nil)
        _ = try uiStore.update(uiRequest.id,operationID:UUID(),revision:1,state:.declined,note:"Fixture completed",targetBuild:nil)
        input.string="A new direct request";buttons.first {$0.title=="Send to Codex"}!.performClick(nil)
        for _ in 0..<150 {if try uiStore.all().last?.delivery?.receipt != nil {break};try await Task.sleep(for:.milliseconds(10))}
        check(try uiStore.all().count==2 && input.string.isEmpty && uiSends==2 && uiCopies.isEmpty,"primary action saves and sends a new request to the configured chat")
        ui.window.contentView!.layoutSubtreeIfNeeded()
        check(!ui.window.isVisible && !ui.window.contentView!.hasAmbiguousLayout,"direct UI fixtures never activate real windows")
        uiDispatcher.stop(); service.improvementOperation = nil
        print("improvement handoff: \(assertions) assertions passed; legacy compatibility, direct destinations, receipts, retries, CLI and native actions")
    }
}
