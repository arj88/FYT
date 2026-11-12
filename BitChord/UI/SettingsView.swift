import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AccountManager.self) private var account
    @Environment(LibraryStore.self) private var library

    @State private var sheet: Sheet?
    @State private var cacheSize: Int64 = 0
    @State private var downloadsSize: Int64 = 0
    @State private var confirmDeleteDownloads = false

    enum Sheet: String, Identifiable { case youtube, discord, lastfm, listenbrainz; var id: String { rawValue } }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("YouTube Music") {
                if let info = account.account {
                    HStack(spacing: 12) {
                        ArtworkImage(url: info.thumbnailUrl.flatMap { Artwork.url($0, size: 120) }, circle: true)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(info.name).font(.headline)
                            if let handle = info.handle { Text(handle).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                    Button("Sync Liked Songs") { Task { await account.syncLikes() } }
                    Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
                } else if account.isSignedIn {
                    Text("Signed in").foregroundStyle(.secondary)
                    Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
                } else {
                    Button { sheet = .youtube } label: { Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus") }
                    Text("Signing in gives you your personal Home, your library and synced likes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = account.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                Picker("Content region", selection: $settings.contentRegion) {
                    ForEach(Self.regions, id: \.self) { code in
                        Text(Locale.current.localizedString(forRegionCode: code) ?? code).tag(code)
                    }
                }
            }

            Section("Playback") {
                Toggle(isOn: $settings.automix) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automix (beta)")
                        Text("DJ-style transitions: beats lined up, tempos matched, bass swapped.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if settings.automix {
                    Picker("Transition length", selection: $settings.automixBeats) {
                        Text("Short — 8 beats").tag(8)
                        Text("Medium — 16 beats").tag(16)
                        Text("Long — 32 beats").tag(32)
                    }
                } else {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Crossfade")
                            Spacer()
                            Text(settings.crossfade == 0 ? "Off" : "\(Int(settings.crossfade))s").foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.crossfade, in: 0...12, step: 1)
                    }
                }
                Toggle("Volume normalization", isOn: $settings.normalize)
                Toggle("Autoplay similar songs", isOn: $settings.autoplay)
                Toggle("Stats for nerds", isOn: $settings.showNerdStats)
            }

            Section {
                Picker("Streaming quality", selection: $settings.quality) {
                    ForEach(AudioQuality.choices) { Text($0.label).tag($0) }
                }
                Picker("Download quality", selection: $settings.downloadQuality) {
                    ForEach(AudioQuality.choices) { Text($0.label).tag($0) }
                }
                if !OpusSupport.isAvailable {
                    Text("This iPhone couldn't play the repackaged Opus files, so AAC 128 kbps is used instead.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio quality")
            } footer: {
                Text("Opus (~160 kbps) is YouTube's best audio for everyone; it starts a second or two later because each song is fetched whole and repackaged for iPhone. AAC 256 kbps is only sent to YouTube Music Premium accounts — sign in first; without Premium it falls back to Opus.")
            }

            Section("Lyrics") {
                ForEach(settings.lyricsProviders) { p in
                    Text(p.rawValue)
                }
                .onMove { settings.lyricsProviders.move(fromOffsets: $0, toOffset: $1) }
                VStack(alignment: .leading) {
                    Text("Text size")
                    Slider(value: $settings.lyricsFontScale, in: 0.7...1.4)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
                }
                AppIconPicker()
                AccentPicker(selection: $settings.accent, customHex: $settings.customAccentHex)
                Toggle("Colours from artwork", isOn: $settings.dynamicColors)
                Toggle("Animated player background", isOn: $settings.animatedBackground)
            }

            Section("Scrobbling & presence") {
                if let user = settings.lastFM?.username {
                    LabeledContent("Last.fm", value: user)
                    Button("Disconnect Last.fm", role: .destructive) { settings.lastFM = nil }
                } else {
                    Button("Connect Last.fm") { sheet = .lastfm }
                }
                if let user = settings.listenBrainzUser, settings.listenBrainzToken != nil {
                    LabeledContent("ListenBrainz", value: user)
                    Button("Disconnect ListenBrainz", role: .destructive) { settings.listenBrainzToken = nil; settings.listenBrainzUser = nil }
                } else {
                    Button("Connect ListenBrainz") { sheet = .listenbrainz }
                }
                if settings.discordToken != nil {
                    Toggle("Discord Rich Presence", isOn: $settings.discordEnabled)
                        .onChange(of: settings.discordEnabled) { _, on in if !on { DiscordPresence.shared.disconnect() } }
                    Button("Log out of Discord", role: .destructive) {
                        DiscordPresence.shared.disconnect()
                        settings.discordToken = nil
                        settings.discordEnabled = false
                    }
                } else {
                    Button("Log in to Discord") { sheet = .discord }
                }
            }

            Section("Storage") {
                LabeledContent("Audio cache", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                Picker("Cache limit", selection: $settings.cacheLimitMB) {
                    ForEach([256, 512, 1024, 2048, 4096], id: \.self) { Text(ByteCountFormatter.string(fromByteCount: Int64($0) * 1024 * 1024, countStyle: .file)).tag($0) }
                }
                Button("Clear Cache") { AudioCache.clear(); cacheSize = 0 }
                LabeledContent("Downloads",
                               value: "\(library.downloads.count) songs · " + ByteCountFormatter.string(fromByteCount: downloadsSize, countStyle: .file))
                Button("Delete All Downloads", role: .destructive) { confirmDeleteDownloads = true }
                    .disabled(library.downloads.isEmpty && library.pendingDownloads.isEmpty)
                Toggle("Pause listening history", isOn: $settings.pauseHistory)
                Button("Clear History", role: .destructive) { library.clearHistory() }
            }

            Section("About") {
                LabeledContent("Version", value: AppInfo.versionText)
                Text("This FYT app is created by Lucky Raj and is not affiliated with, endorsed by, or connected to YouTube or Google.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .environment(\.editMode, .constant(.inactive))
        .task {
            cacheSize = await Task.detached { AudioCache.size() }.value
            downloadsSize = await Task.detached { LibraryStore.downloadsSize() }.value
        }
        .confirmationDialog("Delete all \(library.downloads.count) downloaded songs?",
                            isPresented: $confirmDeleteDownloads, titleVisibility: .visible) {
            Button("Delete All Downloads", role: .destructive) {
                library.removeAllDownloads()
                downloadsSize = 0
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } message: {
            Text("They'll be removed from this iPhone. You can download them again any time.")
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .youtube: YouTubeLoginView()
            case .discord: DiscordLoginView()
            case .lastfm: LastFMLoginView()
            case .listenbrainz: ListenBrainzLoginView()
            }
        }
    }

    static let regions = ["US", "IN", "GB", "CA", "AU", "DE", "FR", "ES", "IT", "BR", "MX", "JP", "KR", "ID", "PH", "PK", "BD", "NG", "ZA", "AE", "SA", "TR", "RU", "NL", "SE"]
}


/// The app's version as shown in Settings, e.g. "1.1.0 (build 24)".
enum AppInfo {
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == "1" ? version : "\(version) (build \(build))"
    }
}

/// A row of colour swatches for the app's accent colour, plus a custom hex value.
struct AccentPicker: View {
    @Binding var selection: AccentChoice
    @Binding var customHex: String
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var draftColor: Color? { Color(hex: draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Accent colour")
                Spacer()
                Text(selection == .custom ? customHex.uppercased() : selection.label).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AccentChoice.presets) { choice in
                        swatch(choice.color, selected: selection == choice, label: choice.label) {
                            selection = choice
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 10) {
                Circle()
                    .fill(draftColor ?? Color(hex: customHex) ?? .gray)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(.white.opacity(selection == .custom ? 0.9 : 0), lineWidth: 2))
                Text("#").foregroundStyle(.secondary)
                TextField("FF0033", text: $draft)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .focused($editing)
                    .onChange(of: draft) { _, value in
                        let cleaned = String(value.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(6))
                        if cleaned != value { draft = cleaned }
                    }
                    .onSubmit(apply)
                Button("Use", action: apply)
                    .buttonStyle(.bordered)
                    .disabled(draftColor == nil)
            }
            if !draft.isEmpty && draftColor == nil {
                Text("Enter 6 hex digits, like FF0033").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .onAppear { draft = customHex.replacingOccurrences(of: "#", with: "").uppercased() }
    }

    private func apply() {
        guard draftColor != nil else { return }
        customHex = "#" + draft
        withAnimation(.snappy) { selection = .custom }
        editing = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func swatch(_ color: Color, selected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Circle()
                .fill(color)
                .frame(width: 30, height: 30)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                    }
                }
                .padding(3)
                .overlay(Circle().stroke(selected ? color : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}


/// Lets the user swap the home-screen icon for one of FYT's colour variants.
struct AppIconPicker: View {
    private struct Option: Identifiable {
        let id: String          // preview image suffix
        let iconName: String?   // nil = the default icon
        let label: String
    }
    private let options: [Option] = [
        Option(id: "Default", iconName: nil, label: "Red"),
        Option(id: "Dark", iconName: "AppIconDark", label: "Dark"),
        Option(id: "Purple", iconName: "AppIconPurple", label: "Purple"),
        Option(id: "Blue", iconName: "AppIconBlue", label: "Blue"),
        Option(id: "Green", iconName: "AppIconGreen", label: "Green"),
        Option(id: "Orange", iconName: "AppIconOrange", label: "Orange"),
        Option(id: "Pink", iconName: "AppIconPink", label: "Pink"),
    ]
    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App icon")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(options) { option in
                        let selected = current == option.iconName
                        Button { choose(option) } label: {
                            VStack(spacing: 6) {
                                Image("IconPreview" + option.id)
                                    .resizable()
                                    .frame(width: 58, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                                            .stroke(selected ? Theme.accent : .clear, lineWidth: 2.5)
                                            .padding(-4)
                                    )
                                Text(option.label)
                                    .font(.caption)
                                    .foregroundStyle(selected ? .primary : .secondary)
                            }
                            .padding(4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(option.label) icon")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if current == nil {
                Text("The red icon turns dark when your Home Screen icons are set to Dark.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func choose(_ option: Option) {
        guard UIApplication.shared.supportsAlternateIcons, current != option.iconName else { return }
        UIApplication.shared.setAlternateIconName(option.iconName) { failure in
            Task { @MainActor in
                if let failure {
                    error = "Couldn't change the icon: \(failure.localizedDescription)"
                } else {
                    error = nil
                    current = option.iconName
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }
}
