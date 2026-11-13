import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// The playback engine: queue, two AVPlayers for gapless/crossfade hand-offs,
/// lock-screen controls, radio autoplay, lyrics, scrobbling and sleep timer.
@MainActor
@Observable
final class PlayerController {
    static let shared = PlayerController()

    // MARK: Observable state

    private(set) var queue: [Song] = []
    private(set) var index: Int = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var errorMessage: String?
    private(set) var streamInfo: String?
    private(set) var sourceTitle: String?
    private(set) var playbackRate: Float = 1
    private(set) var sleepTimerEnd: Date?
    var stopAfterCurrent = false

    private(set) var lyrics: Lyrics?
    private(set) var lyricsLoading = false
    var lyricsOffset: Double = 0
    private(set) var relatedBrowseId: String?
    /// What Automix decided for the next transition (shown in stats for nerds).
    private(set) var automixStatus: String?

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var hasNext: Bool { index + 1 < queue.count || repeatMode == .all }
    var upNext: ArraySlice<Song> { index + 1 < queue.count ? queue[(index + 1)...] : [] }
    var history: ArraySlice<Song> { index > 0 ? queue[..<index] : [] }

    // MARK: Engine

    private let players = [AVPlayer(), AVPlayer()]
    private var active = 0
    private var standby: Int { 1 - active }
    private var loaders: [String: StreamLoader] = [:]
    private var preparedIndex: Int?
    private var preparedSongId: String?
    private var loadGeneration = 0
    private var timeObservers: [Any?] = [nil, nil]
    private var endObservers: [NSObjectProtocol] = []
    private var statusObservations: [NSKeyValueObservation] = []
    private var fading = false
    private var fadeTimer: Timer?
    private var sleepTimer: Timer?
    private var originalQueue: [Song] = []
    private var radioToken: String?
    private var radioPlaylistId: String?
    private var fetchingRadio = false
    private var gain: [Float] = [1, 1]
    private var startedAt = Date()
    private var scrobbled = false
    private var lyricsTask: Task<Void, Never>?
    private var lyricsBrowseId: String?
    private var lyricsSongId: String?
    private var lastRadioAttempt = Date.distantPast
    private var artworkTask: Task<Void, Never>?
    private var nowPlayingArtwork: MPMediaItemArtwork?

    private var settings: AppSettings { AppSettings.shared }

    /// Set while this phone is in a Listen Together party.
    @ObservationIgnored weak var party: ListenTogether?
    /// True while the party is moving the player, so those moves aren't sent back out.
    @ObservationIgnored private var applyingRemote = false
    /// The TV to send playback to while casting (not during a party, which keeps playback local).
    private var castControls: CastManager? {
        guard !applyingRemote, party?.isActive != true, CastManager.shared.isConnected else { return nil }
        return CastManager.shared
    }

    /// The party to send a user action to instead of doing it locally, if there is one.
    private var partyControls: ListenTogether? {
        guard !applyingRemote, let party, party.isActive else { return nil }
        return party
    }

