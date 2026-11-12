// InspectorPanel.swift
//
// An optional panel on the right side of the Mac window with two tabs. "Now Playing" shows
// the current song's artwork, quality badge and a plain-language signal path (source file,
// decoder, sample-rate conversion, volume and the output device). "Details" lists the file's
// tags and technical facts.

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

    var id: String { rawValue }
}

// MARK: - Panel

struct InspectorPanel: View {
    @ObservedObject var controller: PlaybackController

    @AppStorage("inspectorTab") private var tabRaw: String = InspectorTab.nowPlaying.rawValue
    @StateObject private var facts = InspectorFactsModel()

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
            }
        } else {
            InspectorMessage(
                symbol: "waveform",
                title: "Nothing playing",
                detail: "Play a song to see its signal path and details."
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
