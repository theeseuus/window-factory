import AppKit

// The adapter is injectable for IPC/job tests. Production closures call the
// library's exact Coordinator/MacServices instance; there is no second engine.
@MainActor
struct AgentBackend {
    var accessibility: @MainActor ()->Bool
    var requireAccess: @MainActor () throws -> Void
    var desktops: @MainActor ()->[AgentDesktop]
    var context: @MainActor (AgentRequest) throws -> AgentDesktop
    var windows: @MainActor (AgentDesktop) async throws -> [AgentWindow]
    var capture: @MainActor (AgentDesktop) async throws -> Recipe
    var apply: @MainActor (Recipe,Bool,AgentDesktop,@escaping @MainActor (String)->Void) async throws -> Receipt
    var toolQuery: @MainActor (AgentRequest) async throws->AgentToolResult = {_ in throw AgentFailure("unavailable","Tool backend is unavailable.")}
    var toolMutate: @MainActor (AgentRequest) async throws->AgentToolResult = {_ in throw AgentFailure("unavailable","Tool backend is unavailable.")}
    static func live(_ library: LibraryWindow) -> Self {
        func resolve(_ display: UInt32?,_ space: UInt64?) throws -> Context {
            guard let display,let space,let screen=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==display}) else {throw AgentFailure("context_changed","Requested display is unavailable.")}
            let context=try Context(screen:screen)
            guard context.space==space else {throw AgentFailure("context_changed","Requested desktop is no longer active on that display. Nothing was started.")}
            return context
        }
        func desktop(_ context: Context) -> AgentDesktop {AgentDesktop(display:context.display,space:context.space,frame:context.frame)}
        return Self(accessibility:{AXIsProcessTrusted()},requireAccess:{try library.coordinator.services.requireAccess()},desktops:{NSScreen.screens.compactMap{try? desktop(Context(screen:$0))}},context:{try desktop(resolve($0.display,$0.space))},windows:{ target in
            try await library.coordinator.services.collect(resolve(target.display,target.space)).map{AgentWindow(id:$0.id,pid:$0.pid,bundleID:$0.bundleID,appName:$0.appName,frame:$0.frame)}
        },capture:{target in try await library.coordinator.services.capture(resolve(target.display,target.space))},apply:{recipe,establish,target,progress in
            try await library.coordinator.apply(recipe,establish:establish,context:resolve(target.display,target.space),progress:{progress($0)})
        })
    }
}
