import Foundation

public enum Report {
    public static func text(song: SongPlan, options: ExportOptions, lengths: [UInt64], folder: URL) -> String {
        func time(_ frames: UInt64) -> String {
            String(format: "%.3f s", Double(frames) / Double(song.sampleRate))
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = [String]()
        lines.append("DP-32 Export report")
        lines.append("")
        lines.append("Song:      \(song.name)")
        lines.append("Read from: \(song.folder.path)")
        lines.append("Written:   \(stamp)")
        lines.append("Format:    \(song.formatText), mono stems")
        lines.append("Length:    \(song.frames) samples (\(time(song.frames)))")
        lines.append("Padding:   " + (options.padToSongLength
            ? "every stem padded with silence to the song length"
            : "off; each stem ends 10 ms after its last clip, as the unit's own export does"))
        lines.append("")
        lines.append("Every stem starts at time zero of the song.")
        lines.append("")
        lines.append("Stems")
        for (stem, length) in zip(song.stems, lengths) {
            let virtual = stem.suffix.contains("_V") ? ", virtual track \(stem.virtual + 1)" : ""
            lines.append("  \(song.name)\(stem.suffix).WAV   track \(stem.track)\(virtual)   \(length) samples (\(time(length)))   \(stem.clipCount) clip\(stem.clipCount == 1 ? "" : "s")")
        }
        lines.append("")
        lines.append("Masters")
        if song.masters.isEmpty {
            lines.append("  none in the song folder")
        }
        for master in song.masters {
            let renamed = master.sourceName == master.exportName ? "" : "   (copied from \(master.sourceName))"
            lines.append("  \(master.exportName)   \(master.isPrevious ? "previous stereo master" : "stereo master")\(renamed)")
        }
        lines.append("")
        lines.append("Warnings")
        if song.notes.isEmpty {
            lines.append("  none")
        }
        for note in song.notes {
            lines.append("  - \(note)")
        }
        lines.append("")
        lines.append("How close this is to the unit's own export")
        lines.append("  Audio outside clip edges is copied bit for bit. The first 10 ms of each clip and")
        lines.append("  the 10 ms after it are faded the way the unit does it. Against the one hardware")
        lines.append("  export available (24-bit / 48 kHz, 48 million samples) 7 samples differed, each by")
        lines.append("  1 LSB, all inside those fades. See docs/FORMAT.md in the DP32Export project.")
        lines.append("")
        lines.append("Provided as is, without warranty. Use at your own risk; keep a backup of your card")
        lines.append("and listen to these files before deleting anything from it.")
        lines.append("https://github.com/koostix/DP32Export")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
