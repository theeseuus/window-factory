import AppKit

@MainActor
final class AgentDirectWindows {
    let geometry: DirectWindowControls,stash: DirectStashControls,move: DirectSpaceMoveControls,accordion: DirectAccordionControls
    init(geometry: DirectWindowControls,stash: DirectStashControls,move: DirectSpaceMoveControls,accordion: DirectAccordionControls){self.geometry=geometry;self.stash=stash;self.move=move;self.accordion=accordion}
    private func focus(_ window: LiveWindow,_ context: Context) async throws {
        let origin=NSWorkspace.shared.frontmostApplication?.processIdentifier
        try await SpaceMovement.restoreFocus(check:{
            try window.eligible(in:context)
            let front=NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front==origin || front==window.pid else{throw AgentFailure("focus_changed","User focus changed; explicit focus operation stopped.")}
        },request:{
            var main:Int32=0,raised:Int32=0
            guard WFRequestWindowFocus(window.element,window.pid,&main,&raised)==0 else{throw FactoryError("Application refused focus.")}
        },focused:{
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier==window.pid else{return false}
            let root=AXUIElementCreateApplication(window.pid);AXUIElementSetMessagingTimeout(root,0.1)
            return axElement(attribute(root,kAXFocusedWindowAttribute)).map{WFWindowID($0)==window.id} ?? false
        })
    }
    func perform(_ request: AgentRequest,context: Context,window: LiveWindow?) async throws->AgentToolResult {
        let id=request.windowID!,action=request.action!
        if action=="stash" || action=="restore-stash" {
            let frame=try await stash.forAgent(id:id,restoring:action=="restore-stash",window:window,context:context)
            return AgentToolResult(windowID:id,frame:frame,message:stash.lastResult)
        }
        guard let window else{throw AgentFailure("window_not_found","Exact window is unavailable.")}
        try window.eligible(in:context)
        switch action {
        case "geometry":try await geometry.forAgent(GeometryCommand(rawValue:request.geometry!)!,window:window,context:context)
        case "focus":try await focus(window,context)
        case "move-space":
            try await focus(window,context)
            let destination=try await move.forAgent(request.direction!,id:id,context:context)
            return AgentToolResult(windowID:id,message:"Moved, followed and focused on desktop ID \(destination).")
        case "accordion":try await focus(window,context);try await accordion.forAgent(id:id,context:context)
        default:throw AgentFailure("invalid_action","Unknown window operation.")
        }
        var rect=CGRect.zero
        guard WFReadFrame(window.element,&rect) else{throw AgentFailure("frame_unavailable","Operation dispatched; resulting frame is unavailable.")}
        return AgentToolResult(windowID:id,frame:Frame(x:rect.minX,y:rect.minY,w:rect.width,h:rect.height),message:"Exact window operation verified.")
    }
}
