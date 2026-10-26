import AppKit

@MainActor
final class DirectSpaceMoveControls {
    private let preferences: FactoryPreferences
    private let hud = GeometryHUD()
    private var task: Task<Void,Never>?
    var active = false
    private var agentRunning=false
    var isMoving: Bool { task != nil || agentRunning }
    var lastResult = "Native Space movement is disabled."
    var willMove: (()->Void)?
    var workspaceBusy: () -> Bool = { false }
    var changed: (() -> Void)?
    init(preferences: FactoryPreferences) { self.preferences = preferences }
    func enable() throws {
        guard AXIsProcessTrusted(),WFSpaceMoveAvailable() else { throw FactoryError("Accessibility and the native Space bridge are required for move-and-follow.") }
        var failed: UInt32 = 0
        let status = WFRegisterSpaceMoveHotKeys({ index,context in
            MainActor.assumeIsolated { Unmanaged<DirectSpaceMoveControls>.fromOpaque(context).takeUnretainedValue().run(index == 0 ? -1 : 1) }
        },Unmanaged.passUnretained(self).toOpaque(),&failed)
        guard status == 0 else { active = false; lastResult = "Space shortcut registration failed at arrow \(failed) (status \(status)); other groups are unchanged."; changed?(); throw FactoryError(lastResult) }
        active = true; preferences.spaceMoveEnabled = true
        lastResult = "Native move-and-follow enabled: Tab + Left / Right."; changed?()
    }
    func disable() {
        WFUnregisterSpaceMoveHotKeys(); task?.cancel(); active = false; preferences.spaceMoveEnabled = false
        lastResult = "Space arrows released; the Hammerspoon fallback can be enabled."; changed?()
    }
    func restorePreference() {
        if preferences.spaceMoveEnabled { do { try enable() } catch { preferences.spaceMoveEnabled = false; lastResult = error.localizedDescription; changed?() } }
    }
    private func read(_ element: AXUIElement) throws -> Frame {
        var rect = CGRect.zero
        guard WFReadFrame(element,&rect),rect.width>0,rect.height>0 else { throw FactoryError("Window frame unavailable.") }
        return Frame(x:rect.minX,y:rect.minY,w:rect.width,h:rect.height)
    }
    private func topology(_ display: UInt32) throws -> [SpaceMoveEntry] {
        guard let entries = WFSwitcherSpaces(display) as? [[String:Any]] else { throw FactoryError("Ordered desktops unavailable.") }
        return try entries.map { entry in
            guard let id = entry["id"] as? NSNumber,let kind = entry["kind"] as? NSNumber else { throw FactoryError("Desktop membership unavailable.") }
            return SpaceMoveEntry(id:id.uint64Value,kind:kind.intValue)
        }
    }
    private func snapshot() throws -> (LiveWindow,Context) {
        guard AXIsProcessTrusted(),let app = NSWorkspace.shared.frontmostApplication,let bundle = app.bundleIdentifier,
              app.activationPolicy == .regular,!app.isHidden,bundle != Bundle.main.bundleIdentifier,bundle != "org.hammerspoon.Hammerspoon",
              !bundle.lowercased().contains("1password"),!bundle.lowercased().contains("onepassword"),
              bundle != "com.apple.Passwords",bundle != "com.apple.keychainaccess" else { throw FactoryError("Focus a regular application window first.") }
        let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root,0.15)
        guard let element = axElement(attribute(root,kAXFocusedWindowAttribute)),attribute(element,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { throw FactoryError("No focused standard window.") }
        let frame = try read(element),id = WFWindowID(element)
        guard id != 0 else { throw FactoryError("Exact window identity unavailable.") }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let rect = CGRect(x:frame.x,y:frame.y,width:frame.w,height:frame.h)
        let display = NSScreen.screens.max { a,b in
            func area(_ s: NSScreen) -> Double {
                let f = s.frame,i = rect.intersection(CGRect(x:f.minX,y:top-f.maxY,width:f.width,height:f.height))
                return i.isNull ? 0 : i.width*i.height
            }
            return area(a)<area(b)
        }
        guard let display else { throw FactoryError("Display unavailable.") }
        let context = try Context(screen:display)
        let window = LiveWindow(id:id,pid:app.processIdentifier,bundleID:bundle,appName:app.localizedName ?? bundle,element:element,frame:frame)
        try window.eligible(in:context)
        return (window,context)
    }
    private struct Prepared {let entries: [SpaceMoveEntry];let plan: SpaceMovePlan;let sourceWindows: [(UInt32,pid_t)];let input: [UInt32]}
    private func inputCounts()->[UInt32] {[CGEventType.keyDown,.leftMouseDown,.rightMouseDown,.otherMouseDown].map{CGEventSource.counterForEventType(.combinedSessionState,eventType:$0)}}
    private func prepare(_ direction: Int,window: LiveWindow,context: Context)throws->Prepared {
            let entries = try topology(context.display)
            let plan = try SpaceMovement.plan(entries,current:context.space,direction:direction)
            let sourceWindows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []).compactMap { entry -> (UInt32,pid_t)? in
                guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,id != window.id,
                      let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,pid != ProcessInfo.processInfo.processIdentifier,
                      (entry[kCGWindowLayer as String] as? Int) == 0,WFWindowSpaces(id)?.map(\.uint64Value) == [plan.source] else { return nil }
                return (id,pid)
            }
        return Prepared(entries:entries,plan:plan,sourceWindows:sourceWindows,input:inputCounts())
    }
    private func perform(_ direction: Int,window: LiveWindow,context: Context,prepared: Prepared) async throws {
        let entries=prepared.entries,plan=prepared.plan,sourceWindows=prepared.sourceWindows,startingInput=prepared.input
                var moved = false,followed = false
                do {
                    @MainActor func current() throws -> UInt64 {
                        var id: UInt64 = 0,kind: Int32 = -1
                        guard WFContext(context.display,&id,&kind),kind == 0 else { throw FactoryError("Ordinary desktop unavailable; operation stopped.") }
                        return id
                    }
                    @MainActor func identity() throws {
                        try Task.checkCancellation()
                        guard inputCounts() == startingInput else { throw FactoryError("New keyboard or pointer input; Space command stopped.") }
                        guard (!workspaceBusy() || agentRunning),
                              NSRunningApplication(processIdentifier:window.pid)?.bundleIdentifier == window.bundleID,
                              NSRunningApplication(processIdentifier:window.pid)?.isHidden == false,
                              WFWindowID(window.element) == window.id,
                              attribute(window.element,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                              (attribute(window.element,kAXMinimizedAttribute) as? Bool) != true,
                              (attribute(window.element,"AXFullScreen") as? Bool) != true else { throw FactoryError("Application or window eligibility changed; Space command stopped.") }
                        let fresh = try topology(context.display)
                        guard fresh.map(\.id) == entries.map(\.id),fresh.map(\.kind) == entries.map(\.kind) else { throw FactoryError("Desktop order changed; Space command stopped.") }
                    }
                    try await SpaceMovement.perform(plan,check:{ phase in
                        try identity()
                        let shown = try current()
                        switch phase {
                        case .beforeMove:
                            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { throw FactoryError("Foreground application changed before movement.") }
                            try window.eligible(in:context)
                            let root = AXUIElementCreateApplication(window.pid); AXUIElementSetMessagingTimeout(root,0.1)
                            guard let focused = axElement(attribute(root,kAXFocusedWindowAttribute)),WFWindowID(focused) == window.id else { throw FactoryError("Focused window changed before movement.") }
                        case .membership,.beforeFollow:
                            guard shown == plan.source else { throw FactoryError("Desktop changed before follow; command stopped.") }
                        case .following:
                            guard shown == plan.source || shown == plan.destination else { throw FactoryError("User selected another desktop; command stopped.") }
                        case .finish:
                            guard shown == plan.destination else { throw FactoryError("Destination changed before focus restoration.") }
                        }
                    },move:{
                        let sent = WFMoveWindowToAdjacentSpace(window.element,window.pid,context.display,plan.source,plan.destination)
                        moved = sent; return sent
                    },membership:{
                        guard let ids = WFWindowSpaces(window.id)?.map(\.uint64Value) else { throw FactoryError("Window membership unavailable.") }
                        return ids
                    },follow:{
                        let sent = WFSwitcherSelectSpace(context.display,plan.source,plan.destination)
                        followed = sent; return sent
                    },destinationVisible:{
                        guard try current() == plan.destination else { return false }
                        let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
                        let targetVisible = infos.contains{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.id && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == window.pid}
                        let originHidden = sourceWindows.allSatisfy { id,pid in
                            !infos.contains{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid}
                        }
                        return targetVisible && originHidden
                    },finish:{
                        let destination = try Context(screen:context.screen)
                        try window.eligible(in:destination)
                        @MainActor func checkDestination() throws {
                            try identity(); try window.eligible(in:destination)
                            guard try current() == plan.destination else { throw FactoryError("Destination changed; frame/focus restoration stopped.") }
                        }
                        if !(try read(window.element)).matches(window.frame) {
                            let actual = try await DirectFrameApplication.apply(target:window.frame,from:read(window.element),check:checkDestination,read:{try self.read(window.element)},write:{kind,f in
                                let status = kind == .position ? WFSetPosition(window.element,CGPoint(x:f.x,y:f.y)) : WFSetSize(window.element,CGSize(width:f.w,height:f.h))
                                guard status == .success else { throw FactoryError("App rejected moved-window frame restoration.") }
                            },submit:{
                                let f = window.frame
                                guard WFApplyDirectFrame(window.element,CGRect(x:f.x,y:f.y,width:f.w,height:f.h)) == .success else { throw FactoryError("App rejected moved-window frame restoration.") }
                            })
                            guard actual.matches(window.frame) else { throw FactoryError("Moved and followed, but the saved frame was not reached.") }
                        }
                        try checkDestination()
                        try await SpaceMovement.restoreFocus(check:checkDestination,request:{
                            var main: Int32 = 0,raised: Int32 = 0
                            let status = WFRequestWindowFocus(window.element,window.pid,&main,&raised)
                            guard status == 0 else { throw FactoryError("Moved and followed, but focus activation failed (status \(status)).") }
                        },focused:{
                            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { return false }
                            let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system,0.1)
                            guard let root = axElement(attribute(system,kAXFocusedApplicationAttribute)) else { return false }
                            var pid: pid_t = 0
                            guard AXUIElementGetPid(root,&pid) == .success,pid == window.pid else { return false }
                            AXUIElementSetMessagingTimeout(root,0.1)
                            guard let focused = axElement(attribute(root,kAXFocusedWindowAttribute)) else { return false }
                            return WFWindowID(focused) == window.id
                        })
                    })
                    lastResult="\(direction<0 ? "←" : "→") Desktop \(plan.ordinal): exact window moved, followed and focused."
                }catch is CancellationError{throw CancellationError()}catch{
                    let prefix=moved ? (followed ? "Move/follow dispatched. " : "Move dispatched. ") : ""
                    throw FactoryError(prefix+error.localizedDescription)
                }
    }
    func run(_ direction: Int) {
        guard active,!isMoving,!workspaceBusy() else{return}
        do {
            let (window,context)=try snapshot();willMove?();let prepared=try prepare(direction,window:window,context:context)
            task=Task{@MainActor [weak self] in
                guard let self else{return};defer{task=nil;changed?()}
                do{try await perform(direction,window:window,context:context,prepared:prepared);hud.show(lastResult,on:context.screen)}
                catch is CancellationError{lastResult="Space command cancelled; verify the moved window's desktop."}
                catch{lastResult=error.localizedDescription;hud.show(lastResult,on:context.screen)}
            }
        }catch{lastResult=error.localizedDescription;hud.show(lastResult);changed?()}
    }
    func forAgent(_ direction: Int,id: UInt32,context: Context) async throws->UInt64 {
        guard !isMoving else{throw AgentFailure("busy","Space owner is busy.")}
        let (window,actual)=try snapshot()
        guard window.id==id,actual.display==context.display,actual.space==context.space else{throw AgentFailure("window_changed","Exact move target changed.")}
        agentRunning=true;defer{agentRunning=false;changed?()};willMove?()
        let prepared=try prepare(direction,window:window,context:actual)
        try await perform(direction,window:window,context:actual,prepared:prepared)
        return prepared.plan.destination
    }
    func stop() { WFUnregisterSpaceMoveHotKeys(); task?.cancel(); active = false; hud.stop() }
}
