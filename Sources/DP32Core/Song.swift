import Foundation

public struct ClipFile: Equatable {
    public let name: String
    public let path: String
    public let info: WavInfo
}

/// A stretch of a stem's timeline. `clip == nil` is silence.
public struct StemRegion: Equatable {
    public let start: UInt64
    public let length: UInt64
    public let clip: Int?
    public let sourceStart: UInt64
    public var end: UInt64 { start + length }
}

/// One mono file to be written.
public struct StemPlan: Equatable, Identifiable {
    public let track: Int          // 1...32
    public let virtual: Int        // 0...7
    /// "_TRK01", or "_TRK01_V2" when the track has audio on more than one virtual track.
    public let suffix: String
    public let regions: [StemRegion]
    /// Samples from time zero to the end of the last clip's fade-out.
    public let frames: UInt64
    public var id: Int { (track - 1) * 8 + virtual }
    public var clipCount: Int { regions.filter { $0.clip != nil }.count }
}

public struct MasterFile: Equatable {
    public let sourceName: String
    public let path: String
    public let exportName: String
    public let isPrevious: Bool
}

/// Everything needed to export one song, checked in advance.
public struct SongPlan: Equatable {
    public let folder: URL
    public let name: String
    public let sampleRate: Int
    public let bitsPerSample: Int
    public let fadeLength: Int
    public let clips: [ClipFile]
    public let stems: [StemPlan]
    public let masters: [MasterFile]
    /// Things the owner should know. None of them stops the export.
    public let notes: [String]

    public var frames: UInt64 { stems.map { $0.frames }.max() ?? 0 }
    public var seconds: Double { Double(frames) / Double(sampleRate) }
    public var formatText: String {
        let khz = sampleRate % 1000 == 0 ? "\(sampleRate / 1000)" : String(format: "%.1f", Double(sampleRate) / 1000)
        return "\(bitsPerSample)-bit / \(khz) kHz"
    }
    public var trackText: String { SongPlan.describeTracks(stems) }

    static func describeTracks(_ stems: [StemPlan]) -> String {
        let tracks = Array(Set(stems.map { $0.track })).sorted()
        var parts = [String]()
        var i = 0
        while i < tracks.count {
            var j = i
            while j + 1 < tracks.count && tracks[j + 1] == tracks[j] + 1 { j += 1 }
            parts.append(j > i + 1 ? "\(tracks[i])–\(tracks[j])" : (j == i ? "\(tracks[i])" : "\(tracks[i]), \(tracks[j])"))
            i = j + 1
        }
        var text = parts.joined(separator: ", ")
        let virtualTracks = Set(stems.filter { $0.suffix.contains("_V") }.map { $0.track }).count
        if virtualTracks > 0 { text += "  (+ virtual tracks on \(virtualTracks))" }
        return text
    }
}

public enum SongStatus {
    case ready(SongPlan)
    case refused(String)
}

public func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

public enum Song {
    public static func isSongFolder(_ url: URL) -> Bool {
        entryKind(url.appendingPathComponent("edltable.sys").path) == .file
    }

    /// Reads a song folder and says whether it can be exported with certainty.
    public static func inspect(_ folder: URL) -> SongStatus {
        do { return .ready(try plan(folder)) }
        catch let refusal as Refusal { return .refused(refusal.reason) }
        catch { return .refused("the song could not be read (\(error.localizedDescription))") }
    }

