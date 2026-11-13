#if os(macOS)
import CoreServices
#endif
import Foundation
import Observation

/// The vault as a UI sees it: the tree, every conversation, the directory of people,
/// accounts and tags, and every task, kept fresh while the folder changes on disk (by
/// this app, Memosa, git or a hand edit). Reads happen off the main actor; the
/// published values change on it.
///
/// ```swift
/// let library = Library(vault: Vault(root: folder))
/// library.start()            // first load, then follows the disk
/// library.conversations      // newest first
/// let open = library.tasks.filter { !$0.item.done }
/// ```
@MainActor @Observable
public final class Library {
    public let vault: Vault
    public private(set) var tree: [Vault.Node] = []
    public private(set) var conversations: [Conversation] = []
    public private(set) var directory = Vault.Directory(entities: [], tags: [])
    public private(set) var tasks: [VaultTask] = []
    /// Bumps on every reload, for views that key on a change.
    public private(set) var generation = 0

    @ObservationIgnored private var watcher: VaultWatcher?
    @ObservationIgnored private var loading: Task<Void, Never>?

    public init(vault: Vault) { self.vault = vault }

    /// Loads now, then reloads whenever the vault folder changes on disk.
    public func start() {
        guard watcher == nil else { return }
        watcher = VaultWatcher(root: vault.root) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    public func stop() {
        watcher = nil
        loading?.cancel()
    }

    /// Reads the vault again. Calls made while a read runs fold into one more read.
    public func reload() {
        loading?.cancel()
        let vault = vault
        loading = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                (vault.tree(), vault.conversations(), vault.directory(), vault.tasks())
            }.value
            guard !Task.isCancelled else { return }
            (tree, conversations, directory, tasks) = snapshot
            generation += 1
        }
    }

    /// Waits for the read in flight, if any (tests, and a UI that must show fresh data).
    public func settle() async { await loading?.value }

    public func conversations(linkedTo link: Link) async -> [Conversation] {
        let vault = vault
        return await Task.detached { vault.conversations(linkedTo: link) }.value
    }

    /// Conversation ids whose notes or transcript contain the phrase, any case.
    public func search(_ phrase: String) async -> [String] {
        let vault = vault
        return await Task.detached { vault.search(phrase) }.value
    }
}

/// Calls `onChange` (on a background queue, a moment after the last change of a burst)
/// whenever anything under `root` changes. Stops when released.
final class VaultWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "glyph.vault.watch")
    private let onChange: @Sendable () -> Void
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #else
    private var source: DispatchSourceFileSystemObject?
    #endif

    init(root: URL, latency: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        #if os(macOS)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        #else
        // ponytail: iOS has no FSEvents; this sees the vault folder's own entries only. Watch each folder if Mobile needs deeper changes.
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: queue)
        s.setEventHandler { [onChange] in onChange() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
        #endif
    }

    deinit {
        #if os(macOS)
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        #else
        source?.cancel()
        #endif
    }
}
