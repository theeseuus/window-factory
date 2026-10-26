import AppKit

// API composition only: requests call the existing app, creation, tiling, store
// and direct-control owners. The router supplies serialization/access/idempotency.
@MainActor
final class AgentTools {
    let library: LibraryWindow,apps: ApplicationLauncher,creation: NewWindowAction,tiling: TilingController
    var windowOperation: (AgentRequest,Context,LiveWindow?) async throws->AgentToolResult = {_,_,_ in throw AgentFailure("unavailable","Direct window backend unavailable.")}
    init(library: LibraryWindow,apps: ApplicationLauncher,creation: NewWindowAction,tiling: TilingController){self.library=library;self.apps=apps;self.creation=creation;self.tiling=tiling}
    func context(_ request: AgentRequest)throws->Context {
        guard let display=request.display,let space=request.space,let screen=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==display}) else{throw AgentFailure("context_changed","Requested display unavailable.")}
        let value=try Context(screen:screen);guard value.space==space else{throw AgentFailure("context_changed","Requested ordinary desktop is not active.")};return value
    }
    func snapshot()throws->AgentTiling {
        let plan=(try? tiling.plan()) ?? TilePlan()
        return AgentTiling(enabled:tiling.enabled,paused:tiling.paused,busy:tiling.hasPendingWork,display:tiling.desktop?.display,space:tiling.desktop?.space,selected:tiling.selected,tiled:plan.frames.keys.sorted().map{AgentTile(windowID:$0,plannedFrame:plan.frames[$0]!,observedFrame:tiling.known[$0]?.frame)},floating:tiling.floating.sorted(),parked:tiling.suspended.sorted(),splits:plan.dividers.map{AgentSplit(id:$0.id,axis:$0.axis.rawValue,ratio:$0.ratio,region:$0.region)},gap:tiling.options.gap,margin:tiling.options.margin,axis:tiling.options.axis.rawValue,message:tiling.message,excluded:tiling.options.excluded.sorted(),undoAvailable:!tiling.originals.isEmpty)
    }
    func orderedNames()->[String]{LibraryPresentation.ordered(Array(library.store.catalog.recipes.values),savedOrder:library.preferences.layoutOrder,query:"").map(\.name)}
    func query(_ request: AgentRequest) async throws->AgentToolResult {
        switch request.command {
        case .apps:
            let running=Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let values=ApplicationsWindow.inventory(extra:apps.entries).filter{TilingEvents.allowed($0.bundleID) && $0.bundleID != Bundle.main.bundleIdentifier}.map{AgentApp(bundleID:$0.bundleID,name:$0.name,path:$0.path,running:running.contains($0.bundleID))}
            return AgentToolResult(apps:values)
        case .tilingStatus:return AgentToolResult(tiling:try snapshot())
        case .layoutExport:return AgentToolResult(catalog:library.store.catalog,names:orderedNames())
        default:throw AgentFailure("invalid_command","Not a tool query.")
        }
    }
    func mutate(_ request: AgentRequest) async throws->AgentToolResult {
        let target=try context(request);try Task.checkCancellation()
        switch request.command {
        case .appOpen:
            let pid=try await apps.forAgent(request.bundleID!)
            return AgentToolResult(pid:pid,message:"Application activation verified.")
        case .newWindow:
            let receipt=try await creation.forAgent(request.bundleID!,target:NewWindowTarget(display:target.display,space:target.space,frame:target.frame))
            return AgentToolResult(display:target.display,space:target.space,windowID:receipt.windowID,message:"One new window confirmed on the requested desktop.")
        case .tiling:return try await tilingAction(request,target)
        case .window:
            let window=try await library.coordinator.services.collect(target).first{$0.id==request.windowID}
            if !["stash","restore-stash"].contains(request.action ?? ""),window==nil{throw AgentFailure("window_not_found","Exact eligible window was not found on that desktop.")}
            return try await windowOperation(request,target,window)
        case .layoutRename:
            let previousOrder=orderedNames();try library.store.rename(request.name!,to:request.newName!);library.preferences.layoutOrder=previousOrder.map{$0==request.name! ? request.newName! : $0};library.reload(select:request.newName)
            return AgentToolResult(names:orderedNames(),message:"Layout renamed.")
        case .layoutDelete:
            guard library.store.catalog.recipes[request.name!] != nil else{throw AgentFailure("layout_not_found","Layout no longer exists.")}
            try library.store.delete(request.name!);library.preferences.layoutOrder=library.preferences.layoutOrder.filter{$0 != request.name!};library.reload()
            return AgentToolResult(names:orderedNames(),message:"Layout deleted; previous catalog retained by the store.")
        case .layoutOrder:
            guard Set(request.names!)==Set(library.store.catalog.recipes.keys) else{throw AgentFailure("invalid_order","Include every current layout name exactly once.")}
            library.preferences.layoutOrder=request.names!;library.reload();return AgentToolResult(names:orderedNames(),message:"Layout order saved.")
        case .layoutImport:
            try library.store.merge(request.catalog!);library.reload();return AgentToolResult(catalog:library.store.catalog,names:orderedNames(),message:"Catalog merged without overwriting conflicts.")
        default:throw AgentFailure("invalid_command","Not a tool mutation.")
        }
    }
    private func tilingAction(_ request: AgentRequest,_ target: Context) async throws->AgentToolResult {
        let action=request.action!
        if let desktop=tiling.desktop,desktop.display != target.display || desktop.space != target.space{throw AgentFailure("context_changed","The tiling session belongs to another desktop.")}
        guard ["enable","options"].contains(action) || tiling.enabled else{throw AgentFailure("tiling_disabled","Enable a session before editing it.")}
        tiling.agentOperation=true;defer{tiling.agentOperation=false}
        do {
            switch action {
            case "enable":if !tiling.enabled{tiling.enable()}
            case "disable":tiling.disable()
            case "pause":tiling.pause()
            case "resume":tiling.resume()
            case "select","float","rejoin","swap":
                guard let id=request.windowID,tiling.known[id] != nil else{throw AgentFailure("window_not_found","Window is not a member of this tiling session.")}
                tiling.select(id)
                if action=="float",!tiling.floating.contains(id){tiling.toggleFloat()}
                if action=="rejoin" {
                    guard !tiling.suspended.contains(id),tiling.visible.contains(id) else{throw AgentFailure("window_parked","Restore/unhide the window before rejoining.")}
                    if tiling.floating.contains(id){tiling.toggleFloat()}
                }
                if action=="swap"{tiling.swapNext()}
            case "split":
                guard let id=request.splitID,(try tiling.plan()).dividers.contains(where:{$0.id==id}) else{throw AgentFailure("split_not_found","Split is not in the current visible tree.")}
                tiling.editSplit(id,ratio:request.ratio,axis:request.axis.flatMap(TileAxis.init(rawValue:)))
            case "balance":tiling.balance()
            case "restore-positions":tiling.restoreOriginals()
            case "options":
                if let value=request.gap{tiling.options.gap=value};if let value=request.margin{tiling.options.margin=value};if let value=request.axis.flatMap(TileAxis.init(rawValue:)){tiling.options.axis=value}
            default:throw AgentFailure("invalid_action","Unknown tiling action.")
            }
            for _ in 0..<240 {
                try Task.checkCancellation();try target.check()
                if !tiling.hasPendingWork{break}
                try await Task.sleep(for:.milliseconds(50))
            }
            guard !tiling.hasPendingWork else{tiling.pause("Agent tiling operation timed out");throw AgentFailure("operation_timeout","Tiling paused after its bounded deadline; reconcile status before another action.")}
            if ["enable","resume","split","balance","swap","float","rejoin"].contains(action),tiling.paused{throw AgentFailure("placement_failed",tiling.message)}
            if action=="enable",!tiling.enabled{throw AgentFailure("operation_failed",tiling.message)}
            return AgentToolResult(tiling:try snapshot(),message:tiling.message)
        }catch{if Task.isCancelled{tiling.pause("Agent operation cancelled")};throw error}
    }
}
