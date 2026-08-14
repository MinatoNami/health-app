import SwiftUI

/// Past conversations, as a drawer down the left-hand side.
///
/// A sheet was wrong for this. A sheet is modal and arrives from the bottom,
/// which says "finish with me before you carry on" — but a chat list is
/// navigation. You open it to glance, change your mind, and dismiss it, and
/// that wants the gesture every chat app on this platform already trained
/// people to use: slide in from the left, tap anywhere else to put it back.
///
/// The dashboard reaches the same place from the other direction — a permanent
/// column when there is room, this same drawer when there is not.
///
/// Grouped the way people already look for things: projects first, because a
/// project is something you chose to make and stays where you put it, then
/// everything else under Today / Yesterday / Previous 7 days, because a loose
/// conversation is found by roughly when it happened.
struct ChatHistoryView: View {
    @EnvironmentObject private var engine: SyncEngine
    /// Closing is the drawer's job, not the list's — tapping outside, dragging
    /// it away and picking a chat all mean the same thing here.
    let dismiss: () -> Void

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
                    // "No chats yet" is a confident answer, and the wrong one to
                    // give when the request simply failed.
                    if let problem = engine.chatsError {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Could not load your chats.")
                            Text(problem).font(.caption).foregroundStyle(.secondary)
                            Button("Try again") { Task { await engine.loadChats(search: search) } }
                                .font(.subheadline)
                        }
                    } else {
                        Text(search.isEmpty
                             ? "No chats yet. Ask something to start one."
                             : "Nothing matched.")
                            .foregroundStyle(.secondary)
                    }
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

/// Slides a panel in from the left over its content, with a dimmed scrim.
///
/// Written by hand rather than reached for from the toolkit because none of the
/// stock presentations is this: a sheet is modal and comes from the bottom,
/// `NavigationSplitView` collapses to a push on iPhone, and a plain overlay has
/// no gesture. What people expect from a chat list is specifically the drawer —
/// slide it in, tap the dimmed part to put it back, or throw it away with a
/// flick.
///
/// The drag is tracked live rather than animated on release, so the panel
/// follows your thumb and the scrim darkens as it comes. A drawer that ignores
/// the gesture until you let go feels broken even when it ends up in the right
/// place.
///
/// That drag lives on the **scrim**, not on the whole drawer. Putting it on the
/// container costs more than it buys: the panel is a `List` whose rows carry
/// swipe actions, and a container-level horizontal drag eats them — swiping a
/// chat to rename or delete it would close the drawer instead. Dragging the
/// dimmed area is the same gesture in the place where nothing else wants it.
struct SideDrawer<Panel: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder var panel: Panel
    @ViewBuilder var content: Content

    @GestureState private var drag: CGFloat = 0

    /// Wide enough to read a chat title, narrow enough that the conversation
    /// behind stays visible — the strip of context is what tells you the drawer
    /// is temporary.
    private func width(_ available: CGFloat) -> CGFloat {
        min(available * 0.84, 340)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = width(geometry.size.width)
            // Clamped so dragging further open than open does nothing, and the
            // panel cannot be pushed off past its own edge.
            let offset = min(max((isOpen ? 0 : -width) + drag, -width), 0)
            let progress = 1 + offset / width

            ZStack(alignment: .leading) {
                content
                    // The scrim already swallows taps; this keeps VoiceOver from
                    // wandering into a conversation the drawer is covering.
                    .accessibilityHidden(isOpen)

                if progress > 0 {
                    Color.black
                        .opacity(0.35 * progress)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .gesture(closeDrag(width: width))
                        .accessibilityLabel("Close chats")
                        .accessibilityAddTraits(.isButton)
                }

                panel
                    .frame(width: width)
                    .background(Color(.systemGroupedBackground))
                    .ignoresSafeArea(edges: .vertical)
                    .offset(x: offset)
                    .shadow(color: .black.opacity(0.18 * progress), radius: 12, x: 2)
            }
            .animation(.snappy(duration: 0.28), value: isOpen)
        }
    }

    /// Drag the dimmed area to push the drawer back. Only ever closes — there
    /// is no scrim to grab when it is shut, and opening is the toolbar's job.
    private func closeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($drag) { value, state, _ in
                // Leftward, and horizontal: anything else is not this gesture.
                guard value.translation.width < 0,
                      abs(value.translation.width) > abs(value.translation.height)
                else { return }
                state = value.translation.width
            }
            .onEnded { value in
                // Predicted end rather than raw translation, so a short flick
                // closes it and a slow, short drag springs back.
                guard value.predictedEndTranslation.width < -width / 3 else { return }
                close()
            }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.28)) { isOpen = false }
    }
}
