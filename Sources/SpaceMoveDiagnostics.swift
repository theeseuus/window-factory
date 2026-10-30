import Foundation

struct SpaceMoveDiagnosticReport: Codable, Equatable {
    var schemaVersion = 2
    var attemptID = UUID()
    var startedAt = Date()
    var macOS = ProcessInfo.processInfo.operatingSystemVersionString
    var appBuild: String?
    var invocation: String
    var direction: Int
    var outcome = "running"
    var phase = "snapshot"
    var elapsedMS = 0
    var phaseStartedMS: [String:Int] = [:]
    var bundleID: String?
    var appVersion: String?
    var windowID: UInt32?
    var processID: Int32?
    var displayID: UInt32?
    var sourceSpace: UInt64?
    var destinationSpace: UInt64?
    var lastObservedSpace: UInt64?
    var moveDispatched = false
    var followDispatched = false
    var membershipReads = 0
    var lastWindowSpaces: [UInt64]?
    var visibilityReads = 0
    var targetVisible: Bool?
    var sourceWindowsHidden: Bool?
    var inputDeltas: [UInt32]?
    var inputObserverAvailable = false
    var inputEvents: [SpaceMoveInputEvent] = []
    var unattributedKeyboardDelta = false
    var ignoredMoveRequests = 0
    var focusRequests = 0
    var focusObservations = 0
    var lastFrontmostPID: Int32?
    var lastFocusedWindowID: UInt32?
    var focusActivationStatus: Int32?
    var focusMainStatus: Int32?
    var focusRaiseStatus: Int32?
    var failedCheck: String?
    var detail: String?
}

// One in-memory report, piggybacking on reads the controller already makes.
// No titles, document paths, key values, ongoing observers or file history.
@MainActor
final class SpaceMoveDiagnostics {
    private let started = DispatchTime.now().uptimeNanoseconds
    var report: SpaceMoveDiagnosticReport
    init(direction: Int,invocation: String,appBuild: String? = nil) {
        report=SpaceMoveDiagnosticReport(appBuild:appBuild,invocation:invocation,direction:direction)
        mark("snapshot")
    }
    private var elapsed: Int { Int((DispatchTime.now().uptimeNanoseconds-started)/1_000_000) }
    func mark(_ phase: String) {
        report.phase=phase;report.elapsedMS=elapsed
        if report.phaseStartedMS[phase] == nil {report.phaseStartedMS[phase]=report.elapsedMS}
    }
    func finish(_ outcome: String,detail: String? = nil) {
        report.outcome=outcome;report.detail=detail;report.elapsedMS=elapsed
    }
}

// Classification only: never retain the key code, text or document context.
struct SpaceMoveInputEvent: Codable, Equatable {
    var elapsedMS: Int
    var sourcePID: Int32
    var sourceStateID: Int64
    var matchesMoveShortcut: Bool
    var isRepeat: Bool
}
enum SpaceMoveInputPolicy {
    static func cancels(keyboardChanged: Bool,pointerChanged: Bool,moved: Bool,
        observerAvailable: Bool,otherKeyObserved: Bool,moveKeyObserved: Bool) -> Bool {
        if pointerChanged || otherKeyObserved { return true }
        guard keyboardChanged else { return false }
        // A global counter is not proof of user intent. Once movement has been
        // dispatched, finish follow/focus unless a classified event says otherwise.
        // If observation is unavailable, retain the original conservative guard.
        if !observerAvailable { return true }
        return !moved && !moveKeyObserved
    }
}
