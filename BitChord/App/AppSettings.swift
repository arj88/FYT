import Foundation
import Observation
import Security
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System", dark = "Dark", light = "Light"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

/// Accent colours offered in Settings → Appearance.
enum AccentChoice: String, CaseIterable, Identifiable {
    case red, youtube, pink, orange, yellow, green, mint, teal, blue, indigo, purple, custom
    var id: String { rawValue }
    static var presets: [AccentChoice] { allCases.filter { $0 != .custom } }
    var label: String {
        switch self {
        case .red: "Red"
        case .youtube: "FYT Red"
        case .pink: "Pink"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .mint: "Mint"
        case .teal: "Teal"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .custom: "Custom"
        }
    }
    var color: Color {
        switch self {
        case .red: Color(red: 0xFA / 255, green: 0x2D / 255, blue: 0x48 / 255)
        case .youtube: Color(red: 0xFF / 255, green: 0x00 / 255, blue: 0x33 / 255)
        case .pink: Color(red: 0xFF / 255, green: 0x37 / 255, blue: 0x9B / 255)
        case .orange: Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x00 / 255)
        case .yellow: Color(red: 0xFF / 255, green: 0xC4 / 255, blue: 0x00 / 255)
        case .green: Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
        case .mint: Color(red: 0x00 / 255, green: 0xC7 / 255, blue: 0xBE / 255)
        case .teal: Color(red: 0x30 / 255, green: 0xB0 / 255, blue: 0xC7 / 255)
        case .blue: Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
        case .indigo: Color(red: 0x5E / 255, green: 0x5C / 255, blue: 0xE6 / 255)
        case .purple: Color(red: 0xBF / 255, green: 0x5A / 255, blue: 0xF2 / 255)
        case .custom: Color(hex: AccentChoice.lastCustomHex) ?? Color(red: 0xFA / 255, green: 0x2D / 255, blue: 0x48 / 255)
        }
    }
}

extension AccentChoice {
    /// Mirrors AppSettings.customAccentHex so `color` works without the main actor.
    nonisolated(unsafe) static var lastCustomHex = UserDefaults.standard.string(forKey: "customAccentHex") ?? "#FF0033"
}

extension Color {
    /// "#FF0033", "FF0033" or "#F03" → a colour; nil if it isn't valid hex.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// How the Downloads list is ordered.
enum DownloadsSort: String, CaseIterable, Identifiable {
    case playlist, recent, title, artist
    var id: String { rawValue }
    var label: String {
        switch self {
        case .playlist: "Playlist Order"
        case .recent: "Recently Downloaded"
        case .title: "Title"
        case .artist: "Artist"
        }
    }
    var icon: String {
        switch self {
        case .playlist: "list.number"
        case .recent: "clock"
        case .title: "textformat"
        case .artist: "music.mic"
        }
    }
}

enum RepeatMode: String, Codable { case off, all, one }

/// User preferences, persisted in UserDefaults (secrets in the Keychain).
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var appearance: AppearanceMode { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    var accent: AccentChoice { didSet { d.set(accent.rawValue, forKey: "accent") } }
    var customAccentHex: String {
        didSet { d.set(customAccentHex, forKey: "customAccentHex"); AccentChoice.lastCustomHex = customAccentHex }
    }
    var quality: AudioQuality { didSet { d.set(quality.rawValue, forKey: "quality"); StreamResolver.shared.quality = quality } }
    var downloadQuality: AudioQuality { didSet { d.set(downloadQuality.rawValue, forKey: "downloadQuality") } }
    var automix: Bool { didSet { d.set(automix, forKey: "automix") } }
    var automixBeats: Int { didSet { d.set(automixBeats, forKey: "automixBeats") } }
    var crossfade: Double { didSet { d.set(crossfade, forKey: "crossfade") } }
    var normalize: Bool { didSet { d.set(normalize, forKey: "normalize") } }
    var autoplay: Bool { didSet { d.set(autoplay, forKey: "autoplay") } }
    var preferAudioVersions: Bool { didSet { d.set(preferAudioVersions, forKey: "preferAudio") } }
    var dynamicColors: Bool { didSet { d.set(dynamicColors, forKey: "dynamicColors") } }
    var animatedBackground: Bool { didSet { d.set(animatedBackground, forKey: "animatedBackground") } }
    var lyricsProviders: [LyricsProvider] { didSet { d.set(lyricsProviders.map(\.rawValue), forKey: "lyricsProviders") } }
    var lyricsFontScale: Double { didSet { d.set(lyricsFontScale, forKey: "lyricsFontScale") } }
    var cacheLimitMB: Int { didSet { d.set(cacheLimitMB, forKey: "cacheLimitMB"); AudioCache.limitBytes = Int64(cacheLimitMB) * 1024 * 1024 } }
    var showNerdStats: Bool { didSet { d.set(showNerdStats, forKey: "nerdStats") } }
    var contentRegion: String { didSet { d.set(contentRegion, forKey: "region"); InnerTube.shared.region = contentRegion } }
    var pauseHistory: Bool { didSet { d.set(pauseHistory, forKey: "pauseHistory") } }
    var downloadsSort: DownloadsSort { didSet { d.set(downloadsSort.rawValue, forKey: "downloadsSort") } }

    var listenBrainzToken: String? { didSet { Keychain.set(listenBrainzToken, for: "listenbrainz") } }
    var listenBrainzUser: String? { didSet { d.set(listenBrainzUser, forKey: "lbUser") } }
    var lastFM: LastFM.Config? {
        didSet {
            Keychain.set(lastFM.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }, for: "lastfm")
        }
    }
    var discordToken: String? { didSet { Keychain.set(discordToken, for: "discord") } }
    var discordEnabled: Bool { didSet { d.set(discordEnabled, forKey: "discordEnabled") } }

