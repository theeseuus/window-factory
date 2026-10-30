import AppKit
import Darwin

@MainActor private final class AgentFixtureState {var trusted=true,captures=0,applies=0,partial=false}

@main enum AgentTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var assertions=0
        func check(_ value: Bool,_ label: String) {assertions+=1;precondition(value,label)}
        // macOS Unix socket paths cannot fit the longer per-user TMPDIR.
        let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("wf-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        let defaultsName="WindowFactory.AgentTest.\(UUID().uuidString)"
        let testDefaults=UserDefaults(suiteName:defaultsName)!
        defer {testDefaults.removePersistentDomain(forName:defaultsName)}
        let preferences=FactoryPreferences(defaults:testDefaults)
        check(!preferences.agentAccessEnabled,"agent access defaults off")
        let store=try LayoutStore(url:root.appendingPathComponent("layouts.json"))
        let registry=try JSONDecoder().decode(AdapterRegistry.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let library=LibraryWindow(store:store,registry:registry,preview:true,preferences:preferences)
        defer {library.stop()}
        let target=AgentDesktop(display:1,space:42,frame:Frame(x:0,y:0,w:1000,h:800))
        let fixture=Recipe(name:"Fixture",capturedAt:"test",windows:[Slot(bundleID:"local.fixture",appName:"Fixture",ordinal:1,frame:Frame(x:0,y:0,w:0.5,h:1))])
        try store.save(fixture,replace:false)
        let state=AgentFixtureState()
        let backend=AgentBackend(accessibility:{state.trusted},requireAccess:{},desktops:{[target]},context:{request in
            guard request.display==1,request.space==42 else {throw AgentFailure("context_changed","Fixture desktop changed.")};return target
        },windows:{_ in [AgentWindow(id:7,pid:77,bundleID:"local.fixture",appName:"Fixture",frame:target.frame)]},capture:{_ in
            state.captures+=1;try await Task.sleep(for:.milliseconds(50));return fixture
        },apply:{_,establish,_,progress in
            state.applies+=1;progress("Fixture progress");try await Task.sleep(for:.milliseconds(50))
            var receipt=Receipt();receipt.placed=1;receipt.reused=establish ? 0 : 1;receipt.created=establish ? 1 : 0
            if state.partial {receipt.missing=1;receipt.failures=["Fixture rejected placement"]};return receipt
        })
        let path=root.appendingPathComponent("socket/control.sock").path
        let service=AgentService(preferences:preferences,library:library,backend:backend,endpoint:path)
        defer {service.stop()}
        func call(_ request: AgentRequest) async -> AgentResponse {await service.handle(try! JSONEncoder().encode(request))}
        func request(_ command: AgentCommand,name: String? = nil) -> AgentRequest {
            var request=AgentRequest(command:command);request.name=name
            if command.modifies || command == .windows {request.display=1;request.space=42};return request
        }
        func completed(_ id: UUID) async throws -> AgentJob {
            var poll=AgentRequest(command:.job);poll.jobID=id
            for _ in 0..<100 {
                if let job=await call(poll).result?.job,job.terminal {return job}
                try await Task.sleep(for:.milliseconds(10))
            }
            throw FactoryError("Fixture job did not finish.")
        }
        check(await call(AgentRequest(command:.status)).code=="agent_disabled","disabled router rejects requests")
        try service.setEnabled(true)
        check(service.enabled && preferences.agentAccessEnabled,"enabling starts endpoint and saves preference")
        try AgentSocket.owned((path as NSString).deletingLastPathComponent,type:S_IFDIR,mode:0o700)
        try AgentSocket.owned(path,type:S_IFSOCK,mode:0o600)
        let probeFD=socket(AF_UNIX,SOCK_STREAM,0)
        check(probeFD>=0,"blocking-mode fixture socket opens")
        _=fcntl(probeFD,F_SETFL,O_NONBLOCK)
        AgentSocket.timeouts(probeFD)
        check(fcntl(probeFD,F_GETFL)&O_NONBLOCK == 0,"request streams clear inherited nonblocking mode before bounded reads")
        close(probeFD)
        let wire=try JSONEncoder().encode(AgentRequest(command:.status))
        let responseBytes=try await Task.detached {try AgentSocket.exchange(wire,path:path)}.value
        let response=try AgentResponse.decode(responseBytes)
        check(response.result?.status?.desktops.first?.space==42,"real same-user socket round trip returns structured desktop context")
        let second=AgentListener()
        do {try second.start(path:path){$0};check(false,"second listener must fail")} catch {check(true,"exclusive listener lock")}
        var bad=request(.restore,name:"Fixture");bad.space=43
        check(await call(bad).code=="context_changed" && state.applies==0,"stale desktop does not dispatch")
        state.trusted=false
        check(await call(request(.restore,name:"Fixture")).code=="accessibility_required","permission failure is explicit")
        state.trusted=true;service.extraBusy={true}
        check(await call(request(.restore,name:"Fixture")).code=="busy","busy direct control blocks agent mutation")
        service.extraBusy={false}
        let restore=request(.restore,name:"Fixture")
        let accepted=await call(restore),id=accepted.result!.job!.id
        check(accepted.code=="accepted" && accepted.result?.job?.status=="running","acceptance is not completion")
        let duplicate=await call(restore)
        check(duplicate.result?.job?.id==id,"identical request gets same job")
        var conflicting=restore;conflicting.command = .establish
        check(await call(conflicting).code=="request_conflict","changed arguments cannot reuse request ID")
        check(await call(request(.capture,name:"Other")).code=="busy","second mutation is rejected, not queued")
        let restored=try await completed(id)
        check(restored.status=="succeeded" && restored.receipt?.reused==1 && state.applies==1,"one existing operation produces the structured receipt")
        state.partial=true
        let established=await call(request(.establish,name:"Fixture"))
        let partialJob=try await completed(established.result!.job!.id)
        check(partialJob.status=="partial" && partialJob.receipt?.missing==1,"partial placement is not success")
        state.partial=false
        check(await call(request(.capture,name:"Fixture")).code=="layout_exists" && state.captures==0,"capture never silently replaces")
        let captured=await call(request(.capture,name:"Saved"))
        let capturedJob=try await completed(captured.result!.job!.id)
        check(capturedJob.status=="succeeded" && store.catalog.recipes["Saved"]?.name=="Saved","capture uses store save and reports saved recipe")
        let cancelStart=await call(request(.capture,name:"Cancelled"))
        var cancel=AgentRequest(command:.cancel);cancel.jobID=cancelStart.result!.job!.id
        _=await call(cancel)
        let cancelled=try await completed(cancel.jobID!)
        check(cancelled.status=="cancelled" && store.catalog.recipes["Cancelled"]==nil,"cancelled capture does not save")
        let disabledStart=await call(request(.capture,name:"Disabled"))
        try service.setEnabled(false)
        check(!service.enabled && !preferences.agentAccessEnabled && !FileManager.default.fileExists(atPath:path),"off removes endpoint and saves off state")
        check(await call(AgentRequest(command:.status)).code=="agent_disabled","off blocks already connected work")
        try service.setEnabled(true)
        let disabledJob=try await completed(disabledStart.result!.job!.id)
        check(disabledJob.status=="cancelled" && store.catalog.recipes["Disabled"]==nil,"off cancels only the agent-owned job")
        var staleInstance=AgentRequest(command:.status);staleInstance.instanceID=UUID()
        check(await call(staleInstance).code=="instance_changed","old app instance is rejected")
        let unknown=await service.handle(Data("{\"command\":\"enable\"}".utf8))
        check(!unknown.ok,"CLI cannot enable itself")
        let malformed=await service.handle(Data("not json".utf8))
        check(!malformed.ok,"malformed requests produce structured errors")
        for args in [["restore"],["windows","--display","1","--space","0"],["status","--enable"],["status","--wait"],["capture","--name","x","--display","1","--space","42","--replace","--replace"],["job","--job","bad"]] {
            do {_ = try AgentCLI.parse(args);check(false,"bad CLI arguments accepted")} catch {check(true,"invalid CLI arguments rejected")}
        }
        let parsed=try AgentCLI.parse(["capture","--name","Example","--display","1","--space","42","--wait"])
        check(parsed.request.command == .capture && parsed.waitSeconds==60,"CLI accepts documented invocation")
        let unknownFields=Data("{\"version\":1,\"id\":\"\(UUID().uuidString)\",\"command\":\"status\",\"replace\":false,\"enable\":true}".utf8)
        check(!(await service.handle(unknownFields)).ok,"unknown wire fields rejected")
        var toolDispatches=0
        service.stashedWindowIDs={ [71] }
        check(await call(AgentRequest(command:.status)).result?.status?.lastSpaceMove == nil,"status has no move diagnostic until an attempt exists")
        let moveTrace=SpaceMoveDiagnostics(direction:1,invocation:"fixture")
        moveTrace.report.moveDispatched=true;moveTrace.mark("membership");moveTrace.report.failedCheck="new_input";moveTrace.finish("failed",detail:"Fixture new input")
        service.spaceMoveDiagnostic={moveTrace.report}
        let moveStatus=await call(AgentRequest(command:.status))
        let wireStatus=try AgentResponse.decode(moveStatus.encoded())
        check(wireStatus.result?.status?.lastSpaceMove?.attemptID == moveTrace.report.attemptID && wireStatus.result?.status?.lastSpaceMove?.followDispatched == false,"CLI status exposes the exact structured partial-move report")

        service.connectTools(query:{request in
            AgentToolResult(message:request.command.rawValue)
        },mutate:{request in
            toolDispatches+=1
            try await Task.sleep(for:.milliseconds(35))
            return AgentToolResult(windowID:request.windowID,message:request.command.rawValue)
        })
        check(await call(AgentRequest(command:.status)).result?.status?.stashedWindowIDs == [71],"shared stash IDs are discoverable")
        for command in [AgentCommand.apps,.tilingStatus,.layoutExport] {
            let answer=await call(AgentRequest(command:command))
            check(answer.ok && answer.result?.tools?.message==command.rawValue,"read-only tool query routes without opening UI")
        }
        var toolRequests:[AgentRequest]=[]
        for command in [AgentCommand.appOpen,.newWindow] {var value=request(command);value.bundleID="local.fixture";toolRequests.append(value)}
        var tile=request(.tiling);tile.action="options";tile.gap=12;toolRequests.append(tile)
        var win=request(.window);win.action="geometry";win.windowID=7;win.geometry="centeredHalf";toolRequests.append(win)
        var rename=request(.layoutRename,name:"Fixture");rename.newName="Renamed";toolRequests.append(rename)
        var deletion=request(.layoutDelete,name:"Fixture");deletion.confirm=true;toolRequests.append(deletion)
        var ordering=request(.layoutOrder);ordering.names=["Fixture"];toolRequests.append(ordering)
        var importing=request(.layoutImport);var catalog=Catalog();catalog.recipes[fixture.name]=fixture;importing.catalog=catalog;toolRequests.append(importing)
        for value in toolRequests {
            let before=toolDispatches
            let start=await call(value);check(start.code=="accepted","tool mutation is a tracked job")
            let duplicate=await call(value)
            check(duplicate.result?.job?.id==start.result?.job?.id,"tool retry returns same job")
            let finish=try await completed(start.result!.job!.id)
            check(finish.status=="succeeded" && finish.tools?.message==value.command.rawValue && toolDispatches==before+1,"tool receipt is terminal and dispatch occurs once")
        }
        let contextFlags=["--display","1","--space","42"]
        let invalidToolArgs:[[String]]=[
            ["app-open","--bundle-id","bad/path"]+contextFlags,
            ["window","--action","geometry","--window","7","--geometry","unknown"]+contextFlags,
            ["window","--action","focus","--window","7","--direction","1"]+contextFlags,
            ["tiling","--action","options"]+contextFlags,
            ["tiling","--action","split","--split",UUID().uuidString,"--ratio","0.99"]+contextFlags,
            ["tiling","--action","float"]+contextFlags,
            ["layout-delete","--name","Fixture"]+contextFlags,
            ["layout-order","--names-json","[\"Fixture\",\"Fixture\"]"]+contextFlags,
            ["status","--action","enable"]]
        for args in invalidToolArgs {do{_ = try AgentCLI.parse(args);check(false,"invalid tool arguments accepted")}catch{check(true,"strict action fields rejected before dispatch")}}
        var cancelTool=request(.newWindow);cancelTool.bundleID="local.fixture"
        let toolStart=await call(cancelTool)
        var cancelToolRequest=AgentRequest(command:.cancel);cancelToolRequest.jobID=toolStart.result!.job!.id
        _=await call(cancelToolRequest)
        check(try await completed(toolStart.result!.job!.id).status=="cancelled","tool cancellation shares job cancellation")
        service.stop()
        let unsafe=root.appendingPathComponent("unsafe").path
        try FileManager.default.createDirectory(atPath:unsafe,withIntermediateDirectories:false,attributes:[.posixPermissions:0o755])
        do {try AgentListener().start(path:unsafe+"/control.sock"){$0};check(false,"public directory accepted")} catch {check(true,"unsafe permissions rejected")}
        let link=root.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath:link,withDestinationPath:unsafe)
        do {try AgentSocket.owned(link,type:S_IFDIR,mode:0o700);check(false,"symlink accepted")} catch {check(true,"endpoint symlink rejected")}
        for interruption in ["disabled","transport"] {
            var calls=0
            let (data,exitCode)=AgentCLI.execute(["restore","--name","Fixture","--display","1","--space","42","--wait"],call:{request in
                calls+=1
                if calls==1 {
                    let job=AgentJob(id:UUID(),requestID:request.id,command:.restore,name:"Fixture",context:target,startedAt:Date())
                    return AgentResponse(requestID:request.id,ok:true,code:"accepted",result:AgentPayload(job:job))
                }
                if interruption=="transport" {throw AgentFailure("transport_error","Fixture disconnect")}
                return .failure(AgentFailure("agent_disabled","Fixture switch off"),id:request.id)
            })
            let response=try AgentResponse.decode(data)
            check(exitCode==1 && !response.ok && response.result?.job != nil,"waiting retains last known job after \(interruption)")
            check(calls==2 && response.requestID==response.result?.job?.requestID,"waiting never resubmits mutation and preserves original request ID")
        }
        var pair: [Int32]=[0,0]
        guard socketpair(AF_UNIX,SOCK_STREAM,0,&pair)==0 else {throw FactoryError("Test socketpair failed.")}
        defer {close(pair[0]);close(pair[1])}
        AgentSocket.timeouts(pair[0]);AgentSocket.timeouts(pair[1])
        try AgentSocket.send(pair[0],Data("framed".utf8))
        let framed=try AgentSocket.receive(pair[1])
        check(framed == Data("framed".utf8),"transport framing round trip")
        var tooLarge=UInt32(AgentSocket.limit+1).bigEndian
        _=withUnsafeBytes(of:&tooLarge){Darwin.write(pair[0],$0.baseAddress,4)}
        do {_ = try AgentSocket.receive(pair[1]);check(false,"oversized frame accepted")} catch {check(true,"oversized packet rejected before allocation")}
        do {_ = try AgentSocket.address(String(repeating:"x",count:200));check(false,"long path accepted")} catch {check(true,"overlong Unix socket path rejected")}
        check(!library.window.isVisible,"all command tests leave app UI hidden")
        print("native agent CLI: \(assertions) assertions passed; fixture-only operations, no desktop changes or global hotkeys")
    }
}
