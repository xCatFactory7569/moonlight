// LyricsPanel.swift
//
// Lyrics for the Now Playing screen. The panel looks for a ".lrc" file next to the song first,
// then for a saved copy from an earlier lookup, and only then asks online services: the free
// LRCLIB service (lrclib.net) first and Kugou (lyrics.kugou.com) when LRCLIB has no synced
// lyrics. Each lookup sends the artist, title, album and length of the song, and either
// service can be switched off from the menu in the panel. Synced lyrics follow the music and
// can be clicked to jump to a line; plain lyrics are shown as scrolling text. Lookups are
// saved on this Mac so each song is requested once.

import SwiftUI
import AppKit
import Combine
import CryptoKit

// MARK: - Models

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

struct TrackLyrics: Equatable {
    var lines: [LyricLine]
    var plain: String?
    var isInstrumental: Bool
    var source: String
    var rawSynced: String?

    var isSynced: Bool { !lines.isEmpty }
}

struct LyricsQuery: Hashable {
    var artist: String
    var title: String
    var album: String
    var duration: Double
    var fileURL: URL?

    var cacheKey: String {
        let raw = [artist, title, album, String(Int(duration.rounded()))]
            .map { $0.lowercased() }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum LyricsOutcome {
    case found(TrackLyrics)
    case notFound
    case failed(String)
}

// MARK: - LRC parsing

enum LRCParser {
    static func parse(_ text: String) -> [LyricLine] {
        guard let stamp = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?\\]"),
              let wordTag = try? NSRegularExpression(pattern: "<\\d{1,3}:\\d{2}(?:[.:]\\d{1,3})?>")
        else { return [] }

        var offset: Double = 0
        var entries: [(time: Double, text: String)] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.lowercased().hasPrefix("[offset:") {
                let value = line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)
                if let milliseconds = Double(value) { offset = -milliseconds / 1000 }
                continue
            }

            let ns = line as NSString
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }

            var content = ns.substring(from: last.range.location + last.range.length)
            let contentRange = NSRange(location: 0, length: (content as NSString).length)
            content = wordTag.stringByReplacingMatches(in: content, range: contentRange, withTemplate: "")
            content = content.trimmingCharacters(in: .whitespaces)

            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                var fraction = 0.0
                let fractionRange = match.range(at: 3)
                if fractionRange.location != NSNotFound {
                    let digits = ns.substring(with: fractionRange)
                    if let value = Double(digits) {
                        fraction = value / pow(10, Double(digits.count))
                    }
                }
                entries.append((minutes * 60 + seconds + fraction + offset, content))
            }
        }

        let sorted = entries.enumerated().sorted { lhs, rhs in
            if lhs.element.time == rhs.element.time { return lhs.offset < rhs.offset }
            return lhs.element.time < rhs.element.time
        }
        return sorted.enumerated().map { index, item in
            LyricLine(id: index, time: max(0, item.element.time), text: item.element.text)
        }
    }
}

// MARK: - Saved lookups

private struct LyricsCacheEntry: Codable {
    var synced: String?
    var plain: String?
    var instrumental: Bool
    var notFound: Bool
    var date: Date
    var source: String?
}

private enum LyricsDiskCache {
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Moonlight", isDirectory: true)
            .appendingPathComponent("LyricsCache", isDirectory: true)
    }

    static func load(key: String) -> LyricsCacheEntry? {
        guard let directory = directory else { return nil }
        let url = directory.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(LyricsCacheEntry.self, from: data)
        else { return nil }
        // A "not found" answer is only trusted for three days, in case lyrics get added later.
        if entry.notFound, Date().timeIntervalSince(entry.date) > 3 * 24 * 3600 { return nil }
        return entry
    }

    static func save(_ entry: LyricsCacheEntry, key: String) {
        guard let directory = directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
        }
    }
}

// MARK: - Lookup

enum LyricsSettings {
    static var useLRCLib: Bool { UserDefaults.standard.object(forKey: "lyricsUseLRCLIB") as? Bool ?? true }
    static var useKugou: Bool { UserDefaults.standard.object(forKey: "lyricsUseKugou") as? Bool ?? true }
}

private struct LRCLibResponse: Decodable {
    var trackName: String?
    var artistName: String?
    var duration: Double?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?
}

private struct KugouCandidate: Decodable {
    var id: String?
    var accesskey: String?
    var song: String?
    var singer: String?
    var duration: Double?

    enum CodingKeys: String, CodingKey {
        case id, accesskey, song, singer, duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .id) {
            id = text
        } else if let number = try? container.decode(Int64.self, forKey: .id) {
            id = String(number)
        }
        accesskey = try? container.decode(String.self, forKey: .accesskey)
        song = try? container.decode(String.self, forKey: .song)
        singer = try? container.decode(String.self, forKey: .singer)
        duration = try? container.decode(Double.self, forKey: .duration)
    }
}

