import Foundation

// Folder creation is an explicit owner action. Never replace an existing folder,
// commit, publish, change Git identities or delete partial work after failure.
enum ImprovementProjectCreation {
    static var gitExecutable: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/machine-agent-git")
    }
    static func newDestinationURL(_ path: String) -> URL {
        let url = URL(fileURLWithPath:path).standardizedFileURL
        // Resolve the existing parent even while the new leaf does not exist.
        // This keeps retry identity stable across /var -> /private/var aliases.
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent,isDirectory:true)
    }
    static func validateDestination(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath:url.path,isDirectory:&directory), directory.boolValue else {
            throw AgentFailure("invalid_destination", "Choose an existing project folder.")
        }
        return url
    }
    static func create(_ path: String, git: URL = gitExecutable) async throws -> URL {
        try await Task.detached(priority:.userInitiated) { () async throws -> URL in
            let url = newDestinationURL(path)
            guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath:url.path) else {
                throw AgentFailure("project_exists", "The destination already exists; choose it as an existing project instead. Nothing was replaced.")
            }
            _ = try validateDestination(url.deletingLastPathComponent().path)
            guard FileManager.default.isExecutableFile(atPath:git.path) else {
                throw AgentFailure("git_unavailable", "The configured local Git initializer is unavailable. No folder was created.")
            }
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let process = Process(); process.executableURL = git
            process.arguments = ["init","-b","main","--",url.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            defer {if process.isRunning {process.terminate()}}
            do {try process.run()} catch {
                throw AgentFailure("project_initialization_failed", "The folder was created but Git could not start. The folder was preserved for inspection.")
            }
            let deadline = ContinuousClock.now.advanced(by:.seconds(10))
            while process.isRunning && ContinuousClock.now < deadline {try await Task.sleep(for:.milliseconds(20))}
            guard !process.isRunning else {
                throw AgentFailure("project_initialization_failed", "Git initialization timed out. The folder was preserved for inspection.")
            }
            // isRunning was already polled to completion; Foundation waitUntilExit
            // can wait on a run-loop notification on a cooperative executor.
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath:url.appendingPathComponent(".git").path) else {
                throw AgentFailure("project_initialization_failed", "Git initialization failed. The folder was preserved for inspection; no retry or deletion was performed.")
            }
            return url
        }.value
    }
}
