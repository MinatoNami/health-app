import SwiftUI

/// Past conversations, as a sheet.
///
/// The dashboard puts this in a permanent sidebar. A phone has no room for one
/// beside a transcript, and the alternative — a column narrow enough to fit —
/// is two unusable things instead of one usable one. So it is a sheet reached
/// from the toolbar, which is where every chat app on this platform puts it.
///
/// Grouped the way people already look for things: projects first, because a
/// project is something you chose to make and stays where you put it, then
/// everything else under Today / Yesterday / Previous 7 days, because a loose
/// conversation is found by roughly when it happened.
struct ChatHistoryView: View {
    @EnvironmentObject private var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var renaming: ChatSession?
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                if !engine.chatProjects.isEmpty {
                    ForEach(engine.chatProjects) { project in
                        Section {
                            let chats = engine.chats.filter { $0.projectId == project.id }
                            if chats.isEmpty {
                                Text("No chats in here yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(chats) { row(for: $0) }
                        } header: {
                            Text(project.name)
                        } footer: {
                            // The one thing that makes a project more than a
                            // folder: standing context every chat in it starts
                            // with. Worth showing, because it silently shapes
                            // every answer inside.
                            if !project.instructions.isEmpty {
                                Text(project.instructions).font(.caption2)
                            }
                        }
                    }
                }

                ForEach(buckets, id: \.name) { bucket in
                    Section(bucket.name) {
                        ForEach(bucket.chats) { row(for: $0) }
                    }
                }

                if engine.hasMoreChats {
                    Button("Load older chats") {
                        Task { await engine.loadChats(search: search, more: true) }
                    }
                    .font(.subheadline)
                }

                if engine.chats.isEmpty && !engine.isLoadingChats {
                    Text(search.isEmpty
                         ? "No chats yet. Ask something to start one."
                         : "Nothing matched.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search chats")
            // Server-side, so it reaches the questions inside a chat and not
            // just the title — a title here is only ever the first question
            // truncated, so searching titles alone would miss most of what was
            // asked.
            .onSubmit(of: .search) { Task { await engine.loadChats(search: search) } }
            .onChange(of: search) { _, value in
                if value.isEmpty { Task { await engine.loadChats() } }
            }
            .overlay {
                if engine.isLoadingChats && engine.chats.isEmpty { ProgressView() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        engine.newChat()
                        dismiss()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let days = engine.insightStatus?.retentionDays {
                    // Stated, not buried in Settings. A history that silently
                    // drops conversations after a month reads as data loss the
                    // first time somebody notices.
                    Text("Chats are deleted after \(days) days.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .alert("Rename chat", isPresented: renameBinding) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let chat = renaming {
                        let title = newTitle
                        Task { await engine.renameChat(chat.id, to: title) }
                    }
                    renaming = nil
                }
            }
        }
        .task { await engine.loadChats() }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    /// Loose chats, bucketed by when they were last touched. Empty buckets are
    /// dropped rather than rendered as headings over nothing.
    private var buckets: [(name: String, chats: [ChatSession])] {
        let order = ["Today", "Yesterday", "Previous 7 days", "Previous 30 days", "Older"]
        let loose = engine.chats.filter { $0.projectId == nil }
        return order.compactMap { name in
            let chats = loose.filter { $0.bucket == name }
            return chats.isEmpty ? nil : (name, chats)
        }
    }

    private func row(for chat: ChatSession) -> some View {
        Button {
            Task {
                await engine.openChat(chat.id)
                dismiss()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let count = chat.messageCount {
                        Text("\(count) message\(count == 1 ? "" : "s")")
                    }
                    if chat.summaryTurns > 0 {
                        Text("· \(chat.summaryTurns) compacted")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await engine.deleteChat(chat.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                Task { await engine.archiveChat(chat.id) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.gray)
            Button {
                newTitle = chat.title
                renaming = chat
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }
}
