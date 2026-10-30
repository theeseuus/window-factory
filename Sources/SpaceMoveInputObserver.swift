import AppKit

// Listen only for the lifetime of one attempt. No event consumption, synthesis,
// characters, raw key codes or persistent history; at most eight metadata records.
@MainActor
final class SpaceMoveInputObserver {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let trace: SpaceMoveDiagnostics
    private let chords: [ShortcutChord]
    private let started=DispatchTime.now().uptimeNanoseconds
    private(set) var otherKeyObserved=false
    private(set) var moveKeyObserved=false
    var available: Bool { tap.map{CGEvent.tapIsEnabled(tap:$0)} ?? false }
    init(trace: SpaceMoveDiagnostics) {
        self.trace=trace
        let store=KeybindingStore(defaults:.standard)
        chords=ShortcutDefinition.all.filter{$0.group == .spaces}.map{store.chord($0)}
        tap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.listenOnly,
            eventsOfInterest:CGEventMask(1)<<CGEventType.keyDown.rawValue,callback:{ _,type,event,context in
                MainActor.assumeIsolated {
                    if let context {
                        Unmanaged<SpaceMoveInputObserver>.fromOpaque(context).takeUnretainedValue().observe(type,event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },userInfo:Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source=CFMachPortCreateRunLoopSource(nil,tap,0)
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes) }
            CGEvent.tapEnable(tap:tap,enable:true)
        }
        trace.report.inputObserverAvailable=available
    }
    private func observe(_ type: CGEventType,_ event: CGEvent) {
        guard type == .keyDown else {trace.report.inputObserverAvailable=false;return}
        let key=UInt32(event.getIntegerValueField(.keyboardEventKeycode)),flags=event.flags
        var modifiers:UInt32=0
        if flags.contains(.maskControl) {modifiers |= ShortcutChord.control}
        if flags.contains(.maskAlternate) {modifiers |= ShortcutChord.option}
        if flags.contains(.maskCommand) {modifiers |= ShortcutChord.command}
        if flags.contains(.maskShift) {modifiers |= ShortcutChord.shift}
        let matches=chords.contains{$0.key==key && $0.modifiers==modifiers}
        if matches {moveKeyObserved=true} else {otherKeyObserved=true}
        if trace.report.inputEvents.count<8 {
            trace.report.inputEvents.append(SpaceMoveInputEvent(elapsedMS:Int((DispatchTime.now().uptimeNanoseconds-started)/1_000_000),
                sourcePID:Int32(clamping:event.getIntegerValueField(.eventSourceUnixProcessID)),
                sourceStateID:event.getIntegerValueField(.eventSourceStateID),matchesMoveShortcut:matches,
                isRepeat:event.getIntegerValueField(.keyboardEventAutorepeat) != 0))
        }
    }
    func stop() {
        if let source {CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes)}
        if let tap {CFMachPortInvalidate(tap)}
        source=nil;tap=nil
    }
}
