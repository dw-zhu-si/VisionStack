import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var appeared = false
    @StateObject private var navigation = WorkspaceNavigation()
    var body: some View {
        ZStack {
            if let reason = store.persistenceBlockReason {
                PersistenceBlockedView(reason: reason)
            } else {
                PaperBackground()
                HStack(spacing: 0) {
                    SidebarView().frame(width: 238)
                    VStack(spacing: 0) {
                        TopBar()
                        Group {
                            switch navigation.destination {
                            case .home: ProjectHomeView()
                            case .tasks: TaskCenterView(embedded: true, onShowAsset: navigation.showAsset)
                            case .assets: AssetLibraryView(embedded: true, focusedJobID: navigation.focusedAssetID)
                            case .studio:
                                switch store.mode { case .chat: ChatView(); case .image: ImageStudioView(); case .video: VideoStudioView() }
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .environmentObject(navigation)
        .onChange(of: store.studioNavigationRequest) { navigation.destination = .studio }
        .onChange(of: store.mode) { navigation.destination = .studio }
        .onChange(of: store.selectedProjectID) { navigation.focusedAssetID = nil; navigation.taskQuery = ""; navigation.taskKind = "全部"; navigation.taskState = "全部"; navigation.taskPage = 0 }
        .onChange(of: store.showingTasks) { if store.showingTasks { navigation.destination = .tasks; store.showingTasks = false } }
        .onChange(of: store.showingAssets) { if store.showingAssets { navigation.focusedAssetID = nil; navigation.destination = .assets; store.showingAssets = false } }
        .foregroundStyle(VSColor.ink)
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 8).animation(.easeOut(duration: 0.42), value: appeared)
        .onAppear { appeared = true }
        .onChange(of: scenePhase) { if scenePhase != .active { Task { await store.flushPersistence() } } }
        .sheet(isPresented: $store.showingSettings) { SettingsView().environmentObject(store) }
        .sheet(isPresented: $store.showingLibrary) { ResourceLibraryView().environmentObject(store) }
        .sheet(isPresented: $store.showingProjects) { ProjectWorkspaceView().environmentObject(store) }
        .sheet(isPresented: $store.showingPresets) { CreativePresetManagerView().environmentObject(store) }
        .sheet(isPresented: $store.showingRoughCut) { VideoRoughCutView().environmentObject(store) }
        .sheet(isPresented: $store.showingThirdPartyAIConsent) {
            ThirdPartyAIConsentView().environmentObject(store)
        }
        .overlay(alignment: .topTrailing) {
            if let notice = store.notice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(VSColor.vermilion)
                    Text(notice).font(.vsBody(11)).fixedSize(horizontal: false, vertical: true)
                    Button { store.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("关闭状态提示")
                }
                .padding(12).frame(maxWidth: 430, alignment: .leading)
                .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(VSColor.ink.opacity(0.12)))
                .shadow(color: Color.black.opacity(0.12), radius: 16, y: 6)
                .padding(.top, 72).padding(.trailing, 18)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("映栈状态提示：\(notice)")
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.notice)
    }
}

private struct ThirdPartyAIConsentView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(VSColor.vermilion)
                .accessibilityHidden(true)
            Text("授权第三方 AI 处理创作内容").font(.vsTitle(24))
            Text("映栈可以直接连接你配置的 AI 厂商，也可以通过可选的 ModelHub 路由。发送对话、生图或视频任务时，提示词、对话上下文和你主动选择的参考图可能会交给当前供应商处理。")
                .font(.vsBody(13)).foregroundStyle(VSColor.ink).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Label("直连 API Key 只保存在 macOS Keychain，不写入项目、历史、日志或导出包。", systemImage: "key.horizontal")
                Label("结果与任务历史保存在本机；上游保留规则由当前供应商或 ModelHub 配置决定。", systemImage: "internaldrive")
                Label("你可在设置中撤回后续发送授权；已提交的请求不会因撤回而自动删除。", systemImage: "arrow.uturn.backward.circle")
            }.font(.vsBody(11)).foregroundStyle(VSColor.muted)
            HStack(spacing: 16) {
                Link("隐私政策", destination: ThirdPartyAIConsentPolicy.privacyPolicyURL)
                Link("使用条款", destination: ThirdPartyAIConsentPolicy.termsURL)
            }.font(.vsLabel(11)).foregroundStyle(VSColor.vermilion)
            HStack {
                Button("暂不授权") { store.declineThirdPartyAIConsent() }
                Spacer()
                Button("同意并继续") { store.acceptThirdPartyAIConsent() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(PaperBackground())
        .accessibilityElement(children: .contain)
    }
}

private struct PersistenceBlockedView: View {
    let reason: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(VSColor.vermilion)
            Text("本地历史已进入只读保护").font(.vsTitle(26))
            Text("映栈没有创建空白历史，也没有覆盖原文件。请先备份并检查 Application Support/VisionStack 中的 state.json 与 state.backup.json。")
                .font(.vsBody(13)).foregroundStyle(VSColor.muted).multilineTextAlignment(.center)
            Text(reason).font(.vsBody(11)).foregroundStyle(VSColor.vermilion)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }
        .padding(34).frame(maxWidth: 620)
        .background(Color.white.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(VSColor.ink.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaperBackground())
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var navigation: WorkspaceNavigation
    @State private var deleteTarget: Conversation?
    @EnvironmentObject private var store: AppStore
    @State private var renameTarget: Conversation?
    @State private var renameDraft = ""
    @State private var conversationQuery = ""
    @State private var showingArchivedConversations = false
    private var visibleConversations: [Conversation] {
        store.conversations.filter { conversation in
            conversation.projectID == store.selectedProjectID
                && (showingArchivedConversations ? conversation.archivedAt != nil : conversation.archivedAt == nil)
                && (conversationQuery.isEmpty || conversation.title.localizedCaseInsensitiveContains(conversationQuery) || conversation.messages.contains { $0.content.localizedCaseInsensitiveContains(conversationQuery) })
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                AppIconMark()
                VStack(alignment: .leading, spacing: 1) {
                    Text("映栈").font(.vsTitle(23)).foregroundStyle(.white)
                    Text("VISIONSTACK").font(.vsLabel(10)).tracking(1.8).foregroundStyle(Color.white.opacity(0.62))
                }
            }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 26)

            sidebarAction("项目首页", "house") { navigation.destination = .home }.padding(.horizontal, 10)
            FieldLabel("创作模式").foregroundStyle(Color.white.opacity(0.62)).padding(.horizontal, 18)
            VStack(spacing: 7) {
                ForEach(StudioMode.allCases) { mode in
                    Button { store.mode = mode; navigation.destination = .studio } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode.symbol).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) { Text(mode.title).font(.vsLabel(13)); Text(mode.subtitle).font(.vsBody(11)).opacity(0.68) }
                            Spacer(); if navigation.destination == .studio && store.mode == mode { Circle().fill(VSColor.orange).frame(width: 6, height: 6) }
                        }.foregroundStyle(Color.white).padding(.horizontal, 13).padding(.vertical, 10)
                            .background(navigation.destination == .studio && store.mode == mode ? Color.white.opacity(0.12) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }.padding(10)

            HStack {
                FieldLabel("最近对话").foregroundStyle(Color.white.opacity(0.62)); Spacer()
                Button { showingArchivedConversations.toggle() } label: { Image(systemName: showingArchivedConversations ? "tray.full.fill" : "tray") }
                    .buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.82)).help(showingArchivedConversations ? "显示活动对话" : "显示已归档对话")
                Button { store.createConversation() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.82)).help("新建对话").accessibilityLabel("新建对话")
            }.padding(.horizontal, 18).padding(.top, 13)
            TextField("搜索对话", text: $conversationQuery)
                .textFieldStyle(.plain).font(.vsBody(10)).padding(8)
                .background(Color.white.opacity(0.08)).foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 14).padding(.top, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visibleConversations) { conversation in
                        Button { store.selectConversation(conversation.id); navigation.destination = .studio } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title).font(.vsBody(11)).lineLimit(1)
                                Text(conversation.updatedAt.formatted(date: .omitted, time: .shortened)).font(.vsBody(11)).opacity(0.58)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                                .background(navigation.destination == .studio && store.selectedConversationID == conversation.id && store.mode == .chat ? Color.white.opacity(0.10) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).foregroundStyle(Color.white.opacity(0.84))
                        .contextMenu {
                            Button("重命名") { renameTarget = conversation; renameDraft = conversation.title }
                            if conversation.archivedAt == nil { Button("归档") { store.archiveConversation(conversation.id) } }
                            else { Button("恢复") { store.restoreConversation(conversation.id) } }
                            Button("删除", role: .destructive) { deleteTarget = conversation }
                        }
                        .accessibilityAction(named: "删除对话") { deleteTarget = conversation }
                        .accessibilityAction(named: "重命名对话") { renameTarget = conversation; renameDraft = conversation.title }
                    }
                }.padding(.horizontal, 10).padding(.top, 8)
            }
            if let deletedTitle = store.lastDeletedConversationTitle {
                Button { _ = store.undoDeleteConversation() } label: {
                    Label("撤销删除：\(deletedTitle)", systemImage: "arrow.uturn.backward").lineLimit(1)
                }.buttonStyle(.plain).font(.vsBody(11)).foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 8)
            }
            Spacer(minLength: 12)
            VStack(spacing: 5) {
                sidebarAction("项目工作区", "folder.badge.gearshape") { store.showingProjects = true }
                sidebarAction("任务中心", "list.bullet.rectangle") { store.showingTasks = true }
                sidebarAction("素材库", "square.grid.2x2") { store.showingAssets = true }
                sidebarAction("创作预设", "slider.horizontal.below.square.filled.and.square") { store.showingPresets = true }
                sidebarAction("视频草剪台", "timeline.selection") { store.showingRoughCut = true }
                sidebarAction("创作 Agents", "person.2.badge.gearshape") { store.showingLibrary = true }
                sidebarAction("设置", "slider.horizontal.3") { store.showingSettings = true }
            }.padding(10)
        }
        .background(VSColor.ink.opacity(0.97))
        .alert("删除对话？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("删除对话", role: .destructive) { if let id = deleteTarget?.id { store.deleteConversation(id) }; deleteTarget = nil }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { Text("将移除“\(deleteTarget?.title ?? "")”及全部消息。可以通过侧栏“撤销删除”恢复。") }
        .alert("重命名对话", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("对话名称", text: $renameDraft)
            Button("保存") { if let id = renameTarget?.id { store.renameConversation(id, to: renameDraft) }; renameTarget = nil }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
    }
    private func sidebarAction(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Image(systemName: symbol).frame(width: 18); Text(title); Spacer() }.font(.vsBody(11)).padding(10).foregroundStyle(Color.white.opacity(0.78)) }.buttonStyle(.plain)
    }
}