    private init() {
        for (i, p) in players.enumerated() {
            p.automaticallyWaitsToMinimizeStalling = true
            p.allowsExternalPlayback = true
            let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
            timeObservers[i] = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(player: i) }
            }
            statusObservations.append(p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor in self?.statusChanged(player: i, status: status) }
            })
        }
        configureAudioSession()
        configureRemoteCommands()
        restoreQueue()
    }

    // MARK: Public API

    func play(_ songs: [Song], startAt: Int = 0, source: String? = nil, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        if let party = partyControls {
            var list = songs
            var start = min(max(0, startAt), songs.count - 1)
            if shuffled { list.shuffle(); start = 0 }
            party.publishPlay(list, index: start)
            return
        }
        radioToken = nil
        radioPlaylistId = nil
        sourceTitle = source
        originalQueue = songs
        var list = songs
        var start = min(max(0, startAt), songs.count - 1)
        if shuffled {
            list.shuffle()
            start = 0
            shuffle = true
        } else if shuffle {
            let first = list.remove(at: start)
            list.shuffle()
            list.insert(first, at: 0)
            start = 0
        }
        queue = list
        index = start
        loadCurrent(autoplay: true)
    }

    /// Plays a song and fills the queue with its YouTube Music radio.
    func playRadio(_ song: Song) {
        if let party = partyControls {
            party.publishPlay([song], index: 0)
            Task {
                if let radio = try? await YTMusic.radio(videoId: song.videoId) {
                    party.publishAdd(radio.songs.filter { $0.videoId != song.videoId }, playNext: false)
                }
            }
            return
        }
        play([song], source: "\(song.title) Radio")
        Task { await fetchRadio(seed: song, replaceAfterCurrent: true) }
    }

    /// Plays whatever a watch target (artist Mix/Shuffle, mixes, album playlists) queues up.
    func play(target: WatchTarget, source: String?) async {
        isLoading = true
        do {
            let next = try await YTMusic.watch(target)
            guard !next.songs.isEmpty else { isLoading = false; return }
            play(next.songs, source: source)
            radioToken = next.continuation
            radioPlaylistId = target.playlistId
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func playNext(_ songs: [Song]) {
        if let party = partyControls, current != nil { party.publishAdd(songs, playNext: true); return }
        guard current != nil else { play(songs); return }
        let ids = Set(songs.map(\.videoId))
        let currentId = current?.videoId
        queue.removeAll { ids.contains($0.videoId) && $0.videoId != currentId }
        index = queue.firstIndex { $0.videoId == currentId } ?? 0
        queue.insert(contentsOf: songs.filter { $0.videoId != currentId }, at: index + 1)
        invalidatePrepared()
        saveQueue()
    }

    func addToQueue(_ songs: [Song]) {
        if let party = partyControls, current != nil { party.publishAdd(songs, playNext: false); return }
        guard current != nil else { play(songs); return }
        let known = Set(queue.map(\.videoId))
        queue += songs.filter { !known.contains($0.videoId) }
        invalidatePrepared()
        saveQueue()
    }

    func togglePlay() {
        if current == nil { return }
        if let party = partyControls {
            party.publishPlayPause(playing: !isPlaying || party.detached, position: livePosition())
            return
        }
        if let cast = castControls {
            if cast.client?.mediaStatus?.mediaInformation == nil { loadCurrent(autoplay: true, resumeAt: position) } else { cast.playPause(!isPlaying) }
            return
        }
        if players[active].currentItem == nil {
            loadCurrent(autoplay: true, resumeAt: position)
            return
        }
        isPlaying ? pause() : resume()
    }

    func resume() {
        if let party = partyControls { party.publishPlayPause(playing: true, position: livePosition()); return }
        if let cast = castControls { cast.playPause(true); return }
        resumeLocal()
    }

    private func resumeLocal() {
        try? AVAudioSession.sharedInstance().setActive(true)
        players[active].playImmediately(atRate: songRate)
        isPlaying = true
        updateNowPlaying()
        updatePresence()
    }

    func pause() {
        if let party = partyControls { party.publishPlayPause(playing: false, position: livePosition()); return }
        if let cast = castControls { cast.playPause(false); return }
        pauseLocal()
    }

    private func pauseLocal() {
        cancelFade()
        resetAutomix()
        dropStaleMix()
        players[active].pause()
        players[standby].pause()
        isPlaying = false
        updateNowPlaying()
        updatePresence()
        saveQueue()
    }

    func next() {
        if let party = partyControls { party.publishNext(); return }
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            advance(to: index + 1)
        } else if repeatMode == .all {
            advance(to: 0)
        } else if settings.autoplay, let seed = current {
            Task {
                await fetchRadio(seed: seed, replaceAfterCurrent: false)
                if index + 1 < queue.count { advance(to: index + 1) }
            }
        }
    }

    func previous() {
        if let party = partyControls {
            if position > 4 { party.publishSeek(0) } else { party.publishPrevious() }
            return
        }
        if position > 4 || index == 0 {
            seek(to: 0)
        } else {
            advance(to: index - 1)
        }
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        if let party = partyControls { party.publishJump(i); return }
        advance(to: i)
    }

    func seek(to seconds: Double) {
        if let party = partyControls { party.publishSeek(seconds); return }
        if let cast = castControls { cast.seek(to: seconds); position = seconds; return }
        seekLocal(to: seconds)
    }

    private func seekLocal(to seconds: Double) {
        cancelFade()
        resetAutomix()
        dropStaleMix()
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        players[active].seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        position = seconds
        endHandled = false
        updateNowPlaying()
        updatePresence()
    }

    func toggleShuffle() {
        if let party = partyControls, let cur = current {
            // In a party, shuffle reorders what's coming up for everyone.
            var rest = Array(queue[(index + 1)...])
            rest.shuffle()
            party.publishQueue(Array(queue[...index]) + rest, index: index)
            _ = cur
            return
        }
        shuffle.toggle()
        guard let cur = current else { return }
        if shuffle {
            originalQueue = queue
            var rest = queue
            rest.remove(at: index)
            rest.shuffle()
            queue = [cur] + rest
            index = 0
        } else if !originalQueue.isEmpty {
            let known = Set(originalQueue.map(\.videoId))
            queue = originalQueue + queue.filter { !known.contains($0.videoId) }
            index = queue.firstIndex { $0.videoId == cur.videoId } ?? 0
        }
        invalidatePrepared()
        saveQueue()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        invalidatePrepared()
    }

    func move(from source: IndexSet, to destination: Int) {
        // Offsets are relative to the Up Next list (after the current track).
        let base = index + 1
        if let party = partyControls, let from = source.first, queue.indices.contains(base + from) {
            let to = destination > from ? destination - 1 : destination
            party.publishMove(from: base + from, to: base + to, videoId: queue[base + from].videoId)
            return
        }
        var upcoming = Array(queue[base...])
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange(base..., with: upcoming)
        invalidatePrepared()
        saveQueue()
    }

    func removeUpcoming(at offsets: IndexSet) {
        let base = index + 1
        if let party = partyControls {
            for o in offsets where queue.indices.contains(base + o) { party.publishRemove(queue[base + o].videoId) }
            return
        }
        let absolute = offsets.map { $0 + base }.filter { queue.indices.contains($0) }
        for i in absolute.sorted(by: >) { queue.remove(at: i) }
        invalidatePrepared()
        saveQueue()
    }

    func clearUpNext() {
        guard index + 1 < queue.count else { return }
        if let party = partyControls { party.publishClearUpcoming(); return }
        queue.removeSubrange((index + 1)...)
        invalidatePrepared()
        saveQueue()
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        carriedRate = nil
        if isPlaying { players[active].rate = rate }
        updateNowPlaying()
    }

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        stopAfterCurrent = false
        guard let minutes, minutes > 0 else { sleepTimerEnd = nil; return }
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerEnd = end
        sleepTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.party?.detach()
                self?.pauseLocal()
                self?.sleepTimerEnd = nil
            }
        }
    }

    func stop() {
        pauseLocal()
        players.forEach { $0.replaceCurrentItem(with: nil) }
        queue = []
        index = 0
        position = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        saveQueue()
    }

    func reloadLyrics() {
        guard let song = current else { return }
        loadLyrics(for: song, force: true)
    }

    // MARK: Loading

    private func advance(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        if let cast = castControls {
            index = newIndex
            position = 0
            duration = queue[newIndex].durationSeconds ?? 0
            cast.play(from: newIndex)
            songDidStart(beforeLoad: true)
            return
        }
        cancelFade()
        resetAutomix()
        if let prepared = preparedIndex, prepared == newIndex, preparedSongId == queue[newIndex].videoId,
           players[standby].currentItem != nil {
            // Hand over to the pre-buffered player: no gap.
            players[active].pause()
            players[active].replaceCurrentItem(with: nil)
            active = standby
            index = newIndex
            preparedIndex = nil
            preparedSongId = nil
            players[active].volume = gain[active]
            players[active].seek(to: .zero)
            carriedRate = nil
            players[active].playImmediately(atRate: playbackRate)
            isPlaying = true
            songDidStart()
        } else {
            index = newIndex
            loadCurrent(autoplay: true)
        }
    }

    private func loadCurrent(autoplay: Bool, resumeAt: Double = 0) {
        guard let song = current else { return }
        if let cast = castControls {
            players[active].pause()
            position = resumeAt
            duration = song.durationSeconds ?? 0
            isLoading = true
            cast.load(queue: queue, index: index, position: resumeAt, autoplay: autoplay)
            songDidStart(beforeLoad: true)
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        errorMessage = nil
        isLoading = true
        position = resumeAt
        duration = song.durationSeconds ?? 0
        invalidatePrepared()
        players[active].pause()
        songDidStart(beforeLoad: true)

        Task {
            do {
                let built = try await self.makeItem(for: song)
                let item = built.0
                let gainValue = built.1
                let info = built.2
                self.knownDurations[self.active] = built.3
                self.endHandled = false
                guard generation == self.loadGeneration else { return }
                self.gain[self.active] = gainValue
                self.streamInfo = info
                let player = self.players[self.active]
                player.replaceCurrentItem(with: item)
                player.volume = gainValue
                self.observeEnd(of: item, player: self.active)
                if resumeAt > 0 { _ = await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
                if autoplay {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.carriedRate = nil
                    player.playImmediately(atRate: self.playbackRate)
                    self.isPlaying = true
                }
                self.isLoading = false
                self.updateNowPlaying()
                self.updatePresence()
            } catch {
                guard generation == self.loadGeneration else { return }
                self.isLoading = false
                self.errorMessage = "\(song.title): \(error.localizedDescription)"
                // Skip what can't be played rather than stopping the queue.
                if autoplay && self.index + 1 < self.queue.count && self.party?.isActive != true {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if generation == self.loadGeneration { self.advance(to: self.index + 1) }
                } else {
                    self.isPlaying = false
                }
            }
        }
    }

    /// Builds the AVPlayerItem for a song: local file, download, cache, or stream.
    private func makeItem(for song: Song, preferFile: Bool = false) async throws -> (AVPlayerItem, Float, String, Double?) {
        if let name = song.localFile {
            let url = LibraryStore.importsDirectory.appendingPathComponent(name)
            return (configured(AVPlayerItem(url: url)), 1, "Local file · \(url.pathExtension.uppercased())", nil)
        }
        if let url = LibraryStore.downloadURL(for: song.videoId) {
            return (configured(AVPlayerItem(url: url)), 1, "Downloaded · \(Self.codecName(url))", song.durationSeconds)
        }
        if let url = AudioCache.url(for: song.videoId) {
            return (configured(AVPlayerItem(url: url)), 1, "Cached · \(Self.codecName(url))", song.durationSeconds)
        }
        var quality = settings.quality
        if quality.allowsOpus && !OpusSupport.isAvailable { quality = .high }
        var stream = try await StreamResolver.shared.resolve(song.videoId, quality: quality)
        var g: Float = 1
        if settings.normalize, let db = stream.loudnessDb, db > 0 {
            g = Float(pow(10, -db / 20))
        }
        if stream.isOpus {
            // Opus comes in WebM, which AVPlayer can't open: fetch it whole (a couple of
            // seconds), repackage it into CAF and play that file.
            do {
                let raw = try await StreamLoader.fetchAll(videoId: song.videoId, stream: stream)
                let file = try StreamLoader.playableFile(from: raw, stream: stream)
                let url = try AudioCache.write(file.data, for: song.videoId, ext: file.ext)
                if await OpusSupport.verify(url) {
                    return (configured(AVPlayerItem(url: url)), g, stream.codecDescription, stream.durationSeconds ?? song.durationSeconds)
                }
                try? FileManager.default.removeItem(at: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall through to AAC below.
            }
            stream = try await StreamResolver.shared.resolve(song.videoId, forceFresh: true, quality: .high)
        }
        if stream.isHLS {
            let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
            return (configured(AVPlayerItem(asset: asset)), g, "HLS · \(stream.clientName)", stream.durationSeconds)
        }
        if preferFile {
            // Automix needs the whole next track on disk to analyse and to start it on the beat.
            if let raw = try? await StreamLoader.fetchAll(videoId: song.videoId, stream: stream),
               let url = try? AudioCache.write(raw, for: song.videoId, ext: "m4a") {
                return (configured(AVPlayerItem(url: url)), g, stream.codecDescription, stream.durationSeconds ?? song.durationSeconds)
            }
        }
        loaders[song.videoId]?.cancelAll()
        let loader = StreamLoader(videoId: song.videoId, stream: stream)
        loaders[song.videoId] = loader
        trimLoaders()
        return (configured(AVPlayerItem(asset: loader.makeAsset())), g, stream.codecDescription, stream.durationSeconds ?? song.durationSeconds)
    }

    nonisolated static func codecName(_ url: URL) -> String {
        url.pathExtension.lowercased() == "caf" ? "Opus" : "AAC"
    }

    private func configured(_ item: AVPlayerItem) -> AVPlayerItem {
        item.audioTimePitchAlgorithm = .spectral
        item.preferredForwardBufferDuration = 60
        return item
    }

    private func trimLoaders() {
        let keep = Set(queue[max(0, index - 1)..<min(queue.count, index + 3)].map(\.videoId))
        for (id, loader) in loaders where !keep.contains(id) {
            loader.cancelAll()
            loaders[id] = nil
        }
    }

    private func observeEnd(of item: AVPlayerItem, player: Int) {
        let token = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                           object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemEnded(player: player) }
        }
        endObservers.append(token)
        let failed = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                            object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemFailed(player: player) }
        }
        endObservers.append(failed)
        if endObservers.count > 8 {
            NotificationCenter.default.removeObserver(endObservers.removeFirst())
        }
    }

    @ObservationIgnored private var recoveryAttempts: [String: Int] = [:]

    /// The stream broke mid-song: fetch a fresh link and resume where it stopped, once.
    private func itemFailed(player: Int) {
        guard player == active, let song = current else { return }
        let tries = recoveryAttempts[song.videoId, default: 0]
        if tries < 2 {
            recoveryAttempts[song.videoId] = tries + 1
            StreamResolver.shared.invalidate(song.videoId)
            loadCurrent(autoplay: true, resumeAt: position)
        } else {
            errorMessage = "\(song.title) stopped streaming. Skipping."
            if hasNext { next() } else { pauseLocal() }
        }
    }

    private func itemEnded(player: Int) {
        guard player == active, !fading else { return }
        endHandled = true
        if let party, party.isActive, let song = current {
            // The party decides what plays next; tell it this song is over.
            party.trackEnded(song.videoId)
            return
        }
        if stopAfterCurrent {
            stopAfterCurrent = false
            pauseLocal()
            seekLocal(to: 0)
            return
        }
        if repeatMode == .one {
            seekLocal(to: 0)
            carriedRate = nil
            players[active].playImmediately(atRate: playbackRate)
            scrobbled = false
            startedAt = Date()
            return
        }
        if hasNext || settings.autoplay {
            next()
        } else {
            isPlaying = false
            seekLocal(to: 0)
            players[active].pause()
            updateNowPlaying()
        }
    }

    // MARK: Pre-buffering and crossfade

    private var nextIndex: Int? {
        if repeatMode == .one { return nil }
        if index + 1 < queue.count { return index + 1 }
        if repeatMode == .all && !queue.isEmpty { return 0 }
        return nil
    }

    private func invalidatePrepared() {
        if castControls != nil { CastManager.shared.upcomingChanged() }
        resetAutomix()
        preparedIndex = nil
        preparedSongId = nil
        players[standby].replaceCurrentItem(with: nil)
    }

    private func prepareNext() {
        guard let n = nextIndex, preparedIndex != n || preparedSongId != queue[n].videoId else { return }
        let song = queue[n]
        preparedIndex = n
        preparedSongId = song.videoId
        let slot = standby
        Task {
            guard let prepared = try? await self.makeItem(for: song, preferFile: self.automixOn) else {
                if self.preparedSongId == song.videoId { self.preparedIndex = nil; self.preparedSongId = nil }
                return
            }
            let item = prepared.0
            let g = prepared.1
            self.knownDurations[slot] = prepared.3
            guard self.preparedSongId == song.videoId, slot == self.standby else { return }
            self.gain[slot] = g
            self.players[slot].volume = 0
            self.players[slot].replaceCurrentItem(with: item)
            self.observeEnd(of: item, player: slot)
        }
    }

    @ObservationIgnored private var fadeFrom: AVPlayer?
    @ObservationIgnored private var fadeTo: AVPlayer?
    @ObservationIgnored private var fadeGains: (from: Float, to: Float) = (1, 1)
    @ObservationIgnored private var fadeStep = 0
    @ObservationIgnored private var fadeSteps = 1

    private func startCrossfade(over seconds: Double) {
        guard let n = nextIndex, preparedIndex == n, players[standby].currentItem != nil else { return }
        fading = true
        let from = players[active]
        let to = players[standby]
        fadeFrom = from
        fadeTo = to
        fadeGains = (gain[active], gain[standby])
        to.volume = 0
        to.seek(to: .zero)
        carriedRate = nil
        to.playImmediately(atRate: playbackRate)
        fadeSteps = max(1, Int(seconds * 20))
        fadeStep = 0
        // Hand the UI to the incoming track immediately.
        active = standby
        index = n
        preparedIndex = nil
        preparedSongId = nil
        songDidStart()
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: seconds / Double(fadeSteps), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeTick() }
        }
    }

    private func fadeTick() {
        fadeStep += 1
        let t = Float(fadeStep) / Float(fadeSteps)
        fadeFrom?.volume = fadeGains.from * (1 - t)
        fadeTo?.volume = fadeGains.to * t
        if fadeStep >= fadeSteps {
            fadeTimer?.invalidate()
            fadeTimer = nil
            fadeFrom?.pause()
            fadeFrom?.replaceCurrentItem(with: nil)
            fadeFrom = nil
            fadeTo = nil
            fading = false
        }
    }

    private func cancelFade() {
        guard fading else { return }
        fadeTimer?.invalidate()
        fading = false
        players[standby].pause()
        players[standby].replaceCurrentItem(with: nil)
        players[active].volume = gain[active]
        if automixActive { finishAutomixCleanup() }
    }

    // MARK: Automix

    @ObservationIgnored private var automixPlan: TransitionPlan?
    @ObservationIgnored private var automixPlanningKey: String?
    @ObservationIgnored private var automixScheduled = false
    @ObservationIgnored private var automixActive = false
    @ObservationIgnored private var automixOutgoing: AVPlayer?
    /// After a beat-matched mix the new song keeps the tempo it came in at, because
    /// changing AVPlayer's rate mid-song makes the time-stretcher drop out for a moment.
    @ObservationIgnored private var carriedRate: Float?
    /// The incoming song still carries the mix's volume curve and filter; dropped at the
    /// next pause or seek, since swapping it while audible would glitch too.
    @ObservationIgnored private var staleMixOnActive = false
    private var songRate: Float { carriedRate ?? playbackRate }

    /// Automix runs only when nothing else is bending time: normal speed, no repeat-one, no stop-after.
    private var automixOn: Bool {
        settings.automix && playbackRate == 1 && repeatMode != .one && !stopAfterCurrent && party?.isActive != true
    }

    private func automixTick(remaining: Double) {
        guard !fading, let n = nextIndex, queue.indices.contains(n) else { return }
        let key = (current?.videoId ?? "") + ">" + queue[n].videoId
        if automixPlan == nil {
            // Plan once the next track is on disk in the standby player.
            if remaining < 80, automixPlanningKey != key, preparedIndex == n, preparedSongId == queue[n].videoId,
               let url = (players[standby].currentItem?.asset as? AVURLAsset)?.url, url.isFileURL {
                automixPlanningKey = key
                planAutomix(key: key, incomingURL: url)
            }
            return
        }
        guard let plan = automixPlan, !automixScheduled else { return }
        let lead = plan.outStart - livePosition()
        if lead <= 1.2 && lead > 0.1 {
            scheduleAutomix(plan)
        } else if lead <= 0.1 {
            // Missed the moment (a stall, say): let the song end normally.
            resetAutomix()
            automixPlanningKey = key
        }
    }

    private func planAutomix(key: String, incomingURL: URL) {
        guard let outgoing = current, let n = nextIndex else { return }
        let incoming = queue[n]
        let outDuration = duration
        let inDuration = knownDurations[standby] ?? incoming.durationSeconds ?? 240
        let beats = settings.automixBeats
        let outRate = Double(songRate)
        automixStatus = "Automix: analysing…"
        Task {
            guard let outURL = await self.fileURL(for: outgoing) else {
                self.automixStatus = "Automix: couldn't read this song"
                return
            }
            async let tail = AutomixAudio.grid(videoId: outgoing.videoId, url: outURL, section: .tail, duration: outDuration)
            async let head = AutomixAudio.grid(videoId: incoming.videoId, url: incomingURL, section: .head, duration: inDuration)
            let (out, inc) = await (tail, head)
            // Still the same pair, and nothing was reset meanwhile?
            guard self.automixPlanningKey == key, self.current?.videoId == outgoing.videoId,
                  self.nextIndex.map({ self.queue[$0].videoId }) == incoming.videoId else { return }
            guard let out, let inc,
                  let plan = AutomixPlanner.plan(outgoing: out, outDuration: outDuration, incoming: inc,
                                                 beats: beats, notBefore: self.livePosition() + 4,
                                                 outgoingRate: outRate) else {
                self.automixStatus = "Automix: no clean transition found, using a normal ending"
                return
            }
            let outItem = self.players[self.active].currentItem
            let inPlayer = self.players[self.standby]
            guard let inItem = inPlayer.currentItem else { return }

            // Outgoing: equal-power fade from the mix point; bass leaves at the swap.
            // Item-time lengths on the outgoing song (it may itself be running at outRate).
            let outFade = plan.fadeSeconds * outRate
            let swapOut = plan.outStart + outFade * plan.swapAt
            let beatOut = 60 / out.bpm
            let outFilter = BassSwapFilter(points: [(swapOut - beatOut / 2, 20), (swapOut + beatOut / 2, 220)])
            // Incoming (its own time runs at `rate`): fade in; bass arrives at the swap.
            let inFade = plan.fadeSeconds * plan.rate
            let swapIn = plan.inStart + inFade * plan.swapAt
            let beatIn = beatOut / outRate * plan.rate
            let inFilter = BassSwapFilter(points: [(swapIn - beatIn / 2, 220), (swapIn + beatIn / 2, 20)])

            let outMix = await AutomixAudio.audioMix(for: outItem ?? inItem,
                volume: [(0.0, Float(1))] + AutomixAudio.equalPower(from: plan.outStart, to: plan.outStart + outFade, fadingIn: false),
                filter: plan.beatMatched ? outFilter : nil)
            let inMix = await AutomixAudio.audioMix(for: inItem,
                volume: AutomixAudio.equalPower(from: plan.inStart, to: plan.inStart + inFade, fadingIn: true),
                filter: plan.beatMatched ? inFilter : nil)
            guard self.automixPlanningKey == key, let outItem, outItem === self.players[self.active].currentItem,
                  inItem === self.players[self.standby].currentItem else { return }
            outItem.audioMix = outMix
            inItem.audioMix = inMix
            _ = await inPlayer.seek(to: CMTime(seconds: plan.inStart, preferredTimescale: 48000),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.automixPlanningKey == key else { return }
            self.automixPlan = plan
            self.automixStatus = plan.summary
        }
    }

    /// Starts the incoming track at the exact host time the outgoing one reaches the mix point.
    private func scheduleAutomix(_ plan: TransitionPlan) {
        let outPlayer = players[active]
        let inPlayer = players[standby]
        guard let outItem = outPlayer.currentItem, let inItem = inPlayer.currentItem,
              inItem.status == .readyToPlay else {
            resetAutomix()
            return
        }
        let hostClock = CMClockGetHostTimeClock()
        let mixPoint = CMTime(seconds: plan.outStart, preferredTimescale: 48000)
        var hostTime: CMTime
        if let timebase = outItem.timebase {
            hostTime = CMSyncConvertTime(mixPoint, from: timebase, to: hostClock)
        } else {
            let lead = max(0, plan.outStart - livePosition())
            hostTime = CMTimeAdd(CMClockGetTime(hostClock), CMTime(seconds: lead, preferredTimescale: 48000))
        }
        if !hostTime.isValid { hostTime = CMClockGetTime(hostClock) }
        inPlayer.automaticallyWaitsToMinimizeStalling = false
        inPlayer.volume = gain[standby]
        inPlayer.setRate(Float(plan.rate), time: CMTime(seconds: plan.inStart, preferredTimescale: 48000), atHostTime: hostTime)
        automixScheduled = true
        let lead = max(0, plan.outStart - livePosition()) / Double(max(songRate, 0.1))
        DispatchQueue.main.asyncAfter(deadline: .now() + lead) { [weak self] in
            MainActor.assumeIsolated { self?.automixStarted(plan) }
        }
    }

    private func automixStarted(_ plan: TransitionPlan) {
        guard automixScheduled, automixPlan != nil, let n = nextIndex else { return }
        automixActive = true
        fading = true
        automixOutgoing = players[active]
        active = standby
        index = n
        preparedIndex = nil
        preparedSongId = nil
        isPlaying = true
        songDidStart()
        // The new song is already running at the matched tempo; it stays there.
        carriedRate = abs(plan.rate - 1) > 0.001 ? Float(plan.rate) : nil
        updateNowPlaying()
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.fadeSeconds + 0.2) { [weak self] in
            MainActor.assumeIsolated { self?.automixFinished(plan) }
        }
    }

    private func automixFinished(_ plan: TransitionPlan) {
        guard automixActive else { return }
        automixOutgoing?.pause()
        automixOutgoing?.currentItem?.audioMix = nil
        automixOutgoing?.replaceCurrentItem(with: nil)
        finishAutomixCleanup()
    }

    /// Clears the bookkeeping once a mix is over (or abandoned mid-way).
    private func finishAutomixCleanup() {
        automixActive = false
        fading = false
        automixScheduled = false
        automixPlan = nil
        automixOutgoing = nil
        // Touching the playing item's mix, stall policy or rate here would make it skip;
        // leave them and tidy up at the next pause or seek.
        staleMixOnActive = true
    }

    private func dropStaleMix() {
        guard staleMixOnActive else { return }
        staleMixOnActive = false
        players[active].currentItem?.audioMix = nil
        players[active].automaticallyWaitsToMinimizeStalling = true
        players[active].volume = gain[active]
    }

    /// Drops a planned (not yet started) mix and undoes its fades, so the song plays on untouched.
    private func resetAutomix() {
        if automixActive { return }
        if automixScheduled {
            players[standby].pause()
            players[standby].automaticallyWaitsToMinimizeStalling = true
        }
        if automixPlan != nil || automixScheduled {
            players[active].currentItem?.audioMix = nil
            players[standby].currentItem?.audioMix = nil
        }
        automixPlan = nil
        automixScheduled = false
        automixPlanningKey = nil
        if automixStatus != nil { automixStatus = nil }
    }

    /// A file holding the whole song, fetching it if it was only streamed.
    private func fileURL(for song: Song) async -> URL? {
        if let name = song.localFile { return LibraryStore.importsDirectory.appendingPathComponent(name) }
        if let url = LibraryStore.downloadURL(for: song.videoId) { return url }
        if let url = AudioCache.url(for: song.videoId) { return url }
        guard let stream = try? await StreamResolver.shared.resolve(song.videoId), !stream.isHLS,
              let raw = try? await StreamLoader.fetchAll(videoId: song.videoId, stream: stream),
              let file = try? StreamLoader.playableFile(from: raw, stream: stream) else { return nil }
        return try? AudioCache.write(file.data, for: song.videoId, ext: file.ext)
    }

    /// The real length of what each player holds, when YouTube told us (see ResolvedStream.durationSeconds).
    @ObservationIgnored private var knownDurations: [Double?] = [nil, nil]
    @ObservationIgnored private var endHandled = false

    private func tick(player: Int) {
        // While casting, the TV's status (applyCastStatus) drives position and state.
        if castControls != nil { return }
        guard player == active, let item = players[active].currentItem else { return }
        let itemDuration = CMTimeGetSeconds(item.duration)
        if let known = knownDurations[active], known > 0 {
            duration = known
        } else if itemDuration.isFinite && itemDuration > 0 {
            duration = itemDuration
        }
        let t = CMTimeGetSeconds(players[active].currentTime())
        if t.isFinite { position = duration > 0 ? min(t, duration) : t }
        syncNowPlayingIfNeeded()
        // AVPlayer overestimates these files' length and keeps "playing" silence past the
        // end, so the end is called from the real duration rather than waiting for it.
        if let known = knownDurations[active], known > 0, isPlaying, !fading, !endHandled, t.isFinite, t >= known - 0.2 {
            endHandled = true
            itemEnded(player: active)
            return
        }
        guard duration > 0, isPlaying else { return }
        let remaining = duration - position

        if remaining < (automixOn ? 100 : 30) { prepareNext() }
        if automixOn {
            automixTick(remaining: remaining)
        } else {
            let fade = settings.crossfade
            if fade > 0, !fading, remaining <= fade, remaining > 0.3, !stopAfterCurrent, repeatMode != .one, party?.isActive != true {
                startCrossfade(over: min(fade, remaining))
            }
        }
        if index >= queue.count - 2, settings.autoplay, !fetchingRadio, let seed = current, repeatMode == .off, party?.isActive != true,
           Date().timeIntervalSince(lastRadioAttempt) > 30 {
            lastRadioAttempt = Date()
            Task { await fetchRadio(seed: seed, replaceAfterCurrent: false) }
        }
        if !scrobbled, position >= min(240, max(30, duration / 2)) {
            scrobbled = true
            scrobble()
        }
    }

    private func statusChanged(player: Int, status: AVPlayer.TimeControlStatus) {
        guard player == active else { return }
        if status == .playing { isLoading = false }
        if status == .waitingToPlayAtSpecifiedRate { isLoading = true }
        updateNowPlaying()
    }

    // MARK: Radio

    private func fetchRadio(seed: Song, replaceAfterCurrent: Bool) async {
        guard !fetchingRadio else { return }
        fetchingRadio = true
        defer { fetchingRadio = false }
        do {
            let next: WatchNext
            if let token = radioToken, !replaceAfterCurrent {
                next = try await YTMusic.watchMore(token, playlistId: radioPlaylistId)
            } else {
                next = try await YTMusic.radio(videoId: seed.videoId)
                radioPlaylistId = "RDAMVM" + seed.videoId
                if replaceAfterCurrent { lyricsBrowseId = next.lyricsBrowseId; relatedBrowseId = next.relatedBrowseId }
            }
            radioToken = next.continuation
            let known = Set(queue.map(\.videoId))
            let fresh = next.songs.filter { !known.contains($0.videoId) }
            let nextBefore = nextIndex.map { queue[$0].videoId }
            queue += fresh
            // Appending only changes what comes next if the queue had run out; keep a
            // prepared track (and any Automix plan for it) otherwise.
            if nextIndex.map({ queue[$0].videoId }) != nextBefore || preparedSongId != nextBefore {
                invalidatePrepared()
            }
            saveQueue()
        } catch {
            radioToken = nil
        }
    }

    // MARK: Song lifecycle

    private func songDidStart(beforeLoad: Bool = false) {
        guard let song = current else { return }
        endHandled = false
        if let known = knownDurations[active], known > 0 { duration = known }
        startedAt = Date()
        scrobbled = false
        lyricsOffset = 0
        if !beforeLoad { position = 0 }
        LibraryStore.shared.recordPlay(song)
        loadLyrics(for: song)
        loadArtwork(for: song)
        updateNowPlaying()
        updatePresence()
        saveQueue()
        if let config = settings.lastFM { Task { await LastFM.nowPlaying(config, song: song) } }
        if let token = settings.listenBrainzToken { Task { await ListenBrainz.submit(token: token, song: song, listenedAt: nil, playingNow: true) } }
        if !beforeLoad { trimLoaders() }
    }

    private func scrobble() {
        guard let song = current, !song.isVideo || song.albumName != nil else { return }
        let started = startedAt
        if let config = settings.lastFM { Task { await LastFM.scrobble(config, song: song, startedAt: started) } }
        if let token = settings.listenBrainzToken { Task { await ListenBrainz.submit(token: token, song: song, listenedAt: started, playingNow: false) } }
    }

    private func loadLyrics(for song: Song, force: Bool = false) {
        if !force && lyricsSongId == song.videoId { return }
        lyricsSongId = song.videoId
        lyricsTask?.cancel()
        lyrics = nil
        lyricsLoading = true
        let providers = settings.lyricsProviders
        lyricsTask = Task {
            var browseId: String?
            var related: String?
            if !song.isLocal, let next = try? await YTMusic.radio(videoId: song.videoId) {
                browseId = next.lyricsBrowseId
                related = next.relatedBrowseId
            }
            if Task.isCancelled { return }
            self.relatedBrowseId = related
            let found = await LyricsService.fetch(for: song, duration: self.duration > 0 ? self.duration : nil,
                                                  lyricsBrowseId: browseId, providers: providers)
            guard !Task.isCancelled, self.current?.videoId == song.videoId else { return }
            self.lyrics = found
            self.lyricsLoading = false
            self.lyricsTask = nil
        }
    }

    // MARK: System integration

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    self.party?.detach()
                    self.isPlaying = false
                    self.updateNowPlaying()
                } else if options?.contains(.shouldResume) == true {
                    self.resume()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated {
                self?.party?.detach()
                self?.pauseLocal()
            }
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = e.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
        center.likeCommand.localizedTitle = "Love"
        center.likeCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if let song = self?.current { LibraryStore.shared.toggleLike(song) }
            }
            return .success
        }
    }

    // What the lock screen was last told, so it can be corrected when it drifts.
    @ObservationIgnored private var nowPlayingElapsed: Double = 0
    @ObservationIgnored private var nowPlayingRate: Double = 0
    @ObservationIgnored private var nowPlayingDuration: Double = 0
    @ObservationIgnored private var nowPlayingStamp = Date()

    /// The rate the lock screen should count at: only while sound is actually coming out.
    private var audibleRate: Double {
        guard isPlaying else { return 0 }
        if castControls != nil { return isLoading ? 0 : Double(playbackRate) }
        return players[active].timeControlStatus == .playing ? Double(players[active].rate) : 0
    }

    /// Re-sends the position when the lock screen's own estimate has drifted from the player.
    private func syncNowPlayingIfNeeded() {
        let expected = nowPlayingElapsed + Date().timeIntervalSince(nowPlayingStamp) * nowPlayingRate
        if abs(expected - livePosition()) > 0.75 || abs(audibleRate - nowPlayingRate) > 0.01
            || (duration > 0 && abs(duration - nowPlayingDuration) > 0.5) {
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let song = current else { return }
        let elapsed = livePosition()
        let rate = audibleRate
        nowPlayingElapsed = elapsed
        nowPlayingRate = rate
        nowPlayingDuration = duration
        nowPlayingStamp = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = song.albumName { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for song: Song) {
        artworkTask?.cancel()
        nowPlayingArtwork = nil
        Task.detached(priority: .utility) { await OfflineArtwork.remember(song) }
        artworkTask = Task {
            guard let image = await ArtworkStore.image(for: song.artworkURL(544)) else { return }
            guard !Task.isCancelled, self.current?.videoId == song.videoId else { return }
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlaying()
        }
    }

    private func updatePresence() {
        guard settings.discordEnabled, let token = settings.discordToken else { return }
        DiscordPresence.shared.connect(token: token)
        DiscordPresence.shared.update(song: current, position: position, duration: duration, playing: isPlaying)
    }

    // MARK: Persistence

    private struct SavedQueue: Codable {
        var queue: [Song]
        var index: Int
        var position: Double
        var shuffle: Bool
        var repeatMode: RepeatMode
        var source: String?
    }

    nonisolated private static var queueFile: URL { LibraryStore.supportDirectory.appendingPathComponent("queue.json") }

    private func saveQueue() {
        let saved = SavedQueue(queue: Array(queue.prefix(500)), index: index, position: position,
                               shuffle: shuffle, repeatMode: repeatMode, source: sourceTitle)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: PlayerController.queueFile, options: .atomic) }
        }
    }

    private func restoreQueue() {
        guard let data = try? Data(contentsOf: Self.queueFile),
              let saved = try? JSONDecoder().decode(SavedQueue.self, from: data), !saved.queue.isEmpty else { return }
        queue = saved.queue
        index = min(saved.index, saved.queue.count - 1)
        position = saved.position
        shuffle = saved.shuffle
        repeatMode = saved.repeatMode
        sourceTitle = saved.source
        duration = current?.durationSeconds ?? 0
        if let song = current { loadArtwork(for: song) }
    }

    func persistNow() { saveQueue() }

    // MARK: Google Cast

    /// A cast session started: stop here and carry on from the same spot on the TV.
    func castStarted() {
        guard party?.isActive != true, current != nil else { return }
        let resumeAt = livePosition()
        let wasPlaying = isPlaying
        pauseLocal()
        isPlaying = wasPlaying
        loadCurrent(autoplay: wasPlaying, resumeAt: resumeAt)
    }

    /// The cast session ended: pick up on the phone where the TV left off (paused, as phones do).
    func castEnded(position resumeAt: Double, playing: Bool) {
        guard current != nil else { return }
        isPlaying = false
        loadCurrent(autoplay: false, resumeAt: resumeAt)
    }

    /// Mirrors the TV's state into the player the screens read.
    func applyCastStatus(videoId: String?, position tvPosition: Double, duration tvDuration: Double,
                         playing: Bool, loading: Bool, finished: Bool) {
        guard party?.isActive != true else { return }
        if let videoId, current?.videoId != videoId {
            // The TV moved on by itself: follow it.
            let start = max(0, index - 1)
            if let found = queue[start...].firstIndex(where: { $0.videoId == videoId }) ?? queue.firstIndex(where: { $0.videoId == videoId }) {
                index = found
                songDidStart()
            }
        }
        if tvPosition.isFinite { position = tvPosition }
        if tvDuration > 0 { duration = tvDuration }
        isPlaying = playing
        isLoading = loading
        if finished, index + 1 < queue.count, !isLoading {
            advance(to: index + 1)
        } else if finished, index + 1 >= queue.count, settings.autoplay, let seed = current, !fetchingRadio {
            Task {
                await fetchRadio(seed: seed, replaceAfterCurrent: false)
                if index + 1 < queue.count { advance(to: index + 1) }
            }
        }
        updateNowPlaying()
    }

    // MARK: Listen Together (inbound)

    /// Moves the local player to where the party is. Called on every party frame and once a
    /// second; it only acts when something actually differs, so calling it often is cheap.
    func applyParty(queue newQueue: [Song], index newIndex: Int, track: Song?, target: Double, playing: Bool, startInMs: Double) {
        applyingRemote = true
        defer { applyingRemote = false }
        guard let track else {
            if isPlaying { pauseLocal() }
            return
        }
        var list = newQueue
        var i = newIndex
        if !list.indices.contains(i) || list[i].videoId != track.videoId {
            if let found = list.firstIndex(where: { $0.videoId == track.videoId }) { i = found } else { list.insert(track, at: 0); i = 0 }
        }
        let trackChanged = current?.videoId != track.videoId
        if list.map(\.videoId) != queue.map(\.videoId) || index != i {
            let nextBefore = nextIndex.map { queue[$0].videoId }
            queue = list
            index = i
            if nextIndex.map({ queue[$0].videoId }) != nextBefore { invalidatePrepared() }
            saveQueue()
        }
        // Already loading this track: let it finish rather than restarting the load.
        if !trackChanged && isLoading { return }
        if trackChanged || players[active].currentItem == nil {
            loadCurrent(autoplay: playing && startInMs < 80, resumeAt: max(0, target))
            if playing && startInMs >= 80 { scheduleRemoteResume(after: startInMs) }
            return
        }
        guard !isLoading else { return }
        let drift = livePosition() - target
        if playing {
            if startInMs >= 80 {
                // A resume scheduled a moment ahead: wait for it, then start with everyone.
                if !isPlaying { scheduleRemoteResume(after: startInMs) }
            } else if !isPlaying {
                if abs(drift) > 0.15 { seekLocal(to: target) }
                resumeLocal()
            } else if abs(drift) > 0.75 {
                seekLocal(to: target)
            }
        } else {
            if isPlaying { pauseLocal() }
            if abs(drift) > 0.5 { seekLocal(to: target) }
        }
    }

    @ObservationIgnored private var remoteResumeWork: DispatchWorkItem?

    private func scheduleRemoteResume(after ms: Double) {
        remoteResumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.party?.reconcile() }
        }
        remoteResumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000, execute: work)
    }

    /// The exact playhead, read straight from AVPlayer (for lyrics animation).
    func livePosition() -> Double {
        if CastManager.shared.isConnected, party?.isActive != true, let p = CastManager.shared.approximatePosition { return p }
        guard players[active].currentItem != nil else { return position }
        let t = CMTimeGetSeconds(players[active].currentTime())
        return t.isFinite ? t : position
    }

    /// The AVPlayer currently producing sound (for video output and AirPlay).
    var activePlayer: AVPlayer { players[active] }
}
