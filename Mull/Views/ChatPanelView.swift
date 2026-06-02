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

    /// True when no LLM provider is selected — chat can't answer until one is on.
    var isLLMOff: Bool { (UserDefaults.standard.string(forKey: "llmProvider") ?? "off") == "off" }

    /// Fill the input with a suggestion and send it.
    func ask(_ text: String) async {
        input = text
        await send()
    }

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
            .appendingPathComponent("mull/03_projects", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasSuffix(".md") && $0 != "index.md" }
            .sorted().map { "03_projects/\($0)" }
    }
}

struct ChatPanelView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ChatViewModel()
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "What was I mainly working on this week?",
        "What project should I resume?",
        "Summarize what I did today.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            if vm.isLLMOff { llmOffBanner }
            transcript
            composer
        }
        .background(DS.canvas)
        .onAppear { inputFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "sparkle")
                .font(.system(size: 13))
                .foregroundStyle(DS.moon)
            VStack(alignment: .leading, spacing: 1) {
                Text("Chat with mull")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.ink)
                Text("Grounded in your own records — not a general chatbot")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
            }
            Spacer()
            if !vm.messages.isEmpty {
                Button { vm.messages.removeAll() } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.inkFaint)
                .help("Clear conversation")
            }
        }
        .padding(.horizontal, DS.lg)
        .padding(.vertical, DS.md)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.hairline).frame(height: 0.5) }
    }

    private var llmOffBanner: some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "moon.zzz").foregroundStyle(DS.paused)
            Text("LLM is off. Turn on a provider to chat.")
                .font(DS.captionFont).foregroundStyle(DS.inkDim)
            Spacer()
            Button("Open Settings") { AppDelegate.shared?.showSettings() }
                .font(DS.captionFont)
                .buttonStyle(.plain)
                .foregroundStyle(DS.moon)
        }
        .padding(.horizontal, DS.lg)
        .padding(.vertical, DS.sm)
        .background(DS.paused.opacity(0.08))
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.lg) {
                    if vm.messages.isEmpty {
                        emptyState
                    }
                    ForEach(vm.messages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                    if vm.isThinking { thinkingRow.id("thinking") }
                }
                .padding(DS.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: vm.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: vm.isThinking) { _, _ in scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if vm.isThinking { proxy.scrollTo("thinking", anchor: .bottom) }
            else if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            HStack(spacing: DS.sm) {
                Image(systemName: "moon.stars").font(.system(size: 18)).foregroundStyle(DS.moon)
                Text("Ask mull about you")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.ink)
            }
            Text("It reads your me.md, now.md and project notes to answer.")
                .font(DS.bodyFont).foregroundStyle(DS.inkDim)

            VStack(alignment: .leading, spacing: DS.sm) {
                ForEach(suggestions, id: \.self) { s in
                    Button { Task { await vm.ask(s) } } label: {
                        HStack(spacing: DS.sm) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10)).foregroundStyle(DS.moon.opacity(0.7))
                            Text(s).font(DS.bodyFont).foregroundStyle(DS.inkDim)
                            Spacer()
                        }
                        .padding(.horizontal, DS.md).padding(.vertical, DS.sm)
                        .background(RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.surface))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusSm).strokeBorder(DS.hairline, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isLLMOff)
                }
            }
            .padding(.top, DS.xs)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.top, DS.xl)
    }

    private func messageRow(_ msg: ChatViewModel.Message) -> some View {
        HStack(alignment: .top, spacing: DS.sm) {
            if msg.role == .user {
                Spacer(minLength: 48)
                bubble(msg)
            } else {
                avatar
                bubble(msg)
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
    }

    private var avatar: some View {
        Image(systemName: "moon.fill")
            .font(.system(size: 10))
            .foregroundStyle(DS.moon)
            .frame(width: 24, height: 24)
            .background(Circle().fill(DS.moon.opacity(0.12)))
            .overlay(Circle().strokeBorder(DS.moon.opacity(0.25), lineWidth: 0.75))
    }

    private func bubble(_ msg: ChatViewModel.Message) -> some View {
        Text(Self.markdown(msg.text))
            .font(DS.readFont)
            .lineSpacing(4)
            .foregroundStyle(msg.role == .user ? DS.ink : DS.ink)
            .textSelection(.enabled)
            .padding(.horizontal, DS.md)
            .padding(.vertical, DS.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMd)
                    .fill(msg.role == .user ? DS.moon.opacity(0.14) : DS.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMd)
                    .strokeBorder(msg.role == .user ? DS.moon.opacity(0.25) : DS.hairline, lineWidth: 0.75)
            )
            .frame(maxWidth: 560, alignment: .leading)
    }

    private var thinkingRow: some View {
        HStack(spacing: DS.sm) {
            avatar
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(DS.moon.opacity(0.6)).frame(width: 5, height: 5)
                        .opacity(0.4)
                        .scaleEffect(1)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.15), value: vm.isThinking)
                }
            }
            .padding(.horizontal, DS.md).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: DS.radiusMd).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusMd).strokeBorder(DS.hairline, lineWidth: 0.75))
            Spacer(minLength: 48)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(DS.hairline).frame(height: 0.5)
            HStack(alignment: .bottom, spacing: DS.sm) {
                TextField("Ask mull about your records…", text: $vm.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.readFont)
                    .foregroundStyle(DS.ink)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, DS.md)
                    .padding(.vertical, DS.sm)
                    .background(RoundedRectangle(cornerRadius: DS.radiusMd).fill(DS.surface))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusMd)
                        .strokeBorder(inputFocused ? DS.moon.opacity(0.4) : DS.hairline, lineWidth: 0.75))
                    .onSubmit { Task { await vm.send() } }
                    .disabled(vm.isLLMOff)

                Button { Task { await vm.send() } } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSend ? DS.moon : DS.inkFaint)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(DS.md)
        }
    }

    private var canSend: Bool {
        !vm.isLLMOff && !vm.isThinking &&
        !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Inline-markdown render for message text (bold/italic/code/links), with a
    /// plain-text fallback.
    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}
