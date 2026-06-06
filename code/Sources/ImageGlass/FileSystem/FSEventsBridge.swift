// FSEventsBridge.swift
//
// Thin Swift wrapper around the CoreServices FSEvents C API. Lives
// behind `FSEventsScopeWatcher`; nothing else in the app should call
// `FSEventStreamCreate` directly. See spec §3.2 for the chosen flags
// and §3.3 for why we use this and not a Swift-native facade.
//
// The wrapper:
//   * creates streams with the spec's required flag set
//     (FileEvents | WatchRoot | NoDefer | UseCFTypes | UseExtendedData),
//   * delivers normalized callbacks on a caller-provided DispatchQueue
//     via `FSEventStreamSetDispatchQueue` (NOT the deprecated runloop
//     scheduling),
//   * decodes the extended-data CFDictionary to extract per-event inode
//     numbers,
//   * exposes the post-batch `latestEventId` so the owning scope
//     watcher can persist a cursor and replay on relaunch (spec §5.4),
//   * and uses `kFSEventStreamEventIdSinceNow` ↔ explicit cursor
//     semantics for cold launch vs warm replay.

import Foundation
import CoreServices

/// One raw FSEvents callback's contents in Swift-native form.
struct FSEventsRawCallback {
    let paths: [String]
    let flags: [FSEventStreamEventFlags]
    let ids:   [FSEventStreamEventId]
    /// Inode numbers, parallel to `paths`. `nil` for entries where
    /// `kFSEventStreamEventExtendedFileIDKey` was not present.
    let inodes: [UInt64?]
}

final class FSEventsBridge {

    /// Stream root paths the kernel is watching.
    let roots: [URL]
    /// Caller-provided handler. Invoked on `callbackQueue`.
    private let onCallback: (FSEventsRawCallback) -> Void
    /// Queue the callback fires on. The owning `FSEventsScopeWatcher`
    /// owns this queue; we just hand it to `FSEventStreamSetDispatchQueue`.
    private let callbackQueue: DispatchQueue
    /// Replay cursor. `nil` means "since now" (cold start).
    private let sinceWhen: FSEventStreamEventId?
    /// Coalescing latency in seconds (spec §3.2: 0.20 s foreground).
    private let latencySeconds: Double

    private var stream: FSEventStreamRef?

    /// Highest event ID seen across all callbacks. The owning scope
    /// watcher persists this between sessions so the next launch can
    /// pass it back as `sinceWhen` (spec §5.4).
    private(set) var latestEventId: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

    init(roots: [URL],
         sinceWhen: FSEventStreamEventId?,
         latencySeconds: Double,
         callbackQueue: DispatchQueue,
         onCallback: @escaping (FSEventsRawCallback) -> Void) {
        self.roots = roots
        self.sinceWhen = sinceWhen
        self.latencySeconds = latencySeconds
        self.callbackQueue = callbackQueue
        self.onCallback = onCallback
    }

