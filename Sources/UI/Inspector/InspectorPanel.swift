// InspectorPanel.swift
//
// An optional panel on the right side of the Mac window with three tabs. "Now Playing" shows
// the current song's artwork, quality badge and a plain-language signal path (source file,
// decoder, sample-rate conversion, volume and the output device). "Details" lists the file's
// tags and technical facts. "Analysis" reads a short section of the audio and checks whether
// a "hi-res" file really is: padded bit depth, upsampling and lossy-source low-pass filters,
// plus peak level, clipping and a long-term spectrum chart. The analysis is a heuristic and
// is described as such in the panel.

import SwiftUI
import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Combine

// MARK: - Tabs

enum InspectorTab: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing"
    case details = "Details"
    case analysis = "Analysis"

    var id: String { rawValue }
}

// MARK: - Panel

struct InspectorPanel: View {
    @ObservedObject var controller: PlaybackController

    @AppStorage("inspectorTab") private var tabRaw: String = InspectorTab.nowPlaying.rawValue
    @StateObject private var facts = InspectorFactsModel()
    @StateObject private var analysis = InspectorAnalysisModel()

    private var tab: InspectorTab { InspectorTab(rawValue: tabRaw) ?? .nowPlaying }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Rectangle()
                .fill(Color.textQuaternary.opacity(0.25))
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.bgContent)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.textQuaternary.opacity(0.3))
                .frame(width: 1)
        }
        .onAppear { facts.refresh(track: controller.currentTrack) }
        .onChange(of: controller.currentTrack?.dbId) { _ in
            facts.refresh(track: controller.currentTrack)
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            facts.refreshDevice()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { item in
                Button {
                    tabRaw = item.rawValue
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(tab == item ? Color.black.opacity(0.85) : Color.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(tab == item ? Color.dAccent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.bgElevated.opacity(0.7)))
    }

    @ViewBuilder
    private var content: some View {
        if controller.currentRadioStation != nil {
            InspectorMessage(
                symbol: "dot.radiowaves.left.and.right",
                title: "Live radio",
                detail: "There is no audio file to inspect while a radio station plays."
            )
        } else if let track = controller.currentTrack {
            switch tab {
            case .nowPlaying:
                InspectorNowPlayingTab(track: track, controller: controller, facts: facts)
            case .details:
                InspectorDetailsTab(track: track, facts: facts)
            case .analysis:
                InspectorAnalysisTab(track: track, facts: facts, model: analysis)
            }
        } else {
            InspectorMessage(
                symbol: "waveform",
                title: "Nothing playing",
                detail: "Play a song to see its signal path, details and analysis."
            )
        }
    }
}

// MARK: - Small building blocks

private struct InspectorMessage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundColor(Color.textTertiary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.textPrimary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

private struct InspectorSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .foregroundColor(Color.textTertiary)
    }
}

private enum InspectorChipStyle {
    case neutral, accent, warning
}

private struct InspectorChip: View {
    let text: String
    var style: InspectorChipStyle = .neutral

    var body: some View {
        let tint: Color = {
            switch style {
            case .neutral: return Color.textSecondary
            case .accent: return Color.dAccent
            case .warning: return Color.orange
            }
        }()
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tint.opacity(0.45), lineWidth: 1)
            )
    }
}

private struct InspectorInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color.textTertiary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Now Playing tab

