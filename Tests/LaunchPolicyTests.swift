import Foundation
@main enum LaunchPolicyTests {
    static func main() {
        var assertions = 0
        func check(_ value: Bool,_ label: String) { precondition(value,label); assertions += 1 }
        check(FactoryLaunchPolicy.showsLibrary(arguments:[],loginLaunch:false),"normal Dock/Application launch shows the library")
        check(!FactoryLaunchPolicy.showsLibrary(arguments:["--background"],loginLaunch:false),"explicit background launch stays quiet")
        check(!FactoryLaunchPolicy.showsLibrary(arguments:[],loginLaunch:true),"login launch stays quiet")
        check(!FactoryLaunchPolicy.showsLibrary(arguments:["--background"],loginLaunch:true),"login and explicit quiet flags agree")
        check(FactoryLaunchPolicy.showsLibrary(arguments:["--preview"],loginLaunch:false),"normal preview behavior preserved")
        check(FactoryLaunchPolicy.libraryAction(visible:true,key:true,onActiveSpace:true,modal:false) == .close,"second shortcut closes the focused library")
        check(FactoryLaunchPolicy.libraryAction(visible:true,key:false,onActiveSpace:true,modal:false) == .show,"another app focused brings library forward")
        check(FactoryLaunchPolicy.libraryAction(visible:false,key:false,onActiveSpace:true,modal:false) == .show,"closed library opens")
        check(FactoryLaunchPolicy.libraryAction(visible:true,key:false,onActiveSpace:false,modal:false) == .show,"away library opens here rather than being closed")
        check(FactoryLaunchPolicy.libraryAction(visible:true,key:true,onActiveSpace:true,modal:true) == .ignore,"toggle leaves an attached modal alone")
        check(FactoryLaunchPolicy.libraryAction(visible:true,key:true,active:false,onActiveSpace:true,modal:false) == .show,"inactive app must not close a remembered key window")
        print("Window Factory launch policy: \(assertions) assertions passed; no login registration")
    }
}
