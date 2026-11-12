import SwiftUI

enum Route: Hashable {
    case detail(browseId: String, title: String, thumbnail: String?)
    case artist(browseId: String, name: String)
    case shelf(title: String, browseId: String, params: String?)
    case localPlaylist(id: String)
    case liked
    case downloads
    case history
    case localFiles
    case accountLibrary(title: String, browseId: String)
    case youtubeHistory
    case settings

    static func `for`(_ item: ShelfItem) -> Route? {
        guard let id = item.browseId else { return nil }
        switch item.kind {
        case .artist: return .artist(browseId: id, name: item.title)
        default:
            if id.hasPrefix("UC") { return .artist(browseId: id, name: item.title) }
            return .detail(browseId: id, title: item.title, thumbnail: item.thumbnailUrl)
        }
    }
}

struct RouteDestination: View {
    let route: Route
    var body: some View {
        switch route {
        case .detail(let id, let title, let thumb): DetailView(browseId: id, initialTitle: title, initialThumbnail: thumb)
        case .artist(let id, let name): ArtistView(browseId: id, initialName: name)
        case .shelf(let title, let id, let params): ShelfPageView(title: title, browseId: id, params: params)
        case .localPlaylist(let id): LocalPlaylistView(playlistId: id)
        case .liked: SongCollectionView(kind: .liked)
        case .downloads: SongCollectionView(kind: .downloads)
        case .history: SongCollectionView(kind: .history)
        case .localFiles: SongCollectionView(kind: .local)
        case .accountLibrary(let title, let id): AccountLibraryView(title: title, browseId: id)
        case .youtubeHistory: YouTubeHistoryView()
        case .settings: SettingsView()
        }
    }
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}

// MARK: - Song row