private struct InspectorNowPlayingTab: View {
    let track: Track
    @ObservedObject var controller: PlaybackController
    @ObservedObject var facts: InspectorFactsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ArtworkView(
                albumId: track.albumId,
                artworkId: track.artworkId,
                large: true,
                cornerRadius: 10,
                iconFont: .largeTitle,
                retainsPreviousImageWhileLoading: true
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 220)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundColor(Color.textPrimary)
                    .lineLimit(3)
                Text(track.displayArtist)
                    .font(.system(size: 13))
                    .foregroundColor(Color.dAccent)
                    .lineLimit(2)
                Text(albumLine)
                    .font(.system(size: 12))
                    .foregroundColor(Color.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                ForEach(qualityChips, id: \.text) { chip in
                    InspectorChip(text: chip.text, style: chip.style)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                InspectorSectionLabel("Signal path")
                ForEach(signalRows) { row in
                    InspectorSignalRowView(row: row)
                }
                Text("Moonlight plays through the macOS audio mixer, so playback is not exclusive or bit-perfect. This list shows what the mixer is doing with this song.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var albumLine: String {
        var parts = [track.displayAlbum]
        if let year = track.year, year > 0 { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    private var qualityChips: [(text: String, style: InspectorChipStyle)] {
        guard let info = InspectorFormatting.quality(track: track, facts: facts.fileFacts) else { return [] }
        return info
    }

    private var signalRows: [InspectorSignalRow] {
        InspectorSignalPath.rows(
            track: track,
            facts: facts.fileFacts,
            device: facts.device,
            volume: controller.volume,
            volumeMode: controller.volumeMode
        )
    }
}

private struct InspectorSignalRow: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let value: String
    let isChanged: Bool
}

private struct InspectorSignalRowView: View {
    let row: InspectorSignalRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .strokeBorder(Color.dAccent, lineWidth: 1.5)
                .background(Circle().fill(row.isChanged ? Color.dAccent : Color.clear))
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.textPrimary)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Text(row.value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private enum InspectorSignalPath {
    static func rows(
        track: Track,
        facts: AudioFileFacts?,
        device: OutputDeviceInfo?,
        volume: Float,
        volumeMode: PlaybackVolumeMode
    ) -> [InspectorSignalRow] {
        var rows: [InspectorSignalRow] = []

        let codec = facts?.codec ?? (track.format?.uppercased() ?? "Audio")
        let lossless = facts?.isLossless ?? InspectorFormatting.isLosslessName(track.format)
        let channels = InspectorFormatting.channelsLabel(facts?.channels ?? track.channelCount)
        let sourceRate: Double? = facts?.sampleRate ?? track.sampleRate.map { Double($0) }

        var sourceValue: [String] = []
        if let bits = facts?.bitDepth { sourceValue.append("\(bits)-bit") }
        if let rate = sourceRate, rate > 0 { sourceValue.append(InspectorFormatting.kHz(rate)) }

        rows.append(InspectorSignalRow(
            id: "source",
            title: "Source",
            detail: [codec, lossless ? "lossless" : "lossy", channels].joined(separator: " · "),
            value: sourceValue.joined(separator: " · "),
            isChanged: false
        ))

        rows.append(InspectorSignalRow(
            id: "decoder",
            title: "Decoder",
            detail: "Core Audio",
            value: lossless ? "lossless" : "lossy decode",
            isChanged: false
        ))

        if let rate = sourceRate, rate > 0, let device = device, device.sampleRate > 0 {
            if abs(rate - device.sampleRate) < 1 {
                rows.append(InspectorSignalRow(
                    id: "rate",
                    title: "Sample rate",
                    detail: "Output device runs at the source rate",
                    value: "\(InspectorFormatting.kHz(rate)) · native",
                    isChanged: false
                ))
            } else {
                rows.append(InspectorSignalRow(
                    id: "rate",
                    title: "Sample rate",
                    detail: "macOS converts \(InspectorFormatting.kHz(rate)) to \(InspectorFormatting.kHz(device.sampleRate)) for this device",
                    value: "converted",
                    isChanged: true
                ))
            }
        }

        switch volumeMode {
        case .routeVolume:
            rows.append(InspectorSignalRow(
                id: "volume",
                title: "Volume",
                detail: "Output device volume; the player stays at full level",
                value: "device control",
                isChanged: false
            ))
        default:
            if volume >= 0.999 {
                rows.append(InspectorSignalRow(
                    id: "volume",
                    title: "Volume",
                    detail: "Player volume at 100%",
                    value: "unity · 0.0 dB",
                    isChanged: false
                ))
            } else {
                let percent = Int((volume * 100).rounded())
                rows.append(InspectorSignalRow(
                    id: "volume",
                    title: "Volume",
                    detail: "Player volume lowers the digital level",
                    value: "\(percent)%",
                    isChanged: true
                ))
            }
        }

        if let device = device {
            var detail: [String] = []
            if let transport = device.transport { detail.append(transport) }
            rows.append(InspectorSignalRow(
                id: "output",
                title: device.name,
                detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                value: device.sampleRate > 0 ? InspectorFormatting.kHz(device.sampleRate) : "",
                isChanged: false
            ))
        }

        return rows
    }
}

// MARK: - Details tab

private struct InspectorDetailsTab: View {
    let track: Track
    @ObservedObject var facts: InspectorFactsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                InspectorSectionLabel("Tags")
                ForEach(tagRows, id: \.0) { row in
                    InspectorInfoRow(label: row.0, value: row.1)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorSectionLabel("Audio")
                ForEach(audioRows, id: \.0) { row in
                    InspectorInfoRow(label: row.0, value: row.1)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorSectionLabel("Library")
                ForEach(libraryRows, id: \.0) { row in
                    InspectorInfoRow(label: row.0, value: row.1)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorSectionLabel("File")
                InspectorInfoRow(label: "Path", value: filePath)
            }
        }
    }

    private var tagRows: [(String, String)] {
        var rows: [(String, String)] = [("Title", track.displayTitle), ("Artist", track.displayArtist)]
        if let value = nonEmpty(track.albumArtist) { rows.append(("Album artist", value)) }
        rows.append(("Album", track.displayAlbum))
        if let value = nonEmpty(track.composer) { rows.append(("Composer", value)) }
        if let value = nonEmpty(track.genre) { rows.append(("Genre", value)) }
        if let year = track.year, year > 0 { rows.append(("Year", String(year))) }
        if let number = track.trackNumber, number > 0 {
            var text = String(number)
            if let disc = track.discNumber, disc > 0 { text += " (disc \(disc))" }
            rows.append(("Track", text))
        }
        return rows
    }

    private var audioRows: [(String, String)] {
        var rows: [(String, String)] = []
        let facts = self.facts.fileFacts
        rows.append(("Format", facts?.codec ?? (track.format?.uppercased() ?? "Unknown")))
        if let bits = facts?.bitDepth { rows.append(("Bit depth", "\(bits)-bit")) }
        if let rate = facts?.sampleRate ?? track.sampleRate.map({ Double($0) }), rate > 0 {
            rows.append(("Sample rate", InspectorFormatting.kHz(rate)))
        }
        rows.append(("Channels", InspectorFormatting.channelsLabel(facts?.channels ?? track.channelCount)))
        if let bitRate = track.bitRate, bitRate > 0 {
            let kbps = bitRate >= 10_000 ? bitRate / 1000 : bitRate
            rows.append(("Bit rate", "\(kbps) kbps"))
        }
        if let duration = track.duration, duration.isFinite, duration > 0 {
            rows.append(("Duration", track.durationFormatted))
        }
        if let size = track.fileSize, size > 0 {
            rows.append(("File size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        return rows
    }

    private var libraryRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let rating = track.rating, rating > 0 { rows.append(("Rating", "\(rating)")) }
        rows.append(("Favorite", track.isFavorite ? "Yes" : "No"))
        rows.append(("Play count", String(track.playCount)))
        if let last = track.lastPlayedAt {
            rows.append(("Last played", last.formatted(date: .abbreviated, time: .shortened)))
        }
        rows.append(("Added", track.dateAdded.formatted(date: .abbreviated, time: .omitted)))
        return rows
    }

    private var filePath: String {
        if let url = URL(string: track.fileURL), url.isFileURL { return url.path }
        return track.fileURL
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Analysis tab

private struct InspectorAnalysisTab: View {
    let track: Track
    @ObservedObject var facts: InspectorFactsModel
    @ObservedObject var model: InspectorAnalysisModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundColor(Color.textPrimary)
                    .lineLimit(2)
                Text([facts.fileFacts?.codec ?? track.format?.uppercased(), track.displayArtist]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.textTertiary)
                    .lineLimit(2)
            }

            switch model.state {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing audio…")
                        .font(.system(size: 12))
                        .foregroundColor(Color.textSecondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .done(let result):
                InspectorAnalysisReport(result: result)
            }

            HStack {
                if case .done(let result) = model.state {
                    Text("Analyzed \(result.date.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11))
                        .foregroundColor(Color.textTertiary)
                }
                Spacer()
                Button("Re-analyze") {
                    model.analyze(track: track, facts: facts.fileFacts, force: true)
                }
                .controlSize(.small)
                .disabled(model.state == .running)
            }
        }
        .onAppear {
            model.analyze(track: track, facts: facts.fileFacts, force: false)
        }
        .onChange(of: track.dbId) { _ in
            model.analyze(track: track, facts: facts.fileFacts, force: false)
        }
    }
}

private struct InspectorAnalysisReport: View {
    let result: TrackAnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                InspectorChip(text: verdictTitle, style: verdictStyle)
                InspectorChip(text: confidenceText)
            }

            Text(verdictExplanation)
                .font(.system(size: 13))
                .foregroundColor(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                if let claimed = result.claimedBits {
                    InspectorInfoRow(label: "Claimed", value: "\(claimed)-bit")
                }
                if let effective = result.effectiveBits {
                    InspectorInfoRow(label: "Effective", value: "\(effective)-bit")
                }
                InspectorInfoRow(
                    label: "Audio up to",
                    value: "\(InspectorFormatting.kHz(result.cutoffHz)) of \(InspectorFormatting.kHz(result.nyquistHz))"
                )
                InspectorInfoRow(label: "Peak", value: String(format: "%.2f dBFS", result.peakDb))
                InspectorInfoRow(label: "Clipped samples", value: "\(result.clippedSamples)")
                InspectorInfoRow(label: "Analyzed", value: "\(Int(result.analyzedSeconds.rounded())) s")
            }

            VStack(alignment: .leading, spacing: 8) {
                InspectorSectionLabel("Long-term spectrum")
                InspectorSpectrumChart(result: result)
                    .frame(height: 150)
            }

            Text("This is a heuristic based on a short section of the song, not proof. Quiet or sparse music can look band-limited without being fake.")
                .font(.system(size: 11))
                .foregroundColor(Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var verdictTitle: String {
        switch result.verdict {
        case .clean: return "No issues found"
        case .paddedBitDepth: return "Padded bit depth"
        case .likelyUpsampled: return "Likely upsampled"
        case .possibleLossySource: return "Possible lossy source"
        case .lossyFormat: return "Lossy format"
        case .silent: return "Silent section"
        }
    }

    private var verdictStyle: InspectorChipStyle {
        switch result.verdict {
        case .clean: return .accent
        case .paddedBitDepth, .likelyUpsampled, .possibleLossySource: return .warning
        case .lossyFormat, .silent: return .neutral
        }
    }

    private var confidenceText: String {
        switch result.verdict {
        case .paddedBitDepth: return "High confidence"
        case .likelyUpsampled, .possibleLossySource: return "Medium confidence"
        case .clean: return "Heuristic"
        case .lossyFormat, .silent: return "Info"
        }
    }

    private var verdictExplanation: String {
        switch result.verdict {
        case .clean:
            return "No zero-padding, upsampling or lossy low-pass filter was detected in the section analyzed."
        case .paddedBitDepth:
            let claimed = result.claimedBits.map { "\($0)-bit" } ?? "High bit depth"
            let effective = result.effectiveBits.map { "\($0)" } ?? "fewer"
            return "\(claimed) file, but only \(effective) bits carry audio (zero-padded)."
        case .likelyUpsampled(let from):
            return "The sample rate is \(InspectorFormatting.kHz(result.sampleRate)), but the audio stops near \(InspectorFormatting.kHz(result.cutoffHz)). That matches a \(InspectorFormatting.kHz(from)) recording that was upsampled."
        case .possibleLossySource:
            return "The audio ends in a sharp cut near \(InspectorFormatting.kHz(result.cutoffHz)), typical of an MP3 or AAC file that was later stored as lossless."
        case .lossyFormat:
            return "This file uses lossy compression, so bit depth checks do not apply. The spectrum shows what the encoder kept."
        case .silent:
            return "The part of the song that was analyzed is silent or almost silent. Play the song and re-analyze."
        }
    }
}

private struct InspectorSpectrumChart: View {
    let result: TrackAnalysisResult

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let points = chartPoints(in: size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.bgElevated.opacity(0.5))

                ForEach(gridFrequencies, id: \.self) { freq in
                    let x = xPosition(for: freq, width: size.width)
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height - 16))
                    }
                    .stroke(Color.textQuaternary.opacity(0.35), lineWidth: 1)

                    Text(label(for: freq))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color.textTertiary)
                        .position(x: min(max(x, 14), size.width - 14), y: size.height - 7)
                }

                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: size.height - 16))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height - 16))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.dAccent.opacity(0.35), Color.dAccent.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(Color.dAccent, lineWidth: 1.2)
                }
            }
        }
    }

    private var gridFrequencies: [Double] {
        [100, 1_000, 10_000, 20_000, 40_000].filter { $0 < result.nyquistHz }
    }

    private func label(for freq: Double) -> String {
        freq >= 1000 ? "\(Int(freq / 1000))k" : "\(Int(freq))"
    }

    private func xPosition(for freq: Double, width: CGFloat) -> CGFloat {
        let minF = 20.0
        let maxF = max(result.nyquistHz, 1000)
        let t = log(freq / minF) / log(maxF / minF)
        return CGFloat(min(max(t, 0), 1)) * width
    }

    private func chartPoints(in size: CGSize) -> [CGPoint] {
        guard result.spectrumFreqs.count == result.spectrumDb.count, !result.spectrumDb.isEmpty else { return [] }
        let plotHeight = max(size.height - 16, 1)
        let span = max(result.yMax - result.yMin, 1)
        var points: [CGPoint] = []
        for index in 0..<result.spectrumDb.count {
            let x = xPosition(for: Double(result.spectrumFreqs[index]), width: size.width)
            let normalized = min(max((Double(result.spectrumDb[index]) - result.yMin) / span, 0), 1)
            let y = plotHeight - CGFloat(normalized) * plotHeight
            points.append(CGPoint(x: x, y: y))
        }
        return points
    }
}

