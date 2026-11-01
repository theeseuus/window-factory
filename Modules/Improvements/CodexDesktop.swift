import Foundation
import Darwin

/// JSON used only by the explicit desktop connector; no auth/account/config RPCs.
public enum CodexJSON: Codable, Sendable, Equatable {
    case object([String:CodexJSON]), array([CodexJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {self = .null}
        else if let v = try? c.decode(Bool.self) {self = .bool(v)}
        else if let v = try? c.decode(String.self) {self = .string(v)}
        else if let v = try? c.decode(Double.self) {self = .number(v)}
        else if let v = try? c.decode([String:CodexJSON].self) {self = .object(v)}
        else {self = .array(try c.decode([CodexJSON].self))}
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> CodexJSON {if case .object(let v) = self {return v[key] ?? .null}; return .null}
    public var string: String? {if case .string(let v) = self {return v}; return nil}
    public var array: [CodexJSON] {if case .array(let v) = self {return v}; return []}
    public static func text(_ value: String) -> CodexJSON {.string(value)}
}
public struct CodexProject: Codable, Sendable, Equatable, Identifiable {
    public let id: String, name: String
    public let roots: [String]
    public init(id: String, name: String, roots: [String]) {self.id=id;self.name=name;self.roots=roots}
    static func decode(_ value: CodexJSON) throws -> Self {
        guard let id=value["id"].string, let name=value["name"].string else {throw ImprovementFailure("codex_protocol_error","Invalid project response.")}
        return Self(id:id,name:name,roots:value["roots"].array.compactMap {$0["path"].string})
    }
}
public struct CodexChat: Codable, Sendable, Equatable, Identifiable {
    public let id: String, name: String, repository: String
    public let projectID: String?
    public init(id: String,name: String,repository: String,projectID: String?) {self.id=id;self.name=name;self.repository=repository;self.projectID=projectID}
    static func decode(_ value: CodexJSON) throws -> Self {
        guard let id=value["id"].string, let cwd=value["cwd"].string else {throw ImprovementFailure("codex_protocol_error","Invalid chat response.")}
        let name=[value["name"].string,value["preview"].string].compactMap {$0}.first {!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty} ?? "New coding chat"
        return Self(id:id,name:name,repository:cwd,projectID:value["projectId"].string)
    }
}
public struct CodexDestination: Codable, Sendable, Equatable {
    public let projectID: String, projectName: String, repository: String, chatID: String
    public init(projectID: String,projectName: String,repository: String,chatID: String) {
        self.projectID=projectID;self.projectName=projectName;self.repository=repository;self.chatID=chatID
    }
}
public struct CodexSendReceipt: Codable, Sendable, Equatable {
    public let chatID: String, turnID: String, messageID: UUID
    public init(chatID: String,turnID: String,messageID: UUID) {self.chatID=chatID;self.turnID=turnID;self.messageID=messageID}
}

/// One implementation shared by native UI and CLI. Explicit desktop connection only:
/// never falls back to a CLI identity, reads credentials or changes permission policy.
public struct CodexDesktop: Sendable {
    public let executable: URL, socket: URL
    public init(executable: URL = URL(fileURLWithPath:"/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
                socket: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock")) {
        self.executable=executable;self.socket=socket
    }
    public func projects() async throws -> [CodexProject] {
        try await Task.detached {try self.withRPC {rpc in
            var result:[CodexProject]=[],cursor:CodexJSON = .null
            for _ in 0..<100 {
                let page=try rpc.call("project/list",["limit":.number(100),"cursor":cursor])
                result += try page["data"].array.map(CodexProject.decode)
                cursor=page["nextCursor"]; if cursor == .null {return result}
            }
            throw ImprovementFailure("codex_protocol_error","Project pagination exceeded its bound.")
        }}.value
    }
    public func chats(projectID: String) async throws -> [CodexChat] {
        try await Task.detached {try self.withRPC {rpc in
            let project=try CodexProject.decode(rpc.call("project/read",["projectId":.string(projectID)])["project"])
            guard UUID(uuidString:project.id)==UUID(uuidString:projectID) else {throw ImprovementFailure("codex_destination_mismatch","Codex returned another project.")}
            // Legacy desktop chats may have a null server project ID. Show these as
            // repository matches; selection must explicitly assign them before send.
            var result:[CodexChat]=[],cursor:CodexJSON = .null
            for _ in 0..<100 {
                let page=try rpc.call("thread/list",["limit":.number(100),"cursor":cursor,"cwd":.array(project.roots.map(CodexJSON.string)),"useStateDbOnly":.bool(true)])
                result += try page["data"].array.map(CodexChat.decode).filter {$0.projectID == nil || $0.projectID == projectID}
                cursor=page["nextCursor"]; if cursor == .null {return result}
            }
            throw ImprovementFailure("codex_protocol_error","Chat pagination exceeded its bound.")
        }}.value
    }
    public func select(projectID: String, chatID: String, assignUnfiledChat: Bool = false) async throws -> CodexDestination {
        try await Task.detached {try self.withRPC {rpc in
            let project=try CodexProject.decode(rpc.call("project/read",["projectId":.string(projectID)])["project"])
            var chat=try CodexChat.decode(rpc.call("thread/read",["threadId":.string(chatID),"includeTurns":.bool(false)])["thread"])
            guard UUID(uuidString:project.id)==UUID(uuidString:projectID),UUID(uuidString:chat.id)==UUID(uuidString:chatID) else {throw ImprovementFailure("codex_destination_mismatch","Codex returned another project or chat.")}
            try Self.validate(project:project,chat:chat,allowUnfiled:assignUnfiledChat)
            if chat.projectID == nil {
                _ = try rpc.call("thread/metadata/update",["threadId":.string(chatID),"projectId":.string(projectID)])
                chat=try CodexChat.decode(rpc.call("thread/read",["threadId":.string(chatID),"includeTurns":.bool(false)])["thread"])
                try Self.validate(project:project,chat:chat,allowUnfiled:false)
            }
            return CodexDestination(projectID:project.id,projectName:project.name,repository:chat.repository,chatID:chat.id)
        }}.value
    }
    static func validate(project: CodexProject,chat: CodexChat,allowUnfiled: Bool) throws {
        guard UUID(uuidString:project.id) != nil, UUID(uuidString:chat.id) != nil,
              project.roots.contains(chat.repository) else {throw ImprovementFailure("codex_destination_mismatch","The chosen chat is not in a selected project repository.")}
        guard chat.projectID == project.id || (allowUnfiled && chat.projectID == nil) else {
            throw ImprovementFailure("codex_project_unverified","This chat is unfiled or belongs to another project. Explicitly assign an unfiled chat during setup before sending.")
        }
    }
    /// Creation is deliberately unavailable after the live desktop pilot returned
    /// records that were not visible/persistent in the running app. Keep these
    /// entry points source-compatible, but reject before starting any process.
    public static let creationUnavailableMessage = "Create the project and its initial coding chat in Codex, then refresh and select them here. Direct creation from Improvements is unavailable: desktop sidebar registration and empty-chat persistence are not verified."
    public func createProject(name: String, repository: String, operationID: UUID) async throws -> CodexProject {
        throw ImprovementFailure("codex_creation_unavailable",Self.creationUnavailableMessage)
    }
    public func createChat(projectID:String,repository:String) async throws -> CodexChat {
        throw ImprovementFailure("codex_creation_unavailable",Self.creationUnavailableMessage)
    }
    public func checkReady(_ destination:CodexDestination) async throws {
        let selected=try await select(projectID:destination.projectID,chatID:destination.chatID)
        guard selected.repository == destination.repository else {throw ImprovementFailure("codex_destination_mismatch","The configured chat's repository changed.")}
        try await Task.detached {
            let client=try DesktopIPC(url:self.socket);defer {client.close()}
            let result=try client.call("thread-owner-discovery",["hostId":.string("local"),"conversationId":.string(destination.chatID)],version:1)
            guard result["supportsUntrustedAppInput"] == .bool(true) else {throw ImprovementFailure("codex_chat_unavailable","Open the configured chat in Codex. Nothing was sent.")}
        }.value
    }
    public func send(_ prompt: String, to destination: CodexDestination, messageID: UUID) async throws -> CodexSendReceipt {
        guard !prompt.isEmpty, prompt.utf8.count <= 64000 else {throw ImprovementFailure("invalid_improvement","The prepared prompt is empty or too large.")}
        // Reverify persisted identity/repository before sending. No silent retargeting.
        let checked=try await select(projectID:destination.projectID,chatID:destination.chatID)
        guard checked.repository == destination.repository else {throw ImprovementFailure("codex_destination_mismatch","The chat repository changed after setup.")}
        return try await Task.detached {
            let client=try DesktopIPC(url:self.socket); defer {client.close()}
            let discovery=try client.call("thread-owner-discovery",["hostId":.string("local"),"conversationId":.string(destination.chatID)],version:1)
            guard discovery["supportsUntrustedAppInput"] == .bool(true) else {throw ImprovementFailure("codex_chat_unavailable","Open the chosen chat in Codex before sending. Nothing was sent.")}
            let result=try client.call("thread-follower-start-turn",["conversationId":.string(destination.chatID),"turnStart":.object(["request":.object(["threadId":.string(destination.chatID),"clientUserMessageId":.string(messageID.uuidString),"input":.array([.object(["type":.string("text"),"text":.string(prompt),"text_elements":.array([])])])]),"context":.object([:])])],version:2,mayDeliver:true)
            guard let turnID=result["result"]["turn"]["id"].string else {throw ImprovementFailure("codex_delivery_unconfirmed","Codex returned no turn receipt. Inspect the chosen chat before any retry.")}
            return CodexSendReceipt(chatID:destination.chatID,turnID:turnID,messageID:messageID)
        }.value
    }
    private func withRPC<T>(_ body:(DesktopRPC)throws->T) throws -> T {
        let rpc=try DesktopRPC(executable:executable);defer {rpc.close()};return try body(rpc)
    }
}

// Poll-based bounded I/O, isolated from the UI executor. No socket creation/chmod,
// daemon start, account/config RPC, credential read or executor impersonation.
private final class DesktopIO {
    let readFD:Int32,writeFD:Int32
    var buffer=Data()
    init(read:Int32,write:Int32) {
        readFD=read;writeFD=write
        for fd in Set([read,write]) {_ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK);_ = fcntl(fd,F_SETNOSIGPIPE,1)}
    }
    func wait(_ fd:Int32,_ events:Int16,_ deadline:UInt64) throws {
        while true {
            let now=DispatchTime.now().uptimeNanoseconds
            guard now<deadline else {throw ImprovementFailure("codex_timeout","Codex did not answer within the connection deadline.")}
            var p=pollfd(fd:fd,events:events,revents:0)
            let result=Darwin.poll(&p,1,Int32(min((deadline-now)/1_000_000+1,15000)))
            if result<0 && errno == EINTR {continue}
            guard result>0, (p.revents & (events|Int16(POLLHUP))) != 0 else {throw ImprovementFailure("codex_connection_closed","Codex closed or timed out the local connection.")}
            return
        }
    }
    func write(_ data:Data,until deadline:UInt64) throws {
        var offset=0
        while offset<data.count {
            try wait(writeFD,Int16(POLLOUT),deadline)
            let n=data.withUnsafeBytes {Darwin.write(writeFD,$0.baseAddress!.advanced(by:offset),min(8192,data.count-offset))}
            if n<0 && [EINTR,EAGAIN].contains(errno) {continue}
            guard n>0 else {throw ImprovementFailure("codex_connection_closed","The local Codex connection closed.")};offset+=n
        }
    }
    func fill(until deadline:UInt64) throws {
        try wait(readFD,Int16(POLLIN),deadline)
        var bytes=[UInt8](repeating:0,count:16384);let n=Darwin.read(readFD,&bytes,bytes.count)
        if n<0 && [EINTR,EAGAIN].contains(errno) {return}
        guard n>0 else {throw ImprovementFailure("codex_connection_closed","The local Codex connection closed.")}
        buffer.append(contentsOf:bytes.prefix(n))
        guard buffer.count<=8*1024*1024 else {throw ImprovementFailure("codex_protocol_error","Codex response exceeded the bounded frame size.")}
    }
    func jsonLine(until deadline:UInt64) throws -> CodexJSON {
        while true {
            if let i=buffer.firstIndex(of:10) {let line=buffer.prefix(upTo:i);buffer.removeSubrange(...i);return try JSONDecoder().decode(CodexJSON.self,from:line)}
            try fill(until:deadline)
        }
    }
    func frame(until deadline:UInt64) throws -> CodexJSON {
        while buffer.count<4 {try fill(until:deadline)}
        let n=buffer.prefix(4).enumerated().reduce(0) {$0 | (Int($1.element)<<($1.offset*8))}
        guard n>0 && n<=8*1024*1024 else {throw ImprovementFailure("codex_protocol_error","Invalid Codex frame size.")}
        while buffer.count<4+n {try fill(until:deadline)}
        let data=buffer.subdata(in:4..<4+n);buffer.removeSubrange(0..<4+n)
        return try JSONDecoder().decode(CodexJSON.self,from:data)
    }
}
private final class DesktopRPC {
    let process:Process, input:Pipe, output:Pipe,io:DesktopIO
    init(executable:URL) throws {
        guard executable.path.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:executable.path) else {throw ImprovementFailure("codex_unavailable","Codex's bundled runtime is unavailable.")}
        process=Process();input=Pipe();output=Pipe();io=DesktopIO(read:output.fileHandleForReading.fileDescriptor,write:input.fileHandleForWriting.fileDescriptor)
        process.executableURL=executable;process.arguments=["app-server","--stdio"]
        let env=ProcessInfo.processInfo.environment
        var child=env.filter {["HOME","USER","LOGNAME","TMPDIR","LANG"].contains($0.key)};child["PATH"]="/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment=child;process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        try process.run()
        do {
            _ = try call("initialize",["clientInfo":.object(["name":.string("improvements"),"title":.string("Improvements desktop connector"),"version":.string("0.3")]),"capabilities":.object(["experimentalApi":.bool(true)])])
            var data=try JSONEncoder().encode(CodexJSON.object(["method":.string("initialized"),"params":.object([:])]))
            data.append(10);try io.write(data,until:Self.deadline())
        } catch {close();throw error}
    }
    static func deadline()->UInt64 {DispatchTime.now().uptimeNanoseconds+15_000_000_000}
    func call(_ method:String,_ params:[String:CodexJSON]) throws -> CodexJSON {
        let allowed:Set<String>=["initialize","project/list","project/read","thread/list","thread/read","thread/metadata/update"]
        guard allowed.contains(method) else {throw ImprovementFailure("codex_operation_unsupported","This connector does not expose that Codex operation.")}
        let id=UUID().uuidString,deadline=Self.deadline()
        var data=try JSONEncoder().encode(CodexJSON.object(["id":.string(id),"method":.string(method),"params":.object(params)]));data.append(10)
        try io.write(data,until:deadline)
        while true {
            let value=try io.jsonLine(until:deadline)
            guard value["id"].string == id else {continue}
            if value["error"] != .null {throw ImprovementFailure("codex_request_failed",value["error"]["message"].string ?? "Codex rejected the metadata request.")}
            return value["result"]
        }
    }
    func close() {
        try? input.fileHandleForWriting.close()
        let deadline=Date().addingTimeInterval(0.5)
        while process.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.01)}
        if process.isRunning {process.terminate()}
        let limit=Date().addingTimeInterval(0.5)
        while process.isRunning && Date()<limit {Thread.sleep(forTimeInterval:0.01)}
        if process.isRunning {Darwin.kill(process.processIdentifier,SIGKILL)}
        // Foundation owns child reaping; never wait on run-loop notification here.
        try? output.fileHandleForReading.close()
    }
}
private final class DesktopIPC {
    let fd:Int32,io:DesktopIO
    var clientID:String?
    init(url:URL) throws {
        var info=stat(),parent=stat()
        guard lstat(url.path,&info)==0, (info.st_mode & S_IFMT)==S_IFSOCK,info.st_uid==getuid(),info.st_mode & 0o077 == 0,
              lstat(url.deletingLastPathComponent().path,&parent)==0,(parent.st_mode & S_IFMT)==S_IFDIR,parent.st_uid==getuid(),parent.st_mode & 0o022 == 0 else {
            throw ImprovementFailure("codex_unavailable","The running Codex app's owner-only socket is unavailable.")
        }
        fd=Darwin.socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else {throw ImprovementFailure("codex_unavailable","Could not create the local client socket.")}
        io=DesktopIO(read:fd,write:fd)
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(url.path.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else {Darwin.close(fd);throw ImprovementFailure("codex_unavailable","Codex socket path is too long.")}
        withUnsafeMutableBytes(of:&address.sun_path) {$0.copyBytes(from:bytes)}
        let connected=withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard connected==0 else {Darwin.close(fd);throw ImprovementFailure("codex_unavailable","Could not connect to the running Codex app.")}
        do {clientID=try call("initialize",["clientType":.string("improvements")],version:0)["clientId"].string
            guard clientID != nil else {throw ImprovementFailure("codex_protocol_error","Codex did not register the Improvements client.")}
        } catch {Darwin.close(fd);throw error}
    }
    func close() {Darwin.close(fd)}
    func send(_ value:CodexJSON,until deadline:UInt64) throws {
        let json=try JSONEncoder().encode(value);var frame=Data((0..<4).map {UInt8((json.count>>($0*8))&255)});frame.append(json);try io.write(frame,until:deadline)
    }
    func call(_ method:String,_ params:[String:CodexJSON],version:Int,mayDeliver:Bool=false) throws -> CodexJSON {
        let id=UUID().uuidString,deadline=DesktopRPC.deadline()
        var request:[String:CodexJSON]=["type":.string("request"),"requestId":.string(id),"method":.string(method),"version":.number(Double(version)),"params":.object(params),"timeoutMs":.number(10000)]
        if let clientID {request["sourceClientId"] = .string(clientID)}
        do {
            try send(.object(request),until:deadline)
            while true {
                let value=try io.frame(until:deadline)
                if value["type"].string == "client-discovery-request" {
                    try send(.object(["type":.string("client-discovery-response"),"requestId":value["requestId"],"response":.object(["canHandle":.bool(false)])]),until:deadline)
                }
                guard value["type"].string == "response",value["requestId"].string==id else {continue}
                guard value["resultType"].string == "success" else {
                    let message=value["error"].string ?? "Codex rejected the operation."
                    throw ImprovementFailure(mayDeliver ? "codex_delivery_unconfirmed" : "codex_chat_unavailable",message)
                }
                return value["result"]
            }
        } catch {
            if mayDeliver {throw ImprovementFailure("codex_delivery_unconfirmed","Delivery could not be confirmed. Inspect the chosen chat before retrying; the request may have arrived.")}
            throw error
        }
    }
}
