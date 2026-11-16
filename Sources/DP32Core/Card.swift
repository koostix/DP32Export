import Foundation

public enum Card {
    /// A DP-32SD card root holds dp-24.sys and a MUSIC folder.
    public static func isCardRoot(_ url: URL) -> Bool {
        entryKind(url.appendingPathComponent("dp-24.sys").path) == .file
            && entryKind(url.appendingPathComponent("MUSIC").path) == .directory
    }

    /// The card root that `url` is on or inside, if any. Works for paths that do not exist yet.
    public static func cardRoot(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while true {
            if isCardRoot(current) { return current }
            if current.pathComponents.count <= 1 { return nil }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// Mounted volumes that are DP-32SD cards.
    public static func mountedCards() -> [URL] {
        visibleNames(in: "/Volumes")
            .map { URL(fileURLWithPath: "/Volumes/" + $0, isDirectory: true) }
            .filter { isCardRoot($0) }
    }

    /// Song folders reachable from `url`: a card root, a MUSIC folder, one song
    /// folder, or a folder that holds song folders (one or two levels down).
    public static func songFolders(in url: URL) -> [URL] {
        if Song.isSongFolder(url) { return [url] }
        let base = isCardRoot(url) ? url.appendingPathComponent("MUSIC", isDirectory: true) : url
        var songs = [URL]()
        for name in visibleNames(in: base.path) {
            let child = base.appendingPathComponent(name, isDirectory: true)
            guard entryKind(child.path) == .directory else { continue }
            if Song.isSongFolder(child) {
                songs.append(child)
            } else if !isCardRoot(url) {
                for inner in visibleNames(in: child.path) {
                    let grandchild = child.appendingPathComponent(inner, isDirectory: true)
                    if entryKind(grandchild.path) == .directory, Song.isSongFolder(grandchild) { songs.append(grandchild) }
                }
            }
        }
        return songs
    }
}