// MARK: - Formatting helpers

enum InspectorFormatting {
    static func kHz(_ hz: Double) -> String {
        let value = hz / 1000
        if abs(value - value.rounded()) < 0.05 { return "\(Int(value.rounded())) kHz" }
        return String(format: "%.1f kHz", value)
    }

    static func channelsLabel(_ count: Int?) -> String {
        switch count {
        case 1: return "mono"
        case 2: return "stereo"
        case .some(let n) where n > 2: return "\(n) channels"
        default: return "unknown channels"
        }
    }

    static func isLosslessName(_ format: String?) -> Bool {
        guard let format = format?.lowercased() else { return false }
        return ["flac", "alac", "wav", "wave", "aiff", "aif", "aifc", "pcm", "apple lossless"].contains { format.contains($0) }
    }

    fileprivate static func quality(track: Track, facts: AudioFileFacts?) -> [(text: String, style: InspectorChipStyle)]? {
        let lossless = facts?.isLossless ?? isLosslessName(track.format)
        let rate = facts?.sampleRate ?? track.sampleRate.map { Double($0) } ?? 0
        if lossless {
            let bits = facts?.bitDepth ?? 16
            if bits >= 24 || rate > 48_000 {
                return [("Hi-res lossless", .accent)]
            }
            return [("Lossless", .neutral)]
        }
        if track.format != nil || facts != nil {
            return [("Lossy", .neutral)]
        }
        return nil
    }
}

