import Foundation

/// Timings for development builds launched with `--perf`: printed to the console
/// as milliseconds since the app started, and nothing otherwise.
enum PerfLog {
    static let start = CFAbsoluteTimeGetCurrent()
    static let enabled: Bool = {
        #if DEBUG
        return CommandLine.arguments.contains("--perf")
        #else
        return false
        #endif
    }()
    static func mark(_ what: @autoclosure () -> String) {
        guard enabled else { return }
        print("PERF \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms \(what())"); fflush(stdout)
    }
    /// Times a piece of work and prints how long it took.
    @discardableResult static func measure<T>(_ what: String, _ work: () throws -> T) rethrows -> T {
        let begin = CFAbsoluteTimeGetCurrent(); let result = try work()
        if enabled { print("PERF   \(what): \(Int((CFAbsoluteTimeGetCurrent() - begin) * 1000))ms"); fflush(stdout) }
        return result
    }
}
