import AppKit

// Compatibility coverage for histories created by build 58; no new worker exists.
@MainActor
enum ImprovementDispatchTests {
    private struct FixtureCatalog: Encodable {var schemaVersion = 1; let requests: [Improvement]}
    static func run(service: AgentService, root: URL) async throws {
        var assertions = 0
        func check(_ value: Bool, _ label: String) {assertions += 1; precondition(value,label)}
        let fixture = root.appendingPathComponent("legacy-recovery")
        let store = ImprovementStore(url:fixture.appendingPathComponent("requests.json"),version:"test",build:"59")
        let dispatcher = ImprovementDispatcher(store:store,watch:false)
        func start(_ id: UUID) throws -> (ImprovementRun,URL) {
            var values = try store.all(); let index = values.firstIndex(where:{$0.id == id})!
            let run = ImprovementRun(id:UUID(),startedAt:Date(),repository:"legacy-fixture",revision:values[index].revision)
            values[index].runs = (values[index].runs ?? []) + [run]
            values[index].updates.append(ImprovementUpdate(id:UUID(),date:Date(),state:.working,note:"Historical worker fixture",targetBuild:nil))
            try ImprovementFiles.write(FixtureCatalog(requests:values),to:store.url)
            let directory = dispatcher.directory.appendingPathComponent(run.id.uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            return (run,directory)
        }
        let first = try store.submit(text:"Historical request",context:"",source:"ui")
        let (_,directory) = try start(first.id)
        try ImprovementFiles.write(ImprovementWorkerStarted(workerPID:12345,agentPID:12346,date:Date()),to:directory.appendingPathComponent("started.json"))
        dispatcher.alive = {_ in true}; try dispatcher.reconcile()
        check(try store.get(first.id).runs?.last?.phase == "running","existing live run remains visible without launching anything")
        let session = UUID().uuidString
        try Data("{\"type\":\"thread.started\",\"thread_id\":\"\(session)\"}\n".utf8).write(to:directory.appendingPathComponent("events.jsonl"))
        check(ImprovementRunLog.sessionID(directory.appendingPathComponent("events.jsonl")) == session,"historical session metadata remains readable")
        let receipt = ImprovementWorkerReceipt(finishedAt:Date(),succeeded:true,result:ImprovementAgentResult(state:.implemented,note:"Historical fixture receipt",targetBuild:60),sessionID:session)
        try ImprovementFiles.write(receipt,to:directory.appendingPathComponent("receipt.json"))
        let reopened = ImprovementStore(url:store.url,version:"test",build:"59")
        let recovered = ImprovementDispatcher(store:reopened,watch:false)
        try recovered.reconcile(); try dispatcher.reconcile()
        check(try store.get(first.id).revision == 2 && store.get(first.id).runs?.last?.phase == "finished","receipt recovery survives restart and appends once")
        check(try store.get(first.id).status(runningBuild:59).contains("awaiting build 60"),"historical completion retains build availability semantics")
        let second = try store.submit(text:"Interrupted old run",context:"",source:"ui")
        let (interrupted,_) = try start(second.id)
        try dispatcher.reconcile(now:interrupted.startedAt.addingTimeInterval(60))
        check(try store.get(second.id).state == .needsInput,"vanished old worker becomes an attention outcome without restart")
        let (_,lateDirectory) = try start(second.id), current = try store.get(second.id)
        _ = try store.update(second.id,operationID:UUID(),revision:current.revision,state:.declined,note:"Owner moved on",targetBuild:nil)
        try ImprovementFiles.write(ImprovementWorkerReceipt.failure("Late fixture result"),to:lateDirectory.appendingPathComponent("receipt.json"))
        try dispatcher.reconcile()
        check(try store.get(second.id).state == .declined && store.get(second.id).updates.last!.note.contains("current status retained"),"late receipts preserve newer owner state")
        let third = try store.submit(text:"Invalid historical receipt",context:"",source:"ui")
        let (_,badDirectory) = try start(third.id), badURL = badDirectory.appendingPathComponent("receipt.json")
        try Data("invalid".utf8).write(to:badURL); try dispatcher.reconcile()
        check(try store.get(third.id).runs?.last?.phase == "failed" && Data(contentsOf:badURL) == Data("invalid".utf8),"invalid receipt is preserved and does not claim success")
        print("historical improvement recovery: \(assertions) assertions passed; no worker launch or model requests")
    }
}