// MARK: - File facts and output device

struct AudioFileFacts {
    var codec: String
    var bitDepth: Int?
    var isFloat: Bool
    var sampleRate: Double
    var channels: Int
    var isLossless: Bool

    static func read(url: URL) -> AudioFileFacts? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let description = file.fileFormat.streamDescription.pointee
        let formatID = description.mFormatID
        let flags = description.mFormatFlags
        let ext = url.pathExtension.lowercased()

        func bitsFromSourceFlag(_ flag: UInt32) -> Int? {
            switch flag {
            case 1: return 16
            case 2: return 20
            case 3: return 24
            case 4: return 32
            default: return nil
            }
        }

        var codec = "Audio"
        var bits: Int?
        var lossless = false
        var isFloat = false

        if formatID == kAudioFormatLinearPCM {
            codec = ext == "wav" || ext == "wave" ? "WAV" : (ext.hasPrefix("aif") ? "AIFF" : "PCM")
            bits = description.mBitsPerChannel > 0 ? Int(description.mBitsPerChannel) : nil
            lossless = true
            isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        } else if formatID == kAudioFormatFLAC {
            codec = "FLAC"
            bits = bitsFromSourceFlag(flags)
            lossless = true
        } else if formatID == kAudioFormatAppleLossless {
            codec = "ALAC"
            bits = bitsFromSourceFlag(flags)
            lossless = true
        } else if formatID == kAudioFormatMPEGLayer3 {
            codec = "MP3"
        } else if formatID == kAudioFormatMPEG4AAC || formatID == kAudioFormatMPEG4AAC_HE || formatID == kAudioFormatMPEG4AAC_LD {
            codec = "AAC"
        } else if !ext.isEmpty {
            codec = ext.uppercased()
        }

