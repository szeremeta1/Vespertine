//
// Vespertine Remote: the Mac's queue: playing now, playing next, and what continues after.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import VespertineRemoteClient
import VespertineRemoteProtocol

struct QueueView: View {
    let session: RemoteSession
    @State private var feedback = CommandFeedback()

    var body: some View {
        NavigationStack {
            List {
                if let queue = session.queue {
                    if let current = queue.current {
                        Section("Now Playing") { row(current) }
                    }
                    if !queue.playingNext.isEmpty {
                        Section("Playing Next") {
                            ForEach(queue.playingNext, id: \.entry) { row($0) }
                                .onDelete { remove(queue.playingNext, $0) }
                                .onMove { move(queue.playingNext, from: $0, to: $1) }
                        }
                    }
                    if !queue.continuing.isEmpty {
                        Section {
                            ForEach(queue.continuing, id: \.entry) { row($0) }
                                .onDelete { remove(queue.continuing, $0) }
                                .onMove { move(queue.continuing, from: $0, to: $1) }
                        } header: {
                            Text(queue.playingNext.isEmpty ? "Up Next" : "Continue Playing")
                        } footer: {
                            if queue.continuingTotal > queue.continuing.count {
                                Text("And \(queue.continuingTotal - queue.continuing.count) more")
                            }
                        }
                    }
                    if queue.current == nil && queue.playingNext.isEmpty && queue.continuing.isEmpty {
                        Text("The queue is empty.").foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
            }
            .obsidianList()
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { feedback.run(session, .clearUpcoming) }
                        .disabled((session.queue?.playingNext.isEmpty ?? true) && (session.queue?.continuing.isEmpty ?? true))
                }
            }
            .feedback(feedback)
        }
    }

    private func row(_ item: QueueItem) -> some View {
        Button { feedback.run(session, .jump(entry: item.entry)) } label: {
            HStack(spacing: 12) {
                ArtworkView(key: item.track.artworkKey, size: 120, cornerRadius: 4).frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.track.title).lineLimit(1)
                    Text(item.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(formatTime(item.track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func remove(_ items: [QueueItem], _ offsets: IndexSet) {
        feedback.run(session, .removeFromQueue(entries: offsets.map { items[$0].entry }))
    }

    private func move(_ items: [QueueItem], from offsets: IndexSet, to destination: Int) {
        let moving = offsets.map { items[$0].entry }
        let before = destination < items.count ? items[destination].entry : nil
        feedback.run(session, .moveInQueue(entries: moving, before: before))
    }
}
