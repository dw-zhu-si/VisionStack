import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) { toolbar; messages; composer }
            contextRail.frame(width: 260)
        }
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            if store.availableModels.isEmpty { Text("当前连接没有可用模型").font(.vsBody(11)).foregroundStyle(VSColor.vermilion) }
            else {
                ModelSelectionControl(operation: .chat, selection: $store.preferredChatModel)
                    .frame(maxWidth: 360)
            }
            Toggle(isOn: $store.webSearchEnabled) { Label("联网检索", systemImage: "globe.asia.australia.fill").font(.vsBody(11)) }
                .toggleStyle(.switch).controlSize(.small)
            if store.isWorking {
                Button { Task { await store.cancelChat() } } label: { Label("停止", systemImage: "stop.circle") }
                    .buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
            }
            Spacer()
            Text("检索内容仅存于本轮对话；上游日志策略由当前厂商或 ModelHub 配置决定").font(.vsBody(11)).foregroundStyle(VSColor.muted)
        }.padding(.horizontal, 22).frame(height: 56)
    }
    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if store.selectedConversation?.messages.isEmpty != false { welcome }
                    ForEach(store.selectedConversation?.messages ?? []) { MessageBubble(message: $0).id($0.id) }
                    if store.isWorking { WorkingBubble() }
                }.padding(.horizontal, 34).padding(.vertical, 28)
            }.onChange(of: store.selectedConversation?.messages.count) {
                if let id = store.selectedConversation?.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("把一句想法，\n变成一套可执行的创作。").font(.vsTitle(34)).foregroundStyle(VSColor.ink)
            Text("先查资料、整理方向，再交给合适的创作 Agent 统筹执行。").font(.vsBody(13)).foregroundStyle(VSColor.muted)
            HStack { chip("查最近的视觉趋势"); chip("把产品资料变成分镜"); chip("设计一套角色视觉") }
            if store.availableModels.isEmpty { ModelUnavailableCard(operation: .chat).frame(maxWidth: 520) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 34)
    }
    private func chip(_ value: String) -> some View {
        Button(value) { store.chatDraft = value }.buttonStyle(.plain).font(.vsBody(11)).padding(.horizontal, 11).padding(.vertical, 8)
            .background(Color.white.opacity(0.70)).clipShape(Capsule()).overlay(Capsule().stroke(VSColor.ink.opacity(0.12)))
    }
    private var composer: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                TextEditor(text: $store.chatDraft).font(.vsBody(13)).scrollContentBackground(.hidden).frame(minHeight: 54, maxHeight: 120)
                    .padding(9).background(Color.white.opacity(0.76)).clipShape(RoundedRectangle(cornerRadius: 13))
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        submit(); return .handled
                    }
                Button(action: submit) { Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).frame(width: 42, height: 42) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!canSend).accessibilityLabel("发送消息")
            }
            HStack { Text("⌘↩ 发送").font(.vsBody(11)); Spacer(); Text(store.preferredChatModel.isEmpty ? "未选择模型" : store.preferredChatModel).font(.vsBody(11)).lineLimit(1) }
                .foregroundStyle(VSColor.muted)
        }.padding(.horizontal, 24).padding(.vertical, 16).background(VSColor.paper.opacity(0.88))
    }
    private var contextRail: some View {
        VStack(alignment: .leading, spacing: 20) {
            FieldLabel("当前 Agent")
            Picker("Agent", selection: Binding(get: { store.selectedAgentID }, set: { store.selectAgent($0) })) {
                ForEach(store.enabledAgents) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden()
            if let agent = store.enabledAgents.first(where: { $0.id == store.selectedAgentID }) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(agent.summary).font(.vsBody(11)).foregroundStyle(VSColor.muted).fixedSize(horizontal: false, vertical: true)
                    Label("自动托管 \(store.availableCapabilityModuleCount(for: agent)) 个能力模块", systemImage: "sparkles.square.filled.on.square")
                        .font(.vsBody(10)).foregroundStyle(VSColor.moss)
                    if let stableID = agent.stableID,
                       LocalMediaAgentCatalog.personalOnlyAgentStableIDs.contains(stableID) {
                        Text("仅限个人、教育、研究等非商业用途；选择此 Agent 即为显式调用。")
                            .font(.vsBody(10)).foregroundStyle(VSColor.vermilion)
                    }
                }
            } else {
                Text("请先同步并选择一个创作 Agent。").font(.vsBody(11)).foregroundStyle(VSColor.muted)
            }
            Spacer()
            Button { Task { await store.importLocalMediaSkills() } } label: { Label("同步本机创作 Agents", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(.plain).font(.vsLabel(11)).foregroundStyle(VSColor.vermilion)
        }.padding(18).background(VSColor.canvas.opacity(0.48))
            .overlay(alignment: .leading) { Rectangle().fill(VSColor.ink.opacity(0.10)).frame(width: 1) }
    }
    private var canSend: Bool {
        !store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isWorking && store.canUseModelService && !store.preferredChatModel.isEmpty
    }
    private func submit() {
        guard canSend, !BillingConfirmationPresentation.requiresModal(for: .chat) else { return }
        let text = store.chatDraft
        store.chatDraft = ""
        Task { await store.sendChat(text, confirmBillable: true) }
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var store: AppStore
    let message: StudioMessage
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user { Spacer(minLength: 110) }
            VStack(alignment: .leading, spacing: 12) {
                Text(message.role == .user ? "你" : "映栈").font(.vsLabel(10)).foregroundStyle(message.role == .user ? Color.white.opacity(0.76) : VSColor.vermilion)
                Text(message.content).font(.vsBody(13)).textSelection(.enabled).foregroundStyle(message.role == .user ? Color.white : VSColor.ink)
                ForEach(Array(message.sources.enumerated()), id: \.element.id) { index, source in
                    if let url = URL(string: source.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        Link("[\(index + 1)] \(source.title)", destination: url).font(.vsBody(11)).foregroundStyle(VSColor.vermilion)
                    }
                }
                HStack(spacing: 12) {
                    Button { store.transferText(message.content, to: .chat) } label: { Label("编辑再发", systemImage: "pencil") }
                    if message.role == .assistant {
                        Button { store.prepareRegeneration(after: message.id) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                    }
                    Button { store.transferText(message.content, to: .image) } label: { Label("转生图", systemImage: "photo") }
                    Button { store.transferText(message.content, to: .video) } label: { Label("转视频", systemImage: "film") }
                    Button { store.transferText(message.content, to: .video, addAsStoryboardShot: true) } label: { Label("加分镜", systemImage: "rectangle.split.3x1") }
                    Button { store.transferToStoryboardGroup(message.content) } label: { Label("转分镜组", systemImage: "square.stack.3d.up") }
                }.buttonStyle(.plain).font(.vsBody(9)).foregroundStyle(message.role == .user ? Color.white.opacity(0.8) : VSColor.vermilion)
            }.padding(16).background(message.role == .user ? VSColor.charcoal : Color.white.opacity(0.74))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if message.role != .user { Spacer(minLength: 76) }
        }
    }
}
private struct WorkingBubble: View {
    @State private var phase = false
    var body: some View {
        HStack { Circle().fill(VSColor.vermilion).frame(width: 7, height: 7).opacity(phase ? 1 : 0.35); Text("正在整理创作线索…").font(.vsBody(11)); Spacer() }
            .padding(14).onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { phase = true } }
    }
}
