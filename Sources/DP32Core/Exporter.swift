import Foundation

public struct ExportOptions: Equatable {
    /// Make every stem as long as the longest one.
    public var padToSongLength: Bool
    public init(padToSongLength: Bool = false) { self.padToSongLength = padToSongLength }
}

public struct ExportResult {
    public let folder: URL
    public let stemFiles: [String]
    public let masterFiles: [String]
    public let notes: [String]
}

public enum Exporter {
    public static let reportName = "Export Report.txt"

    public static var defaultDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("Depot Lift Exports", isDirectory: true)
    }

    /// The real path of `url`: symlinks resolved for the part that exists, the rest appended.
    static func canonical(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        var missing = [String]()
        while true {
            if let real = realpath(current.path, nil) {
                var resolved = URL(fileURLWithPath: String(cString: real), isDirectory: true)
                free(real)
                for name in missing.reversed() { resolved.appendPathComponent(name) }
                return resolved
            }
            if current.pathComponents.count <= 1 { return url.standardizedFileURL }
            missing.append(current.lastPathComponent)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    private static func components(_ url: URL) -> [String] {
        canonical(url).pathComponents
    }

    private static func isSameOrInside(_ inner: [String], _ outer: [String]) -> Bool {
        inner.count >= outer.count && Array(inner[0..<outer.count]) == outer
    }

    /// Throws when exports must not be written under `destination`.
    public static func checkDestination(_ destination: URL, song: URL) throws {
        if let card = Card.cardRoot(containing: canonical(destination)) ?? Card.cardRoot(containing: destination) {
            throw Refusal("the export folder is on the card (\(card.path)). The card is only ever read; choose a folder on the Mac")
        }
        let d = components(destination)
        let s = components(song)
        if isSameOrInside(d, s) { throw Refusal("the export folder is inside the song folder. Choose a folder somewhere else") }
        if isSameOrInside(s, d) { throw Refusal("the export folder contains the song folder. Choose a folder somewhere else") }
    }

    /// Makes "<name>", or "<name> 2", "<name> 3" … Never returns a folder that already existed.
    static func makeNewFolder(named name: String, in parent: URL) throws -> URL {
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw Refusal("the export folder \(parent.path) could not be created") }
        for attempt in 1...9999 {
            let candidate = parent.appendingPathComponent(attempt == 1 ? name : "\(name) \(attempt)", isDirectory: true)
            if mkdir(candidate.path, 0o755) == 0 { return candidate }
            if errno != EEXIST { break }
        }
        throw Refusal("a new folder for \(name) could not be created in \(parent.path)")
    }

    private static func copy(from source: String, to target: String, isCancelled: () -> Bool) throws {
        let input = try ReadOnlyFile(path: source)
        let output = try NewFile(path: target)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var offset: UInt64 = 0
        while offset < input.size {
            if isCancelled() { throw Cancelled() }
            let count = Int(min(UInt64(buffer.count), input.size - offset))
            try buffer.withUnsafeMutableBytes { bytes in
                let slice = UnsafeMutableRawBufferPointer(rebasing: bytes[0..<count])
                try input.read(at: offset, into: slice)
                try output.append(UnsafeRawBufferPointer(slice))
            }
            offset += UInt64(count)
        }
        try output.finish()
    }

    /// Exports one song into a new folder under `destination`. `progress` gets 0...1.
    /// On failure or cancellation the new folder is removed again.
    public static func export(_ song: SongPlan, to destination: URL, options: ExportOptions = ExportOptions(),
                              progress: (Double) -> Void = { _ in },
                              isCancelled: () -> Bool = { false }) throws -> ExportResult {
        try checkDestination(destination, song: song.folder)
        let songFrames = song.frames
        let lengths = song.stems.map { options.padToSongLength ? songFrames : $0.frames }
        let totalFrames = max(lengths.reduce(0, +), 1)

        let folder = try makeNewFolder(named: song.name, in: destination)
        do {
            var done: UInt64 = 0
            var stemFiles = [String]()
            for (stem, length) in zip(song.stems, lengths) {
                let fileName = song.name + stem.suffix + ".WAV"
                try Renderer.render(stem: stem, song: song, to: folder.appendingPathComponent(fileName).path,
                                    totalFrames: length,
                                    progress: { frames in
                                        done += frames
                                        progress(Double(done) / Double(totalFrames))
                                    },
                                    isCancelled: isCancelled)
                stemFiles.append(fileName)
            }
            var masterFiles = [String]()
            for master in song.masters {
                try copy(from: master.path, to: folder.appendingPathComponent(master.exportName).path, isCancelled: isCancelled)
                masterFiles.append(master.exportName)
            }
            let report = Report.text(song: song, options: options, lengths: lengths, folder: folder)
            let reportFile = try NewFile(path: folder.appendingPathComponent(reportName).path)
            try reportFile.append(Array(report.utf8))
            try reportFile.finish()
            progress(1)
            return ExportResult(folder: folder, stemFiles: stemFiles, masterFiles: masterFiles, notes: song.notes)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
