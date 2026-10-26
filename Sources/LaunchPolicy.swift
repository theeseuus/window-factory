import Foundation

enum FactoryLaunchPolicy {
    enum LibraryAction { case show,close,ignore }
    static func libraryAction(visible: Bool,key: Bool,active: Bool = true,onActiveSpace: Bool,modal: Bool) -> LibraryAction {
        if modal { return .ignore }
        return visible && key && active && onActiveSpace ? .close : .show
    }
    static func showsLibrary(arguments: [String],loginLaunch: Bool) -> Bool {
        !arguments.contains("--background") && !loginLaunch
    }
}
