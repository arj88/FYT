import Foundation
import Observation
import UIKit
import UserNotifications

struct LocalPlaylist: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var songs: [Song] = []
    var created = Date()
}

struct HistoryEntry: Codable, Hashable, Identifiable {
    var song: Song
    var playedAt: Date
    var id: String { song.videoId + "\(playedAt.timeIntervalSince1970)" }
}

enum DownloadState: Equatable {
    case queued
    case downloading(Double)
    case done
    case failed(String)
}

/// Everything BitChord keeps on the device: likes, playlists, saved pages,
/// history, search history, downloads and imported files.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var liked: [Song] = []
    private(set) var playlists: [LocalPlaylist] = []
    private(set) var saved: [ShelfItem] = []
    private(set) var history: [HistoryEntry] = []
    private(set) var searchHistory: [String] = []
    private(set) var downloads: [Song] = []
    private(set) var localSongs: [Song] = []
    var downloadStates: [String: DownloadState] = [:]
    /// Songs queued, downloading or failed, so the list can show titles.
    private(set) var pendingDownloads: [String: Song] = [:]

    private struct Snapshot: Codable {
        var liked: [Song] = []
        var playlists: [LocalPlaylist] = []
        var saved: [ShelfItem] = []
        var history: [HistoryEntry] = []
        var searchHistory: [String] = []
        var downloads: [Song] = []
        var localSongs: [Song] = []
        /// Downloads that failed, kept so they can be retried after a relaunch.
        var failedDownloads: [Song]? = nil
    }

    private var saveTask: Task<Void, Never>?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var runningDownloads = 0
    /// Where each queued song belongs in Downloads: newest batch first, and inside a
    /// batch the order of the playlist it came from (not the order downloads finish in).
    @ObservationIgnored private var orderKeys: [String: Double] = [:]
    @ObservationIgnored private var batchCounter = 0

    // The current batch of downloads, for the progress bar and the "done" notification.
    private(set) var batchTotal = 0
    private(set) var batchDone = 0
    private(set) var batchFailed = 0
    /// A short message shown above the mini player ("Downloading 40 songs", "Downloaded ✓").
    private(set) var downloadNotice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    var isDownloading: Bool { batchTotal > 0 && batchDone + batchFailed < batchTotal }

    /// 0…1 across the whole batch, counting songs part-way through.
    var batchProgress: Double {
        guard batchTotal > 0 else { return 0 }
        let partial = downloadStates.values.reduce(0.0) { acc, state in
            if case .downloading(let p) = state { return acc + p }
            return acc
        }
        return min(1, (Double(batchDone + batchFailed) + partial) / Double(batchTotal))
    }

    private func notice(_ text: String, for seconds: Double = 2.5) {
        downloadNotice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self.downloadNotice = nil }
        }
    }

    private func finishBatchIfDone() {
        guard batchTotal > 0, batchDone + batchFailed >= batchTotal else { return }
        let done = batchDone, failed = batchFailed
        batchTotal = 0; batchDone = 0; batchFailed = 0
        let text = failed == 0
            ? (done == 1 ? "Downloaded ✓" : "Downloaded \(done) songs ✓")
            : "Downloaded \(done), \(failed) failed — see Downloads"
        notice(text, for: 4)
        UINotificationFeedbackGenerator().notificationOccurred(failed == 0 ? .success : .warning)
        // A notification too, for when the app is in the background.
        if UIApplication.shared.applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = "Downloads finished"
            content.body = text
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "downloads-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }
    /// Like/unlike changes made here recently, so a sync doesn't undo them before
    /// YouTube has caught up: videoId → (liked, when).
    @ObservationIgnored private var recentLikeChanges: [String: (liked: Bool, at: Date)] = [:]

    nonisolated static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    nonisolated static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    nonisolated static var downloadsDirectory: URL { documents.appendingPathComponent("Downloads", isDirectory: true) }
    nonisolated static var importsDirectory: URL { documents.appendingPathComponent("Imported", isDirectory: true) }
    private nonisolated static var file: URL { supportDirectory.appendingPathComponent("library.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            liked = snap.liked
            playlists = snap.playlists
            saved = snap.saved
            history = snap.history
            searchHistory = snap.searchHistory
            downloads = snap.downloads
            localSongs = snap.localSongs
            for song in snap.failedDownloads ?? [] where Self.downloadURL(for: song.videoId) == nil {
                downloadStates[song.videoId] = .failed("Download failed")
                pendingDownloads[song.videoId] = song
            }
        }
        for song in downloads where Self.downloadURL(for: song.videoId) != nil {
            downloadStates[song.videoId] = .done
        }
        downloads.removeAll { downloadStates[$0.videoId] != .done }
        // Earlier versions listed downloads newest-finished first (roughly reversed).
        // Once, put the ones that are liked back into Liked Songs order.
        if !UserDefaults.standard.bool(forKey: "downloadsOrderFixed") {
            UserDefaults.standard.set(true, forKey: "downloadsOrderFixed")
            var position: [String: Int] = [:]
            for (i, song) in liked.enumerated() where position[song.videoId] == nil { position[song.videoId] = i }
            downloads = downloads.enumerated()
                .sorted { (position[$0.element.videoId] ?? Int.max, $0.offset) < (position[$1.element.videoId] ?? Int.max, $1.offset) }
                .map(\.element)
            persist()
        }
    }

    private func persist() {
        saveTask?.cancel()
        let snap = Snapshot(liked: liked, playlists: playlists, saved: saved, history: history,
                            searchHistory: searchHistory, downloads: downloads, localSongs: localSongs,
                            failedDownloads: failedDownloads)
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            if let data = try? JSONEncoder().encode(snap) {
                try? data.write(to: LibraryStore.file, options: .atomic)
            }
        }
    }

    // MARK: Likes

    func isLiked(_ song: Song) -> Bool { liked.contains { $0.videoId == song.videoId } }

    func toggleLike(_ song: Song) {
        let nowLiked = !isLiked(song)
        setLiked(song, nowLiked)
        recentLikeChanges[song.videoId] = (nowLiked, Date())
        if InnerTube.shared.isSignedIn {
            Task { try? await InnerTube.shared.rate(videoId: song.videoId, status: nowLiked ? .like : .indifferent) }
        }
        if let lastfm = AppSettings.shared.lastFM {
            Task { await LastFM.love(lastfm, song: song, loved: nowLiked) }
        }
    }

    func setLiked(_ song: Song, _ value: Bool) {
        liked.removeAll { $0.videoId == song.videoId }
        if value { liked.insert(song, at: 0) }
        persist()
    }

    /// Makes the local likes match the account's Liked Music (newest first).
    ///
    /// The first sync after signing in also keeps likes made on this iPhone before sign-in,
    /// and sends them to YouTube. After that YouTube is the source of truth, except for
    /// changes made here in the last ten minutes that it may not reflect yet.
    func syncLiked(from server: [Song], firstSync: Bool) {
        // An empty answer is far more likely a failed read than an account with no likes.
        guard !server.isEmpty || liked.isEmpty else { return }
        let serverIds = Set(server.map(\.videoId))
        let cutoff = Date().addingTimeInterval(-600)
        recentLikeChanges = recentLikeChanges.filter { $0.value.at > cutoff }
        var result = server.filter { recentLikeChanges[$0.videoId]?.liked != false }
        let keepLocal = liked.filter { song in
            guard !serverIds.contains(song.videoId) else { return false }
            return firstSync || recentLikeChanges[song.videoId]?.liked == true
        }
        if firstSync, InnerTube.shared.isSignedIn {
            let toPush = keepLocal.filter { !$0.isLocal }.map(\.videoId)
            Task { for id in toPush { try? await InnerTube.shared.rate(videoId: id, status: .like) } }
        }
        result.insert(contentsOf: keepLocal, at: 0)
        liked = result
        persist()
    }

    // MARK: Saved pages

    func isSaved(_ browseId: String) -> Bool { saved.contains { $0.browseId == browseId } }

    func toggleSaved(_ item: ShelfItem) {
        guard let id = item.browseId else { return }
        if isSaved(id) { saved.removeAll { $0.browseId == id } } else { saved.insert(item, at: 0) }
        persist()
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(_ name: String, songs: [Song] = []) -> LocalPlaylist {
        let p = LocalPlaylist(name: name, songs: songs)
        playlists.insert(p, at: 0)
        persist()
        return p
    }

    func add(_ songs: [Song], to playlistId: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        let known = Set(playlists[i].songs.map(\.videoId))
        playlists[i].songs += songs.filter { !known.contains($0.videoId) }
        persist()
    }

    func remove(_ song: Song, from playlistId: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[i].songs.removeAll { $0.videoId == song.videoId }
        persist()
    }

    func move(in playlistId: String, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[i].songs.move(fromOffsets: from, toOffset: to)
        persist()
    }

    func rename(_ playlistId: String, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        playlists[i].name = name
        persist()
    }

    func deletePlaylist(_ playlistId: String) {
        playlists.removeAll { $0.id == playlistId }
        persist()
    }

    // MARK: History

    func recordPlay(_ song: Song) {
        guard !AppSettings.shared.pauseHistory else { return }
        history.removeAll { $0.song.videoId == song.videoId }
        history.insert(HistoryEntry(song: song, playedAt: Date()), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        persist()
    }

    func clearHistory() { history = []; persist() }

    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchHistory.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        searchHistory.insert(q, at: 0)
        if searchHistory.count > 30 { searchHistory.removeLast() }
        persist()
    }

    func removeSearch(_ query: String) { searchHistory.removeAll { $0 == query }; persist() }
    func clearSearches() { searchHistory = []; persist() }

    // MARK: Downloads

    nonisolated static func downloadURL(for videoId: String) -> URL? {
        for ext in ["caf", "m4a"] {
            let u = downloadsDirectory.appendingPathComponent("\(videoId).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    func isDownloaded(_ song: Song) -> Bool { downloadStates[song.videoId] == .done }

    func download(_ songs: [Song]) {
        var added: [Song] = []
        batchCounter += 1
        var place = 0
        for song in songs where !song.isLocal && downloadStates[song.videoId] != .done && downloadTasks[song.videoId] == nil {
            orderKeys[song.videoId] = Double(-batchCounter) * 1_000_000 + Double(place)
            place += 1
            downloadStates[song.videoId] = .queued
            pendingDownloads[song.videoId] = song
            added.append(song)
            downloadTasks[song.videoId] = Task { [weak self] in
                await self?.performDownload(song)
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard !added.isEmpty else {
            notice(songs.isEmpty ? "Nothing to download" : "Already downloaded ✓")
            return
        }
        batchTotal += added.count
        notice(added.count == 1 ? "Downloading “\(added[0].title)”" : "Downloading \(added.count) songs")
        // Ask once, the first time, so a finished batch can say so from the background.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func performDownload(_ song: Song) async {
        let id = song.videoId
        var song = song
        let quality = AppSettings.shared.downloadQuality
        // Three at a time, so "Download all" on a big list doesn't flood the connection.
        while runningDownloads >= 3 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
        }
        runningDownloads += 1
        defer { runningDownloads -= 1 }
        do {
            let cached = AudioCache.url(for: id)
            // Reuse a fully streamed copy only when it's what this quality would download anyway.
            let reuse = cached.map { url in quality.allowsOpus ? url.pathExtension == "caf" : (quality != .low && url.pathExtension == "m4a") } ?? false
            if reuse, let cached {
                try FileManager.default.createDirectory(at: Self.downloadsDirectory, withIntermediateDirectories: true)
                let target = Self.downloadsDirectory.appendingPathComponent("\(id).\(cached.pathExtension)")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: cached, to: target)
            } else {
                let result = try await StreamLoader.download(videoId: id, into: Self.downloadsDirectory, quality: quality) { progress in
                    Task { @MainActor in LibraryStore.shared.downloadStates[id] = .downloading(progress) }
                }
                if song.durationText == nil, let length = result.duration { song.durationText = Self.format(length) }
            }
            downloadStates[id] = .done
            pendingDownloads[id] = nil
            batchDone += 1
            finishBatchIfDone()
            downloads.removeAll { $0.videoId == id }
            // Older downloads have no key and sort after anything queued this session.
            let key = orderKeys[id] ?? 0
            let spot = downloads.firstIndex { (orderKeys[$0.videoId] ?? .infinity) > key } ?? downloads.count
            downloads.insert(song, at: spot)
            ArtworkStore.prefetch(song.artwork(544))
            persist()
        } catch {
            if Task.isCancelled { return }
            downloadStates[id] = .failed(error.localizedDescription)
            batchFailed += 1
            persist()
            finishBatchIfDone()
        }
        downloadTasks[id] = nil
    }

    /// How many of `songs` are already on the device.
    func downloadedCount(_ songs: [Song]) -> Int {
        songs.filter { downloadStates[$0.videoId] == .done }.count
    }

    /// Songs from `songs` still downloading or queued.
    func activeDownloads(_ songs: [Song]) -> Int {
        songs.filter {
            switch downloadStates[$0.videoId] {
            case .queued, .downloading: return true
            default: return false
            }
        }.count
    }

    func cancelDownload(_ song: Song) {
        downloadTasks[song.videoId]?.cancel()
        let wasActive: Bool
        switch downloadStates[song.videoId] {
        case .queued, .downloading: wasActive = true
        default: wasActive = false
        }
        downloadTasks[song.videoId] = nil
        downloadStates[song.videoId] = nil
        pendingDownloads[song.videoId] = nil
        if wasActive && batchTotal > 0 { batchTotal -= 1; finishBatchIfDone() }
        persist()
    }

    /// Songs whose download failed, in the order they were asked for.
    var failedDownloads: [Song] {
        pendingDownloads.values
            .filter { if case .failed = downloadStates[$0.videoId] { return true }; return false }
            .sorted { (orderKeys[$0.videoId] ?? .infinity, $0.title) < (orderKeys[$1.videoId] ?? .infinity, $1.title) }
    }

    /// Songs queued or downloading right now, in download order.
    var activeDownloadSongs: [Song] {
        pendingDownloads.values
            .filter {
                switch downloadStates[$0.videoId] {
                case .queued, .downloading: return true
                default: return false
                }
            }
            .sorted { (orderKeys[$0.videoId] ?? .infinity, $0.title) < (orderKeys[$1.videoId] ?? .infinity, $1.title) }
    }

    func failedCount(_ songs: [Song]) -> Int {
        songs.filter { if case .failed = downloadStates[$0.videoId] { return true }; return false }.count
    }

    func retryAllFailed() {
        download(failedDownloads)
    }

    /// Removes every downloaded song, and stops anything still downloading.
    func removeAllDownloads() {
        for task in downloadTasks.values { task.cancel() }
        downloadTasks = [:]
        try? FileManager.default.removeItem(at: Self.downloadsDirectory)
        downloads = []
        downloadStates = [:]
        pendingDownloads = [:]
        orderKeys = [:]
        batchTotal = 0; batchDone = 0; batchFailed = 0
        downloadNotice = nil
        persist()
    }

    /// Space the downloaded songs take up.
    nonisolated static func downloadsSize() -> Int64 {
        guard let files = FileManager.default.enumerator(at: downloadsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func retryDownload(_ song: Song) {
        downloadTasks[song.videoId] = nil
        downloadStates[song.videoId] = nil
        download([song])
    }

    func removeDownload(_ song: Song) {
        if let url = Self.downloadURL(for: song.videoId) { try? FileManager.default.removeItem(at: url) }
        downloads.removeAll { $0.videoId == song.videoId }
        downloadStates[song.videoId] = nil
        persist()
    }

    // MARK: Imported files

    func importFiles(_ urls: [URL]) async {
        try? FileManager.default.createDirectory(at: Self.importsDirectory, withIntermediateDirectories: true)
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let dest = Self.importsDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { continue }
            let meta = await LocalMetadata.read(dest)
            let song = Song(videoId: "local:" + name, title: meta.title ?? url.deletingPathExtension().lastPathComponent,
                            artist: meta.artist ?? "Unknown artist", albumName: meta.album,
                            durationText: meta.duration.map(Self.format), localFile: name)
            localSongs.removeAll { $0.videoId == song.videoId }
            localSongs.append(song)
        }
        localSongs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        persist()
    }

    func removeLocal(_ song: Song) {
        if let name = song.localFile { try? FileManager.default.removeItem(at: Self.importsDirectory.appendingPathComponent(name)) }
        localSongs.removeAll { $0.videoId == song.videoId }
        persist()
    }

    nonisolated static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
