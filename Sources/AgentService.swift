import AppKit

@MainActor
final class AgentService {
    let instanceID = UUID()
    private let preferences: FactoryPreferences
    private let library: LibraryWindow
    private let listener = AgentListener()
    private var backend: AgentBackend
    private let endpoint: String
    private var generation = UUID()
    private var jobs: [UUID:AgentJob] = [:]
    private var order: [UUID] = []
    private var seen: [UUID:AgentRequest] = [:]
    private var requestJobs: [UUID:UUID] = [:]
    private var activeJob: UUID?
    var stashedWindowIDs: ()->[UInt32] = {[]}
    var extraBusy: ()->Bool = { false }
    var changed: (()->Void)?
    private(set) var enabled = false
    init(preferences: FactoryPreferences,library: LibraryWindow,backend: AgentBackend? = nil,endpoint: String = AgentSocket.path) {self.preferences=preferences;self.library=library;self.backend=backend ?? .live(library);self.endpoint=endpoint}
    var ownedCommand: AgentCommand? {activeJob.flatMap{jobs[$0]?.command}}
    func connectTools(query: @escaping @MainActor (AgentRequest) async throws->AgentToolResult,mutate: @escaping @MainActor (AgentRequest) async throws->AgentToolResult) {backend.toolQuery=query;backend.toolMutate=mutate}
    func setEnabled(_ value: Bool) throws {
        if value {
            guard !enabled else {return}
            let epoch=UUID();generation=epoch
            try listener.start(path:endpoint) { [weak self] data in
                guard let self,self.enabled,self.generation==epoch else {return AgentResponse.failure(AgentFailure("agent_disabled","Agent access is disabled.")).encoded()}
                let response=await self.handle(data)
                guard self.enabled,self.generation==epoch else {return AgentResponse.failure(AgentFailure("agent_disabled","Agent access was disabled during the request.")).encoded()}
                return response.encoded()
            }
            enabled=true;preferences.agentAccessEnabled=true
        } else {
            enabled=false;generation=UUID();listener.stop()
            if activeJob != nil {library.task?.cancel()}
            preferences.agentAccessEnabled=false
        }
        changed?()
    }
    func restorePreference() throws {if preferences.agentAccessEnabled {try setEnabled(true)}}
    func stop() {enabled=false;generation=UUID();listener.stop();if activeJob != nil {library.task?.cancel()}}
    private var busy: Bool {library.task != nil || library.frozen != nil || extraBusy()}
    private func status() -> AgentStatus {
        AgentStatus(instanceID:instanceID,agentAccess:enabled,accessibility:backend.accessibility(),busy:busy,desktops:backend.desktops(),stashedWindowIDs:stashedWindowIDs())
    }
    func handle(_ data: Data) async -> AgentResponse {
        var request: AgentRequest?
        do {
            guard enabled else {throw AgentFailure("agent_disabled","Agent access is disabled.")}
            let decoded=try AgentRequest.decode(data);request=decoded
            if let instance=decoded.instanceID,instance != instanceID {throw AgentFailure("instance_changed","Window Factory restarted. Reconcile current status before submitting a new operation.")}
            var payload=AgentPayload()
            switch decoded.command {
            case .status: payload.status=status()
            case .capabilities: payload.commands=AgentCommand.allCases.map(\.rawValue);payload.status=status()
            case .layouts: payload.layouts=library.store.catalog.recipes.values.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
            case .windows:
                guard backend.accessibility() else {throw AgentFailure("accessibility_required","Window Factory needs Accessibility access for live windows.")}
                let context=try backend.context(decoded)
                let windows=try await backend.windows(context)
                guard enabled else {throw AgentFailure("agent_disabled","Agent access is disabled.")}
                payload.windows=windows
            case .capture,.restore,.establish,.appOpen,.newWindow,.tiling,.window,.layoutRename,.layoutDelete,.layoutOrder,.layoutImport:
                payload.job=try submit(decoded)
            case .apps,.tilingStatus,.layoutExport:
                payload.tools=try await backend.toolQuery(decoded)
                guard enabled else{throw AgentFailure("agent_disabled","Agent access was disabled.")}
            case .job:
                guard let id=decoded.jobID,let job=jobs[id] else {throw AgentFailure("job_not_found","Job is unknown or its result expired; it has not been resubmitted.")};payload.job=job
            case .cancel:
                guard let id=decoded.jobID,let job=jobs[id] else {throw AgentFailure("job_not_found","Job is unknown or its result expired.")}
                if activeJob==id {library.task?.cancel()}
                payload.job=job
            }
            return AgentResponse(requestID:decoded.id,instanceID:instanceID,ok:true,code:payload.job?.terminal == false ? "accepted" : "ok",result:payload)
        } catch {return .failure(error,id:request?.id,instance:instanceID)}
    }
    private func submit(_ request: AgentRequest) throws -> AgentJob {
        if let previous=seen[request.id] {
            guard previous==request else {throw AgentFailure("request_conflict","This request ID was used with different arguments.")}
            guard let id=requestJobs[request.id],let job=jobs[id] else {throw AgentFailure("result_expired","This request already ran; its result expired. It will not be repeated.")}
            return job
        }
        guard seen.count<4096 else {throw AgentFailure("history_full","This app session reached its request limit. Reconcile jobs before restarting Window Factory.")}
        guard !busy,NSApp.modalWindow==nil,library.window.attachedSheet==nil else {throw AgentFailure("busy","Finish the current Window Factory operation first; nothing was queued.")}
        guard backend.accessibility() else {throw AgentFailure("accessibility_required","Window Factory needs Accessibility access for layout operations.")}
        try backend.requireAccess()
        let context=try backend.context(request),name=request.name ?? request.command.rawValue
        let recipe=library.store.catalog.recipes[name]
        if request.command == .capture {
            if recipe != nil && !request.replace {throw AgentFailure("layout_exists","Use --replace explicitly to replace this layout.")}
        } else if [.restore,.establish,.layoutRename,.layoutDelete].contains(request.command),recipe==nil {throw AgentFailure("layout_not_found","No saved layout has that exact name.")}
        let job=AgentJob(id:UUID(),requestID:request.id,command:request.command,name:name,context:context,startedAt:Date())
        seen[request.id]=request;requestJobs[request.id]=job.id;jobs[job.id]=job;order.append(job.id);activeJob=job.id
        while order.count>100 {let oldest=order.removeFirst();jobs.removeValue(forKey:oldest)}
        library.task=Task { @MainActor [weak self] in
            guard let self else {return}
            defer {activeJob=nil;library.task=nil;library.updateButtons();changed?()}
            do {
                try Task.checkCancellation();_ = try backend.context(request)
                if request.command.toolMutation {
                    jobs[job.id]?.sideEffectsPossible=true
                    jobs[job.id]?.tools=try await backend.toolMutate(request)
                    try Task.checkCancellation();guard enabled else{throw CancellationError()}
                    jobs[job.id]?.status="succeeded"
                } else if request.command == .capture {
                    var captured=try await backend.capture(context)
                    try Task.checkCancellation();guard enabled else {throw CancellationError()}
                    captured.name=name;_ = try backend.context(request)
                    jobs[job.id]?.sideEffectsPossible=true
                    try library.store.save(captured,replace:request.replace)
                    jobs[job.id]?.recipe=captured;library.reload(select:name)
                    jobs[job.id]?.status="succeeded"
                } else {
                    jobs[job.id]?.sideEffectsPossible=true
                    let receipt=try await backend.apply(recipe!,request.command == .establish,context) { [weak self] progress in self?.jobs[job.id]?.progress=progress }
                    library.lastReceipt=receipt;jobs[job.id]?.receipt=receipt
                    jobs[job.id]?.status=receipt.missing>0 || !receipt.failures.isEmpty ? "partial" : "succeeded"
                }
                jobs[job.id]?.progress="Finished"
            } catch is CancellationError {
                jobs[job.id]?.status="cancelled";jobs[job.id]?.error=AgentFailure("cancelled","Completed changes are retained; cancellation does not undo them.")
            } catch {
                jobs[job.id]?.status="failed";jobs[job.id]?.error=error as? AgentFailure ?? AgentFailure("operation_failed",error.localizedDescription)
            }
            jobs[job.id]?.finishedAt=Date()
        }
        library.updateButtons();return job
    }
}
