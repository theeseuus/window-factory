import AppKit

@MainActor
final class DirectAccordionControls {
    private let preferences: FactoryPreferences
    private let hud = GeometryHUD()
    private var task: Task<Void,Never>?
    private var agentRunning=false
    var isBusy: Bool { task != nil || agentRunning }
    var active = false
    var lastResult = "Native accordion is disabled."
    var willArrange: (()->Void)?
    var workspaceBusy: () -> Bool = { false }
    var changed: (() -> Void)?
    init(preferences: FactoryPreferences) { self.preferences = preferences }
    func enable() throws {
        guard AXIsProcessTrusted() else { throw FactoryError("Accessibility access is required for accordion.") }
        let status = WFRegisterAccordionHotKey({ _,context in
            MainActor.assumeIsolated { Unmanaged<DirectAccordionControls>.fromOpaque(context).takeUnretainedValue().run() }
        },Unmanaged.passUnretained(self).toOpaque())
        guard status == 0 else { active = false; lastResult = "Accordion registration failed (status \(status)); other groups are unchanged."; changed?(); throw FactoryError(lastResult) }
        active = true; preferences.accordionEnabled = true
        lastResult = "Native accordion enabled: Tab + Shift + S."; changed?()
    }
    func disable() {
        WFUnregisterAccordionHotKey(); task?.cancel(); active = false; preferences.accordionEnabled = false
        lastResult = "Accordion shortcut released; the Hammerspoon fallback can be enabled."; changed?()
    }
    func restorePreference() {
        if preferences.accordionEnabled { do { try enable() } catch { preferences.accordionEnabled = false; lastResult = error.localizedDescription; changed?() } }
    }
    private func read(_ element: AXUIElement) throws -> Frame {
        var rect = CGRect.zero
        guard WFReadFrame(element,&rect),rect.width>0,rect.height>0 else { throw FactoryError("Window frame unavailable.") }
        return Frame(x:rect.minX,y:rect.minY,w:rect.width,h:rect.height)
    }
    private func snapshot() throws -> (LiveWindow,Context,[LiveWindow]) {
        guard AXIsProcessTrusted(),let app = NSWorkspace.shared.frontmostApplication,let bundle = app.bundleIdentifier,
              app.activationPolicy == .regular,!app.isHidden,bundle != Bundle.main.bundleIdentifier,bundle != "org.hammerspoon.Hammerspoon",
              !bundle.lowercased().contains("1password"),!bundle.lowercased().contains("onepassword"),
              bundle != "com.apple.Passwords",bundle != "com.apple.keychainaccess" else { throw FactoryError("Focus a regular application window first.") }
        let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root,0.15)
        guard let focused = axElement(attribute(root,kAXFocusedWindowAttribute)),attribute(focused,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { throw FactoryError("No focused standard window.") }
        let frame = try read(focused),id = WFWindowID(focused)
        guard id != 0 else { throw FactoryError("Window identity unavailable.") }
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
        func window(_ element: AXUIElement,_ frame: Frame) -> LiveWindow {
            LiveWindow(id:WFWindowID(element),pid:app.processIdentifier,bundleID:bundle,appName:app.localizedName ?? bundle,element:element,frame:frame)
        }
        let anchor = window(focused,frame); try anchor.eligible(in:context)
        var seen = Set<UInt32>(),others: [LiveWindow] = []
        for element in children(root,kAXWindowsAttribute) {
            let candidateID = WFWindowID(element)
            guard candidateID != 0,candidateID != id,seen.insert(candidateID).inserted,
                  attribute(element,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                  let frame = try? read(element),frame.isVisible(in:context.frame) else { continue }
            let candidate = window(element,frame)
            guard (try? candidate.eligible(in:context)) != nil else { continue }
            others.append(candidate)
        }
        return (anchor,context,others)
    }
    private func check(_ anchor: LiveWindow,_ context: Context) throws {
        try Task.checkCancellation(); try anchor.eligible(in:context)
        guard (!workspaceBusy() || agentRunning),NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.pid else { throw FactoryError("Focus or workspace operation changed; accordion stopped.") }
        let root = AXUIElementCreateApplication(anchor.pid); AXUIElementSetMessagingTimeout(root,0.1)
        guard let focused = axElement(attribute(root,kAXFocusedWindowAttribute)),WFWindowID(focused) == anchor.id,
              try read(anchor.element).matches(anchor.frame) else { throw FactoryError("Anchor changed; accordion stopped.") }
    }
    private func stack(_ plan: [AccordionRecord],anchor: LiveWindow,others: [LiveWindow],context: Context) async throws {
        guard !plan.isEmpty else { return }
        try check(anchor,context)
        let windows = [anchor]+others
        var rejected = false
        // Do not yield within this pass. AXRaise can temporarily change the
        // app's focused window; the anchor is raised and restored last.
        for id in AccordionGeometry.raiseOrder(anchor:anchor.id,fan:plan) {
            try context.check()
            guard (!workspaceBusy() || agentRunning),NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.pid,
                  try read(anchor.element).matches(anchor.frame),
                  let target = windows.first(where:{$0.id == id}) else { throw FactoryError("Focus or anchor changed; accordion ordering stopped.") }
            try target.eligible(in:context)
            if AXUIElementPerformAction(target.element,kAXRaiseAction as CFString) != .success { rejected = true }
        }
        // Preserve the chosen anchor even in apps where raising a sibling also
        // changes the main/focused window. Never activate an unrelated app.
        try context.check()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.pid else { throw FactoryError("Focus changed; anchor restoration stopped.") }
        try anchor.eligible(in:context)
        var main: Int32 = 0,raised: Int32 = 0
        _ = WFRequestWindowFocus(anchor.element,anchor.pid,&main,&raised)
        let expected = [anchor.id]+plan.map(\.id),ids = Set(expected)
        for _ in 0..<6 {
            try await Task.sleep(for:.milliseconds(30)); try context.check()
            guard (!workspaceBusy() || agentRunning),NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.pid,
                  try read(anchor.element).matches(anchor.frame) else { throw FactoryError("Focus or anchor changed; accordion verification stopped.") }
            try anchor.eligible(in:context)
            let root = AXUIElementCreateApplication(anchor.pid); AXUIElementSetMessagingTimeout(root,0.1)
            let focused = axElement(attribute(root,kAXFocusedWindowAttribute)).map{WFWindowID($0)}
            guard let focused,ids.contains(focused) else { throw FactoryError("User focus changed; accordion verification stopped.") }
            let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []
            let actual = infos.compactMap{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value}.filter{ids.contains($0)}
            if actual == expected,focused == anchor.id { return }
        }
        throw FactoryError(rejected ? "Frames placed; the app rejected accordion stacking and the expected order was not confirmed." : "Frames placed; accordion stacking order was not confirmed.")
    }
    func run() {
        guard active,task == nil,!agentRunning,!workspaceBusy() else { return }
        do {
            let (anchor,context,others) = try snapshot()
            willArrange?()
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { task = nil; changed?() }
                do {
                    try await perform(anchor:anchor,context:context,others:others,showHUD:true)
                } catch is CancellationError { lastResult = "Accordion cancelled." }
                catch { lastResult = error.localizedDescription; hud.show(lastResult) }
            }
        } catch { lastResult = error.localizedDescription; hud.show(lastResult); changed?() }
    }
    private func perform(anchor: LiveWindow,context: Context,others: [LiveWindow],showHUD: Bool) async throws {
                    let plan = AccordionGeometry.plan(anchor:AccordionRecord(id:anchor.id,frame:anchor.frame),others:others.map{AccordionRecord(id:$0.id,frame:$0.frame)},screen:context.frame)
                    for destination in plan {
                        try check(anchor,context)
                        guard let target = others.first(where:{$0.id == destination.id}) else { continue }
                        try target.eligible(in:context)
                        let f = destination.frame
                        guard WFApplyDirectFrame(target.element,CGRect(x:f.x,y:f.y,width:f.w,height:f.h)) == .success else { throw FactoryError("Application rejected accordion placement; some windows may already be placed.") }
                    }
                    // Submit the whole fan first; do not delay each window behind
                    // the previous window's animation or move the anchor to focus it.
                    if !plan.isEmpty { try await Task.sleep(for:.milliseconds(400)) }
                    try check(anchor,context)
                    var placed = 0
                    for destination in plan {
                        guard let target = others.first(where:{$0.id == destination.id}) else { continue }
                        try target.eligible(in:context)
                        if try read(target.element).matches(destination.frame) { placed += 1 }
                    }
                    guard placed == plan.count else { throw FactoryError("Accordion placed \(placed) of \(plan.count) other windows; the app constrained the remaining frames.") }
                    try await stack(plan,anchor:anchor,others:others,context:context)
                    lastResult = "Accordion: \(plan.count+1) windows; anchor unchanged."; if showHUD{hud.show("ACC \(plan.count+1)",on:context.screen)}
    }
    func forAgent(id: UInt32,context: Context) async throws {
        guard !isBusy else{throw AgentFailure("busy","Accordion owner is busy.")}
        let (anchor,actual,others)=try snapshot()
        guard anchor.id==id,actual.space==context.space,actual.display==context.display else{throw AgentFailure("window_changed","Exact accordion anchor changed.")}
        agentRunning=true;defer{agentRunning=false;changed?()};willArrange?()
        try await perform(anchor:anchor,context:actual,others:others,showHUD:false)
    }
    func stop() { WFUnregisterAccordionHotKey(); task?.cancel(); active = false; hud.stop() }
}
