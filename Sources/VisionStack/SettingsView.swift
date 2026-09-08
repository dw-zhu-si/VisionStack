import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftURL = ""
    @State private var draftToken = ""
    @State private var draftContextBudgetTokens = ContextBudget.defaultTokens
    @State private var draftConcurrency = 2
    @State private var draftNotifications = false
    @State private var saving = false
    @State private var confirmClear = false
    @State private var modelQuery = ""
    @State private var modelScope = "全部"
    @State private var editingModel: ModelDescriptor?
    @State private var showingCapabilityWizard = false
    @State private var showingProviderEditor = false
    @State private var showingManualModelEditor = false
    @State private var providerDeleteTarget: AIProviderConfiguration?
    @State private var manualModelDeleteTarget: ModelDescriptor?

    private var filteredModels: [ModelDescriptor] {
        store.models.filter { model in
            let matchesQuery = modelQuery.isEmpty || model.id.localizedCaseInsensitiveContains(modelQuery) || model.owner.localizedCaseInsensitiveContains(modelQuery)
            let profile = store.profile(for: model.id)
            let matchesScope = switch modelScope {
            case "路由": model.isRoute
            case "可执行": profile?.isConfigured == true
            case "暂不支持": profile?.source == .unsupported
            case "未匹配": profile?.isResolved != true
            default: true
            }
            return matchesQuery && matchesScope
        }.sorted {
            if $0.isRoute != $1.isRoute { return $0.isRoute }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) { Text("映栈设置").font(.vsTitle(24)); Text("厂商直连、ModelHub 与本地边界").font(.vsBody(11)).foregroundStyle(VSColor.muted) }
                Spacer(); Button("关闭") { dismiss() }
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    StudioCard {
                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                FieldLabel("当前模型连接")
                                Spacer()
                                Button { showingProviderEditor = true } label: { Label("添加厂商", systemImage: "plus") }
                                    .buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
                                if let provider = store.activeProvider,
                                   provider.id != AIProviderConfiguration.defaultModelHubID {
                                    Button(role: .destructive) { providerDeleteTarget = provider } label: {
                                        Label("移除", systemImage: "trash")
                                    }.buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
                                }
                            }
                            Picker("当前模型连接", selection: Binding(
                                get: { store.selectedProviderID },
                                set: { selectProvider($0) }
                            )) {
                                ForEach(store.providerConnections) { provider in
                                    Text("\(provider.displayName) · \(provider.kind.title)").tag(Optional(provider.id))
                                }
                            }
                            .labelsHidden()
                            .disabled(saving)

                            FieldLabel(store.activeProvider?.kind == .modelHub ? "ModelHub 回环地址" : "厂商 API 基址")
                            TextField(store.activeProvider?.kind.defaultBaseURL ?? "https://api.example.com/v1", text: $draftURL)
                                .textFieldStyle(.roundedBorder)
                            Text(store.activeProvider?.kind == .modelHub
                                 ? "ModelHub 只允许 localhost、127.0.0.1 或 ::1；连接测试成功后才会保存。"
                                 : "厂商直连必须使用 HTTPS，且不能指向回环、局域网或云元数据地址。")
                                .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                            FieldLabel(store.activeProvider?.kind == .modelHub ? "网关 Bearer Token" : "API Key")
                            SecureField("保存在 macOS Keychain", text: $draftToken).textFieldStyle(.roundedBorder)
                            Text("密钥不会写入项目、历史、日志或导出包；留空会沿用当前连接已保存的密钥。")
                                .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                            if let detail = store.connection.detail { Label(detail, systemImage: "exclamationmark.triangle.fill").font(.vsBody(11)).foregroundStyle(VSColor.vermilion) }
                            Divider()
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(VSColor.moss)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("推荐安装 ModelHub（非必需）").font(.vsLabel(12))
                                    Text("需要统一管理多家厂商、自动发现模型，或接入没有统一协议的图片与视频接口时，可通过 ModelHub 路由；厂商直连仍可独立使用。")
                                        .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                                    Link("在 App Store 查看 ModelHub", destination: ProviderRecommendation.modelHubAppStoreURL)
                                        .font(.vsLabel(10)).foregroundStyle(VSColor.vermilion)
                                }
                            }
                        }
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: 9) {
                            FieldLabel("能力读取")
                            if let status = store.modelHubStatus {
                                Text("\(status.service) 在线 · \(status.providerCount) 个供应商 · \(status.routeCount) 条路由")
                                    .font(.vsBody(11)).foregroundStyle(VSColor.moss)
                            }
                            metric("当前连接模型", store.models.count)
                            metric("结构化声明", store.capabilities.values.filter { $0.source == .modelHub }.count)
                            metric("本地档案", store.capabilities.values.filter { $0.source == .localProfile }.count)
                            metric("内置匹配", store.bundledProfileModels.count)
                            metric("当前不支持", store.unsupportedModels.count)
                            metric("尚未匹配", store.unresolvedModels.count)
                            HStack {
                                Text("匹配覆盖")
                                Spacer()
                                Text("\(store.models.count - store.unresolvedModels.count) / \(store.models.count)")
                                    .foregroundStyle(store.unresolvedModels.isEmpty ? VSColor.moss : VSColor.orange)
                            }.font(.vsLabel(12))
                            Text("优先使用当前连接返回的结构化能力；其余目录项可采用内置高置信匹配或由你确认本地档案。不支持的能力会明确标记且不能误选。")
                                .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                            Divider()
                            HStack {
                                Text(store.billingGate.title).font(.vsLabel(11))
                                Spacer()
                                Text(store.billingGate.allowsRequest ? "门控开放" : "门控关闭").font(.vsBody(11)).foregroundStyle(store.billingGate.allowsRequest ? VSColor.moss : VSColor.vermilion)
                            }
                            if let detail = store.billingGate.detail { Text(detail).font(.vsBody(11)).foregroundStyle(VSColor.vermilion) }
                        }
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: 12) {
                            FieldLabel("性能与任务预算")
                            HStack {
                                Text("上下文输入预算").font(.vsBody(12))
                                Spacer()
                                Picker("上下文输入预算", selection: $draftContextBudgetTokens) {
                                    ForEach([4_096, 8_192, 16_384, 32_768, 65_536], id: \.self) { Text("\($0 / 1_024)K token").tag($0) }
                                }.labelsHidden().frame(width: 150)
                            }
                            HStack {
                                Text("生成任务并发").font(.vsBody(12))
                                Spacer()
                                Stepper("\(draftConcurrency) 个", value: $draftConcurrency, in: 1...4).frame(width: 130)
                            }
                            Toggle("任务完成后发送本机通知", isOn: $draftNotifications).toggleStyle(.switch)
                            Text("只在“测试连接并保存”成功后请求 macOS 通知权限；关闭不会触发系统提示。")
                                .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                            if let report = store.lastContextBudgetReport {
                                Text("上次请求约 \(report.estimatedTokens) token；保留 \(report.includedMessageCount) 条、裁掉 \(report.droppedMessageCount) 条历史。")
                                    .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                            }
                            Text("上下文按中英文混合文本保守估算；并发统计包含仍在排队和生成中的图片/视频任务。")
                                .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                        }
                    }
                    Text("模型能力档案").font(.vsTitle(19))
                    StudioCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                TextField("搜索模型或供应商", text: $modelQuery).textFieldStyle(.roundedBorder)
                                Picker("范围", selection: $modelScope) {
                                    ForEach(["全部", "路由", "可执行", "暂不支持", "未匹配"], id: \.self) { Text($0).tag($0) }
                                }.frame(width: 110)
                                Button { showingCapabilityWizard = true } label: { Label("配置向导", systemImage: "wand.and.stars") }
                                    .disabled(store.capabilityCandidates.isEmpty)
                                Button { showingManualModelEditor = true } label: { Label("添加模型", systemImage: "plus") }
                            }
                            Text("显示 \(filteredModels.count) / \(store.models.count) 项；厂商目录不完整时可手动登记任意模型 ID 和能力。")
                                .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                            if store.models.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "cpu").font(.system(size: 28, weight: .light)).foregroundStyle(VSColor.muted)
                                    Text("当前连接还没有模型").font(.vsLabel(12))
                                    Text("先连接厂商，或手动添加模型 ID。").font(.vsBody(10)).foregroundStyle(VSColor.muted)
                                }.frame(maxWidth: .infinity).padding(.vertical, 28)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(filteredModels) { model in
                                        ModelCapabilitySummaryRow(
                                            model: model,
                                            profile: store.profile(for: model.id),
                                            onRefresh: { Task { await store.refreshCapability(for: model.id) } },
                                            onEdit: { editingModel = model },
                                            onReset: { store.resetCustomCapability(modelID: model.id) },
                                            onDelete: model.isManual ? { manualModelDeleteTarget = model } : nil
                                        )
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: 10) {
                            FieldLabel("隐私与第三方 AI")
                            Text("对话、提示词与你主动选择的参考图会直接发送给当前厂商，或由你选择的 ModelHub 路由。直连 API Key 仅保存在 macOS Keychain。")
                                .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                            HStack {
                                Text(store.requiresThirdPartyAIConsent ? "未授权后续发送" : "已授权后续发送")
                                    .font(.vsLabel(11))
                                    .foregroundStyle(store.requiresThirdPartyAIConsent ? VSColor.vermilion : VSColor.moss)
                                Spacer()
                                if store.requiresThirdPartyAIConsent {
                                    Button("查看并授权") { store.showingThirdPartyAIConsent = true }
                                } else {
                                    Button("撤回授权", role: .destructive) { store.revokeThirdPartyAIConsent() }
                                }
                            }
                            HStack(spacing: 14) {
                                Link("隐私政策", destination: ThirdPartyAIConsentPolicy.privacyPolicyURL)
                                Link("使用条款", destination: ThirdPartyAIConsentPolicy.termsURL)
                            }.font(.vsBody(11))
                        }
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: 10) {
                            FieldLabel("本地历史")
                            Text("清空操作会删除生成任务和映栈媒体目录中的归档文件。").font(.vsBody(11)).foregroundStyle(VSColor.muted)
                            Button("清空生成历史与媒体", role: .destructive) { confirmClear = true }
                        }
                    }
                    HStack {
                        Button("取消") { dismiss() }; Spacer()
                        Button(saving ? "正在测试…" : "测试连接并保存") {
                            saving = true
                            Task {
                                let ok = await store.saveSettings(
                                    baseURL: draftURL,
                                    token: draftToken,
                                    contextBudgetTokens: draftContextBudgetTokens,
                                    maxConcurrentGenerationTasks: draftConcurrency,
                                    completionNotificationsEnabled: draftNotifications
                                )
                                saving = false
                                if ok { dismiss() }
                            }
                        }.buttonStyle(PrimaryButtonStyle()).disabled(saving)
                    }
                }.padding(24)
            }
        }
        .frame(width: 820, height: 760).background(PaperBackground())
        .onAppear {
            syncProviderDrafts()
            draftContextBudgetTokens = store.contextBudgetTokens
            draftConcurrency = store.maxConcurrentGenerationTasks
            draftNotifications = store.completionNotificationsEnabled
        }
        .onDisappear { Task { await store.flushPersistence() } }
        .sheet(item: $editingModel) { model in
            CapabilityEditorSheet(model: model, profile: store.profile(for: model.id)).environmentObject(store)
        }
        .sheet(isPresented: $showingCapabilityWizard) { CapabilityWizardSheet().environmentObject(store) }
        .sheet(isPresented: $showingProviderEditor) { ProviderConnectionEditorSheet().environmentObject(store) }
        .sheet(isPresented: $showingManualModelEditor) { ManualModelEditorSheet().environmentObject(store) }
        .confirmationDialog("清空全部生成历史？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空历史和媒体", role: .destructive) { Task { await store.clearGenerationHistory() } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "移除厂商连接？",
            isPresented: Binding(get: { providerDeleteTarget != nil }, set: { if !$0 { providerDeleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: providerDeleteTarget
        ) { provider in
            Button("移除 \(provider.displayName)", role: .destructive) {
                Task {
                    _ = await store.removeProviderConnection(provider.id)
                    syncProviderDrafts()
                    providerDeleteTarget = nil
                }
            }
            Button("取消", role: .cancel) { providerDeleteTarget = nil }
        } message: { _ in
            Text("会删除该连接及其 Keychain 密钥，不会删除其他厂商连接、ModelHub 推荐项或已生成作品。")
        }
        .confirmationDialog(
            "移除手动模型？",
            isPresented: Binding(get: { manualModelDeleteTarget != nil }, set: { if !$0 { manualModelDeleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: manualModelDeleteTarget
        ) { model in
            Button("移除 \(model.id)", role: .destructive) {
                _ = store.removeManualModel(modelID: model.id)
                manualModelDeleteTarget = nil
            }
            Button("取消", role: .cancel) { manualModelDeleteTarget = nil }
        } message: { _ in
            Text("只移除当前连接中的手动模型与本地能力档案，不会删除厂商连接或远端模型。")
        }
    }

    private func selectProvider(_ providerID: UUID?) {
        guard let providerID, providerID != store.selectedProviderID else { return }
        saving = true
        Task {
            await store.selectProvider(providerID)
            syncProviderDrafts()
            saving = false
        }
    }

    private func syncProviderDrafts() {
        draftURL = store.baseURL
        draftToken = store.token
    }

    private func metric(_ title: String, _ count: Int) -> some View {
        HStack { Text(title).font(.vsBody(12)); Spacer(); Text("\(count)").font(.vsLabel(12)) }
    }
}

private struct ModelCapabilitySummaryRow: View {
    let model: ModelDescriptor
    let profile: CapabilityProfile?
    let onRefresh: () -> Void
    let onEdit: () -> Void
    let onReset: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isRoute ? "point.3.connected.trianglepath.dotted" : "cpu")
                .foregroundStyle(model.isRoute ? VSColor.vermilion : VSColor.muted).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.id).font(.vsLabel(11)).lineLimit(1).textSelection(.enabled)
                HStack(spacing: 7) {
                    Text(model.owner)
                    if model.isRoute { Text("路由") }
                    if !model.isAvailable { Text("不可用").foregroundStyle(VSColor.vermilion) }
                    Text(profile?.source.rawValue ?? "尚未配置")
                }.font(.vsBody(10)).foregroundStyle(VSColor.muted)
            }
            Spacer()
            if let profile, !profile.operations.isEmpty {
                Text(profile.operations.map(\.title).sorted().joined(separator: " · ")).font(.vsBody(10)).foregroundStyle(VSColor.moss)
            }
            Button("读取声明", action: onRefresh).buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
            if profile?.source == .localProfile {
                Button("恢复内置", action: onReset).buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
            }
            Button("编辑", action: onEdit).buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
            if let onDelete {
                Button("移除", role: .destructive, action: onDelete).buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
            }
        }.padding(.vertical, 9)
    }
}