private struct KugouSearchResponse: Decodable {
    var candidates: [KugouCandidate]?
}

private struct KugouDownloadResponse: Decodable {
    var content: String?
}

enum LyricsService {
    private static let userAgent = "Moonlight-macOS13 (https://github.com/musopen/moonlight)"

    static func fetch(_ query: LyricsQuery) async -> LyricsOutcome {
        // 1. A .lrc file next to the song
        if let url = query.fileURL, url.isFileURL {
            let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
            if let text = readText(at: sidecar) {
                let lines = LRCParser.parse(text)
                if !lines.isEmpty {
                    return .found(TrackLyrics(lines: lines, plain: nil, isInstrumental: false, source: "Local .lrc file"))
                }
            }
        }

        let useLRCLib = LyricsSettings.useLRCLib
        let useKugou = LyricsSettings.useKugou
        guard useLRCLib || useKugou else {
            return .failed("Both online lyrics sources are switched off. Use the menu at the top right.")
        }

        // 2. A saved lookup (kept separately for each combination of sources)
        let key = query.cacheKey + "-" + (useLRCLib ? "l" : "") + (useKugou ? "k" : "")
        if let entry = LyricsDiskCache.load(key: key) {
            if entry.notFound { return .notFound }
            return .found(makeLyrics(synced: entry.synced, plain: entry.plain,
                                     instrumental: entry.instrumental, source: entry.source ?? "Saved"))
        }

        guard !query.title.isEmpty else { return .notFound }

        // 3. Online: LRCLIB first, then Kugou when LRCLIB has nothing or only plain text
        var best: TrackLyrics?
        var hadError = false

        if useLRCLib {
            do {
                best = try await lrclib(query)
            } catch {
                if Task.isCancelled { return .failed("Cancelled") }
                hadError = true
            }
        }

        if useKugou, best?.isSynced != true {
            do {
                if let kugouLyrics = try await kugou(query), kugouLyrics.isSynced || best == nil {
                    best = kugouLyrics
                }
            } catch {
                if Task.isCancelled { return .failed("Cancelled") }
                hadError = true
            }
        }

        if let best = best {
            let syncedText = best.isSynced ? best.rawSynced : nil
            LyricsDiskCache.save(
                LyricsCacheEntry(synced: syncedText, plain: best.plain, instrumental: best.isInstrumental,
                                 notFound: false, date: Date(), source: best.source),
                key: key
            )
            return .found(best)
        }
        if hadError { return .failed("Could not reach the lyrics services.") }

        LyricsDiskCache.save(
            LyricsCacheEntry(synced: nil, plain: nil, instrumental: false, notFound: true, date: Date(), source: nil),
            key: key
        )
        return .notFound
    }

    private static func makeLyrics(synced: String?, plain: String?, instrumental: Bool, source: String) -> TrackLyrics {
        let lines = synced.map { LRCParser.parse($0) } ?? []
        let plainText = (plain?.isEmpty == false) ? plain : nil
        var lyrics = TrackLyrics(lines: lines, plain: plainText, isInstrumental: instrumental, source: source)
        lyrics.rawSynced = synced
        return lyrics
    }

