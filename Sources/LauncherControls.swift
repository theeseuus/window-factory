import AppKit
import ServiceManagement

@MainActor
final class LauncherControls {
    private let preferences: FactoryPreferences
    var active = false
    var lastResult = "Tab+R launcher is disabled."
    var loginResult: String?
    var toggleLibrary: (() -> Void)?
    var toggleShortcuts: (() -> Void)?
    var changed: (() -> Void)?
    init(preferences: FactoryPreferences) { self.preferences = preferences; refreshLoginState() }
    func enable() throws {
        let status = WFRegisterLauncherHotKey({ index,context in
            MainActor.assumeIsolated {
                let owner = Unmanaged<LauncherControls>.fromOpaque(context).takeUnretainedValue()
                if index == 0 { owner.toggleLibrary?() } else if index == 1 { owner.toggleShortcuts?() }
            }
        },Unmanaged.passUnretained(self).toOpaque())
        guard status == 0 else { active = false; lastResult = "Tab+R could not register (status \(status)); other controls are unchanged."; changed?(); throw FactoryError(lastResult) }
        active = true; preferences.launcherEnabled = true
        lastResult = "Library and Keyboard Shortcuts bindings are enabled."; changed?()
    }
    func disable() {
        WFUnregisterLauncherHotKey(); active = false; preferences.launcherEnabled = false
        lastResult = "Tab+R released. The menu-bar badge and Dock still open Window Factory."; changed?()
    }
    func restorePreference() {
        if preferences.launcherEnabled { do { try enable() } catch { preferences.launcherEnabled = false; lastResult = error.localizedDescription; changed?() } }
    }
    var loginAvailable: Bool { Bundle.main.bundlePath == "/Applications/Window Factory.app" }
    private(set) var loginState = SMAppService.Status.notRegistered
    func refreshLoginState() { loginState = SMAppService.mainApp.status }
    var loginDescription: String {
        if let loginResult { return loginResult }
        switch loginState {
        case .enabled: return "Start at login is on. Window Factory starts quietly."
        case .notRegistered: return "Start at login is off."
        case .requiresApproval: return "Start at login needs approval in macOS Login Items Settings."
        case .notFound: return "No macOS login registration was found. Start at login is off."
        @unknown default: return "Login item status is unavailable."
        }
    }
    func setLoginEnabled(_ enabled: Bool) {
        guard loginAvailable else { loginResult = "Use /Applications/Window Factory.app to change login startup."; changed?(); return }
        refreshLoginState()
        do {
            if enabled {
                if loginState == .requiresApproval { loginResult = "Approve Window Factory in macOS Login Items Settings." }
                else if loginState != .enabled { try SMAppService.mainApp.register(); loginResult = nil }
                else { loginResult = nil }
            } else {
                if loginState == .enabled || loginState == .requiresApproval { try SMAppService.mainApp.unregister() }
                loginResult = nil
            }
        } catch { loginResult = "Could not change start at login: \(error.localizedDescription)" }
        refreshLoginState(); changed?()
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event,event.eventID == AEEventID(kAEOpenApplication) else { return false }
        // Support the documented login marker and its property-data form.
        return event.paramDescriptor(forKeyword:AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue == true
            || event.paramDescriptor(forKeyword:AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
    func stop() { WFUnregisterLauncherHotKey(); active = false }
}