private struct CapabilityWizardSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var confirming = false

    private var candidates: [ModelDescriptor] {
        store.capabilityCandidates.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("能力配置向导").font(.vsTitle(23))
                    Text("名称匹配只生成候选；必须勾选并确认后才采用。").font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }.padding(22)
            Divider()
            if candidates.isEmpty {
                EmptyStudioState(symbol: "checkmark.seal", title: "没有待确认候选", detail: "ModelHub 已声明或本地已配置的模型不会重复出现。")
            } else {
                List(candidates) { model in
                    let profile = CapabilityRegistry.profile(for: model.id)
                    HStack(spacing: 12) {
                        Toggle("选择", isOn: Binding(
                            get: { selected.contains(model.id) },
                            set: { if $0 { selected.insert(model.id) } else { selected.remove(model.id) } }
                        )).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.id).font(.vsLabel(11)).textSelection(.enabled)
                            Text("候选能力：\(profile.operations.map(\.title).sorted().joined(separator: " · "))")
                                .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                            if profile.operations.contains(.image) { Text("图片：\(profile.imageSizes.joined(separator: ", ")) · \(profile.qualities.joined(separator: ", "))").font(.vsBody(9)).foregroundStyle(VSColor.muted) }
                            if profile.operations.contains(.video) { Text("视频：\(profile.videoResolutions.joined(separator: ", ")) · \(profile.aspectRatios.joined(separator: ", ")) · \(profile.durations.map(String.init).joined(separator: ", ")) 秒").font(.vsBody(9)).foregroundStyle(VSColor.muted) }
                        }
                        Spacer()
                        Button("单独编辑") { store.notice = "关闭向导后可在模型列表中逐项编辑参数。" }.buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
                    }.padding(.vertical, 6)
                }.scrollContentBackground(.hidden)
            }
            HStack {
                Button("全选候选") { selected = Set(candidates.map(\.id)) }.disabled(candidates.isEmpty)
                Spacer()
                Text("已选 \(selected.count) 项").font(.vsBody(11)).foregroundStyle(VSColor.muted)
                Button("确认采用") { confirming = true }.buttonStyle(PrimaryButtonStyle()).disabled(selected.isEmpty)
            }.padding(18)
        }
        .frame(width: 800, height: 660)
        .background(PaperBackground())
        .confirmationDialog("采用所选本地能力档案？", isPresented: $confirming, titleVisibility: .visible) {
            Button("采用 \(selected.count) 个候选") { store.adoptCapabilityCandidates(selected); dismiss() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这是本机兼容档案，不代表 ModelHub 或供应商已验证。生成前仍会显示模型、参数和可能计费确认。")
        }
    }
}

