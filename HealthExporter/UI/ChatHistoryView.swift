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
        VStack(spacing: 0) {
            header
            searchField

            List {
                if !engine.chatProjects.isEmpty {
                    ForEach(engine.chatProjects) { project in
                        Section {
                            let chats = engine.chats.filter { $0.projectId == project.id }
                            if chats.isEmpty {
                                Text("No chats in here yet.")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Ink.faint)
                                    .listRowBackground(Ink.surface)
                            }
                            ForEach(chats) { row(for: $0) }
                        } header: {
                            Text(project.name).sectionLabelStyle()
                        } footer: {
                            // The one thing that makes a project more than a
                            // folder: standing context every chat in it starts
                            // with. Worth showing, because it silently shapes
                            // every answer inside.
                            if !project.instructions.isEmpty {
                                Text(project.instructions)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Ink.faint)
                            }
                        }
                    }
                }

                ForEach(buckets, id: \.name) { bucket in
                    Section {
                        ForEach(bucket.chats) { row(for: $0) }
                    } header: {
                        Text(bucket.name).sectionLabelStyle()
                    }
                }

                if engine.hasMoreChats {
                    Button("Load older chats") {
                        Task { await engine.loadChats(search: search, more: true) }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.accent)
                    .buttonStyle(.plain)
                    .listRowBackground(Ink.surface)
                }

                if engine.chats.isEmpty && !engine.isLoadingChats {
                    // "No chats yet" is a confident answer, and the wrong one to
                    // give when the request simply failed.
                    if let problem = engine.chatsError {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Could not load your chats.")
                                .font(.system(size: 14))
                                .foregroundStyle(Ink.primary)
                            Text(problem)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Ink.muted)
                            Button("Try again") { Task { await engine.loadChats(search: search) } }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Ink.accent)
                                .buttonStyle(.plain)
                        }
                        .listRowBackground(Ink.surface)
                    } else {
                        Text(search.isEmpty
                             ? "No chats yet. Ask something to start one."
                             : "Nothing matched.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Ink.muted)
                            .listRowBackground(Ink.surface)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .overlay {
                if engine.isLoadingChats && engine.chats.isEmpty {
                    ProgressView().tint(Ink.muted)
                }
            }

            retentionFooter
        }
        .background(Ink.surface)
        // The drawer's own edge. Without it the panel and a dark screen behind
        // it are the same colour at the seam, and the thing reads as the page
        // having scrolled sideways rather than as a panel over it.
        .overlay(alignment: .trailing) {
            Rectangle().fill(Ink.hairline).frame(width: 1).ignoresSafeArea()
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
        .task { await engine.loadChats() }
    }

    private var header: some View {
        HStack {
            Text("Chats")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Spacer(minLength: 8)
            Button {
                engine.newChat()
                dismiss()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New chat")
        }
        .padding(.leading, 18)
        .padding(.trailing, 4)
        .padding(.bottom, 6)
    }

    /// Drawn rather than `.searchable`.
    ///
    /// A system search bar inside a hand-built drawer brings its own chrome —
    /// a cancel button, a scope row, and a background that is not this panel's
    /// — none of which the board has room for at 306pt wide.
    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Ink.faint)
            TextField("", text: $search)
                .prompt("Search questions", visible: search.isEmpty, size: 13)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Ink.primary)
                .tint(Ink.accent)
                .submitLabel(.search)
                // Server-side, so it reaches the questions inside a chat and
                // not just the title — a title here is only ever the first
                // question truncated, so searching titles alone would miss most
                // of what was asked.
                .onSubmit { Task { await engine.loadChats(search: search) } }
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Ink.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Ink.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .onChange(of: search) { _, value in
            if value.isEmpty { Task { await engine.loadChats() } }
        }
    }

    /// Stated, not buried in Settings. A history that silently drops
    /// conversations after a month reads as data loss the first time somebody
    /// notices.
    @ViewBuilder
    private var retentionFooter: some View {
        if let days = engine.insightStatus?.retentionDays {
            RetentionNote(days: days, keepRated: engine.insightStatus?.keepRated == true)
        }
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
            ChatHistoryRow(
                title: chat.title,
                subtitle: ChatHistoryRow.subtitle(
                    for: chat.lastMessageAt, compacted: chat.summaryTurns
                )
            )
        }
        // Without this a `Button` inside a `List` tints its entire label with
        // the accent colour, so every chat title read as a link. The row is
        // still tappable across its full width — that is what the content shape
        // above is for.
        .buttonStyle(.plain)
        .listRowBackground(Ink.surface)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 18))
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
            .tint(Ink.hairline)
            Button {
                newTitle = chat.title
                renaming = chat
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Ink.raised)
        }
    }

}

/// One chat: what was asked, and roughly when.
///
/// When, not how many. A chat is found by roughly when it happened — that is
/// what the buckets above it are for, and the message count answered a question
/// nobody was asking. The compacted count stays, because it explains why a
/// reopened conversation reads shorter to the model than it looks.
struct ChatHistoryRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Ink.primary)
                .lineSpacing(1.5)
                .lineLimit(1)
            Text(subtitle)
                .font(.figure(11.5, weight: .regular))
                .foregroundStyle(Ink.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    static func subtitle(for date: Date, compacted: Int) -> String {
        let when = ago.localizedString(for: date, relativeTo: Date())
        return compacted > 0 ? "\(when) · \(compacted) compacted" : when
    }

    /// "2h ago", not "2 hours ago" — the column is 11.5pt mono in a 306pt
    /// panel, and the long form wraps.
    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// How long a conversation lives, said in the drawer rather than buried in
/// Settings. A history that silently drops chats after a month reads as data
/// loss the first time somebody notices.
struct RetentionNote: View {
    let days: Int
    /// Only claimed when the server confirms it. `INSIGHT_KEEP_RATED` can turn
    /// the exemption off, and printing a retention promise this app is not
    /// keeping is worse than printing none.
    let keepRated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Ink.divider).frame(height: 1)
            Text(keepRated
                 ? "Chats are deleted after \(days) days. Rated answers are kept."
                 : "Chats are deleted after \(days) days.")
                .font(.system(size: 11.5))
                .foregroundStyle(Ink.faint)
                .lineSpacing(2.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 4)
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
                    // Deeper than a stock scrim: at 0.35 over a near-black
                    // ground the conversation behind stayed legible enough to
                    // keep reading, which makes the drawer look like a panel
                    // that failed to take focus.
                    Color(red: 0.031, green: 0.027, blue: 0.035)
                        .opacity(0.62 * progress)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .gesture(closeDrag(width: width))
                        .accessibilityLabel("Close chats")
                        .accessibilityAddTraits(.isButton)
                }

                panel
                    .frame(width: width)
                    .background(Ink.surface)
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


#if DEBUG
/// The drawer's hand-built parts, without the `List` around them.
///
/// `ImageRenderer` draws neither a `List` nor a `TextField`, so the row layout,
/// the header and the retention footer are what can be checked this way. The
/// search field and the sectioned list itself are verified only by building and
/// by using the app.
enum ChatHistoryPreview {
    static func row(_ title: String, ago: Date, compacted: Int = 0) -> some View {
        ChatHistoryRow(
            title: title,
            subtitle: ChatHistoryRow.subtitle(for: ago, compacted: compacted)
        )
    }

    static func footer(retentionDays: Int, keepRated: Bool) -> some View {
        RetentionNote(days: retentionDays, keepRated: keepRated)
    }
}
#endif
