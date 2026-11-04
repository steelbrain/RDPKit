import Foundation
#if os(macOS) || targetEnvironment(macCatalyst)
import CoreServices
#endif

/// A change in a shared folder as FSEvents reports it: the directory it happened in, not
/// the item or what changed about it. A directory watch reports to the handles on its
/// directory without one.
enum RDPSharedDriveChange: Equatable, Sendable {
    /// What a directory holds changed: an entry was added, removed or renamed, or an item in
    /// it changed.
    case directory(String)
    /// Anything under a directory may have changed, as FSEvents could not tell what
    /// (kFSEventStreamEventFlagMustScanSubDirs), or a volume was mounted or unmounted there.
    case tree(String)
    /// Anything in the folder may have changed: FSEvents dropped events, or the folder
    /// itself moved.
    case everything

    /// Whether a change notification on `directory` hears of this change: one in what the
    /// directory holds, or with `watchTree` anywhere under it ([MS-RDPEFS] 2.2.3.3.11). Paths
    /// are canonical, as `realpath` and FSEvents give them; a directory that no longer
    /// resolves, nil, hears of every change.
    func concerns(_ directory: String?, watchTree: Bool) -> Bool {
        guard let directory else {
            return true
        }
        switch self {
        case let .directory(path):
            return path == directory || watchTree && Self.isPath(path, under: directory)
        case let .tree(path):
            return path == directory || Self.isPath(directory, under: path) || watchTree && Self.isPath(path, under: directory)
        case .everything:
            return true
        }
    }

    private static func isPath(_ path: String, under directory: String) -> Bool {
        path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }
}

/// How a shared drive hears of changes in its folder.
enum RDPSharedDriveChangeSource: Equatable, Sendable {
    /// Only `receive(_:)` reports changes, for tests.
    case none
    /// A kqueue watch on each directory a handle watches (`RDPSharedDriveDirectoryWatch`),
    /// for platforms without FSEvents.
    case directoryWatches
    #if os(macOS) || targetEnvironment(macCatalyst)
    /// One FSEvents stream over the folder (`RDPSharedDriveChangeStream`).
    case fsEvents
    #endif

    /// FSEvents where the platform has it, directory watches elsewhere.
    static var platformDefault: Self {
        #if os(macOS) || targetEnvironment(macCatalyst)
        .fsEvents
        #else
        .directoryWatches
        #endif
    }
}

/// A kqueue watch on one directory, which reports on its queue when an entry is added to the
/// directory, removed from it or renamed in it, and when the directory is deleted or its
/// volume goes away, which stops it. Writes to the files in the directory, and anything in
/// its subdirectories, go unreported. It holds a descriptor from its budget until it stops.
/// Use it on its queue only.
final class RDPSharedDriveDirectoryWatch: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let descriptorBudget: RDPSharedDriveDescriptorBudget
    /// Takes whether the directory is gone.
    private let report: (_ isGone: Bool) -> Void
    private var isStopped = false

    /// Watches the directory at `path` while it is still the one `identity` names. Nil when
    /// the budget has no descriptor left or the directory cannot be opened.
    init?(
        path: String,
        identity: RDPFileIdentity,
        queue: DispatchQueue,
        descriptorBudget: RDPSharedDriveDescriptorBudget,
        report: @escaping (_ isGone: Bool) -> Void
    ) {
        guard descriptorBudget.reserve() else {
            return nil
        }
        // O_EVTONLY leaves the volume free to unmount. O_DIRECTORY and O_NONBLOCK refuse
        // anything else put in the directory's place without waiting on it.
        let descriptor = open(path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0, RDPFileIdentity(info) == identity else {
            if descriptor >= 0 {
                close(descriptor)
            }
            descriptorBudget.release()
            return nil
        }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .revoke],
            queue: queue
        )
        self.descriptorBudget = descriptorBudget
        self.report = report
        source.setEventHandler { [weak self] in
            self?.receiveEvents()
        }
        // The descriptor stays open until the source no longer uses it.
        source.setCancelHandler {
            close(descriptor)
        }
        source.activate()
    }

    deinit {
        stop()
    }

    /// Stops reporting. The descriptor goes back to the budget at once, so another watch can
    /// start in its place, and closes once the source lets go of it, soon after on the queue.
    func stop() {
        guard !isStopped else {
            return
        }
        isStopped = true
        source.cancel()
        descriptorBudget.release()
    }

    private func receiveEvents() {
        let isGone = !source.data.isDisjoint(with: [.delete, .revoke])
        if isGone {
            stop()
        }
        report(isGone)
    }
}