    private init() {
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .red
        customAccentHex = d.string(forKey: "customAccentHex") ?? "#FF0033"
        quality = AudioQuality(rawValue: d.string(forKey: "quality") ?? "") ?? .high
        downloadQuality = AudioQuality(rawValue: d.string(forKey: "downloadQuality") ?? "") ?? .opus
        automix = d.bool(forKey: "automix")
        automixBeats = d.object(forKey: "automixBeats") as? Int ?? 16
        crossfade = d.object(forKey: "crossfade") as? Double ?? 0
        normalize = d.object(forKey: "normalize") as? Bool ?? true
        autoplay = d.object(forKey: "autoplay") as? Bool ?? true
        preferAudioVersions = d.object(forKey: "preferAudio") as? Bool ?? true
        dynamicColors = d.object(forKey: "dynamicColors") as? Bool ?? true
        animatedBackground = d.object(forKey: "animatedBackground") as? Bool ?? true
        let providers = (d.stringArray(forKey: "lyricsProviders") ?? []).compactMap(LyricsProvider.init(rawValue:))
        lyricsProviders = providers.isEmpty ? LyricsProvider.allCases : providers
        lyricsFontScale = d.object(forKey: "lyricsFontScale") as? Double ?? 1
        cacheLimitMB = d.object(forKey: "cacheLimitMB") as? Int ?? 1024
        showNerdStats = d.bool(forKey: "nerdStats")
        contentRegion = d.string(forKey: "region") ?? InnerTube.shared.region
        pauseHistory = d.bool(forKey: "pauseHistory")
        downloadsSort = DownloadsSort(rawValue: d.string(forKey: "downloadsSort") ?? "") ?? .playlist
        listenBrainzToken = Keychain.get("listenbrainz")
        listenBrainzUser = d.string(forKey: "lbUser")
        lastFM = Keychain.get("lastfm").flatMap { try? JSONDecoder().decode(LastFM.Config.self, from: Data($0.utf8)) }
        discordToken = Keychain.get("discord")
        discordEnabled = d.bool(forKey: "discordEnabled")

        StreamResolver.shared.quality = quality
        AudioCache.limitBytes = Int64(cacheLimitMB) * 1024 * 1024
        InnerTube.shared.region = contentRegion
    }
}

/// Minimal Keychain wrapper for tokens and cookies.
enum Keychain {
    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "bitchord",
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "bitchord",
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