private struct TopBar: View {
    @EnvironmentObject private var navigation: WorkspaceNavigation
    private var title: String { switch navigation.destination { case .home: "项目首页"; case .tasks: "任务中心"; case .assets: "素材库"; case .studio: store.mode.title } }
    private var subtitle: String { switch navigation.destination { case .home: "创作进度与交付"; case .tasks: "执行进度与恢复"; case .assets: "评审、整理与导出"; case .studio: store.mode.subtitle } }
    @EnvironmentObject private var store: AppStore
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) { Text(title).font(.vsTitle(20)); Text(subtitle).font(.vsBody(11)).foregroundStyle(VSColor.muted) }
            Spacer()
            if navigation.focusedAssetID != nil {
                Button("返回") { navigation.returnFromAsset() }.help("返回素材来源页面")
            }
            Button { store.showingProjects = true } label: {
                HStack(spacing: 6) { Image(systemName: "folder"); Text(store.selectedProject?.name ?? "项目").lineLimit(1) }
                    .font(.vsLabel(10)).padding(.horizontal, 10).padding(.vertical, 7).background(Color.white.opacity(0.68)).clipShape(Capsule())
            }.buttonStyle(.plain).foregroundStyle(VSColor.ink).frame(maxWidth: 180)
            Button { if !store.connection.isConnected { store.showingSettings = true } } label: { StatusPill(title: store.connection.title, color: statusColor) }
                .buttonStyle(.plain).help(connectionSummary)
            Button { Task { await store.refreshModelHub() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(VSColor.ink).help("刷新当前连接").accessibilityLabel("刷新当前连接")
            Button { store.showingTasks = true } label: {
                HStack(spacing: 6) { Image(systemName: "list.bullet.rectangle"); Text("\(store.currentProjectTaskCount)") }
                    .font(.vsLabel(11)).padding(.horizontal, 10).padding(.vertical, 7).background(Color.white.opacity(0.68)).clipShape(Capsule())
            }.buttonStyle(.plain).foregroundStyle(VSColor.ink).accessibilityLabel("当前项目任务中心，共 \(store.currentProjectTaskCount) 项")
            Button { store.showingAssets = true } label: {
                HStack(spacing: 6) { Image(systemName: "square.grid.2x2"); Text("\(store.currentProjectAssetCount)") }
                    .font(.vsLabel(11)).padding(.horizontal, 10).padding(.vertical, 7).background(Color.white.opacity(0.68)).clipShape(Capsule())
            }.buttonStyle(.plain).foregroundStyle(VSColor.ink).accessibilityLabel("当前项目素材库，共 \(store.currentProjectAssetCount) 项")
            Button { store.showingLibrary = true } label: {
                HStack(spacing: 6) { Image(systemName: "person.2.badge.gearshape"); Text("\(store.installedAgentCount)") }
                    .font(.vsLabel(11)).padding(.horizontal, 10).padding(.vertical, 7).background(Color.white.opacity(0.68)).clipShape(Capsule())
            }.buttonStyle(.plain).foregroundStyle(VSColor.ink).accessibilityLabel("创作 Agent，共 \(store.installedAgentCount) 个")
        }.padding(.horizontal, 22).frame(height: 64).background(VSColor.paper.opacity(0.90))
            .overlay(alignment: .bottom) { Rectangle().fill(VSColor.ink.opacity(0.10)).frame(height: 1) }
    }
    private var connectionSummary: String {
        let name = store.activeProvider?.displayName ?? "模型服务"
        switch store.connection {
        case .offline: return "\(name) 离线；打开设置检查连接。"
        case .connecting: return "正在连接 \(name)…"
        case .connected(let count): return "\(name) 已连接，\(count) 个模型可用。"
        case .failed(let reason): return "\(name) 连接失败：\(reason)"
        }
    }
    private var statusColor: Color { switch store.connection { case .connected: VSColor.moss; case .connecting: VSColor.orange; default: VSColor.vermilion } }
}