#if os(macOS) || targetEnvironment(macCatalyst)
/// An FSEvents stream over a shared folder, which reports the directories changes happen in
/// on its queue. Use it on that queue only.
final class RDPSharedDriveChangeStream: @unchecked Sendable {
    /// FSEvents gathers the changes of this long into one report; the first change after a
    /// quiet spell is reported at once (kFSEventStreamCreateFlagNoDefer), so Explorer shows
    /// a single change made on the Mac without waiting.
    static let latency: CFTimeInterval = 0.2

    private let stream: FSEventStreamRef
    private let handler: RDPSharedDriveChangeStreamHandler

    /// Starts reporting the changes under `path`, from now on, to `report` on `queue`, a
    /// serial queue. Nil when FSEvents does not start.
    init?(path: String, queue: DispatchQueue, report: @escaping ([RDPSharedDriveChange]) -> Void) {
        let handler = RDPSharedDriveChangeStreamHandler(report: report)
        // The stream holds the handler from here until it is released.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else {
                    return nil
                }
                _ = Unmanaged<RDPSharedDriveChangeStreamHandler>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else {
                    return
                }
                Unmanaged<RDPSharedDriveChangeStreamHandler>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            rdpSharedDriveChangeStreamCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            // WatchRoot reports the folder itself moving or going away.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        ) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
        self.handler = handler
    }

    /// Stops the stream; a report FSEvents had already queued is dropped.
    func stop() {
        guard !handler.isStopped else {
            return
        }
        handler.isStopped = true
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// The change an FSEvents event reports, or nil for one that reports none.
    static func change(path: String, flags: FSEventStreamEventFlags) -> RDPSharedDriveChange? {
        func has(_ flag: Int) -> Bool {
            flags & FSEventStreamEventFlags(flag) != 0
        }
        if has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped)
            || has(kFSEventStreamEventFlagRootChanged)
        {
            return .everything
        }
        if has(kFSEventStreamEventFlagEventIdsWrapped) || has(kFSEventStreamEventFlagHistoryDone) {
            return nil
        }
        // Directory paths end in "/".
        let directory = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagMount)
            || has(kFSEventStreamEventFlagUnmount)
        {
            return .tree(directory)
        }
        return .directory(directory)
    }
}

/// What an FSEvents stream's context holds: where its reports go, and whether it stopped.
private final class RDPSharedDriveChangeStreamHandler {
    let report: ([RDPSharedDriveChange]) -> Void
    /// Read and written on the stream's queue only.
    var isStopped = false

    init(report: @escaping ([RDPSharedDriveChange]) -> Void) {
        self.report = report
    }
}

private let rdpSharedDriveChangeStreamCallback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
    guard let info else {
        return
    }
    let handler = Unmanaged<RDPSharedDriveChangeStreamHandler>.fromOpaque(info).takeUnretainedValue()
    guard !handler.isStopped else {
        return
    }
    // Without kFSEventStreamCreateFlagUseCFTypes the paths are C strings.
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    let changes = (0 ..< eventCount).compactMap { index in
        RDPSharedDriveChangeStream.change(path: String(cString: paths[index]), flags: eventFlags[index])
    }
    if !changes.isEmpty {
        handler.report(changes)
    }
}
#endif