private struct CapabilityEditorSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let model: ModelDescriptor
    @State private var operations: Set<CreativeOperation>
    @State private var sizes: String
    @State private var qualities: String
    @State private var resolutions: String
    @State private var ratios: String
    @State private var durations: String
    @State private var supportsReferenceImage: Bool

    init(model: ModelDescriptor, profile: CapabilityProfile?) {
        self.model = model
        let value = profile ?? CapabilityRegistry.profile(for: model.id)
        _operations = State(initialValue: value.operations)
        _sizes = State(initialValue: value.imageSizes.joined(separator: ", "))
        _qualities = State(initialValue: value.qualities.joined(separator: ", "))
        _resolutions = State(initialValue: value.videoResolutions.joined(separator: ", "))
        _ratios = State(initialValue: value.aspectRatios.joined(separator: ", "))
        _durations = State(initialValue: value.durations.map(String.init).joined(separator: ", "))
        _supportsReferenceImage = State(initialValue: value.supportsReferenceImage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("模型能力档案").font(.vsTitle(22)); Spacer(); Button("关闭") { dismiss() } }
            StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading) { Text(model.id).font(.vsLabel(12)).textSelection(.enabled); Text(model.owner).font(.vsBody(11)).foregroundStyle(VSColor.muted) }
                    Spacer()
                }
                HStack {
                    ForEach(CreativeOperation.allCases) { op in
                        Toggle(op.title, isOn: Binding(get: { operations.contains(op) }, set: { if $0 { operations.insert(op) } else { operations.remove(op) } })).toggleStyle(.checkbox)
                    }
                }
                if operations.contains(.image) { HStack { field("图片尺寸", $sizes, "1024x1024"); field("质量", $qualities, "auto, high") } }
                if operations.contains(.video) { HStack { field("分辨率", $resolutions, "720p"); field("比例", $ratios, "16:9"); field("时长", $durations, "5, 8") } }
                if operations.contains(.image) || operations.contains(.video) {
                    Toggle("支持参考图输入", isOn: $supportsReferenceImage).toggleStyle(.checkbox)
                }
            }
            }
            HStack {
                Button("重新读取 ModelHub 声明") { Task { await store.refreshCapability(for: model.id) } }
                if store.profile(for: model.id)?.source == .localProfile {
                    Button("删除本地档案") { store.resetCustomCapability(modelID: model.id); dismiss() }
                        .foregroundStyle(VSColor.vermilion)
                }
                Spacer(); Button("取消") { dismiss() }
                Button("保存本地档案") { save(); dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24).frame(width: 680).background(PaperBackground())
    }

    private func field(_ label: String, _ text: Binding<String>, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { FieldLabel(label); TextField(hint, text: text).textFieldStyle(.roundedBorder) }
    }
    private func list(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func save() {
        store.saveCustomCapability(modelID: model.id, operations: operations, imageSizes: list(sizes), qualities: list(qualities),
            videoResolutions: list(resolutions), aspectRatios: list(ratios), durations: list(durations).compactMap(Int.init), supportsReferenceImage: supportsReferenceImage)
    }
}

