import Foundation

/// 轻量运营日志（stderr，带时间戳）：主题宿主链路（WebView 池 / 握手 / 主题面轮询 /
/// 切换 / Dock 图标联动）的排障轨迹。移植自参考宿主 GrokDesktop 的同名设施；
/// 只写 stderr，不触碰任何既有行为。
enum Log {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        write("INFO", message)
    }

    static func warn(_ message: String) {
        write("WARN", message)
    }

    static func error(_ message: String) {
        write("ERR ", message)
    }

    private static func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(formatter.string(from: Date()))] [\(level)] DSHDesktop: \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
