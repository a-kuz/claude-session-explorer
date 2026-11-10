// Watches ~/.claude/projects (recursively) for changes via FSEvents and
// fires a debounced callback so the session list stays live as Claude Code
// writes new turns into the jsonl files.

import Foundation
import CoreServices

final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void
    /// Decides per event (path, is-directory) whether it can matter; a batch
    /// with no relevant event doesn't fire. `nil` = every event is relevant.
    private let relevant: ((String, Bool) -> Bool)?
    private let debounce: TimeInterval
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "ai.enface.SessionExplorer.watcher")

    init(path: String, debounce: TimeInterval = 0.6,
         relevant: ((String, Bool) -> Bool)? = nil, onChange: @escaping () -> Void) {
        self.path = path
        self.relevant = relevant
        self.onChange = onChange
        self.debounce = debounce
    }

    func start() {
        guard stream == nil else { return }
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let relevant = watcher.relevant else { watcher.fire(); return }
            // Without kFSEventStreamCreateFlagUseCFTypes the paths are C strings.
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            // Coalesced or dropped events carry no usable path: rescan.
            let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged)
            for i in 0..<count {
                let f = flags[i]
                if f & rescan != 0
                    || relevant(String(cString: cPaths[i]),
                                f & UInt32(kFSEventStreamEventFlagItemIsDir) != 0) {
                    watcher.fire(); return
                }
            }
        }

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, flags) else { return }

        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func fire() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit { stop() }
}