enum AppResources {
    static let swiftPackageBundleName = "VisionStack_VisionStack.bundle"

    static var swiftPackageResourceBundleURL: URL? {
        if let installedBundle = firstReadableDirectoryURL([
            Bundle.main.resourceURL?.appending(path: swiftPackageBundleName),
            Bundle.main.bundleURL.appending(path: swiftPackageBundleName)
        ]) {
            return installedBundle
        }
        return firstReadableDirectoryURL([Bundle.module.bundleURL])
    }

    static var appIconURL: URL? {
        firstReadableURL([
            Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
            Bundle.main.bundleURL.appending(path: swiftPackageBundleName).appending(path: "AppIcon.png"),
            Bundle.main.resourceURL?.appending(path: swiftPackageBundleName).appending(path: "AppIcon.png")
        ])
    }

    static func firstReadableURL(_ candidates: [URL?], fileManager: FileManager = .default) -> URL? {
        candidates.compactMap { $0 }.first { fileManager.isReadableFile(atPath: $0.path) }
    }

    static func firstReadableDirectoryURL(_ candidates: [URL?], fileManager: FileManager = .default) -> URL? {
        candidates.compactMap { $0 }.first { candidate in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}

private struct AppIconMark: View {
    var body: some View {
        Group {
            if let url = AppResources.appIconURL, let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "camera.aperture").font(.system(size: 22)).foregroundStyle(VSColor.orange) }
        }.frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
