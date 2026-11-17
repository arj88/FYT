import AppIntents
import Foundation

// Siri and Shortcuts support through App Intents. Unlike SiriKit this needs no special
// Apple entitlement, so it works in a sideloaded build. Each command is an
// AudioPlaybackIntent, which lets iOS start the music without opening the app.
// Siri only recognises phrases that include the app's name, e.g. "Play my downloads on FYT".

// MARK: Shortcuts Siri knows about

struct FYTShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .red

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                "Play a song on \(.applicationName)",
                "Play a song in \(.applicationName)",
                "Play something on \(.applicationName)",
                "Search \(.applicationName)",
                "Find a song on \(.applicationName)",
            ],
            shortTitle: "Play a Song",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play \(.applicationName)",
                "Play music on \(.applicationName)",
                "Play music in \(.applicationName)",
                "Resume \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayLikedSongsIntent(),
            phrases: [
                "Play my liked songs on \(.applicationName)",
                "Play my liked songs in \(.applicationName)",
                "Shuffle my liked songs on \(.applicationName)",
                "Play my favourites on \(.applicationName)",
                "Play my favorites on \(.applicationName)",
            ],
            shortTitle: "Liked Songs",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: PlayDownloadsIntent(),
            phrases: [
                "Play my downloads on \(.applicationName)",
                "Play my downloads in \(.applicationName)",
                "Play downloaded songs on \(.applicationName)",
                "Play offline music on \(.applicationName)",
            ],
            shortTitle: "Downloads",
            systemImageName: "arrow.down.circle.fill"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) on \(.applicationName)",
                "Play \(\.$playlist) in \(.applicationName)",
                "Play my playlist on \(.applicationName)",
                "Play a playlist on \(.applicationName)",
            ],
            shortTitle: "Play a Playlist",
            systemImageName: "music.note.list"
        )
    }
}

// MARK: Play a song by name

struct PlaySongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play a Song"
    static var description = IntentDescription("Finds a song, artist or album and plays it, with similar songs after it.")

    @Parameter(title: "Song", requestValueDialog: IntentDialog("What would you like to play?"))
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result(dialog: "Tell me a song or an artist to play.") }

        // A downloaded match plays even without internet.
        let words = text.lowercased().split(separator: " ").map(String.init)
        if let song = LibraryStore.shared.downloads.first(where: { song in
            let hay = (song.title + " " + song.artist).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }) {
            PlayerController.shared.playRadio(song)
            return .result(dialog: "Playing \(song.title) by \(song.primaryArtist).")
        }

        do {
            let page = try await YTMusic.search(text, filter: .songs)
            var found: Song?
            if case .song(let top)? = page.top { found = top }
            if found == nil {
                for result in page.results {
                    if case .song(let s) = result { found = s; break }
                }
            }
            guard let song = found else {
                return .result(dialog: "I couldn't find \(text) on FYT.")
            }
            PlayerController.shared.playRadio(song)
            return .result(dialog: "Playing \(song.title) by \(song.primaryArtist).")
        } catch {
            return .result(dialog: "FYT can't search right now. Check your internet connection, or say: play my downloads on FYT.")
        }
    }
}

// MARK: Resume / start playing

struct PlayMusicIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play Music"
    static var description = IntentDescription("Resumes what was playing, or shuffles your liked songs.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = PlayerController.shared
        let library = LibraryStore.shared
        if let song = player.current {
            player.resume()
            return .result(dialog: "Playing \(song.title).")
        }
        if !library.liked.isEmpty {
            player.play(library.liked, source: "Liked Songs", shuffled: true)
            return .result(dialog: "Shuffling your liked songs.")
        }
        if !library.downloads.isEmpty {
            player.play(library.downloads, source: "Downloads", shuffled: true)
            return .result(dialog: "Shuffling your downloads.")
        }
        return .result(dialog: "There's nothing to play yet. Try: play a song on FYT.")
    }
}

// MARK: Liked songs

struct PlayLikedSongsIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle Liked Songs"
    static var description = IntentDescription("Shuffles your liked songs.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let liked = LibraryStore.shared.liked
        guard !liked.isEmpty else { return .result(dialog: "You haven't liked any songs yet.") }
        PlayerController.shared.play(liked, source: "Liked Songs", shuffled: true)
        return .result(dialog: "Shuffling your liked songs.")
    }
}

// MARK: Downloads

struct PlayDownloadsIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle Downloads"
    static var description = IntentDescription("Shuffles the songs downloaded to this iPhone. Works offline.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let downloads = LibraryStore.shared.downloads
        guard !downloads.isEmpty else { return .result(dialog: "You don't have any downloads yet.") }
        PlayerController.shared.play(downloads, source: "Downloads", shuffled: true)
        return .result(dialog: "Shuffling your downloads.")
    }
}

// MARK: Your playlists

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play a Playlist"
    static var description = IntentDescription("Plays one of your FYT playlists.")

    @Parameter(title: "Playlist", requestValueDialog: IntentDialog("Which playlist?"))
    var playlist: PlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let list = LibraryStore.shared.playlists.first(where: { $0.id == playlist.id }), !list.songs.isEmpty else {
            return .result(dialog: "That playlist is empty.")
        }
        PlayerController.shared.play(list.songs, source: list.name)
        return .result(dialog: "Playing \(list.name).")
    }
}

struct PlaylistEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static var defaultQuery = PlaylistQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        await all()
    }

    private func all() async -> [PlaylistEntity] {
        await MainActor.run {
            LibraryStore.shared.playlists.map { PlaylistEntity(id: $0.id, name: $0.name) }
        }
    }
}
