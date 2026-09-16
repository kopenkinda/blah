import SwiftUI

struct TranscriptHistoryView: View {
    @Bindable var controller: DictationController
    @State private var selection: UUID?
    @State private var search = ""

    private var entries: [TranscriptHistory.Entry] {
        controller.history.reversed().filter {
            search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
                || $0.rawText.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search transcripts", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search transcripts")
                Button { controller.reloadHistory() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh history").accessibilityLabel("Refresh history")
                Menu {
                    Button("Open history file") { controller.openHistory() }
                    Button("Show in Finder") { controller.openHistory(reveal: true) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("History file")
            }.padding(16)
            Divider()
            if let unsaved = controller.unsavedHistoryEntry {
                HStack {
                    Text("The latest transcript could not be saved.").font(.callout)
                    Spacer()
                    Button("Copy transcript") { TextInsertion.copy(unsaved.text) }
                }.padding().background(.orange.opacity(0.1))
            }
            if let error = controller.historyError {
                ContentUnavailableView {
                    Label("Could not read history", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Open history file") { controller.openHistory() }
                    Button("Retry") { controller.reloadHistory() }
                }
            } else if entries.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No transcripts yet" : "No matching transcripts",
                                       systemImage: "text.bubble",
                                       description: Text(search.isEmpty ? "Your completed dictations will appear here." : "Try a different search."))
            } else {
                HSplitView {
                    List(entries, selection: $selection) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.text).lineLimit(3).font(.callout)
                        }.padding(.vertical, 5).tag(entry.id)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 190, idealWidth: 235, maxWidth: 320)
                    if let entry = entries.first(where: { $0.id == selection }) {
                        detail(entry).frame(minWidth: 270, maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Select a transcript", systemImage: "text.alignleft")
                            .frame(minWidth: 270, maxWidth: .infinity)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(controller.history.count) of \(TranscriptHistory.limit.formatted()) transcripts")
                Spacer()
                if controller.history.count >= TranscriptHistory.limit {
                    Text("Limit reached. New transcripts replace the oldest.")
                }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: search) { selectFirstIfNeeded() }
        .onChange(of: controller.history.map(\.id)) { selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        if !entries.contains(where: { $0.id == selection }) { selection = entries.first?.id }
    }

    private func detail(_ entry: TranscriptHistory.Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Transcript").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Copy") { TextInsertion.copy(entry.text) }
                }
                Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if entry.rawText != entry.text {
                    DisclosureGroup("Original transcription") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(entry.rawText).textSelection(.enabled)
                            Button("Copy original") { TextInsertion.copy(entry.rawText) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Details").font(.headline)
                    metadata("Created", entry.createdAt.formatted(date: .complete, time: .standard))
                    metadata("Words", String(entry.text.split(whereSeparator: { $0.isWhitespace }).count))
                    metadata("Characters", String(entry.text.count))
                    if let duration = entry.duration { metadata("Recording", String(format: "%.1f seconds", duration)) }
                    if let model = entry.speechModel { metadata("Transcription model", LocalModel.name(for: model)) }
                    if let model = entry.formattingModel { metadata("Formatting model", LocalModel.name(for: model)) }
                    if let status = entry.formattingStatus { metadata("Formatting", status) }
                    metadata("ID", entry.id.uuidString)
                    if entry.speechModel == nil {
                        Text("Model and recording details were not stored for this older entry.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(20)
        }
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}