        return AudioFileFacts(
            codec: codec,
            bitDepth: bits,
            isFloat: isFloat,
            sampleRate: file.fileFormat.sampleRate,
            channels: Int(file.fileFormat.channelCount),
            isLossless: lossless
        )
    }
}

struct OutputDeviceInfo {
    var name: String
    var sampleRate: Double
    var transport: String?

    static func current() -> OutputDeviceInfo? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }

        // Name
        var nameRef: CFString? = nil
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = withUnsafeMutablePointer(to: &nameRef) {
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, $0)
        }
        let name = (nameStatus == noErr ? nameRef.map { $0 as String } : nil) ?? "Output device"

        // Nominal sample rate
        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let rateStatus = AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &rate)

        // Connection type
        var transportType = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let transportStatus = AudioObjectGetPropertyData(
            deviceID, &transportAddress, 0, nil, &transportSize, &transportType
        )

        return OutputDeviceInfo(
            name: name,
            sampleRate: rateStatus == noErr ? rate : 0,
            transport: transportStatus == noErr ? transportName(transportType) : nil
        )
    }

    private static func transportName(_ type: UInt32) -> String? {
        if type == UInt32(kAudioDeviceTransportTypeBuiltIn) { return "Built-in" }
        if type == UInt32(kAudioDeviceTransportTypeUSB) { return "USB" }
        if type == UInt32(kAudioDeviceTransportTypeBluetooth) || type == UInt32(kAudioDeviceTransportTypeBluetoothLE) { return "Bluetooth" }
        if type == UInt32(kAudioDeviceTransportTypeAirPlay) { return "AirPlay" }
        if type == UInt32(kAudioDeviceTransportTypeHDMI) { return "HDMI" }
        if type == UInt32(kAudioDeviceTransportTypeDisplayPort) { return "DisplayPort" }
        if type == UInt32(kAudioDeviceTransportTypeThunderbolt) { return "Thunderbolt" }
        if type == UInt32(kAudioDeviceTransportTypeVirtual) { return "Virtual" }
        if type == UInt32(kAudioDeviceTransportTypeAggregate) { return "Aggregate" }
        return nil
    }
}

