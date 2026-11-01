import AppKit

@MainActor
enum ImprovementTests {
    static func run(service: AgentService, root: URL) async throws {
        var assertions = 0
        func check(_ value: Bool, _ label: String) {assertions += 1; precondition(value,label)}
        func rejects(_ label: String, _ operation: () throws -> Void) {
            do {try operation(); check(false,label)} catch {check(true,label)}
        }
        let url = root.appendingPathComponent("improvements/requests.json")
        let store = ImprovementStore(url:url,version:"0.2.0",build:"57")
        service.improvementOperation = {try store.handle($0)}
        func call(_ request: AgentRequest) async -> AgentResponse {await service.handle(try! JSONEncoder().encode(request))}
        check(try store.all().isEmpty,"missing file is an empty store")
        rejects("blank requests rejected") {_ = try store.submit(text:" \n",context:"",source:"ui")}
        rejects("byte bound counts multibyte input") {_ = try store.submit(text:String(repeating:"😀",count:2001),context:"",source:"ui")}
        var submission = try AgentCLI.parse(["improvement-submit","--text","Keep my place","--context","Layout library"]).request
        let answer = await call(submission)
        check(answer.ok && answer.result?.job == nil,"record submission is immediate, not a desktop job")
        let value = answer.result!.tools!.improvement!
        check(value.id == submission.id && value.text == "Keep my place" && value.build == "57","wire request and app build retained")
        let repeated = await call(submission)
        check(try repeated.result?.tools?.improvement?.id == value.id && store.all().count == 1,"submission retry is durable and does not duplicate")
        submission.text = "Different"
        check(await call(submission).code == "request_conflict","conflicting submit cannot replace original")
        let reopened = ImprovementStore(url:url,version:"0.2.0",build:"58")
        check(try reopened.get(value.id).text == value.text,"requests survive store restart")
        var change = try AgentCLI.parse(["improvement-update","--improvement",value.id.uuidString,"--revision","0","--state","implemented","--note","Preserved list selection; fixture regression passed; local commit recorded.","--target-build","58"]).request
        let updated = await call(change)
        check(updated.result?.tools?.improvement?.revision == 1,"update returns current revision")
        check(try store.get(value.id).status(runningBuild:57).contains("awaiting build 58"),"uninstalled fix is not available")
        check(try reopened.get(value.id).status(runningBuild:58) == "Available in this build","running target build reports availability")
        check(try reopened.get(value.id).status(runningBuild:nil).contains("awaiting"),"unknown build does not claim availability")
        check(await call(change).result?.tools?.improvement?.revision == 1,"update retry does not append another event")
        change.note = "Conflicting outcome"
        check(await call(change).code == "request_conflict","update retry checks original content")
        change.id = UUID()
        check(await call(change).code == "revision_conflict","stale revision cannot overwrite progress")
        let record = try store.get(value.id)
        check(record.text == value.text && record.context == "Layout library" && record.updates.count == 1,"updates preserve original request and context")
        let query = try AgentCLI.parse(["improvements","--improvement",value.id.uuidString]).request
        let wire = try AgentResponse.decode(await call(query).encoded())
        check(wire.result?.tools?.improvement?.updates.first?.targetBuild == 58,"structured response survives ISO date wire roundtrip")
        for i in 0..<105 {_ = try store.submit(text:"Request \(i)",context:"",source:"ui")}
        let page1 = await call(AgentRequest(command:.improvements))
        let page2 = await call(try AgentCLI.parse(["improvements","--offset","100"]).request)
        check(page1.result?.tools?.improvements?.count == 100 && page2.result?.tools?.improvements?.count == 6 && page2.result?.tools?.improvementCount == 106,"list pagination retains requests beyond first page")
        let invalid = [
            ["improvement-submit","--text",""],
            ["improvement-submit","--text","x","--display","1","--space","42"],
            ["improvement-submit","--text","x","--wait"],
            ["improvements","--text","extra"],
            ["improvements","--offset","-1"],
            ["improvement-update","--improvement",value.id.uuidString,"--revision","1","--state","available","--note","x"],
            ["improvement-update","--improvement",value.id.uuidString,"--revision","1","--state","implemented","--note","x"],
            ["improvement-update","--improvement",value.id.uuidString,"--revision","1","--state","working","--note","x","--target-build","58"]
        ]
        for args in invalid {rejects("unexpected or incomplete fields rejected") {_ = try AgentCLI.parse(args)}}
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,"request file is private")
        // Render only this fixture window's view, without screen capture or live app state.
        let previewStore = ImprovementStore(url:root.appendingPathComponent("preview/requests.json"),version:"0.2.0",build:"57")
        let sample = try previewStore.submit(text:"Keep my place in the list when I return from a layout.",context:"Layout library",source:"ui")
        _ = try previewStore.update(sample.id,operationID:UUID(),revision:0,state:.implemented,note:"Selection and scroll position now survive returning to the library. Fixture regression passed.",targetBuild:58)
        let ui = ImprovementsWindow(store:previewStore)
        func descendants(_ view: NSView) -> [NSView] {view.subviews.flatMap {[$0] + descendants($0)}}
        let views = descendants(ui.window.contentView!)
        let input = views.compactMap {$0 as? NSTextView}.first {$0.isEditable}!
        let send = views.compactMap {$0 as? NSButton}.first {$0.title == "Save for later"}!
        input.string = "Show a clearer explanation when a window cannot move."
        send.performClick(nil)
        check(try previewStore.all().count == 2 && input.string.isEmpty,"form submission saves and clears only after success")
        send.performClick(nil)
        check(try previewStore.all().count == 2,"blank form does not save another request")
        let history = views.compactMap {$0 as? NSTableView}.first!
        history.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        ui.window.contentView!.layoutSubtreeIfNeeded()
        check(!ui.window.isVisible && !ui.window.contentView!.hasAmbiguousLayout,"request UI lays out without showing a live window")
        if let output = ProcessInfo.processInfo.environment["WF_IMPROVEMENTS_PREVIEW"] {
            let view = ui.window.contentView!
            if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output))
            }
        }
        let original = try Data(contentsOf:url)
        try Data("broken".utf8).write(to:url)
        rejects("corrupt history blocks new writes") {_ = try store.submit(text:"Must not erase history",context:"",source:"ui")}
        check(try Data(contentsOf:url) == Data("broken".utf8),"corrupt data preserved")
        try original.write(to:url)
        var object = try JSONSerialization.jsonObject(with:original) as! [String:Any]
        object["schemaVersion"] = 99
        let unsupported = try JSONSerialization.data(withJSONObject:object)
        try unsupported.write(to:url)
        rejects("unsupported schema blocks writes") {_ = try store.submit(text:"No migration",context:"",source:"ui")}
        check(try Data(contentsOf:url) == unsupported,"unsupported data preserved")
        try original.write(to:url)
        let missing = UUID()
        rejects("missing IDs are explicit errors") {_ = try store.get(missing)}
        try service.setEnabled(false)
        check(await call(query).code == "agent_disabled","improvement API respects owner agent toggle")
        try service.setEnabled(true)
        let capabilities = await call(AgentRequest(command:.capabilities))
        check(capabilities.result?.commands?.contains("improvement-update") == true,"capabilities advertise record operations")
        service.improvementOperation = nil
        print("improvement requests: \(assertions) assertions passed; isolated persistence, CLI, build status and AppKit layout")
    }
}
