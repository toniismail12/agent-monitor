import Foundation

enum Shell {
    /// Runs an executable and returns its stdout, or nil if it could not be launched.
    /// With a timeout, a run that takes longer is stopped and returns what it printed so far.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"  // so ps prints "15.6", not a localized "15,6"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            }
        }
        // Drain the pipe before waiting so a large output cannot block the child.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
