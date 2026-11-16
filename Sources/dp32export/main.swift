import Foundation
import DP32Core

let usage = """
dp32export — read-only stem export for Tascam DP-32SD songs

  dp32export list [<path>]
      Show the songs on <path> (a card, a MUSIC folder, a song folder, or a folder
      of song folders) and whether each can be exported. Without <path>, every
      mounted DP-32SD card is listed.

  dp32export export [<path>] [--song <name>]... [--out <folder>] [--pad]
      Export songs as time-aligned mono WAVs. Each song gets a new folder under
      <folder> (default: ~/Desktop/Depot Lift Exports). --pad makes every stem
      as long as the song.

  dp32export compare <folder A> <folder B> [--ignore-head <file>=<samples>]... [--max-differences <n>]
      Compare the _TRK WAVs in A with the files of the same name in B.

Exit codes: 0 done, 1 comparison failed, 2 a song was refused or an export failed, 3 bad arguments.
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func sources(_ path: String?) -> [URL] {
    if let path = path {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let songs = Card.songFolders(in: url)
        if songs.isEmpty { fail("No DP-32SD songs found at \(url.path)", code: 3) }
        return songs
    }
    let cards = Card.mountedCards()
    if cards.isEmpty { fail("No DP-32SD card is mounted. Give a path to a card or a song folder.", code: 3) }
    return cards.flatMap { Card.songFolders(in: $0) }
}

func runList(_ args: [String]) -> Int32 {
    guard args.count <= 1 else { fail(usage, code: 3) }
    var refused = 0
    for url in sources(args.first) {
        switch Song.inspect(url) {
        case .ready(let plan):
            print("\(plan.name)  \(plan.formatText)  \(formatDuration(plan.seconds))  tracks \(plan.trackText)  Ready")
            for note in plan.notes { print("    note: \(note)") }
        case .refused(let reason):
            refused += 1
            print("\(url.lastPathComponent)  Cannot export: \(reason)")
        }
    }
    return refused == 0 ? 0 : 2
}

func runExport(_ args: [String]) -> Int32 {
    var path: String? = nil
    var names = [String]()
    var out = Exporter.defaultDestination
    var options = ExportOptions()
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--pad" {
            options.padToSongLength = true
        } else if a == "--song", i + 1 < args.count {
            i += 1; names.append(args[i])
        } else if a == "--out", i + 1 < args.count {
            i += 1; out = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath, isDirectory: true)
        } else if !a.hasPrefix("--"), path == nil {
            path = a
        } else {
            fail(usage, code: 3)
        }
        i += 1
    }
    var songs = sources(path)
    if !names.isEmpty {
        songs = songs.filter { names.contains($0.lastPathComponent) }
        if songs.count != names.count { fail("Not every --song name was found.", code: 3) }
    }
    var failures = 0
    for url in songs {
        switch Song.inspect(url) {
        case .refused(let reason):
            failures += 1
            print("\(url.lastPathComponent): not exported — \(reason)")
        case .ready(let plan):
            do {
                var shown = -1
                let result = try Exporter.export(plan, to: out, options: options, progress: { fraction in
                    let percent = Int(fraction * 100)
                    if percent / 10 != shown / 10 || shown < 0 {
                        shown = percent
                        FileHandle.standardError.write("\r\(plan.name): \(percent)%".data(using: .utf8)!)
                    }
                })
                FileHandle.standardError.write("\r".data(using: .utf8)!)
                print("\(plan.name): \(result.stemFiles.count) stems, \(result.masterFiles.count) masters -> \(result.folder.path)")
                for note in result.notes { print("    note: \(note)") }
            } catch {
                failures += 1
                print("\(plan.name): export failed — \(error.localizedDescription)")
            }
        }
    }
    return failures == 0 ? 0 : 2
}

func runCompare(_ args: [String]) -> Int32 {
    var folders = [String]()
    var ignore = [String: UInt64]()
    var maxDifferences: UInt64? = nil
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--ignore-head", i + 1 < args.count {
            i += 1
            let parts = args[i].split(separator: "=")
            guard parts.count == 2, let frames = UInt64(parts[1]) else { fail(usage, code: 3) }
            ignore[parts[0].lowercased()] = frames
        } else if a == "--max-differences", i + 1 < args.count, let n = UInt64(args[i + 1]) {
            i += 1; maxDifferences = n
        } else if !a.hasPrefix("--") {
            folders.append((a as NSString).expandingTildeInPath)
        } else {
            fail(usage, code: 3)
        }
        i += 1
    }
    guard folders.count == 2 else { fail(usage, code: 3) }
    var other = [String: String]()
    for name in visibleNames(in: folders[1]) { other[name.lowercased()] = name }
    var total: UInt64 = 0
    var samples: UInt64 = 0
    var ok = true
    var compared = 0
    for name in visibleNames(in: folders[0]) where name.lowercased().hasSuffix(".wav") && name.uppercased().contains("_TRK") {
        guard let match = other[name.lowercased()] else {
            print("\(name): no file of that name in \(folders[1])")
            continue
        }
        do {
            let r = try Compare.wavs(folders[0] + "/" + name, folders[1] + "/" + match, ignoreHead: ignore[name.lowercased()] ?? 0)
            compared += 1
            var line = "\(name): header \(r.headersIdentical ? "identical" : "DIFFERS"), "
            if r.sameLength {
                line += "\(r.framesA) samples, \(r.differing) differ"
                if r.differing > 0 { line += " (largest \(r.largest) LSB, first at \(r.firstDifferences.map { String($0) }.joined(separator: " ")))" }
                if r.headersIdentical && r.differing == 0 && r.ignoredDiffering == 0 { line += ", byte-identical" }
                if r.ignoredDiffering > 0 { line += ", plus \(r.ignoredDiffering) ignored at the start" }
            } else {
                line += "LENGTH DIFFERS (\(r.framesA) vs \(r.framesB) samples)"
                ok = false
            }
            if !r.headersIdentical || r.largest > 1 { ok = false }
            total += r.differing
            samples += min(r.framesA, r.framesB)
            print(line)
        } catch {
            ok = false
            print("\(name): \(error.localizedDescription)")
        }
    }
    print("total: \(total) of \(samples) samples differ in \(compared) files")
    if compared == 0 { ok = false }
    if let limit = maxDifferences, total > limit { ok = false }
    return ok ? 0 : 1
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}
let rest = Array(arguments.dropFirst())
switch command {
case "list": exit(runList(rest))
case "export": exit(runExport(rest))
case "compare": exit(runCompare(rest))
case "help", "--help", "-h": print(usage); exit(0)
default: fail(usage, code: 3)
}
