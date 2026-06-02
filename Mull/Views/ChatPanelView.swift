import SwiftUI

/// A scoped chat over your own mull data — NOT a general-purpose chatbot.
///
/// Per PRODUCT.md Direction v2: the chat box is "a window to instruct
/// re-processing of the raw source," not a ChatGPT clone. The system prompt
/// grounds every answer in me.md / now.md / the project files and forbids
/// generic open-domain assistance. Heavy chatting belongs in Claude/ChatGPT,
/// which can read mull via MCP; this panel is for asking mull about *you*.
@MainActor
final class ChatViewModel: ObservableObject {

    struct Message: Identifiable {
        let id = UUID()
        let role: Role
        var text: String
        enum Role { case user, assistant }
    }

    @Published var messages: [Message] = []
    @Published var input: String = ""
    @Published var isThinking = false

    private let llm = LLMClient()

    /// Send the current input, grounding the model in the user's mull context.
    func send() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isThinking else { return }

        messages.append(Message(role: .user, text: prompt))
        input = ""
        isThinking = true
        defer { isThinking = false }

        do {
            let reply = try await llm.complete(
                system: systemPrompt(),
                prompt: conversationPrompt(latest: prompt),
                options: .init(maxTokens: 1500)
            )
            messages.append(Message(role: .assistant, text: reply))
        } catch {
            messages.append(Message(role: .assistant,
                                    text: "⚠️ \(error.localizedDescription)"))
        }
    }

    // MARK: - Grounding

    /// Build the scoping system prompt with the user's current context inlined.
    private func systemPrompt() -> String {
        var ctx: [String] = []
        if let me = MullDirectory.read("me.md") { ctx.append("=== me.md ===\n\(me)") }
        if let now = MullDirectory.read("now.md") { ctx.append("=== now.md ===\n\(now)") }
        for project in projectFiles() {
            if let body = MullDirectory.read(project) {
                ctx.append("=== \(project) ===\n\(body)")
            }
        }
        let context = ctx.isEmpty
            ? "(no mull context generated yet)"
            : ctx.joined(separator: "\n\n")

        return """
        You are mull's built-in assistant. mull is a second brain that records \
        what this person does and organizes it. You answer questions about THIS \
        PERSON using the context below, and you help them reorganize and reflect \
        on their own records.

        Scope rules:
        - You are not a general-purpose chatbot. If asked something unrelated to \
        this person's life, work, or records (e.g. "write me a poem", "what's \
        the capital of France"), briefly decline and suggest they use a general \
        AI like Claude or ChatGPT, which can read their mull data over MCP.
        - Ground every answer in the context. Prefer observations from the data \
        over speculation. Do not judge or psychoanalyze; report what the records \
        show.
        - Be concise and concrete. Plain text.

        === THE PERSON'S CURRENT CONTEXT ===
        \(context)
        """
    }

    /// A compact transcript so the model has short-term memory of the exchange.
    private func conversationPrompt(latest: String) -> String {
        let history = messages.dropLast() // exclude the just-added user turn
            .suffix(8)
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n")
        if history.isEmpty { return latest }
        return "\(history)\nUser: \(latest)"
    }

    private func projectFiles() -> [String] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("mull/projects", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.sorted().map { "projects/\($0)" }
    }
}

struct ChatPanelView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(.textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Chat with mull")
                    .font(DS.titleFont)
                Text("Ask about your own records — not a general chatbot")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(DS.md)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.md) {
                    if vm.messages.isEmpty {
                        emptyState
                    }
                    ForEach(vm.messages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                    if vm.isThinking {
                        HStack(spacing: DS.xs) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(DS.captionFont).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(DS.md)
            }
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Try asking:").font(DS.captionFont).foregroundStyle(.tertiary)
            ForEach(["What was I mainly working on this week?",
                     "What project should I resume?",
                     "Summarize what I did today."], id: \.self) { s in
                Text("“\(s)”").font(DS.bodyFont).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DS.xl)
    }

    private func messageRow(_ msg: ChatViewModel.Message) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 40) }
            Text(msg.text)
                .font(DS.bodyFont)
                .textSelection(.enabled)
                .padding(DS.sm)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(msg.role == .user
                              ? Color.accentColor.opacity(0.15)
                              : Color(.controlBackgroundColor))
                )
                .frame(maxWidth: 520, alignment: msg.role == .user ? .trailing : .leading)
            if msg.role == .assistant { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(spacing: DS.sm) {
            TextField("Ask mull about your records…", text: $vm.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(DS.sm)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor)))
                .onSubmit { Task { await vm.send() } }

            Button {
                Task { await vm.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .disabled(vm.input.trimmingCharacters(in: .whitespaces).isEmpty || vm.isThinking)
        }
        .padding(DS.md)
    }
}