struct SongRow: View {
    let song: Song
    var index: Int?
    var showArtwork = true
    var subtitle: String?
    var onTap: () -> Void
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let index, !showArtwork {
                    Text("\(index)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22)
                }
                if showArtwork {
                    ArtworkImage(url: song.artworkURL(120), cornerRadius: 5)
                        .frame(width: song.isVideo ? 64 : 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(song.title)
                            .font(.body)
                            .lineLimit(1)
                            .foregroundStyle(player.current?.videoId == song.videoId ? Theme.accent : Color.primary)
                        if song.isExplicit { ExplicitBadge() }
                    }
                    HStack(spacing: 4) {
                        switch library.downloadStates[song.videoId] {
                        case .some(.done):
                            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.secondary)
                        case .some(.downloading(let p)):
                            ProgressRing(progress: p, lineWidth: 2).frame(width: 11, height: 11)
                        case .some(.queued):
                            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                        case .some(.failed):
                            Image(systemName: "exclamationmark.circle.fill").font(.caption2).foregroundStyle(.red)
                        case .none:
                            EmptyView()
                        }
                        Text(subtitle ?? song.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if player.current?.videoId == song.videoId && player.isPlaying {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .foregroundStyle(Theme.accent)
                        .font(.footnote)
                }
                SongMenuButton(song: song)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { SongMenuItems(song: song) }
    }
}

struct SongMenuButton: View {
    let song: Song
    var body: some View {
        Menu {
            SongMenuItems(song: song)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 36)
                .contentShape(Rectangle())
        }
    }
}

/// The long-press menu for a track, as BitChord offers it.
struct SongMenuItems: View {
    let song: Song
    var playlistContext: String?
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button { player.playNext([song]) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue([song]) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
        if !song.isLocal {
            Button { player.playRadio(song) } label: { Label("Start Radio", systemImage: "dot.radiowaves.left.and.right") }
        }
        Divider()
        Button { library.toggleLike(song) } label: {
            library.isLiked(song) ? Label("Unlove", systemImage: "heart.slash") : Label("Love", systemImage: "heart")
        }
        Button { router.addToPlaylist = [song] } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
        if !song.isLocal {
            if library.isDownloaded(song) {
                Button(role: .destructive) { library.removeDownload(song) } label: { Label("Remove Download", systemImage: "trash") }
            } else {
                Button { library.download([song]) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
        Divider()
        if let artist = song.artists.first(where: { $0.browseId != nil }), let id = artist.browseId {
            Button { router.open(.artist(browseId: id, name: artist.name)) } label: { Label("Go to Artist", systemImage: "music.mic") }
        }
        if let albumId = song.albumId {
            Button { router.open(.detail(browseId: albumId, title: song.albumName ?? "", thumbnail: song.thumbnailUrl)) } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
        }
        if !song.isLocal {
            ShareLink(item: URL(string: "https://music.youtube.com/watch?v=\(song.videoId)")!) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

// MARK: - Cards and shelves

struct ShelfCard: View {
    let item: ShelfItem
    var width: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(url: item.artwork(Int(width * 3)), cornerRadius: item.kind == .artist ? width / 2 : Theme.cardCorner,
                         circle: item.kind == .artist)
                .frame(width: width, height: item.isVideo ? width * 9 / 16 : width)
            VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(item.kind == .artist ? 1 : 2)
                    .foregroundStyle(.primary)
                if !item.subtitle.isEmpty && item.kind != .artist {
                    Text(item.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: item.kind == .artist ? .center : .leading)
        }
        .frame(width: width)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(title).font(.title2.weight(.bold))
            }
            Spacer()
            if let action {
                Button(action: action) {
                    Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
    }
}

/// One shelf from a YouTube Music feed, drawn in the layout its content suits.
struct ShelfView: View {
    let shelf: HomeShelf
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: shelf.title, subtitle: shelf.strapline,
                          action: moreAction)
            switch shelf.layout {
            case .list:
                quickPicks
            default:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(shelf.items) { item in
                            Button { tap(item) } label: {
                                ShelfCard(item: item, width: shelf.layout == .wide ? 240 : (shelf.layout == .circles ? 130 : 160))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { ItemMenuItems(item: item) }
                        }
                    }
                    .padding(.horizontal)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    /// Quick picks: a paged grid of four rows per column, as YouTube Music lays them out.
    private var quickPicks: some View {
        let columns = stride(from: 0, to: shelf.items.count, by: 4).map { Array(shelf.items[$0..<min($0 + 4, shelf.items.count)]) }
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: 10) {
                        ForEach(column) { item in
                            Button { tap(item) } label: {
                                HStack(spacing: 12) {
                                    ArtworkImage(url: item.artwork(120), cornerRadius: item.kind == .artist ? 24 : 5, circle: item.kind == .artist)
                                        .frame(width: 50, height: 50)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.body).lineLimit(1)
                                        Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { ItemMenuItems(item: item) }
                        }
                    }
                    .containerRelativeFrame(.horizontal) { w, _ in w * 0.86 }
                }
            }
            .padding(.horizontal)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
    }

    private var moreAction: (() -> Void)? {
        guard let id = shelf.moreBrowseId else { return nil }
        let title = shelf.title
        let params = shelf.moreParams
        let router = self.router
        return { router.open(.shelf(title: title, browseId: id, params: params)) }
    }

    private func tap(_ item: ShelfItem) {
        ItemAction.open(item, in: shelf.items, player: player, router: router, source: shelf.title)
    }
}

enum ItemAction {
    @MainActor
    static func open(_ item: ShelfItem, in siblings: [ShelfItem] = [], player: PlayerController, router: AppRouter, source: String?) {
        if let route = Route.for(item) {
            router.open(route)
        } else if let song = item.asSong {
            let songs = siblings.compactMap(\.asSong)
            if songs.count > 1, let i = songs.firstIndex(where: { $0.videoId == song.videoId }) {
                player.play(songs, startAt: i, source: source)
            } else if let playlistId = item.playlistId, !playlistId.isEmpty {
                Task { await player.play(target: WatchTarget(videoId: song.videoId, playlistId: playlistId), source: source) }
            } else {
                player.playRadio(song)
            }
        }
    }
}

struct ItemMenuItems: View {
    let item: ShelfItem
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let song = item.asSong, item.browseId == nil {
            SongMenuItems(song: song)
        } else {
            if let playlistId = item.playlistId {
                Button {
                    Task { await player.play(target: WatchTarget(playlistId: playlistId), source: item.title) }
                } label: { Label("Play", systemImage: "play.fill") }
            }
            if item.browseId != nil, item.kind != .artist {
                Button { library.toggleSaved(item) } label: {
                    library.isSaved(item.browseId ?? "") ? Label("Remove from Library", systemImage: "minus.circle") : Label("Add to Library", systemImage: "plus")
                }
            }
            if item.kind == .artist {
                Button { library.toggleSaved(item) } label: {
                    library.isSaved(item.browseId ?? "") ? Label("Unfollow", systemImage: "person.badge.minus") : Label("Follow", systemImage: "person.badge.plus")
                }
            }
            if let id = item.browseId {
                ShareLink(item: URL(string: item.kind == .artist ? "https://music.youtube.com/channel/\(id)" : "https://music.youtube.com/browse/\(id)")!) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

// MARK: - States

struct LoadingView: View {
    var body: some View {
        ProgressView().controlSize(.large).frame(maxWidth: .infinity, minHeight: 240)
    }
}

struct ErrorView: View {
    let message: String
    var retry: (() -> Void)?
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            HStack(spacing: 12) {
                if let retry { Button("Try Again", action: retry).buttonStyle(.bordered) }
                if !library.downloads.isEmpty {
                    Button {
                        router.tab = .library
                        router.libraryPath = NavigationPath([Route.downloads])
                    } label: {
                        Label("Go to Downloads", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// One tap to save a whole list offline, with live progress.
struct DownloadAllButton: View {
    let songs: [Song]
    /// For lists that load in pages (long playlists): fetches every remaining song first.
    var loadAll: (() async -> [Song])?
    @Environment(LibraryStore.self) private var library
    @State private var fetching = false
    @State private var requested: [Song]?

    var body: some View {
        let list = (requested ?? songs).filter { !$0.isLocal }
        let done = library.downloadedCount(list)
        let active = library.activeDownloads(list)
        let failed = library.failedCount(list)
        let allDone = !list.isEmpty && done == list.count && !fetching
        Button {
            Task {
                var all = songs
                if let loadAll {
                    fetching = true
                    all = await loadAll()
                    fetching = false
                }
                requested = all
                library.download(all.filter { !$0.isLocal })
            }
        } label: {
            HStack(spacing: 8) {
                if fetching {
                    ProgressView().controlSize(.small)
                    Text("Getting the whole playlist…")
                } else if active > 0 {
                    ProgressView().controlSize(.small)
                    Text("Downloading… \(done) of \(list.count)")
                } else if failed > 0 {
                    Image(systemName: "arrow.clockwise.circle")
                    Text("Retry \(failed) failed")
                } else if allDone {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Downloaded")
                } else {
                    Image(systemName: "arrow.down.circle")
                    Text("Download")
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(Theme.accent)
        .disabled(songs.isEmpty || fetching || active > 0 || allDone)
    }
}

struct PlayShuffleButtons: View {
    var play: () -> Void
    var shuffle: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(Theme.accent)
    }
}
