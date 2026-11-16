import AppKit
import Foundation
import DP32Core

enum CheckState {
    case checking
    case ready(SongPlan)
    case refused(String)
}

enum ExportState {
    case idle
    case waiting
    case running(Double)
    case done(URL, Int)
    case failed(String)
}

struct SongRow: Identifiable {
    let id: String
    let url: URL
    let source: String
    var check: CheckState = .checking
    var export: ExportState = .idle

    var name: String { url.lastPathComponent }
    var plan: SongPlan? {
        if case .ready(let plan) = check { return plan }
        return nil
    }
}

final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// All state lives on the main thread. Reading cards and exporting happen on `work`.
final class AppModel: ObservableObject {
    @Published var rows: [SongRow] = []
    @Published var selection = Set<String>()
    @Published var cards: [URL] = []
    @Published var destination: URL
    @Published var padToSongLength: Bool {
        didSet { UserDefaults.standard.set(padToSongLength, forKey: "padToSongLength") }
    }
    @Published var exporting = false
    @Published var message = ""

    private var openedFolders: [URL] = []
    private let work = DispatchQueue(label: "dp32export.work", qos: .userInitiated)
    private var cancelFlag = CancelFlag()
    private var observers: [NSObjectProtocol] = []

    init() {
        if let saved = UserDefaults.standard.string(forKey: "destination") {
            destination = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            destination = Exporter.defaultDestination
        }
        padToSongLength = UserDefaults.standard.bool(forKey: "padToSongLength")
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.rescan()
            })
        }
        rescan()
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var readyRows: [SongRow] { rows.filter { $0.plan != nil } }
    var selectedReadyRows: [SongRow] { readyRows.filter { selection.contains($0.id) } }

    /// Finds mounted cards and rebuilds the song list, keeping what is already known.
    func rescan() {
        guard !exporting else { return }
        let found = Card.mountedCards()
        cards = found
        var fresh: [SongRow] = []
        var seen = Set<String>()
        func add(_ urls: [URL], source: String) {
            for url in urls {
                let id = url.standardizedFileURL.path
                if seen.contains(id) { continue }
                seen.insert(id)
                if let old = rows.first(where: { $0.id == id }) {
                    var kept = old
                    if case .refused = kept.check { kept.check = .checking }
                    fresh.append(kept)
                } else {
                    fresh.append(SongRow(id: id, url: url, source: source))
                }
            }
        }
        for card in found { add(Card.songFolders(in: card), source: card.lastPathComponent) }
        for folder in openedFolders { add(Card.songFolders(in: folder), source: folder.lastPathComponent) }
        rows = fresh
        selection = selection.intersection(seen)
        checkPending()
    }

    private func checkPending() {
        for row in rows {
            guard case .checking = row.check else { continue }
            let id = row.id
            let url = row.url
            work.async { [weak self] in
                let status = Song.inspect(url)
                DispatchQueue.main.async {
                    guard let self = self, let index = self.rows.firstIndex(where: { $0.id == id }) else { return }
                    switch status {
                    case .ready(let plan): self.rows[index].check = .ready(plan)
                    case .refused(let reason): self.rows[index].check = .refused(reason)
                    }
                }
            }
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a song folder, a folder of song folders, or a DP-32SD card"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if Card.songFolders(in: url).isEmpty {
            message = "No DP-32SD songs were found in \(url.lastPathComponent). A song folder holds an edltable.sys file."
            return
        }
        message = ""
        if !openedFolders.contains(url) { openedFolders.append(url) }
        rescan()
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Each song is exported into its own new folder inside the folder you choose"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let card = Card.cardRoot(containing: url) {
            message = "That folder is on the card (\(card.lastPathComponent)). The card is only ever read; choose a folder on the Mac."
            return
        }
        message = ""
        destination = url
        UserDefaults.standard.set(url.path, forKey: "destination")
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func cancel() {
        cancelFlag.cancel()
    }

    func export(_ chosen: [SongRow]) {
        guard !exporting, !chosen.isEmpty else { return }
        exporting = true
        message = ""
        let flag = CancelFlag()
        cancelFlag = flag
        let target = destination
        let options = ExportOptions(padToSongLength: padToSongLength)
        var jobs: [(String, SongPlan)] = []
        for row in chosen {
            guard let plan = row.plan, let index = rows.firstIndex(where: { $0.id == row.id }) else { continue }
            rows[index].export = .waiting
            jobs.append((row.id, plan))
        }
        work.async { [weak self] in
            for (id, plan) in jobs {
                func set(_ state: ExportState) {
                    DispatchQueue.main.async {
                        guard let self = self, let index = self.rows.firstIndex(where: { $0.id == id }) else { return }
                        self.rows[index].export = state
                    }
                }
                if flag.isCancelled { set(.idle); continue }
                set(.running(0))
                do {
                    var shown = 0
                    let result = try Exporter.export(plan, to: target, options: options, progress: { fraction in
                        let percent = Int(fraction * 100)
                        if percent != shown {
                            shown = percent
                            set(.running(fraction))
                        }
                    }, isCancelled: { flag.isCancelled })
                    set(.done(result.folder, result.notes.count))
                } catch is Cancelled {
                    set(.idle)
                } catch {
                    set(.failed(error.localizedDescription))
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.exporting = false
                if flag.isCancelled { self.message = "Export cancelled. Songs that had not finished were removed again." }
            }
        }
    }
}