    public static func plan(_ folder: URL) throws -> SongPlan {
        let dir = folder.path
        let name = folder.lastPathComponent
        guard entryKind(dir) == .directory else { throw Refusal("this is not a folder") }
        let edlPath = folder.appendingPathComponent("edltable.sys").path
        guard entryKind(edlPath) == .file else {
            throw Refusal("there is no edltable.sys in this folder, so it is not a DP-32SD song")
        }
        let edlFile = try ReadOnlyFile(path: edlPath)
        guard edlFile.size == UInt64(EditList.fileSize) else {
            throw Refusal("edltable.sys is \(edlFile.size) bytes; a DP-32SD edit list is always \(EditList.fileSize)")
        }
        let edl = try EditList.parse(try edlFile.bytes(at: 0, count: EditList.fileSize))
        let fade = UInt64(edl.fadeLength)

        // Regular files only. A symlink in a song folder is never followed.
        var onDisk = [String: String]()
        var wavNames = [String]()
        for entry in visibleNames(in: dir) where entryKind(dir + "/" + entry) == .file {
            if onDisk[entry.lowercased()] == nil { onDisk[entry.lowercased()] = entry }
            if entry.lowercased().hasSuffix(".wav") { wavNames.append(entry) }
        }

        var clips = [ClipFile]()
        var clipIndex = [UInt32: Int]()
        var notes = [String]()
        func note(_ text: String) { if !notes.contains(text) { notes.append(text) } }

        struct Draft { let track: Int; let virtual: Int; let regions: [StemRegion]; let frames: UInt64 }
        var drafts = [Draft]()

        for track in edl.tracks where track.hasAudio {
            let label = "Track \(track.track)" + (track.virtual == 0 ? "" : " virtual track \(track.virtual + 1)")
            var regions = [StemRegion]()
            var lastEnd: UInt64 = 0
            for (j, r) in track.regions.enumerated() {
                let previous = j > 0 ? track.regions[j - 1] : nil
                let next = j + 1 < track.regions.count ? track.regions[j + 1] : nil
                guard let fileID = r.fileID else {
                    if let p = previous, p.fileID != nil, let n = next, n.fileID != nil {
                        guard r.length >= fade else {
                            throw Refusal("\(label) has a gap between two clips that is shorter than the unit's 10 ms edge fade; what the unit does there is not known")
                        }
                        note("\(label) has a gap between two clips. That case was never compared with a hardware export.")
                    }
                    regions.append(StemRegion(start: r.start, length: r.length, clip: nil, sourceStart: 0))
                    continue
                }
                let index: Int
                if let known = clipIndex[fileID] {
                    index = known
                } else {
                    let clipName = edl.files[fileID] ?? ""
                    guard let actual = onDisk[clipName.lowercased()] else {
                        throw Refusal("\(label) needs the clip file \(clipName), which is not in the song folder")
                    }
                    let file = try ReadOnlyFile(path: dir + "/" + actual)
                    let info = try Wav.info(of: file)
                    guard info.isClassicPCM, info.channels == 1, info.sampleRate == edl.sampleRate,
                          info.bitsPerSample == edl.bitsPerSample, info.blockAlign == edl.bitsPerSample / 8 else {
                        throw Refusal("\(actual) is not a mono \(edl.bitsPerSample)-bit \(edl.sampleRate) Hz PCM file like the rest of the song")
                    }
                    index = clips.count
                    clips.append(ClipFile(name: actual, path: dir + "/" + actual, info: info))
                    clipIndex[fileID] = index
                }
                guard r.length >= fade else {
                    throw Refusal("\(label) has a clip shorter than the unit's 10 ms edge fade; what the unit does there is not known")
                }
                guard let following = next else {
                    throw Refusal("\(label) has audio running to the very end of the timeline")
                }
                let (needed, overflow) = r.sourceStart.addingReportingOverflow(r.length + fade)
                guard !overflow, clips[index].info.frames >= needed else {
                    throw Refusal("\(clips[index].name) is shorter than the edit list says it should be")
                }
                if following.fileID != nil && r.fadeOutFlag == 0 {
                    note("\(label) has a punch-in. Its 10 ms crossfade uses the rule measured on a punch-out, the only kind compared with a hardware export.")
                }
                let atFileStart = r.sourceStart == 0
                let atFileEnd = clips[index].info.frames == needed
                if (r.fadeInFlag != 0) != atFileStart || (r.fadeOutFlag != 0) != atFileEnd {
                    note("\(label) has a clip whose stored edge-fade flags are unusual. The export treats it like any other clip.")
                }
                regions.append(StemRegion(start: r.start, length: r.length, clip: index, sourceStart: r.sourceStart))
                lastEnd = r.start + r.length
            }
            if track.undoneEdits > 0 {
                note("\(label) has \(track.undoneEdits) undone edit\(track.undoneEdits == 1 ? "" : "s"). The state the unit shows now is exported, not the undone one.")
            }
            if let source = track.cloneOfKey {
                note("\(label) is a clone of track \(source / 8 + 1) and shares its clips.")
            }
            drafts.append(Draft(track: track.track, virtual: track.virtual, regions: regions, frames: lastEnd + fade))
        }

        guard !drafts.isEmpty else { throw Refusal("nothing has been recorded in this song") }

        var virtualCount = [Int: Int]()
        for d in drafts { virtualCount[d.track, default: 0] += 1 }
        var stems = [StemPlan]()
        for d in drafts {
            var suffix = String(format: "_TRK%02d", d.track)
            if virtualCount[d.track, default: 0] > 1 { suffix += "_V\(d.virtual + 1)" }
            stems.append(StemPlan(track: d.track, virtual: d.virtual, suffix: suffix, regions: d.regions, frames: d.frames))
        }
        if virtualCount.values.contains(where: { $0 > 1 }) {
            note("Some tracks have audio on more than one virtual track. Which one the unit has assigned is not known, so each is exported (_V1, _V2 …).")
        }
        if edl.bitsPerSample == 16 {
            note("This is a 16-bit song. The 10 ms edge fades were only ever checked against a 24-bit hardware export.")
        }

        // Masters: stereo WAVs that are not ZZ clip files. A folder renamed on the Mac no
        // longer matches its master's file name, so the name is not used to find them.
        var found = [(name: String, previous: Bool)]()
        for wav in wavNames where !wav.lowercased().hasPrefix("zz") {
            guard let file = try? ReadOnlyFile(path: dir + "/" + wav), let info = try? Wav.info(of: file),
                  info.channels == 2 else { continue }
            let stem = (wav as NSString).deletingPathExtension.lowercased()
            found.append((wav, stem.hasSuffix("_z")))
        }
        var masters = [MasterFile]()
        for previous in [false, true] {
            let group = found.filter { $0.previous == previous }
            if group.count == 1 {
                masters.append(MasterFile(sourceName: group[0].name, path: dir + "/" + group[0].name,
                                          exportName: name + (previous ? "_z.WAV" : ".WAV"), isPrevious: previous))
            } else if group.count > 1 {
                note("The folder holds more than one \(previous ? "previous master" : "stereo master"). They are copied under their own names.")
                for g in group {
                    masters.append(MasterFile(sourceName: g.name, path: dir + "/" + g.name, exportName: g.name, isPrevious: previous))
                }
            }
        }

        return SongPlan(folder: folder, name: name, sampleRate: edl.sampleRate, bitsPerSample: edl.bitsPerSample,
                        fadeLength: edl.fadeLength, clips: clips, stems: stems, masters: masters, notes: notes)
    }
}