    /// Create the FSEventStream, attach our dispatch queue, and start
    /// it. Returns `false` if `FSEventStreamCreate` returned NULL —
    /// this happens on completely-unreachable roots; the watcher
    /// layer treats that as "fall back to polling" (spec §4.4).
    @discardableResult
    func start() -> Bool {
        // CFArrayCallBacks for retained CFStrings (matches what
        // FSEventStreamCreate expects).
        let pathsCF = roots.map { $0.path as CFString } as CFArray

        // Spec §3.2 flag set:
        //   FileEvents      → per-file granularity in callback flags
        //   WatchRoot       → fire RootChanged on rename/delete of root
        //   NoDefer         → emit first event in a batch immediately
        //   UseCFTypes      → eventPaths is CFArrayRef of CF objects
        //   UseExtendedData → CFArray contains CFDictionaryRef per event
        //                     with path + inode keys
        let flags: FSEventStreamCreateFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagUseExtendedData
        )

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let since = sinceWhen ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            FSEventsBridge.staticCallback,
            &context,
            pathsCF,
            since,
            latencySeconds,
            flags
        ) else {
            return false
        }

        FSEventStreamSetDispatchQueue(s, callbackQueue)
        let ok = FSEventStreamStart(s)
        if !ok {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        self.stream = s
        return true
    }

    /// Stop and dispose. Safe to call from any thread.
    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit {
        stop()
    }

    // MARK: - Cursor query

    /// The most recent event ID delivered by the kernel. Returns
    /// `kFSEventStreamEventIdSinceNow` if no batch has arrived yet.
    func currentEventId() -> FSEventStreamEventId {
        return latestEventId
    }

    // MARK: - Static C trampoline

    private static let staticCallback: FSEventStreamCallback = {
        (streamRef, clientInfo, numEvents, eventPaths, eventFlags, eventIds) in
        guard let clientInfo else { return }
        let bridge = Unmanaged<FSEventsBridge>
            .fromOpaque(clientInfo)
            .takeUnretainedValue()
        bridge.dispatchRaw(numEvents: numEvents,
                           eventPaths: eventPaths,
                           eventFlags: eventFlags,
                           eventIds: eventIds)
    }

    /// Decode the CF objects delivered by the kernel into Swift types
    /// and forward to the caller's handler.
    ///
    /// `eventPaths` is a `CFArrayRef`. With `UseExtendedData` set,
    /// each element is a `CFDictionaryRef` with these keys:
    ///   * `kFSEventStreamEventExtendedDataPathKey` → `CFStringRef`
    ///   * `kFSEventStreamEventExtendedFileIDKey`   → `CFNumberRef`
    /// Without `UseExtendedData`, each element is `CFStringRef`.
    private func dispatchRaw(numEvents: Int,
                             eventPaths: UnsafeMutableRawPointer,
                             eventFlags: UnsafePointer<FSEventStreamEventFlags>,
                             eventIds: UnsafePointer<FSEventStreamEventId>) {

        let cfArray = Unmanaged<CFArray>
            .fromOpaque(eventPaths)
            .takeUnretainedValue()
        let count = CFArrayGetCount(cfArray)

        var paths: [String] = []
        var inodes: [UInt64?] = []
        paths.reserveCapacity(count)
        inodes.reserveCapacity(count)

        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cfArray, i) else {
                paths.append("")
                inodes.append(nil)
                continue
            }
            let cf = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            let typeID = CFGetTypeID(cf)

            if typeID == CFDictionaryGetTypeID() {
                let dict = unsafeBitCast(cf, to: CFDictionary.self)
                let pathKey = unsafeBitCast(
                    kFSEventStreamEventExtendedDataPathKey, to: UnsafeRawPointer.self)
                let idKey = unsafeBitCast(
                    kFSEventStreamEventExtendedFileIDKey, to: UnsafeRawPointer.self)

                if let p = CFDictionaryGetValue(dict, pathKey) {
                    let pcf = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue()
                    paths.append(pcf as String)
                } else {
                    paths.append("")
                }
                if let inodeRaw = CFDictionaryGetValue(dict, idKey) {
                    let ncf = Unmanaged<CFNumber>.fromOpaque(inodeRaw).takeUnretainedValue()
                    var u: UInt64 = 0
                    CFNumberGetValue(ncf, .sInt64Type, &u)
                    inodes.append(u)
                } else {
                    inodes.append(nil)
                }
            } else if typeID == CFStringGetTypeID() {
                let s = unsafeBitCast(cf, to: CFString.self)
                paths.append(s as String)
                inodes.append(nil)
            } else {
                paths.append("")
                inodes.append(nil)
            }
        }

        let flagBuf = UnsafeBufferPointer(start: eventFlags, count: numEvents)
        let idBuf = UnsafeBufferPointer(start: eventIds, count: numEvents)
        let flags = Array(flagBuf)
        let ids = Array(idBuf)

        if let last = ids.last, last != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) {
            self.latestEventId = last
        }

        onCallback(FSEventsRawCallback(
            paths: paths, flags: flags, ids: ids, inodes: inodes
        ))
    }
}

// MARK: - FSEventStreamEventFlag helpers

extension FSEventsBridge {

    /// Decode the per-event flag bitmask into the small set of
    /// boolean facts the scope watcher actually consumes.
    struct DecodedFlags {
        let isCreated: Bool
        let isRemoved: Bool
        let isRenamed: Bool
        let isModified: Bool
        let isAttribChange: Bool
        let isFile: Bool
        let isDir: Bool
        let isSymlink: Bool
        let isRootChanged: Bool
        let mustScanSubdirs: Bool
        /// Kernel dropped events in this batch — caller must trigger
        /// a baseline rescan of the affected scope (spec §5.4).
        let dropped: Bool
        /// Kernel signaled a user-space-side drop (rare).
        let userDropped: Bool
        /// Cloud / iCloud materialization hint (best-effort).
        let isCloudMaterialized: Bool
    }

    static func decode(_ flags: FSEventStreamEventFlags) -> DecodedFlags {
        func has(_ flag: Int) -> Bool {
            return (flags & FSEventStreamEventFlags(flag)) != 0
        }
        return DecodedFlags(
            isCreated:          has(kFSEventStreamEventFlagItemCreated),
            isRemoved:          has(kFSEventStreamEventFlagItemRemoved),
            isRenamed:          has(kFSEventStreamEventFlagItemRenamed),
            isModified:         has(kFSEventStreamEventFlagItemModified)
                                || has(kFSEventStreamEventFlagItemInodeMetaMod),
            isAttribChange:     has(kFSEventStreamEventFlagItemChangeOwner)
                                || has(kFSEventStreamEventFlagItemXattrMod)
                                || has(kFSEventStreamEventFlagItemFinderInfoMod),
            isFile:             has(kFSEventStreamEventFlagItemIsFile),
            isDir:              has(kFSEventStreamEventFlagItemIsDir),
            isSymlink:          has(kFSEventStreamEventFlagItemIsSymlink),
            isRootChanged:      has(kFSEventStreamEventFlagRootChanged),
            mustScanSubdirs:    has(kFSEventStreamEventFlagMustScanSubDirs),
            dropped:            has(kFSEventStreamEventFlagKernelDropped),
            userDropped:        has(kFSEventStreamEventFlagUserDropped),
            isCloudMaterialized: has(kFSEventStreamEventFlagItemCloned)
        )
    }
}