@MainActor
final class InspectorFactsModel: ObservableObject {
    @Published private(set) var fileFacts: AudioFileFacts?
    @Published private(set) var device: OutputDeviceInfo?

    private var factsTrackID: Int64?

    func refreshDevice() {
        device = OutputDeviceInfo.current()
    }

    func refresh(track: Track?) {
        device = OutputDeviceInfo.current()
        guard let track = track else {
            fileFacts = nil
            factsTrackID = nil
            return
        }
        if factsTrackID == track.dbId, fileFacts != nil { return }
        factsTrackID = track.dbId
        fileFacts = nil
        guard let url = URL(string: track.fileURL) else { return }
        let trackID = track.dbId
        Task {
            let result = await Task.detached(priority: .utility) {
                AudioFileFacts.read(url: url)
            }.value
            if self.factsTrackID == trackID {
                self.fileFacts = result
            }
        }
    }
}

// MARK: - Analysis model

enum AnalysisVerdict {
    case clean
    case paddedBitDepth
    case likelyUpsampled(from: Double)
    case possibleLossySource
    case lossyFormat
    case silent
}

struct TrackAnalysisResult {
    var claimedBits: Int?
    var effectiveBits: Int?
    var sampleRate: Double
    var cutoffHz: Double
    var nyquistHz: Double
    var peakDb: Double
    var clippedSamples: Int
    var analyzedSeconds: Double
    var verdict: AnalysisVerdict
    var spectrumFreqs: [Float]
    var spectrumDb: [Float]
    var yMin: Double
    var yMax: Double
    var date: Date
}

enum InspectorAnalysisState: Equatable {
    case idle
    case running
    case done(TrackAnalysisResult)
    case failed(String)

    static func == (lhs: InspectorAnalysisState, rhs: InspectorAnalysisState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.running, .running): return true
        case (.done(let a), .done(let b)): return a.date == b.date
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

@MainActor
final class InspectorAnalysisModel: ObservableObject {
    @Published private(set) var state: InspectorAnalysisState = .idle

    private var cache: [Int64: TrackAnalysisResult] = [:]
    private var currentTrackID: Int64?
    private var work: Task<Result<TrackAnalysisResult, Error>, Never>?