struct ResourceLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var previewResource: ImportedResource?
    @State private var deleteTarget: ImportedResource?
    private var agents: [ImportedResource] { store.resources.filter { $0.kind == .agent } }
    private var filtered: [ImportedResource] {
        query.isEmpty ? agents : agents.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.classifiedMediaDomains.contains { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("创作 Agents").font(.vsTitle(24))
                    Text("\(store.installedAgentCount) 个 Agent · 底层托管 \(store.managedCapabilityModuleCount) 个能力模块")
                        .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
                Spacer(); Button("关闭") { dismiss() }
            }.padding(22)
            Divider()
            HStack {
                TextField("搜索 Agent 或能力", text: $query).textFieldStyle(.roundedBorder)
                Button { Task { await store.importLocalMediaSkills() } } label: { Label("同步本机创作 Agents", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(PrimaryButtonStyle())
            }.padding(18)
            if filtered.isEmpty { EmptyStudioState(symbol: "person.2.slash", title: "还没有创作 Agent", detail: "点击同步，把本机已审查的图片与视频能力装配为可选择的 Agent。") }
            else {
                List(filtered) { resource in
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.square.filled.and.at.rectangle").foregroundStyle(VSColor.vermilion)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(resource.name).font(.vsLabel(12))
                                ForEach(resource.classifiedMediaDomains.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { domain in
                                    Text(domain.title).font(.vsBody(9)).foregroundStyle(domain == .utility ? VSColor.muted : VSColor.moss)
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(VSColor.canvas.opacity(0.75)).clipShape(Capsule())
                                }
                            }
                            Text(resource.summary).font(.vsBody(11)).foregroundStyle(VSColor.muted).lineLimit(2)
                            Text("自动托管 \(store.availableCapabilityModuleCount(for: resource)) 个当前可用能力模块")
                                .font(.vsBody(10)).foregroundStyle(VSColor.moss)
                        }
                        Spacer()
                        Button("详情") { previewResource = resource }.buttonStyle(.plain).foregroundStyle(VSColor.vermilion)
                        Toggle("启用", isOn: Binding(get: { resource.enabled }, set: { _ in store.toggleResource(resource) })).labelsHidden()
                        Button(role: .destructive) { deleteTarget = resource } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }.padding(.vertical, 7)
                }.scrollContentBackground(.hidden)
            }
            HStack { Image(systemName: "lock.shield"); Text("底层能力只由 Agent 受控调用；执行声明保持禁用，脚本、Hook 和 MCP 不会运行。") }.font(.vsBody(11)).foregroundStyle(VSColor.muted).padding(14)
        }.frame(width: 820, height: 680).background(PaperBackground())
        .sheet(item: $previewResource) { resource in ResourceDetailSheet(resource: resource) }
        .confirmationDialog("删除创作 Agent？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("删除本地 Agent 索引", role: .destructive) {
                if let resource = deleteTarget { store.deleteResource(resource) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("只删除映栈中的 Agent 索引，不会删除本机底层能力文件；再次同步可恢复。")
        }
    }
}

private struct ResourceDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let resource: ImportedResource

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(resource.name).font(.vsTitle(23))
                    Text("Agent · \(resource.classifiedMediaDomains.map(\.title).sorted().joined(separator: " / ").isEmpty ? "通用" : resource.classifiedMediaDomains.map(\.title).sorted().joined(separator: " / ")) · 托管 \(resource.assignedSkillIDs.count) 个能力模块")
                        .font(.vsBody(11)).foregroundStyle(VSColor.moss)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }.padding(22)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                FieldLabel("摘要")
                Text(resource.summary).font(.vsBody(12)).textSelection(.enabled)
                FieldLabel("能力说明")
                ScrollView { Text(resource.instructions).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                    .background(Color.white.opacity(0.62)).clipShape(RoundedRectangle(cornerRadius: 10))
                Label("底层能力内容属于不可信输入，不能覆盖映栈安全边界；脚本、Hook 和 MCP 不会执行。", systemImage: "lock.shield")
                    .font(.vsBody(10)).foregroundStyle(VSColor.muted)
            }.padding(22)
        }
        .frame(width: 820, height: 680)
        .background(PaperBackground())
    }
}
