import CoreServices
import Foundation

/// Watches directory trees for file changes using macOS FSEvents on a dispatch queue.
package final class FileWatcher: @unchecked Sendable {
    package static let defaultDirectories: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        AegisLoop.directory,
        HookHandler.defaultDirectory
    ]

    private static let queueKey = DispatchSpecificKey<Void>()

    private var stream: FSEventStreamRef?
    private let callback: @Sendable () -> Void
    private let queue: DispatchQueue
    private var isStopped = false

    package init(
        paths: [String]? = nil,
        latency: CFTimeInterval = 0.5,
        queue: DispatchQueue = DispatchQueue(label: "com.agentmonitor.filewatcher", qos: .utility),
        callback: @escaping @Sendable () -> Void
    ) {
        self.callback = callback
        self.queue = queue
        queue.setSpecific(key: Self.queueKey, value: ())

        let targetPaths = paths ?? Self.defaultDirectories.map(\.path)
        let existingPaths = targetPaths.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }.filter { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }

        guard !existingPaths.isEmpty else {
            self.stream = nil
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let eventCallback: FSEventStreamCallback = { streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds in
            guard let clientCallBackInfo else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            watcher.notify()
        }

        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            existingPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            self.stream = nil
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func notify() {
        guard !isStopped else { return }
        callback()
    }

    package func stop() {
        let performStop = {
            guard !self.isStopped else { return }
            self.isStopped = true
            guard let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            performStop()
        } else {
            queue.sync(execute: performStop)
        }
    }

    deinit {
        stop()
    }
}