    private static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func request(base: String, path: String, items: [URLQueryItem], timeout: TimeInterval = 10) async throws -> Data? {
        guard var components = URLComponents(string: base + path) else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: LRCLIB

    private static func lrclib(_ query: LyricsQuery) async throws -> TrackLyrics? {
        var found = try await lrclibExact(query)
        if found == nil { found = try await lrclibSearch(query) }
        guard let match = found else { return nil }
        let hasText = (match.syncedLyrics?.isEmpty == false) || (match.plainLyrics?.isEmpty == false)
        let instrumental = match.instrumental ?? false
        guard hasText || instrumental else { return nil }
        return makeLyrics(synced: match.syncedLyrics, plain: match.plainLyrics,
                          instrumental: instrumental, source: "LRCLIB")
    }

    private static func lrclibExact(_ query: LyricsQuery) async throws -> LRCLibResponse? {
        var items = [
            URLQueryItem(name: "artist_name", value: query.artist),
            URLQueryItem(name: "track_name", value: query.title)
        ]
        if !query.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: query.album)) }
        if query.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(query.duration.rounded()))))
        }
        guard let data = try await request(base: "https://lrclib.net/api", path: "/get", items: items, timeout: 8) else { return nil }
        return try? JSONDecoder().decode(LRCLibResponse.self, from: data)
    }

    private static func lrclibSearch(_ query: LyricsQuery) async throws -> LRCLibResponse? {
        let items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist)
        ]
        guard let data = try await request(base: "https://lrclib.net/api", path: "/search", items: items, timeout: 8),
              let results = try? JSONDecoder().decode([LRCLibResponse].self, from: data)
        else { return nil }

        func distance(_ result: LRCLibResponse) -> Double {
            guard query.duration > 0, let duration = result.duration else { return 0 }
            return abs(duration - query.duration)
        }
        let candidates = results
            .filter { distance($0) <= 4 }
            .sorted { distance($0) < distance($1) }
        if let synced = candidates.first(where: { $0.syncedLyrics?.isEmpty == false }) { return synced }
        return candidates.first(where: { $0.plainLyrics?.isEmpty == false })
    }

    // MARK: Kugou

    private static func kugou(_ query: LyricsQuery) async throws -> TrackLyrics? {
        let base = "https://lyrics.kugou.com"
        let artistPart = query.artist.lowercased() == "unknown artist" ? "" : query.artist
        let keyword = [artistPart, query.title].filter { !$0.isEmpty }.joined(separator: " - ")
        guard !keyword.isEmpty else { return nil }

        var items = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "man", value: "yes"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "hash", value: "")
        ]
        if query.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int((query.duration * 1000).rounded()))))
        }
        guard let searchData = try await request(base: base, path: "/search", items: items),
              let search = try? JSONDecoder().decode(KugouSearchResponse.self, from: searchData),
              let candidates = search.candidates, !candidates.isEmpty
        else { return nil }

        var bestScore = -Double.infinity
        var best: KugouCandidate?
        for candidate in candidates {
            guard candidate.id != nil, candidate.accesskey != nil,
                  let score = kugouScore(candidate, query: query) else { continue }
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        guard let chosen = best, let id = chosen.id, let accessKey = chosen.accesskey else { return nil }

        let downloadItems = [
            URLQueryItem(name: "ver", value: "1"),
            URLQueryItem(name: "client", value: "pc"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "accesskey", value: accessKey),
            URLQueryItem(name: "fmt", value: "lrc"),
            URLQueryItem(name: "charset", value: "utf8")
        ]
        guard let downloadData = try await request(base: base, path: "/download", items: downloadItems),
              let download = try? JSONDecoder().decode(KugouDownloadResponse.self, from: downloadData),
              let content = download.content,
              let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
              var text = String(data: decoded, encoding: .utf8)
        else { return nil }

        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = LRCParser.parse(text)
        guard !lines.isEmpty else { return nil }
        var lyrics = TrackLyrics(lines: lines, plain: nil, isInstrumental: false, source: "Kugou")
        lyrics.rawSynced = text
        return lyrics
    }

    /// Lower-cases, removes accents, width variants and bracketed notes, and keeps only letters and
    /// digits of any script, so Chinese, Japanese and Korean titles compare correctly.
    private static func normalized(_ text: String) -> String {
        var folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        folded = folded.replacingOccurrences(
            of: "\\(.*?\\)|\\[.*?\\]|（.*?）|【.*?】",
            with: "",
            options: .regularExpression
        )
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Returns nil when a result does not match the song, otherwise a higher score for a closer match.
    private static func kugouScore(_ candidate: KugouCandidate, query: LyricsQuery) -> Double? {
        let wantedTitle = normalized(query.title)
        let foundTitle = normalized(candidate.song ?? "")
        guard !wantedTitle.isEmpty, !foundTitle.isEmpty else { return nil }

        var score = 0.0
        if wantedTitle == foundTitle {
            score += 4
        } else if wantedTitle.contains(foundTitle) || foundTitle.contains(wantedTitle) {
            score += 2
        } else {
            return nil
        }

        let wantedArtist = normalized(query.artist)
        let foundArtist = normalized(candidate.singer ?? "")
        if !wantedArtist.isEmpty, !foundArtist.isEmpty {
            if wantedArtist == foundArtist {
                score += 3
            } else if wantedArtist.contains(foundArtist) || foundArtist.contains(wantedArtist) {
                score += 2
            } else {
                score -= 1
            }
        }

        if query.duration > 0, let raw = candidate.duration, raw > 0 {
            let seconds = raw > 1000 ? raw / 1000 : raw
            let difference = abs(seconds - query.duration)
            if difference > 8 { return nil }
            score += max(0, 2 - difference / 4)
        }
        return score
    }
}

// MARK: - View model