    func analyze(track: Track, facts: AudioFileFacts?, force: Bool) {
        let trackID = track.dbId ?? Int64(track.fileURL.hashValue)
        if !force, let cached = cache[trackID] {
            currentTrackID = trackID
            state = .done(cached)
            return
        }
        if !force, currentTrackID == trackID, state == .running { return }

        work?.cancel()
        currentTrackID = trackID
        state = .running

        guard let url = URL(string: track.fileURL) else {
            state = .failed("This song's file location is not valid.")
            return
        }

        let task = Task.detached(priority: .utility) { () -> Result<TrackAnalysisResult, Error> in
            let knownFacts = facts ?? AudioFileFacts.read(url: url)
            do {
                return .success(try TrackAnalyzer.analyze(url: url, facts: knownFacts))
            } catch {
                return .failure(error)
            }
        }
        work = task

        Task {
            let outcome = await task.value
            guard self.currentTrackID == trackID else { return }
            switch outcome {
            case .success(let result):
                self.cache[trackID] = result
                self.state = .done(result)
            case .failure(let error):
                if error is CancellationError { return }
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let known = error as? TrackAnalyzerError {
            switch known {
            case .tooShort: return "This song is too short to analyze."
            case .unreadable: return "Moonlight could not decode this file for analysis."
            }
        }
        return "Analysis failed: \(error.localizedDescription)"
    }
}

// MARK: - Analyzer

enum TrackAnalyzerError: Error {
    case tooShort
    case unreadable
}

/// A small radix-2 FFT so the analysis has no dependency on other frameworks.
private struct InspectorFFT {
    let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let reversed: [Int]

    init(size: Int) {
        self.size = size
        var bits = 0
        var probe = size
        while probe > 1 {
            probe >>= 1
            bits += 1
        }
        var cosines = [Float](repeating: 0, count: size / 2)
        var sines = [Float](repeating: 0, count: size / 2)
        for index in 0..<(size / 2) {
            let angle = -2.0 * Double.pi * Double(index) / Double(size)
            cosines[index] = Float(cos(angle))
            sines[index] = Float(sin(angle))
        }
        var order = [Int](repeating: 0, count: size)
        for index in 0..<size {
            var value = index
            var result = 0
            for _ in 0..<bits {
                result = (result << 1) | (value & 1)
                value >>= 1
            }
            order[index] = result
        }
        cosTable = cosines
        sinTable = sines
        reversed = order
    }

    func transform(real: inout [Float], imag: inout [Float]) {
        for index in 0..<size {
            let other = reversed[index]
            if other > index {
                real.swapAt(index, other)
                imag.swapAt(index, other)
            }
        }
        var length = 2
        while length <= size {
            let half = length / 2
            let step = size / length
            var start = 0
            while start < size {
                var k = 0
                for j in start..<(start + half) {
                    let wr = cosTable[k]
                    let wi = sinTable[k]
                    let tr = real[j + half] * wr - imag[j + half] * wi
                    let ti = real[j + half] * wi + imag[j + half] * wr
                    real[j + half] = real[j] - tr
                    imag[j + half] = imag[j] - ti
                    real[j] += tr
                    imag[j] += ti
                    k += step
                }
                start += length
            }
            length <<= 1
        }
    }
}

enum TrackAnalyzer {
    static func analyze(url: URL, facts: AudioFileFacts?) throws -> TrackAnalysisResult {
        guard let file = try? AVAudioFile(forReading: url) else { throw TrackAnalyzerError.unreadable }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard sampleRate > 0, channelCount > 0, file.length > 0 else { throw TrackAnalyzerError.unreadable }

        // Analyze up to 30 seconds, starting a fifth of the way in for long songs.
        let totalFrames = file.length
        let wantedFrames = AVAudioFramePosition(sampleRate * 30)
        let startFrame: AVAudioFramePosition = totalFrames > wantedFrames * 2 ? totalFrames / 5 : 0
        let framesToRead = min(wantedFrames, totalFrames - startFrame)
        file.framePosition = startFrame

        let isLossless = facts?.isLossless ?? false
        let claimedBits = facts?.bitDepth
        var testBits: Int?
        if isLossless, facts?.isFloat != true, let claimed = claimedBits, claimed >= 8 {
            testBits = min(claimed, 24)
        }
        let scale: Float = testBits.map { Float(1 << ($0 - 1)) } ?? 1

        let fftSize = 8192
        let hop = 4096
        let fft = InspectorFFT(size: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        for index in 0..<fftSize {
            window[index] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(index) / Double(fftSize)))
        }

        var powerSum = [Double](repeating: 0, count: fftSize / 2 + 1)
        var windowCount = 0
        var pending: [Float] = []
        pending.reserveCapacity(fftSize * 3)
        var real = [Float](repeating: 0, count: fftSize)
        var imag = [Float](repeating: 0, count: fftSize)

        var orMask: UInt32 = 0
        var nonZeroSamples = 0
        var peak: Float = 0
        var clipped = 0
        var framesAnalyzed: Int64 = 0

        let capacity: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TrackAnalyzerError.unreadable
        }

        var remaining = Int64(framesToRead)
        while remaining > 0 {
            try Task.checkCancellation()
            let want = AVAudioFrameCount(min(Int64(capacity), remaining))
            do {
                try file.read(into: buffer, frameCount: want)
            } catch {
                if windowCount > 0 { break }
                throw TrackAnalyzerError.unreadable
            }
            let got = Int(buffer.frameLength)
            if got == 0 { break }
            guard let data = buffer.floatChannelData else { throw TrackAnalyzerError.unreadable }

            for i in 0..<got {
                var mono: Float = 0
                for c in 0..<channelCount {
                    let x = data[c][i]
                    guard x.isFinite else { continue }
                    let a = abs(x)
                    if a > peak { peak = a }
                    if a >= 0.99995 { clipped += 1 }
                    if testBits != nil {
                        let v = Int32((x * scale).rounded())
                        if v != 0 {
                            orMask |= UInt32(abs(v))
                            nonZeroSamples += 1
                        }
                    }
                    mono += x
                }
                pending.append(mono / Float(channelCount))
            }
            framesAnalyzed += Int64(got)
            remaining -= Int64(got)

            var position = 0
            while pending.count - position >= fftSize {
                for i in 0..<fftSize {
                    real[i] = pending[position + i] * window[i]
                    imag[i] = 0
                }
                fft.transform(real: &real, imag: &imag)
                for k in 0...(fftSize / 2) {
                    powerSum[k] += Double(real[k] * real[k] + imag[k] * imag[k])
                }
                windowCount += 1
                position += hop
            }
            if position > 0 { pending.removeFirst(position) }
        }

        guard windowCount > 0 else { throw TrackAnalyzerError.tooShort }

        // Average power relative to a full-scale sine (0 dB).
        let reference = pow(Double(fftSize) / 4.0, 2)
        var averagePower = [Double](repeating: 0, count: fftSize / 2 + 1)
        for k in 0..<averagePower.count {
            averagePower[k] = powerSum[k] / Double(windowCount) / reference
        }
        func decibels(_ power: Double) -> Double { 10 * log10(max(power, 1e-20)) }

        let nyquist = sampleRate / 2
        let binHz = sampleRate / Double(fftSize)

        // Coarse linear bands for cutoff detection.
        let bandCount = 160
        let bandHz = nyquist / Double(bandCount)
        var bandDb = [Double](repeating: -200, count: bandCount)
        for band in 0..<bandCount {
            let k0 = min(Int(Double(band) * bandHz / binHz), fftSize / 2)
            let k1 = min(max(k0 + 1, Int(Double(band + 1) * bandHz / binHz)), fftSize / 2 + 1)
            var sum = 0.0
            for k in k0..<k1 { sum += averagePower[k] }
            bandDb[band] = decibels(sum / Double(max(k1 - k0, 1)))
        }

        let upper = (0..<bandCount).filter { (Double($0) + 0.5) * bandHz > 1000 }.map { bandDb[$0] }.sorted()
        let floorDb = upper.isEmpty ? (bandDb.min() ?? -150) : upper[Int(Double(upper.count - 1) * 0.05)]
        let threshold = floorDb + 20

        var cutoffBand = 0
        var index = bandCount - 1
        while index >= 1 {
            if bandDb[index] > threshold && bandDb[index - 1] > threshold {
                cutoffBand = index
                break
            }
            index -= 1
        }
        let fullBandwidth = cutoffBand >= bandCount - 2
        let cutoffHz = fullBandwidth ? nyquist : Double(cutoffBand + 1) * bandHz

        var drop = 0.0
        if cutoffBand + 5 < bandCount {
            let above = bandDb[(cutoffBand + 2)...(cutoffBand + 5)]
            drop = bandDb[cutoffBand] - above.reduce(0, +) / Double(above.count)
        }

        // Spectrum for the chart: 200 log-spaced points from 20 Hz to Nyquist.
        let pointCount = 200
        let minFreq = 20.0
        var freqs: [Float] = []
        var levels: [Float] = []
        let ratio = pow(max(nyquist, minFreq * 2) / minFreq, 1.0 / Double(pointCount))
        for point in 0..<pointCount {
            let low = minFreq * pow(ratio, Double(point))
            let high = low * ratio
            let k0 = min(Int(low / binHz), fftSize / 2)
            let k1 = min(max(k0 + 1, Int((high / binHz).rounded(.up))), fftSize / 2 + 1)
            var sum = 0.0
            for k in k0..<k1 { sum += averagePower[k] }
            freqs.append(Float(sqrt(low * high)))
            levels.append(Float(decibels(sum / Double(max(k1 - k0, 1)))))
        }
        let maxLevel = Double(levels.max() ?? -20)
        let yMax = min(10.0, (maxLevel / 10).rounded(.up) * 10)
        let yMin = yMax - 120

        let peakDb = peak > 0 ? 20 * log10(Double(peak)) : -200
        var effectiveBits: Int?
        if let bits = testBits, nonZeroSamples > 5000 {
            let trailingZeros = orMask == 0 ? 0 : orMask.trailingZeroBitCount
            effectiveBits = max(1, bits - trailingZeros)
        }

        // Verdict
        var verdict: AnalysisVerdict = .clean
        let silent = peakDb < -70 || (testBits != nil && nonZeroSamples <= 1000)
        if silent {
            verdict = .silent
        } else if !isLossless && facts != nil {
            verdict = .lossyFormat
        } else if let claimed = claimedBits, let effective = effectiveBits, claimed >= 20, effective <= 16 {
            verdict = .paddedBitDepth
        } else if isLossless, nyquist >= 40_000, cutoffHz <= 23_000 {
            verdict = .likelyUpsampled(from: cutoffHz <= 22_300 ? 44_100 : 48_000)
        } else if isLossless, sampleRate >= 32_000, cutoffHz >= 14_000, cutoffHz <= 19_500, drop >= 25 {
            verdict = .possibleLossySource
        }

        return TrackAnalysisResult(
            claimedBits: claimedBits,
            effectiveBits: effectiveBits,
            sampleRate: sampleRate,
            cutoffHz: cutoffHz,
            nyquistHz: nyquist,
            peakDb: peakDb,
            clippedSamples: clipped,
            analyzedSeconds: Double(framesAnalyzed) / sampleRate,
            verdict: verdict,
            spectrumFreqs: freqs,
            spectrumDb: levels,
            yMin: yMin,
            yMax: yMax,
            date: Date()
        )
    }
}
