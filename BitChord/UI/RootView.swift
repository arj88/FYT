import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerController.self) private var player
    /// Height of the mini player (and download bar), so lists can scroll their last row above it.
    @State private var accessoryHeight: CGFloat = 0

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.homePath) {
                HomeView().withRoutes()
            }
            .overlay(alignment: .bottom) { BottomAccessory(height: $accessoryHeight) }
            .contentMargins(.bottom, accessoryHeight + 8, for: .scrollContent)
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(AppTab.home)

            NavigationStack(path: $router.explorePath) {
                ExploreView().withRoutes()
            }
            .overlay(alignment: .bottom) { BottomAccessory(height: $accessoryHeight) }
            .contentMargins(.bottom, accessoryHeight + 8, for: .scrollContent)
            .tabItem { Label("Explore", systemImage: "square.grid.2x2.fill") }
            .tag(AppTab.explore)

            NavigationStack(path: $router.libraryPath) {
                LibraryView().withRoutes()
            }
            .overlay(alignment: .bottom) { BottomAccessory(height: $accessoryHeight) }
            .contentMargins(.bottom, accessoryHeight + 8, for: .scrollContent)
            .tabItem { Label("Library", systemImage: "music.note.list") }
            .tag(AppTab.library)

            NavigationStack(path: $router.searchPath) {
                SearchView().withRoutes()
            }
            .overlay(alignment: .bottom) { BottomAccessory(height: $accessoryHeight) }
            .contentMargins(.bottom, accessoryHeight + 8, for: .scrollContent)
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(AppTab.search)
        }
        .onAppear { UIApplication.shared.beginReceivingRemoteControlEvents() }
        .fullScreenCover(isPresented: $router.showPlayer) {
            NowPlayingView()
                .sheet(isPresented: $router.showParty) { ListenTogetherView() }
        }
        .sheet(isPresented: Binding(get: { router.showParty && !router.showPlayer }, set: { router.showParty = $0 })) {
            ListenTogetherView()
        }
        .sheet(isPresented: Binding(get: { router.addToPlaylist != nil }, set: { if !$0 { router.addToPlaylist = nil } })) {
            AddToPlaylistSheet(songs: router.addToPlaylist ?? [])
        }
    }
}

/// The bar above the tab bar showing the current track.
struct MiniPlayer: View {
    @Environment(PlayerController.self) private var player
    @Environment(ListenTogether.self) private var party
    @Environment(CastManager.self) private var cast
    @Environment(AppRouter.self) private var router

    var body: some View {
        if let song = player.current {
            HStack(spacing: 12) {
                ArtworkImage(url: song.artworkURL(120), cornerRadius: 6)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if party.isActive { Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(Theme.accent) }
                        if cast.isConnected { Image(systemName: "tv").font(.caption2).foregroundStyle(Theme.accent) }
                        Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Text(song.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if player.isLoading && !player.isPlaying {
                    ProgressView().frame(width: 36, height: 36)
                } else {
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 36, height: 36)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: player.duration > 0 ? geo.size.width * min(1, player.position / player.duration) : 0, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
            }
            .contentShape(Rectangle())
            .onTapGesture { router.showPlayer = true }
            .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < -30 { router.showPlayer = true }
                else if value.translation.width < -60 { player.next() }
                else if value.translation.width > 60 { player.previous() }
            })
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// What sits above the tab bar: download progress (when there is any) and the mini player.
struct BottomAccessory: View {
    @Environment(LibraryStore.self) private var library
    @Binding var height: CGFloat
    var body: some View {
        VStack(spacing: 6) {
            DownloadStatusBar()
            MiniPlayer()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: library.isDownloading)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: library.downloadNotice)
    }
}

/// "Downloading 12 of 658" with a progress bar; tap to open Downloads.
struct DownloadStatusBar: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    var body: some View {
        let active = library.isDownloading
        if active || library.downloadNotice != nil {
            Button {
                router.tab = .library
                router.libraryPath = NavigationPath([Route.downloads])
            } label: {
                HStack(spacing: 10) {
                    if active {
                        ProgressRing(progress: library.batchProgress)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(library.downloadNotice ?? "Downloading \(library.batchDone + 1) of \(library.batchTotal)")
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        if active && library.downloadNotice != nil {
                            Text("\(library.batchDone) of \(library.batchTotal) done")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if active {
                        Text("\(Int(library.batchProgress * 100))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(.regularMaterial).shadow(color: .black.opacity(0.12), radius: 6, y: 2))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// A small determinate progress ring.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 2.5
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, progress)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
        }
    }
}
