import Foundation
import SwiftUI

struct LyricsTrack: Hashable {
    let title: String
    let artist: String
    let album: String
    let duration: Int
}
struct LyricsLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}
enum LRCParser {
    static func parse(_ input: String) -> [LyricsLine] {
        let regex = try! NSRegularExpression(pattern: #"\[(?:(\d+):)?(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        let offsetRegex = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let whole = input as NSString
        var offset = 0.0
        if let match = offsetRegex.firstMatch(in: input, range: NSRange(location: 0, length: whole.length)) {
            offset = (Double(whole.substring(with: match.range(at: 1))) ?? 0) / 1000
        }
        var entries: [(Double, String)] = []
        for raw in input.components(separatedBy: .newlines) {
            let line = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: line.length))
            guard let last = matches.last else { continue }
            let text = line.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                func number(_ group: Int) -> Double {
                    let range = match.range(at: group)
                    return range.location == NSNotFound ? 0 : (Double(line.substring(with: range)) ?? 0)
                }
                let fractionRange = match.range(at: 4)
                let fraction = fractionRange.location == NSNotFound ? 0 : number(4) / pow(10, Double(fractionRange.length))
                let time = number(1) * 3600 + number(2) * 60 + number(3) + fraction + offset
                entries.append((max(0, time), text))
            }
        }
        // Stable order for simultaneous timestamps. Empty lines mark instrumental gaps.
        return entries.enumerated().sorted { a, b in a.element.0 == b.element.0 ? a.offset < b.offset : a.element.0 < b.element.0 }
            .enumerated().map { index, value in LyricsLine(id: index, time: value.element.0, text: value.element.1) }
    }
    static func activeIndex(in lines: [LyricsLine], at position: Double) -> Int? {
        guard position.isFinite else { return nil }
        return lines.lastIndex { $0.time <= position }
    }
}
private struct LRCLIBRecord: Decodable {
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}
private struct LyricsContent {
    let lines: [LyricsLine]
    let plain: String
    let instrumental: Bool
}

@MainActor
final class LyricsModel: ObservableObject {
    @Published private(set) var lines: [LyricsLine] = []
    @Published private(set) var plain = ""
    @Published private(set) var loading = false
    @Published private(set) var message = ""
    @Published private(set) var canRetry = false
    private var cache: [LyricsTrack: LyricsContent] = [:]
    private var generation = UUID()
    private var retryAfter = Date.distantPast

    func load(_ track: LyricsTrack?, enabled: Bool, force: Bool = false) async {
        let token = UUID(); generation = token
        lines = []; plain = ""; message = ""; canRetry = false; loading = false
        guard enabled else { return }
        guard let track, !track.artist.isEmpty, track.duration > 1 else {
            message = "Select a track in Spotify to view lyrics."
            return
        }
        if !force, let value = cache[track] { apply(value); return }
        if retryAfter > Date() {
            message = "LRCLIB is rate limiting requests. Try again in \(Int(ceil(retryAfter.timeIntervalSinceNow))) seconds."
            canRetry = true; return
        }
        loading = true
        defer { if generation == token { loading = false } }
        var url = URLComponents(string: "https://lrclib.net/api/get")!
        url.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(track.duration))
        ]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 15
        request.setValue("Spectrum/1.0 (macOS; https://github.com/wafiqhsn/Spectrum)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard generation == token, let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 429 || http.statusCode == 503 {
                let header = http.value(forHTTPHeaderField: "Retry-After") ?? "30"
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                retryAfter = Double(header).map { Date().addingTimeInterval(max(1, $0)) } ?? formatter.date(from: header) ?? Date().addingTimeInterval(30)
                message = "LRCLIB is busy. Please try again shortly."; canRetry = true; return
            }
            if http.statusCode == 404 {
                let value = LyricsContent(lines: [], plain: "", instrumental: false)
                remember(value, for: track); apply(value); canRetry = true; return
            }
            guard http.statusCode == 200, data.count < 2_000_000 else {
                message = "Unable to load lyrics (HTTP \(http.statusCode))."; canRetry = true; return
            }
            let record = try JSONDecoder().decode(LRCLIBRecord.self, from: data)
            let value = LyricsContent(lines: LRCParser.parse(record.syncedLyrics ?? ""), plain: record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", instrumental: record.instrumental)
            remember(value, for: track); apply(value)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            message = "Unable to reach LRCLIB. Check your internet connection."; canRetry = true
        }
    }
    private func remember(_ value: LyricsContent, for track: LyricsTrack) {
        if cache.count >= 40 { cache.removeAll() }
        cache[track] = value
    }
    private func apply(_ value: LyricsContent) {
        lines = value.lines; plain = value.plain
        if value.instrumental { message = "Instrumental · no lyrics" }
        else if lines.isEmpty && plain.isEmpty { message = "Lyrics are not available for this version of the track."; canRetry = true }
    }
}

struct LyricsPanel: View {
    @ObservedObject var lyrics: LyricsModel
    let position: Double
    let retry: () -> Void
    var height: CGFloat = 80
    private var active: Int? { LRCParser.activeIndex(in: lyrics.lines, at: position) }
    var body: some View {
        VStack(spacing: 4) {
            if lyrics.loading {
                HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("Finding lyrics…").font(.system(size: 11)) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !lyrics.lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 12) {
                            ForEach(lyrics.lines) { line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                                    .scaleEffect(line.id == active ? 1 : 0.74)
                                    .opacity(line.id == active ? 0.98 : 0.32)
                                    .animation(.smooth(duration: 0.18), value: active)
                                    .id(line.id)
                            }
                        }.padding(.vertical, height / 2 - 16)
                    }.scrollIndicators(.hidden)
                        .onChange(of: active, initial: true) { _, index in
                            withAnimation(.smooth(duration: 0.95)) { proxy.scrollTo(index ?? 0, anchor: .center) }
                        }
                }
            } else if !lyrics.plain.isEmpty {
                ScrollView { Text(lyrics.plain).font(.system(size: 12)).multilineTextAlignment(.center).frame(maxWidth: .infinity).textSelection(.enabled) }
                    .scrollIndicators(.hidden).help("Plain lyrics · no timestamps")
            } else {
                VStack(spacing: 4) {
                    Text(lyrics.message).font(.system(size: 10)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if lyrics.canRetry { Button("Try again", action: retry).buttonStyle(.link).font(.system(size: 10)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(height: height)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.18), .init(color: .white, location: 0.82), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .accessibilityLabel("Lyrics panel")
    }
}
