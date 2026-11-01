import AppKit

@MainActor
enum ImprovementHandoffTests {
    static func run(service: AgentService, root: URL) async throws {
        var assertions = 0
        func check(_ value: Bool, _ label: String) {assertions += 1; precondition(value,label)}
        func rejects(_ code: String, _ operation: () throws -> Void) {
            do {try operation(); check(false,"expected \(code)")} catch {check(((error as? AgentFailure)?.code ?? (error as? ImprovementFailure)?.code) == code,"expected \(code), got \(error)")}
        }
        let fixture = root.appendingPathComponent("handoff"), repo = fixture.appendingPathComponent("repo with spaces & + symbols")
        try FileManager.default.createDirectory(at:repo.appendingPathComponent("Sources"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:repo.appendingPathComponent("docs"),withIntermediateDirectories:true)
        for path in [".git","AGENTS.md","Sources/Main.swift","docs/improvements.md"] {try Data().write(to:repo.appendingPathComponent(path))}
        let store = ImprovementStore(url:fixture.appendingPathComponent("requests.json"),version:"test",build:"59")
        let dispatcher = ImprovementDispatcher(store:store,watch:false)
        defer {dispatcher.stop()}
        var opened: [URL] = []
        dispatcher.openURL = {opened.append($0); return true}
        let first = try store.submit(text:"Keep A & B + C?\n$(do not execute) 😀",context:"Layout library",source:"ui")
        rejects("repository_required") {_ = try dispatcher.openRequest(first.id)}
        check(opened.isEmpty,"missing repository cannot open another workspace")
        _ = try dispatcher.configure(repository:repo.path)
        rejects("codex_project_required") {_ = try dispatcher.openRequest(first.id)}
        check(try opened.isEmpty && store.get(first.id).handoffs == nil,"missing project binding opens no composer and creates no handoff")
        _ = try dispatcher.configure(repository:repo.path,codexProjectID:"fixture-project")
        check(try dispatcher.configure(repository:repo.path).codexProjectID == "fixture-project","selecting the same repository preserves its project binding")
        let otherRepo = fixture.appendingPathComponent("other-repo")
        try FileManager.default.copyItem(at:repo,to:otherRepo)
        check(try dispatcher.configure(repository:otherRepo.path).codexProjectID == nil,"changing repositories clears the previous project binding")
        _ = try dispatcher.configure(repository:repo.path,codexProjectID:"fixture-project")
        _ = try dispatcher.openRequest(first.id)
        let prepared = try store.get(first.id), handoff = prepared.handoffs!.last!
        check(prepared.state == .queued && prepared.revision == 0 && prepared.runs == nil,"opening a composer is not working or a background run")
        check(prepared.status(runningBuild:59) == "Ready in Codex — press Send","status explicitly awaits final Send")
        let components = URLComponents(url:opened[0],resolvingAgainstBaseURL:false)!
        let query = Dictionary(uniqueKeysWithValues:components.queryItems!.map {($0.name,$0.value!)})
        check(components.scheme == "codex" && components.host == "threads" && components.path == "/new","uses documented new-chat route")
        check(query["path"] == repo.resolvingSymlinksInPath().path,"workspace path survives URL encoding")
        check(query["mode"] == "codex", "handoff explicitly selects coding mode instead of inheriting ChatGPT")
        check(query["projectId"] == "fixture-project","handoff selects the bound saved project explicitly")
        check(components.queryItems!.map(\.name) == ["mode","projectId","path","prompt"] && components.percentEncodedQuery!.contains("path=%2F"),"handoff matches the verified routing-first, strictly encoded desktop wire format")
        check(!opened[0].absoluteString.contains("+"),"literal plus signs are safe for both URLComponents and form-style query decoders")
        check(query["prompt"]!.contains("A & B + C?") && query["prompt"]!.contains("$(do not execute) 😀"),"request remains data and survives URL encoding")
        check(query["prompt"]!.contains(handoff.id.uuidString) && query["prompt"]!.contains("CODEX_THREAD_ID") && query["prompt"]!.contains("improvement-link"),"prepared prompt carries stable callback IDs and current-chat discovery")
        let prompt = query["prompt"]!
        let retryPosition = prompt.range(of:"request normal tool approval/escalation")!.lowerBound
        let stopPosition = prompt.range(of:"If review is rejected")!.lowerBound
        let workPosition = prompt.range(of:"Investigate the intended outcome")!.lowerBound
        check(retryPosition < stopPosition && stopPosition < workPosition && prompt.contains("retry the same callback once"),"local sandbox denial reaches bounded normal review before the stop/product-work gates")
        check(prompt.contains("without changing permission grants") && prompt.contains("Continue product work only after improvement-link returns a successful response") && prompt.contains("evade a rejection"),"retry guidance retains grant boundaries, rejection stop and successful-link requirement")
        check(prompt.contains("applies to request reads and outcome callbacks") && prompt.contains("number of entries in improvement.updates") && prompt.contains("Do not claim the app received an unconfirmed note"),"read/outcome retries and truthful delivery include an unambiguous numeric revision")
        _ = try dispatcher.openRequest(first.id)
        check(try store.get(first.id).handoffs?.count == 1,"reopening an unsent handoff retains its callback token")
        let chat = UUID()
        _ = try store.linkChat(first.id,handoffID:handoff.id,threadID:chat)
        let linked = try store.get(first.id)
        check(linked.revision == 1 && linked.state == .working && linked.handoffs?.last?.phase == "linked","agent callback establishes working state and chat link")
        _ = try store.linkChat(first.id,handoffID:handoff.id,threadID:chat)
        check(try store.get(first.id).revision == 1,"link retry does not append duplicate notes")
        rejects("request_conflict") {_ = try store.linkChat(first.id,handoffID:handoff.id,threadID:UUID())}
        let countBeforeOpen = opened.count
        _ = try dispatcher.openRequest(first.id)
        check(opened.count == countBeforeOpen + 1 && opened.last == ImprovementHandoffLink.chatURL(chat),"linked request opens existing chat rather than another task")
        let reopened = ImprovementStore(url:store.url,version:"test",build:"60")
        check(try reopened.get(first.id).handoffs?.last?.threadID == chat,"chat association survives app restart")
        let second = try store.submit(text:"Second request",context:"",source:"ui")
        _ = try dispatcher.openRequest(second.id)
        let secondHandoff = try store.get(second.id).handoffs!.last!
        rejects("request_conflict") {_ = try store.linkChat(second.id,handoffID:secondHandoff.id,threadID:chat)}
        rejects("handoff_not_found") {_ = try store.linkChat(second.id,handoffID:UUID(),threadID:UUID())}
        rejects("chat_not_linked") {try dispatcher.openChat(second.id)}
        dispatcher.openURL = {_ in false}
        let failed = try store.submit(text:"Unavailable desktop app",context:"",source:"ui")
        rejects("codex_open_failed") {_ = try dispatcher.openRequest(failed.id)}
        check(try store.get(failed.id).handoffs?.last?.phase == "failed" && store.get(failed.id).state == .needsInput,"open failure preserves request without claiming model work")
        // The existing structured CLI supports native chat callbacks and outcome notes.
        service.improvementOperation = {try dispatcher.handle($0)}
        func call(_ args: [String]) async throws -> AgentResponse {
            let invocation = try AgentCLI.parse(args)
            return await service.handle(try JSONEncoder().encode(invocation.request))
        }
        let capabilitiesRequest = AgentRequest(command:.capabilities)
        let capabilities = await service.handle(try JSONEncoder().encode(capabilitiesRequest)).result!.commands!
        check(capabilities.contains("improvement-open") && capabilities.contains("improvement-link") && !capabilities.contains("improvement-dispatch"),"capabilities advertise visible handoff rather than retired background execution")
        let configurationReply = try await call(["improvement-agent","--repository",repo.path,"--codex-project","fixture-project"])
        check(configurationReply.result?.tools?.improvementAgent?.codexProjectID == "fixture-project","CLI config roundtrip retains the explicit project binding")
        let background = try await call(["improvement-dispatch","--improvement",second.id.uuidString])
        check(background.code == "background_dispatch_disabled","old command cannot silently launch a headless model")
        let linkReply = try await call(["improvement-link","--improvement",second.id.uuidString,"--handoff",secondHandoff.id.uuidString,"--thread",UUID().uuidString])
        check(linkReply.ok && linkReply.result?.tools?.improvement?.handoffs?.last?.threadID != nil,"CLI callback links the actual chat through the shared store")
        let outcome = try await call(["improvement-update","--improvement",second.id.uuidString,"--revision","1","--state","implemented","--note","Fixture change verified and committed", "--target-build","60"])
        check(outcome.ok && outcome.result?.tools?.improvement?.status(runningBuild:59).contains("awaiting build 60") == true,"outcome callback updates app without claiming installation")
        for args in [["improvement-agent","--codex-project","unbound"],["improvement-agent","--repository",repo.path,"--codex-project","bad id"],["improvements","--codex-project","unexpected"],["improvement-open"],["improvement-link","--improvement",second.id.uuidString],["improvement-link","--improvement",second.id.uuidString,"--handoff","bad","--thread",chat.uuidString],["improvement-open","--improvement",second.id.uuidString,"--wait"]] {
            do {_ = try AgentCLI.parse(args); check(false,"invalid handoff fields accepted")} catch {check(true,"strict handoff args rejected")}
        }
        // Actual hidden AppKit actions: Save never opens; Open only prepares the URL.
        let uiStore = ImprovementStore(url:fixture.appendingPathComponent("ui/requests.json"),version:"test",build:"59")
        let uiDispatcher = ImprovementDispatcher(store:uiStore,watch:false)
        _ = try uiDispatcher.configure(repository:repo.path,codexProjectID:"fixture-project")
        var uiURLs: [URL] = []; uiDispatcher.openURL = {uiURLs.append($0); return true}
        let presentationSuite = "WindowFactory.ImprovementPresentationTest.\(UUID().uuidString)"
        let presentationDefaults = UserDefaults(suiteName:presentationSuite)!
        defer { presentationDefaults.removePersistentDomain(forName:presentationSuite) }
        let ui = ImprovementsWindow(store:uiStore,preferences:FactoryPreferences(defaults:presentationDefaults),dispatcher:uiDispatcher)
        func descendants(_ view: NSView) -> [NSView] {view.subviews.flatMap {[$0] + descendants($0)}}
        let views = descendants(ui.window.contentView!), buttons = views.compactMap {$0 as? NSButton}
        let input = views.compactMap {$0 as? NSTextView}.first {$0.isEditable}!
        input.string = "Saved for later"; buttons.first {$0.title == "Save for later"}!.performClick(nil)
        check(try uiStore.all().count == 1 && uiURLs.isEmpty,"Save for later does not open or start anything")
        buttons.first {$0.title == "Open selected in Codex…"}!.performClick(nil)
        check(uiURLs.count == 1,"saved request can prepare a visible Codex handoff")
        let uiRequest = try uiStore.all()[0], uiChat = UUID()
        _ = try uiStore.linkChat(uiRequest.id,handoffID:uiRequest.handoffs!.last!.id,threadID:uiChat)
        let openChat = buttons.first {$0.title == "Open chat"}!
        check(openChat.isEnabled,"linked request exposes Open chat")
        openChat.performClick(nil)
        check(uiURLs.last == ImprovementHandoffLink.chatURL(uiChat),"Open chat follows the durable task link")
        input.string = "A new request"; buttons.first {$0.title == "Open in Codex…"}!.performClick(nil)
        check(try uiStore.all().count == 2 && input.string.isEmpty && uiStore.all().last!.state == .queued,"new handoff saves draft and awaits owner Send in Codex")
        ui.window.contentView!.layoutSubtreeIfNeeded()
        check(!ui.window.isVisible && !ui.window.contentView!.hasAmbiguousLayout,"handoff UI is laid out without activating live windows")
        service.improvementOperation = nil
        print("visible improvement handoff: \(assertions) assertions passed; URL encoding, chat callbacks, persistence and native actions")
    }
}
