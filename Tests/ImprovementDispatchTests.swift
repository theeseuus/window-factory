import AppKit

@MainActor
enum ImprovementDispatchTests {
    static func run(service: AgentService, root: URL) async throws {
        var assertions = 0
        func check(_ value: Bool, _ label: String) {assertions += 1; precondition(value,label)}
        func rejects(_ code: String, _ operation: () throws -> Void) {
            do {try operation(); check(false,"expected \(code)")}
            catch {check((error as? AgentFailure)?.code == code,"expected \(code), got \(error)")}
        }
        let fixture = root.appendingPathComponent("dispatch"), repo = fixture.appendingPathComponent("repo with spaces")
        try FileManager.default.createDirectory(at:repo.appendingPathComponent("Sources"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:repo.appendingPathComponent("docs"),withIntermediateDirectories:true)
        for file in [".git","AGENTS.md","Sources/Main.swift","docs/improvements.md"] {try Data().write(to:repo.appendingPathComponent(file))}
        let canonicalRepo = try ImprovementRepository.validate(repo.path)
        check(canonicalRepo.path == repo.resolvingSymlinksInPath().path,"repository binding validates expected app structure and canonicalizes paths")
        rejects("invalid_repository") {_ = try ImprovementRepository.validate(fixture.path)}
        var guiEnvironment = ProcessInfo.processInfo.environment
        guiEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let gitVersion = try ImprovementRepository.git(["--version"],at:repo,environment:guiEnvironment)
        check(gitVersion.hasPrefix("git version"),"managed Git resolves independently of the GUI app's minimal PATH")
        let store = ImprovementStore(url:fixture.appendingPathComponent("requests.json"),version:"test",build:"58")
        let dispatcher = ImprovementDispatcher(store:store,watch:false)
        defer {dispatcher.stop()}
        dispatcher.preflight = {_ in (canonicalRepo,"baseline")}
        var launches: [URL] = []
        dispatcher.launch = {launches.append($0)}
        let first = try store.submit(text:"Fix one thing; $(touch should-not-run)",context:"test",source:"ui")
        rejects("repository_required") {_ = try dispatcher.dispatch(first.id)}
        check(try store.get(first.id).state == .queued && launches.isEmpty,"unconfigured dispatch does not mark work started")
        _ = try dispatcher.configure(repository:repo.path)
        let restartedConfig = ImprovementDispatcher(store:store,watch:false)
        check(try restartedConfig.configuration().repository == canonicalRepo.path,"repository binding survives controller restart")
        _ = try dispatcher.dispatch(first.id)
        check(try launches.count == 1 && store.get(first.id).status(runningBuild:58) == "Starting agent…","one explicit send launches one run")
        let spec = try ImprovementFiles.read(ImprovementWorkerSpecification.self,from:launches[0].appendingPathComponent("input.json"))
        check(spec.text == first.text && spec.repository == canonicalRepo.path,"request reaches correct repo as data, preserving shell characters")
        rejects("agent_busy") {_ = try dispatcher.dispatch(first.id)}
        let second = try store.submit(text:"Later request",context:"",source:"ui")
        rejects("agent_busy") {_ = try dispatcher.dispatch(second.id)}
        try ImprovementFiles.write(ImprovementWorkerStarted(workerPID:12345,agentPID:12346,date:Date()),to:launches[0].appendingPathComponent("started.json"))
        dispatcher.alive = {_ in true}
        try dispatcher.reconcile()
        check(try store.get(first.id).status(runningBuild:58) == "Agent running","started marker distinguishes running from launching")
        let receipt = ImprovementWorkerReceipt(finishedAt:Date(),succeeded:true,result:ImprovementAgentResult(state:.implemented,note:"Fixture-only verified outcome",targetBuild:59),sessionID:UUID().uuidString)
        try ImprovementFiles.write(receipt,to:launches[0].appendingPathComponent("receipt.json"))
        try dispatcher.reconcile(); try dispatcher.reconcile()
        let finished = try store.get(first.id)
        check(finished.runs?.count == 1 && finished.revision == 2 && finished.runs?.last?.phase == "finished","completion reconciles exactly once")
        check(finished.status(runningBuild:58).contains("awaiting build 59"),"completed implementation still awaits installation")
        rejects("request_finished") {_ = try dispatcher.dispatch(first.id)}
        dispatcher.launch = {_ in throw FactoryError("fixture launch failure")}
        rejects("agent_launch_failed") {_ = try dispatcher.dispatch(second.id)}
        check(try store.get(second.id).state == .needsInput && store.get(second.id).runs?.last?.phase == "failed","launch failure is saved as an honest outcome")
        dispatcher.launch = {launches.append($0)}
        _ = try dispatcher.dispatch(second.id)
        let interrupted = try store.get(second.id).runs!.last!
        try dispatcher.reconcile(now:interrupted.startedAt.addingTimeInterval(60))
        check(try store.get(second.id).state == .needsInput && launches.count == 2,"interrupted launch is reconciled without automatic retry")
        // Do not overwrite an outcome updated while the model was running.
        _ = try dispatcher.dispatch(second.id)
        let current = try store.get(second.id), lastRun = current.runs!.last!
        _ = try store.update(second.id,operationID:UUID(),revision:current.revision,state:.declined,note:"Owner chose to leave this alone",targetBuild:nil)
        let late = ImprovementWorkerReceipt(finishedAt:Date(),succeeded:true,result:ImprovementAgentResult(state:.needsInput,note:"Late agent result",targetBuild:nil),sessionID:nil)
        try ImprovementFiles.write(late,to:dispatcher.directory.appendingPathComponent(lastRun.id.uuidString).appendingPathComponent("receipt.json"))
        try dispatcher.reconcile()
        check(try store.get(second.id).state == .declined && store.get(second.id).updates.last!.note.contains("current status retained"),"late worker result preserves newer owner state")
        // Exercise worker result validation and exit-failure handling, without a model.
        let workerDir = fixture.appendingPathComponent("worker")
        try FileManager.default.createDirectory(at:workerDir,withIntermediateDirectories:true)
        let workerResult = try ImprovementWorker.execute(spec,directory:workerDir,invoke:{prompt,directory in
            check(prompt.contains("Do not pick up other saved requests") && prompt.contains("do not call improvement-update"),"worker prompt scopes work and gives app status ownership")
            let result = ImprovementAgentResult(state:.needsInput,note:"Fixture investigation needs input",targetBuild:nil)
            try ImprovementFiles.write(result,to:directory.appendingPathComponent("result.json")); return 0
        })
        check(workerResult.succeeded && workerResult.result.state == .needsInput,"worker accepts a bounded structured investigation result")
        let failedWorker = try ImprovementWorker.execute(spec,directory:workerDir,invoke:{_,_ in 23})
        check(!failedWorker.succeeded && failedWorker.result.note.contains("23"),"nonzero exit cannot claim success")
        do {
            _ = try ImprovementWorker.execute(spec,directory:workerDir,invoke:{_,directory in
                try Data("not JSON".utf8).write(to:directory.appendingPathComponent("result.json")); return 0
            }); check(false,"malformed final output accepted")
        } catch {check(true,"malformed final output rejected")}
        rejects("invalid_agent_result") {try ImprovementAgentResult(state:.working,note:"Still working",targetBuild:nil).validate()}
        let session = UUID().uuidString
        try Data("{\"type\":\"thread.started\",\"thread_id\":\"\(session)\"}\n".utf8).write(to:workerDir.appendingPathComponent("events.jsonl"))
        check(ImprovementWorker.sessionID(workerDir.appendingPathComponent("events.jsonl")) == session,"session ID extracted without loading entire logs")
        service.improvementOperation = {try dispatcher.handle($0)}
        func call(_ args: [String]) async throws -> AgentResponse {
            let request = try AgentCLI.parse(args).request
            return await service.handle(try JSONEncoder().encode(request))
        }
        let configReply = try await call(["improvement-agent"])
        check(configReply.result?.tools?.improvementAgent?.runner == "codex-ai","CLI exposes configured subscription runner")
        let third = try store.submit(text:"CLI dispatch",context:"",source:"cli")
        let dispatchReply = try await call(["improvement-dispatch","--improvement",third.id.uuidString])
        check(dispatchReply.ok && dispatchReply.result?.job == nil && dispatchReply.result?.tools?.improvement?.runs?.last?.active == true,"CLI dispatch uses same owner, without a desktop job")
        for args in [["improvement-dispatch"],["improvement-agent","--repository","relative"],["improvement-dispatch","--improvement",third.id.uuidString,"--wait"]] {
            do {_ = try AgentCLI.parse(args); check(false,"invalid dispatch fields accepted")} catch {check(true,"strict dispatch args rejected")}
        }
        let replayID = UUID()
        let replayArgs = ["improvement-dispatch","--improvement",third.id.uuidString,"--request-id",replayID.uuidString]
        // A retry of a finished failed dispatch must not silently launch again.
        let activeThird = try store.get(third.id).runs!.last!
        try ImprovementFiles.write(ImprovementWorkerReceipt.failure("Fixture completion"),to:dispatcher.directory.appendingPathComponent(activeThird.id.uuidString).appendingPathComponent("receipt.json"))
        try dispatcher.reconcile()
        _ = try await call(replayArgs)
        let replayRun = try store.get(third.id).runs!.last!
        try ImprovementFiles.write(ImprovementWorkerReceipt.failure("Fixture failure"),to:dispatcher.directory.appendingPathComponent(replayRun.id.uuidString).appendingPathComponent("receipt.json"))
        try dispatcher.reconcile()
        let beforeReplay = launches.count
        let replayReply = try await call(replayArgs)
        check(replayReply.ok && launches.count == beforeReplay,"identical dispatch retry returns its recorded result after failure without relaunching")
        let invalidOutcome = try dispatcher.dispatch(third.id).runs!.last!
        let invalidReceiptURL = dispatcher.directory.appendingPathComponent(invalidOutcome.id.uuidString).appendingPathComponent("receipt.json")
        try Data("invalid receipt".utf8).write(to:invalidReceiptURL)
        try dispatcher.reconcile()
        check(try store.get(third.id).runs?.last?.phase == "failed" && Data(contentsOf:invalidReceiptURL) == Data("invalid receipt".utf8),"invalid receipts become an attention outcome while preserving original evidence")
        // Actual AppKit actions: Save never dispatches; Send does; saved rows can be sent later.
        let uiStore = ImprovementStore(url:fixture.appendingPathComponent("ui/requests.json"),version:"test",build:"58")
        let uiDispatcher = ImprovementDispatcher(store:uiStore,watch:false)
        _ = try uiDispatcher.configure(repository:repo.path); uiDispatcher.preflight = {_ in (canonicalRepo,"baseline")}
        var uiLaunches = 0; uiDispatcher.launch = {_ in uiLaunches += 1}
        let ui = ImprovementsWindow(store:uiStore,dispatcher:uiDispatcher)
        func descendants(_ view: NSView) -> [NSView] {view.subviews.flatMap {[$0] + descendants($0)}}
        let views = descendants(ui.window.contentView!)
        let input = views.compactMap {$0 as? NSTextView}.first {$0.isEditable}!
        let buttons = views.compactMap {$0 as? NSButton}
        input.string = "Save this for later"
        buttons.first {$0.title == "Save for later"}!.performClick(nil)
        check(try uiStore.all().count == 1 && uiLaunches == 0,"Save for later never invokes a model")
        buttons.first {$0.title == "Send selected now"}!.performClick(nil)
        check(uiLaunches == 1,"existing saved request can be sent with one action")
        let uiRun = try uiStore.all()[0].runs!.last!
        try ImprovementFiles.write(ImprovementWorkerReceipt.failure("Fixture finished"),to:uiDispatcher.directory.appendingPathComponent(uiRun.id.uuidString).appendingPathComponent("receipt.json"))
        try uiDispatcher.reconcile()
        input.string = "Send this new request now"
        buttons.first {$0.title == "Send to agent now"}!.performClick(nil)
        check(try uiStore.all().count == 2 && uiLaunches == 2 && input.string.isEmpty,"Send now saves first and dispatches without copy/paste")
        ui.window.contentView!.layoutSubtreeIfNeeded()
        check(!ui.window.isVisible && !ui.window.contentView!.hasAmbiguousLayout,"dispatch UI remains hidden in tests and has a resolved layout")
        service.improvementOperation = nil
        print("improvement dispatch: \(assertions) assertions passed; injected runner, persisted lifecycle, CLI and native form actions")
    }
}
