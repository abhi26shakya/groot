import Foundation
import CoreServices

/// A single filesystem change reported by FSEvents, already classified.
public struct FSChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case created, modified, removed, renamed, other
    }
    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// Thin, testable wrapper over the FSEvents C API. Not an actor — it owns a raw
/// `FSEventStreamRef` and delivers coalesced changes on a private dispatch queue
/// via a `@Sendable` callback. The owning agent turns those into bus events.
public final class FSEventsWatcher: @unchecked Sendable {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let onChange: @Sendable ([FSChange]) -> Void
    private let queue = DispatchQueue(label: "org.groot.fsevents", qos: .utility)

    private var stream: FSEventStreamRef?

    public init(
        paths: [String],
        latency: CFTimeInterval = 1.0,
        onChange: @escaping @Sendable ([FSChange]) -> Void
    ) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    /// Begin watching. Idempotent.
    public func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            // Balance the retain we did for `info` if creation failed.
            Unmanaged<FSEventsWatcher>.fromOpaque(context.info!).release()
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stop and tear down the stream. Idempotent.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        // Release the retain taken for the callback `info` pointer.
        Unmanaged.passUnretained(self).release()
    }

    deinit {
        stop()
    }

    /// Called (on `queue`) by the C trampoline with already-decoded changes.
    fileprivate func deliver(_ changes: [FSChange]) {
        guard !changes.isEmpty else { return }
        onChange(changes)
    }

    // MARK: Pure mapping (unit-tested)

    /// Map an FSEvents flag bitmask to our classified `FSChange.Kind`. Pure and
    /// deterministic so it can be tested without a live stream. Order matters:
    /// FSEvents coalesces multiple changes into one flag word, so we pick the
    /// most actionable interpretation (created > renamed > removed > modified).
    public static func classify(flags: FSEventStreamEventFlags) -> FSChange.Kind {
        let f = Int(flags)
        if f & kFSEventStreamEventFlagItemCreated != 0 { return .created }
        if f & kFSEventStreamEventFlagItemRenamed != 0 { return .renamed }
        if f & kFSEventStreamEventFlagItemRemoved != 0 { return .removed }
        if f & kFSEventStreamEventFlagItemModified != 0 { return .modified }
        return .other
    }
}

/// C callback trampoline. Reconstructs the watcher from `info`, decodes the
/// event arrays, and forwards classified changes.
private func fsEventsCallback(
    stream: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    count: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()

    // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray of CFString.
    let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self)
    guard let paths = cfPaths as? [String] else { return }

    var changes: [FSChange] = []
    changes.reserveCapacity(count)
    for i in 0..<count where i < paths.count {
        let kind = FSEventsWatcher.classify(flags: eventFlags[i])
        changes.append(FSChange(path: paths[i], kind: kind))
    }
    watcher.deliver(changes)
}
