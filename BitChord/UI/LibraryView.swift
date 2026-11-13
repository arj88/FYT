import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(ListenTogether.self) private var party
    @Environment(LibraryStore.self) private var library
    @Environment(AccountManager.self) private var account
    @Environment(AppRouter.self) private var router
    @State private var newPlaylist = false
    @State private var newName = ""
    @State private var importing = false
    @State private var filter = 0

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.liked) { row("Liked Songs", "heart.fill", "\(library.liked.count)") }
                NavigationLink(value: Route.downloads) { row("Downloads", "arrow.down.circle.fill", "\(library.downloads.count)") }
                NavigationLink(value: Route.history) { row("History", "clock.fill", nil) }
                NavigationLink(value: Route.localFiles) { row("On This iPhone", "iphone", "\(library.localSongs.count)") }
                Button { router.showParty = true } label: {
                    row("Listen Together", "person.2.wave.2.fill", party.code)
                }
                if account.isSignedIn {
                    NavigationLink(value: Route.youtubeHistory) {
                        row("YouTube History", "clock.arrow.circlepath", nil)
                    }
                    NavigationLink(value: Route.accountLibrary(title: "YouTube Music Playlists", browseId: "FEmusic_liked_playlists")) {
                        row("YouTube Playlists", "music.note.list", nil)
                    }
                    NavigationLink(value: Route.accountLibrary(title: "YouTube Music Albums", browseId: "FEmusic_liked_albums")) {
                        row("YouTube Albums", "square.stack.fill", nil)
                    }
                    NavigationLink(value: Route.accountLibrary(title: "Subscriptions", browseId: "FEmusic_library_corpus_track_artists")) {
                        row("YouTube Artists", "music.mic", nil)
                    }
                }
            }

            Section {
                Button { newPlaylist = true } label: {
                    Label("New Playlist", systemImage: "plus.square.on.square").foregroundStyle(Theme.accent)
                }
                ForEach(library.playlists) { p in
                    NavigationLink(value: Route.localPlaylist(id: p.id)) {
                        HStack(spacing: 12) {
                            PlaylistCollage(songs: p.songs).frame(width: 56, height: 56)
                            VStack(alignment: .leading) {
                                Text(p.name).lineLimit(1)
                                Text("\(p.songs.count) songs").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in idx.map { library.playlists[$0].id }.forEach(library.deletePlaylist) }
            } header: { Text("Playlists") }

            if !library.saved.isEmpty {
                Section {
                    Picker("Saved", selection: $filter) {
                        Text("All").tag(0); Text("Albums").tag(1); Text("Playlists").tag(2); Text("Artists").tag(3)
                    }
                    .pickerStyle(.segmented)
                    ForEach(savedFiltered) { item in
                        if let route = Route.for(item) {
                            NavigationLink(value: route) {
                                HStack(spacing: 12) {
                                    ArtworkImage(url: item.artwork(160), cornerRadius: 6, circle: item.kind == .artist)
                                        .frame(width: 56, height: 56)
                                    VStack(alignment: .leading) {
                                        Text(item.title).lineLimit(1)
                                        Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .contextMenu { ItemMenuItems(item: item) }
                        }
                    }
                } header: { Text("Saved") }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { importing = true } label: { Label("Import Audio Files", systemImage: "square.and.arrow.down") }
                    Button { newPlaylist = true } label: { Label("New Playlist", systemImage: "plus") }
                    NavigationLink(value: Route.settings) { Label("Settings", systemImage: "gearshape") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("New Playlist", isPresented: $newPlaylist) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                if !newName.isEmpty { library.createPlaylist(newName) }
                newName = ""
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
        }
    }

    private var savedFiltered: [ShelfItem] {
        switch filter {
        case 1: return library.saved.filter { $0.kind == .album }
        case 2: return library.saved.filter { $0.kind == .playlist || $0.kind == .podcast || $0.kind == .other }
        case 3: return library.saved.filter { $0.kind == .artist }
        default: return library.saved
        }
    }

    private func row(_ title: String, _ icon: String, _ count: String?) -> some View {
        HStack {
            Label(title, systemImage: icon).foregroundStyle(.primary)
            Spacer()
            if let count { Text(count).foregroundStyle(.secondary) }
        }
    }
}

struct PlaylistCollage: View {
    let songs: [Song]
    var body: some View {
        let arts = Array(songs.prefix(4))
        Group {
            if arts.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { tile(arts[0]); tile(arts[1]) }
                    HStack(spacing: 0) { tile(arts[2]); tile(arts[3]) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let first = arts.first {
                ArtworkImage(url: first.artworkURL(240), cornerRadius: 6)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(UIColor.secondarySystemFill))
                    Image(systemName: "music.note.list").foregroundStyle(.secondary)
                }
            }
        }
    }
    private func tile(_ song: Song) -> some View {
        ArtworkImage(url: song.artworkURL(120), cornerRadius: 0)
    }
}

/// Liked songs, downloads, history and imported files.
struct SongCollectionView: View {
    enum Kind { case liked, downloads, history, local }
    let kind: Kind
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(AccountManager.self) private var account
    @State private var query = ""
    @State private var importing = false

    private var title: String {
        switch kind {
        case .liked: return "Liked Songs"
        case .downloads: return "Downloads"
        case .history: return "History"
        case .local: return "On This iPhone"
        }
    }

    private var songs: [Song] {
        let all: [Song]
        switch kind {
        case .liked: all = library.liked
        case .downloads: all = sortedDownloads
        case .history: all = library.history.map(\.song)
        case .local: all = library.localSongs
        }
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let list = songs
        List {
            if !list.isEmpty {
                PlayShuffleButtons {
                    player.play(list, source: title)
                } shuffle: {
                    player.play(list, source: title, shuffled: true)
                }
                .listRowSeparator(.hidden)
                if kind == .liked || kind == .history {
                    DownloadAllButton(songs: list).listRowSeparator(.hidden)
                }
                if kind == .liked && account.isSyncing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Syncing with YouTube Music…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            if kind == .downloads && query.isEmpty {
                DownloadIssuesSection()
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, song in
                SongRow(song: song) { player.play(list, startAt: i, source: title) }
                    .swipeActions {
                        switch kind {
                        case .liked:
                            Button(role: .destructive) { library.toggleLike(song) } label: { Label("Unlove", systemImage: "heart.slash") }
                        case .downloads:
                            Button(role: .destructive) { library.removeDownload(song) } label: { Label("Delete", systemImage: "trash") }
                        case .local:
                            Button(role: .destructive) { library.removeLocal(song) } label: { Label("Delete", systemImage: "trash") }
                        case .history:
                            Button { player.addToQueue([song]) } label: { Label("Queue", systemImage: "text.badge.plus") }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if list.isEmpty && query.isEmpty && !(kind == .downloads && !library.pendingDownloads.isEmpty) {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon, description: Text(emptyText))
            }
        }
        .searchable(text: $query, prompt: "Filter")
        .navigationTitle(title)
        .task { if kind == .liked { await account.syncLikes(force: false) } }
        .refreshable { if kind == .liked { await account.syncLikes() } }
        .toolbar {
            if kind == .downloads && !library.downloads.isEmpty {
                Menu {
                    Picker("Sort By", selection: Bindable(AppSettings.shared).downloadsSort) {
                        ForEach(DownloadsSort.allCases) { option in
                            Label(option.label, systemImage: option.icon).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort")
            }
            if kind == .history && !library.history.isEmpty {
                Button("Clear") { library.clearHistory() }
            }
            if kind == .local {
                Button { importing = true } label: { Image(systemName: "plus") }
            }
            if kind == .liked && account.isSignedIn {
                Button { Task { await account.syncLikes() } } label: {
                    if account.isSyncing { ProgressView() } else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await library.importFiles(urls) } }
        }
    }

    /// Downloads in the order picked from the sort button.
    private var sortedDownloads: [Song] {
        let downloads = library.downloads   // newest batch first
        switch AppSettings.shared.downloadsSort {
        case .recent:
            return downloads
        case .title:
            return downloads.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return downloads.sorted {
                let a = $0.artist.localizedStandardCompare($1.artist)
                return a == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a == .orderedAscending
            }
        case .playlist:
            // Liked Songs order first, then your playlists in order, then anything else.
            var position: [String: Int] = [:]
            var next = 0
            for song in library.liked + library.playlists.flatMap(\.songs) where position[song.videoId] == nil {
                position[song.videoId] = next
                next += 1
            }
            return downloads.enumerated()
                .sorted { (position[$0.element.videoId] ?? Int.max, $0.offset) < (position[$1.element.videoId] ?? Int.max, $1.offset) }
                .map(\.element)
        }
    }

    private var emptyTitle: String {
        switch kind {
        case .liked: return "No Liked Songs"
        case .downloads: return "No Downloads"
        case .history: return "Nothing Played Yet"
        case .local: return "No Imported Music"
        }
    }
    private var emptyIcon: String {
        switch kind {
        case .liked: return "heart"
        case .downloads: return "arrow.down.circle"
        case .history: return "clock"
        case .local: return "iphone"
        }
    }
    private var emptyText: String {
        switch kind {
        case .liked: return "Tap the heart on any song to keep it here."
        case .downloads: return "Download songs, albums and playlists to listen offline."
        case .history: return "Songs you play will show up here."
        case .local: return "Import MP3, M4A, FLAC, WAV or ALAC files from the Files app."
        }
    }
}

struct LocalPlaylistView: View {
    let playlistId: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        let playlist = library.playlists.first { $0.id == playlistId }
        List {
            if let playlist {
                VStack(spacing: 12) {
                    PlaylistCollage(songs: playlist.songs).frame(width: 220, height: 220)
                        .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
                    Text(playlist.name).font(.title2.weight(.bold))
                    Text("\(playlist.songs.count) songs").foregroundStyle(.secondary)
                    if !playlist.songs.isEmpty {
                        PlayShuffleButtons {
                            player.play(playlist.songs, source: playlist.name)
                        } shuffle: {
                            player.play(playlist.songs, source: playlist.name, shuffled: true)
                        }
                        DownloadAllButton(songs: playlist.songs)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                ForEach(Array(playlist.songs.enumerated()), id: \.element.id) { i, song in
                    SongRow(song: song) { player.play(playlist.songs, startAt: i, source: playlist.name) }
                }
                .onDelete { idx in idx.map { playlist.songs[$0] }.forEach { library.remove($0, from: playlistId) } }
                .onMove { library.move(in: playlistId, from: $0, to: $1) }
            }
        }
        .listStyle(.plain)
        .toolbar {
            EditButton()
            Menu {
                Button { name = playlist?.name ?? ""; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                Button { library.download(playlist?.songs ?? []) } label: { Label("Download All", systemImage: "arrow.down.circle") }
                Button(role: .destructive) { library.deletePlaylist(playlistId); dismiss() } label: { Label("Delete Playlist", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if !name.isEmpty { library.rename(playlistId, to: name) } }
        }
    }
}

/// Playlists, albums or artists saved to the signed-in YouTube Music account.
struct AccountLibraryView: View {
    let title: String
    let browseId: String
    @State private var items: [ShelfItem] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var creating = false
    @State private var newName = ""
    @State private var privacy = "PRIVATE"

    var body: some View {
        List {
            if !loaded { LoadingView().listRowSeparator(.hidden) }
            if let error { ErrorView(message: error) { Task { await load() } } }
            ForEach(items) { item in
                if let route = Route.for(item) {
                    NavigationLink(value: route) {
                        HStack(spacing: 12) {
                            ArtworkImage(url: item.artwork(160), cornerRadius: 6, circle: item.kind == .artist)
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading) {
                                Text(item.title).lineLimit(1)
                                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .task { if !loaded { await load() } }
        .refreshable { await load() }
        .toolbar {
            if browseId == "FEmusic_liked_playlists" {
                Button { newName = ""; creating = true } label: { Image(systemName: "plus") }
            }
        }
        .alert("New YouTube Playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Private") { privacy = "PRIVATE"; Task { await create() } }
            Button("Unlisted") { privacy = "UNLISTED"; Task { await create() } }
            Button("Public") { privacy = "PUBLIC"; Task { await create() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose who can see it.")
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            _ = try await InnerTube.shared.createPlaylist(title: name, privacy: privacy)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        do {
            items = try await YTMusic.libraryItems(browseId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

struct AddToPlaylistSheet: View {
    let songs: [Song]
    @Environment(LibraryStore.self) private var library
    @Environment(AccountManager.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var remote: [ShelfItem] = []
    @State private var status: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New playlist name", text: $name)
                        Button("Create") {
                            guard !name.isEmpty else { return }
                            library.createPlaylist(name, songs: songs)
                            dismiss()
                        }
                        .disabled(name.isEmpty)
                    }
                    if account.isSignedIn {
                        Button {
                            Task {
                                do {
                                    _ = try await InnerTube.shared.createPlaylist(title: name, privacy: "PRIVATE",
                                                                                  videoIds: songs.filter { !$0.isLocal }.map(\.videoId))
                                    dismiss()
                                } catch { status = error.localizedDescription }
                            }
                        } label: {
                            Label("Create on YouTube Music instead", systemImage: "icloud.and.arrow.up")
                        }
                        .disabled(name.isEmpty)
                    }
                }
                Section("On This iPhone") {
                    ForEach(library.playlists) { p in
                        Button {
                            library.add(songs, to: p.id)
                            dismiss()
                        } label: {
                            HStack {
                                PlaylistCollage(songs: p.songs).frame(width: 44, height: 44)
                                Text(p.name).foregroundStyle(.primary)
                                Spacer()
                                Text("\(p.songs.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if account.isSignedIn {
                    Section("YouTube Music") {
                        ForEach(remote.filter { $0.kind == .playlist }) { p in
                            Button {
                                Task {
                                    do {
                                        try await InnerTube.shared.addToPlaylist(playlistId: p.browseId ?? "", videoIds: songs.filter { !$0.isLocal }.map(\.videoId))
                                        dismiss()
                                    } catch { status = error.localizedDescription }
                                }
                            } label: {
                                HStack {
                                    ArtworkImage(url: p.artwork(120), cornerRadius: 5).frame(width: 44, height: 44)
                                    Text(p.title).foregroundStyle(.primary)
                                }
                            }
                        }
                        if let status { Text(status).font(.footnote).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(songs.count == 1 ? "Add to Playlist" : "Add \(songs.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                if account.isSignedIn { remote = (try? await YTMusic.ownPlaylists()) ?? [] }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The account's YouTube Music history, grouped by day; swipe a row to remove it from YouTube.
struct YouTubeHistoryView: View {
    @Environment(PlayerController.self) private var player
    @State private var sections: [HistorySection] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            if !loaded { LoadingView().listRowSeparator(.hidden) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(Array(section.songs.enumerated()), id: \.offset) { _, song in
                        SongRow(song: song) {
                            let all = sections.flatMap(\.songs)
                            player.play(all, startAt: all.firstIndex(of: song) ?? 0, source: "YouTube History")
                        }
                        .swipeActions {
                            if song.historyRemoveToken != nil {
                                Button(role: .destructive) { Task { await remove(song) } } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            if loaded && sections.isEmpty && error == nil {
                ContentUnavailableView("No History", systemImage: "clock", description: Text("Songs played on YouTube Music show up here."))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("YouTube History")
        .task { if !loaded { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            sections = try await YTMusic.history()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func remove(_ song: Song) async {
        do {
            try await YTMusic.removeFromHistory(song)
            for i in sections.indices { sections[i].songs.removeAll { $0.id == song.id && $0.historyRemoveToken == song.historyRemoveToken } }
            sections.removeAll { $0.songs.isEmpty }
        } catch {
            self.error = "Couldn't remove it: \(error.localizedDescription)"
        }
    }
}


/// At the top of Downloads: songs that failed (with Retry) and songs still downloading.
struct DownloadIssuesSection: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let failed = library.failedDownloads
        let active = library.activeDownloadSongs
        if !failed.isEmpty {
            Section {
                ForEach(failed) { song in
                    row(song) {
                        Text(reason(song)).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } trailing: {
                        Button { library.retryDownload(song) } label: {
                            Image(systemName: "arrow.clockwise.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Retry")
                    }
                    .swipeActions {
                        Button(role: .destructive) { library.cancelDownload(song) } label: { Label("Remove", systemImage: "xmark") }
                    }
                }
            } header: {
                HStack {
                    Label("\(failed.count) failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry All") { library.retryAllFailed() }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                        .tint(Theme.accent)
                }
                .textCase(nil)
            }
        }
        if !active.isEmpty {
            Section {
                ForEach(active) { song in
                    row(song) {
                        if case .downloading(let p) = library.downloadStates[song.videoId] {
                            ProgressView(value: p).tint(Theme.accent)
                        } else {
                            Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                        }
                    } trailing: {
                        Button { library.cancelDownload(song) } label: {
                            Image(systemName: "xmark.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Cancel")
                    }
                }
            } header: {
                Text("Downloading \(active.count)").textCase(nil)
            }
        }
        if !failed.isEmpty || !active.isEmpty {
            Section {} header: { Text("Downloaded").textCase(nil) }
        }
    }

    private func reason(_ song: Song) -> String {
        if case .failed(let text) = library.downloadStates[song.videoId] { return text }
        return "Download failed"
    }

    private func row<Detail: View, Trailing: View>(_ song: Song, @ViewBuilder detail: () -> Detail,
                                                   @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            ArtworkImage(url: song.artworkURL(120), cornerRadius: 5).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).lineLimit(1)
                detail()
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}
