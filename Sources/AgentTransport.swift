import Foundation
import Darwin

// One length-prefixed JSON request/reply per same-user Unix-domain connection.
// No network listener, shell execution or authentication material is involved.
enum AgentSocket {
    static let limit = 1_048_576
    static var directory: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/window-factory/agent").path }
    static var path: String { directory+"/control.sock" }
    static func failure(_ action: String) -> AgentFailure { AgentFailure("transport_error","\(action) failed (errno \(errno)).") }
    static func metadata(_ path: String) throws -> stat { var info=stat();guard lstat(path,&info)==0 else { throw failure("Inspect endpoint") };return info }
    static func owned(_ path: String,type: mode_t,mode: mode_t) throws {
        let info=try metadata(path)
        guard info.st_uid==getuid(),info.st_mode&S_IFMT==type,info.st_mode&0o777==mode else { throw AgentFailure("unsafe_endpoint","Endpoint must be owned by this user with private permissions.") }
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var addr=sockaddr_un();addr.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(path.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:addr.sun_path) else { throw AgentFailure("invalid_endpoint","Socket path is too long.") }
        withUnsafeMutableBytes(of:&addr.sun_path) { buffer in buffer.copyBytes(from:bytes) }
        addr.sun_len=UInt8(MemoryLayout<sockaddr_un>.size);return addr
    }
    static func timeouts(_ fd: Int32) {
        // Darwin accept inherits the listener's O_NONBLOCK flag. Request/reply
        // streams need blocking I/O so the bounded socket timeouts can apply.
        let flags=fcntl(fd,F_GETFL)
        if flags>=0 { _=fcntl(fd,F_SETFL,flags & ~O_NONBLOCK) }
        var timeout=timeval(tv_sec:3,tv_usec:0),yes:Int32=1
        _=setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        _=setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        _=setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size))
        _=fcntl(fd,F_SETFD,FD_CLOEXEC)
    }
    static func peer(_ fd: Int32) throws { var uid:uid_t=0,gid:gid_t=0;guard getpeereid(fd,&uid,&gid)==0,uid==getuid() else { throw AgentFailure("peer_denied","Only the current user may use this endpoint.") } }
    static func read(_ fd: Int32,count: Int) throws -> Data {
        var data=Data(count:count),offset=0
        while offset<count {
            let remaining=count-offset
            let n=data.withUnsafeMutableBytes { bytes in Darwin.read(fd,bytes.baseAddress!.advanced(by:offset),remaining) }
            if n<0 && errno==EINTR { continue }
            guard n>0 else { throw failure("Read reply") };offset+=n
        }
        return data
    }
    static func receive(_ fd: Int32) throws -> Data {
        let header=try read(fd,count:4)
        let count=header.reduce(UInt32(0)){($0<<8)|UInt32($1)}
        guard count>0,count<=limit else { throw AgentFailure("message_too_large","Message exceeds the one-megabyte limit.") }
        return try read(fd,count:Int(count))
    }
    static func send(_ fd: Int32,_ data: Data) throws {
        guard !data.isEmpty,data.count<=limit else { throw AgentFailure("message_too_large","Message exceeds the one-megabyte limit.") }
        var count=UInt32(data.count).bigEndian
        var framed=withUnsafeBytes(of:&count){Data($0)};framed.append(data)
        var offset=0
        while offset<framed.count {
            let n=framed.withUnsafeBytes { bytes in Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),framed.count-offset) }
            if n<0 && errno==EINTR { continue }
            guard n>0 else { throw failure("Write request") };offset+=n
        }
    }
    static func exchange(_ request: Data,path: String = path) throws -> Data {
        try owned((path as NSString).deletingLastPathComponent,type:S_IFDIR,mode:0o700)
        try owned(path,type:S_IFSOCK,mode:0o600)
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else { throw failure("Create client") };defer{close(fd)}
        timeouts(fd);var addr=try address(path)
        let connected=withUnsafePointer(to:&addr){pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard connected==0 else { throw failure("Connect to Window Factory") }
        try peer(fd);try send(fd,request);return try receive(fd)
    }
}

@MainActor
final class AgentListener {
    private var source: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var socketPath: String?
    private var socketInode: ino_t?
    func start(path: String = AgentSocket.path,handler: @escaping @MainActor @Sendable (Data) async -> Data) throws {
        guard source==nil else { return }
        let directory=(path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try AgentSocket.owned(directory,type:S_IFDIR,mode:0o700)
        let lock=open(directory+"/listener.lock",O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard lock>=0 else { throw AgentSocket.failure("Lock listener") }
        var info=stat()
        guard fstat(lock,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFREG,info.st_mode&0o777==0o600,flock(lock,LOCK_EX|LOCK_NB)==0 else {close(lock);throw AgentFailure("listener_owned","Another listener owns this endpoint, or its lock is unsafe.")}
        let fd=socket(AF_UNIX,SOCK_STREAM,0)
        guard fd>=0 else {close(lock);throw AgentSocket.failure("Create listener")}
        var boundSocket=false
        do {
            var old=stat()
            if lstat(path,&old)==0 { try AgentSocket.owned(path,type:S_IFSOCK,mode:0o600);guard unlink(path)==0 else {throw AgentSocket.failure("Remove stale socket")} }
            var addr=try AgentSocket.address(path)
            let bound=withUnsafePointer(to:&addr){pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            guard bound==0 else {throw AgentSocket.failure("Bind listener")}
            boundSocket=true
            guard chmod(path,0o600)==0,listen(fd,8)==0,fcntl(fd,F_SETFL,O_NONBLOCK)==0 else {throw AgentSocket.failure("Prepare listener")}
            _=fcntl(fd,F_SETFD,FD_CLOEXEC)
            let socketInode=try AgentSocket.metadata(path).st_ino
            let source=DispatchSource.makeReadSource(fileDescriptor:fd,queue:DispatchQueue(label:"WindowFactory.AgentListener"))
            let capacity=DispatchSemaphore(value:8)
            source.setEventHandler { @Sendable in
                while true {
                    let client=accept(fd,nil,nil)
                    if client<0 { if errno==EINTR {continue};break }
                    guard capacity.wait(timeout:.now()) == .success else {close(client);continue}
                    AgentSocket.timeouts(client)
                    Task.detached {
                        defer {close(client);capacity.signal()}
                        do {
                            try AgentSocket.peer(client)
                            let request=try AgentSocket.receive(client)
                            let reply=await handler(request)
                            try AgentSocket.send(client,reply)
                        } catch { try? AgentSocket.send(client,AgentResponse.failure(error).encoded()) }
                    }
                }
            }
            source.setCancelHandler { @Sendable in close(fd);close(lock)}
            self.source=source;self.lockFD=lock;self.socketPath=path;self.socketInode=socketInode;source.resume()
        } catch {if boundSocket {_=unlink(path)};close(fd);close(lock);throw error}
    }
    func stop() {
        if let socketPath,let info=try? AgentSocket.metadata(socketPath),info.st_ino==socketInode,info.st_uid==getuid() { _=unlink(socketPath) };socketPath=nil;socketInode=nil
        if lockFD>=0 { _=flock(lockFD,LOCK_UN) }
        source?.cancel();source=nil;lockFD = -1
    }
}
