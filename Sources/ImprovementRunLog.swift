import Foundation

// Bounded metadata reader for preserved build-58 run history. No model launch.
enum ImprovementRunLog {
    static func sessionID(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom:url) else {return nil}
        defer {try? handle.close()}
        // thread.started is at the start; do not load potentially large command logs.
        let data = handle.readData(ofLength:65536)
        for line in String(decoding:data,as:UTF8.self).split(separator:"\n") {
            if let value = try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],
               value["type"] as? String == "thread.started",let id = value["thread_id"] as? String, UUID(uuidString:id) != nil {return id}
        }
        return nil
    }
}
