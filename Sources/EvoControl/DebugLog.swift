import Foundation

enum DebugLog {
    private static let path = "/tmp/evo-control-debug.log"
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? Data().write(to: URL(fileURLWithPath: path))
    }

    static func write(_ component: String, _ message: String) {
        let line = "[\(component)] \(message)\n"
        let data = Data(line.utf8)

        lock.lock()
        defer { lock.unlock() }

        FileHandle.standardError.write(data)
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