@MainActor
final class LyricsViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(TrackLyrics)
        case notFound
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func load(track: Track) async {
        state = .loading
        let query = LyricsQuery(
            artist: track.displayArtist,
            title: track.displayTitle,
            album: track.displayAlbum,
            duration: track.duration ?? 0,
            fileURL: URL(string: track.fileURL)
        )
        let outcome = await LyricsService.fetch(query)
        if Task.isCancelled { return }
        switch outcome {
        case .found(let lyrics): state = .loaded(lyrics)
        case .notFound: state = .notFound
        case .failed(let message): state = .failed(message)
        }
    }
}

// MARK: - Panel

struct LyricsPanel: View {
    let track: Track
    let controller: PlaybackController

    @StateObject private var model = LyricsViewModel()
    @State private var elapsed: TimeInterval = 0
    @State private var reloadToken = 0
    @AppStorage("lyricsUseLRCLIB") private var useLRCLib = true
    @AppStorage("lyricsUseKugou") private var useKugou = true

    private var taskKey: String {
        "\(track.dbId.map(String.init) ?? track.fileURL)-\(reloadToken)"
    }

    var body: some View {
        ZStack {
            switch model.state {
            case .idle:
                Color.clear
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .environment(\.colorScheme, .dark)
            case .notFound:
                LyricsMessage(title: "No lyrics found", detail: "Put a .lrc file next to the song to use your own lyrics.")
            case .failed(let message):
                VStack(spacing: 10) {
                    LyricsMessage(title: "Lyrics unavailable", detail: message)
                    Button("Try again") { reloadToken += 1 }
                        .controlSize(.small)
                }
            case .loaded(let lyrics):
                if lyrics.isInstrumental && !lyrics.isSynced && lyrics.plain == nil {
                    LyricsMessage(title: "Instrumental", detail: "This song has no lyrics.")
                } else if lyrics.isSynced {
                    SyncedLyricsView(lyrics: lyrics, elapsed: elapsed) { time in
                        controller.seek(to: time)
                    }
                } else {
                    PlainLyricsView(text: lyrics.plain ?? "")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 56)
        .padding(.bottom, 12)
        .overlay(alignment: .topTrailing) {
            Menu {
                Toggle("LRCLIB", isOn: $useLRCLib)
                Toggle("Kugou", isOn: $useKugou)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundColor(Color.white.opacity(0.7))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Lyrics sources")
            .padding(.top, 18)
            .padding(.trailing, 22)
        }
        .onChange(of: useLRCLib) { _ in reloadToken += 1 }
        .onChange(of: useKugou) { _ in reloadToken += 1 }
        .task(id: taskKey) {
            await model.load(track: track)
        }
        .onReceive(controller.engine.timePublisher) { time in
            elapsed = time
        }
    }
}

private struct LyricsMessage: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 28))
                .foregroundColor(Color.white.opacity(0.45))
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.85))
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }
}

private struct LyricsEdgeFade: ViewModifier {
    func body(content: Content) -> some View {
        content.mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.10),
                    .init(color: .black, location: 0.90),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct SyncedLyricsView: View {
    let lyrics: TrackLyrics
    let elapsed: TimeInterval
    let onSelect: (TimeInterval) -> Void

    private var activeIndex: Int {
        let position = elapsed + 0.2
        var result = -1
        for line in lyrics.lines {
            if line.time <= position { result = line.id } else { break }
        }
        return result
    }

    var body: some View {
        let active = activeIndex
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: 90)
                    ForEach(lyrics.lines) { line in
                        LyricLineView(line: line, distance: active < 0 ? line.id + 1 : abs(line.id - active)) {
                            onSelect(line.time)
                        }
                        .id(line.id)
                    }
                    Text(lyrics.source)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.3))
                        .padding(.top, 20)
                    Color.clear.frame(height: 260)
                }
                .padding(.horizontal, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(LyricsEdgeFade())
            .onChange(of: active) { newValue in
                guard newValue >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(newValue, anchor: UnitPoint(x: 0.5, y: 0.35))
                }
            }
        }
    }
}

private struct LyricLineView: View {
    let line: LyricLine
    let distance: Int
    let action: () -> Void

    @State private var isHovered = false

    private var opacity: Double {
        switch distance {
        case 0: return 1.0
        case 1: return 0.55
        case 2: return 0.40
        default: return 0.28
        }
    }

    var body: some View {
        Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: 28, weight: .bold))
            .foregroundColor(Color.white.opacity(isHovered ? min(1, opacity + 0.25) : opacity))
            .scaleEffect(distance == 0 ? 1 : 0.96, anchor: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.3), value: distance)
    }
}

private struct PlainLyricsView: View {
    let text: String

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .font(.system(size: 18, weight: .medium))
                .lineSpacing(7)
                .foregroundColor(Color.white.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 60)
        }
        .modifier(LyricsEdgeFade())
    }
}
