import SwiftUI
import DP32Core

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.rows.isEmpty {
                emptyState
            } else {
                List(selection: $model.selection) {
                    ForEach(model.rows) { row in
                        SongRowView(row: row, reveal: { model.reveal($0) })
                            .tag(row.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.cards.isEmpty ? "sdcard" : "sdcard.fill")
                .font(.title2)
                .foregroundColor(model.cards.isEmpty ? .secondary : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.cards.isEmpty ? "No DP-32SD card found" : "Card: " + model.cards.map { $0.path }.joined(separator: ", "))
                    .font(.headline)
                Text(model.cards.isEmpty
                     ? "Connect the DP-32SD by USB, put its SD card in a reader, or open a song folder."
                     : "\(model.rows.count) songs. The card is only ever read.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Open Folder…") { model.openFolder() }
            Button("Rescan") { model.rescan() }
                .disabled(model.exporting)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No songs to show")
                .font(.title3)
            Text("Songs appear here when a DP-32SD card is mounted. You can also open a song folder that was copied to this Mac.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.message.isEmpty {
                Text(model.message)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("Export to:")
                Text(model.destination.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                    .help(model.destination.path)
                Button("Change…") { model.chooseDestination() }
                    .disabled(model.exporting)
                Spacer()
                Toggle("Pad every stem to the song length", isOn: $model.padToSongLength)
                    .disabled(model.exporting)
            }
            HStack(spacing: 8) {
                Text(summary)
                    .foregroundColor(.secondary)
                Spacer()
                if model.exporting {
                    Button("Cancel") { model.cancel() }
                }
                Button("Export Selected") { model.export(model.selectedReadyRows) }
                    .disabled(model.exporting || model.selectedReadyRows.isEmpty)
                Button("Export All") { model.export(model.readyRows) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.exporting || model.readyRows.isEmpty)
            }
        }
        .padding(12)
    }

    private var summary: String {
        let ready = model.readyRows.count
        let refused = model.rows.filter { if case .refused = $0.check { return true } else { return false } }.count
        var text = "\(ready) ready"
        if refused > 0 { text += ", \(refused) cannot be exported" }
        if !model.selection.isEmpty { text += ", \(model.selection.count) selected" }
        return text
    }
}

struct SongRowView: View {
    let row: SongRow
    let reveal: (URL) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.body.weight(.medium))
                detail
            }
            Spacer(minLength: 12)
            status
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var detail: some View {
        switch row.check {
        case .checking:
            Text("Reading…")
                .font(.caption)
                .foregroundColor(.secondary)
        case .ready(let plan):
            Text("\(plan.formatText)   \(formatDuration(plan.seconds))   Tracks \(plan.trackText)")
                .font(.caption)
                .foregroundColor(.secondary)
            if !plan.notes.isEmpty {
                Text(plan.notes.count == 1 ? "1 note — it goes in the export report" : "\(plan.notes.count) notes — they go in the export report")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .help(plan.notes.joined(separator: "\n\n"))
            }
        case .refused(let reason):
            Text("Cannot export: \(reason).")
                .font(.caption)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        switch row.export {
        case .idle:
            switch row.check {
            case .checking: ProgressView().controlSize(.small)
            case .ready: Text("Ready").foregroundColor(.green)
            case .refused: Text("Not exportable").foregroundColor(.red)
            }
        case .waiting:
            Text("Waiting…").foregroundColor(.secondary)
        case .running(let fraction):
            ProgressView(value: fraction)
                .frame(width: 140)
        case .done(let folder, let notes):
            HStack(spacing: 8) {
                Text(notes == 0 ? "Exported" : "Exported, see report")
                    .foregroundColor(.green)
                Button("Reveal in Finder") { reveal(folder) }
                    .buttonStyle(.link)
            }
        case .failed(let reason):
            Text("Failed: \(reason)")
                .foregroundColor(.red)
                .frame(maxWidth: 320, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
