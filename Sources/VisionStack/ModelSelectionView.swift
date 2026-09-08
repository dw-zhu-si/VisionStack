import SwiftUI

struct ModelSelectionControl: View {
    @EnvironmentObject private var store: AppStore
    let operation: CreativeOperation
    @Binding var selection: String
    @State private var showingDirectory = false

    var body: some View {
        Button { showingDirectory = true } label: {
            HStack(spacing: 9) {
                Image(systemName: operationSymbol)
                    .foregroundStyle(VSColor.vermilion)
                Text(selection.isEmpty ? "选择\(operation.title)模型" : selection)
                    .font(.vsBody(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(store.availableModels.count) 个")
                    .font(.vsBody(9))
                    .foregroundStyle(VSColor.muted)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VSColor.muted)
            }
            .foregroundStyle(VSColor.ink)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(Color.white.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(VSColor.ink.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(store.availableModels.isEmpty)
        .accessibilityLabel("选择\(operation.title)模型，当前为\(selection.isEmpty ? "未选择" : selection)，共 \(store.availableModels.count) 个可用模型")
        .sheet(isPresented: $showingDirectory) {
            ModelSelectionSheet(operation: operation, selection: $selection)
                .environmentObject(store)
        }
    }

    private var operationSymbol: String {
        switch operation {
        case .chat: "text.bubble"
        case .image: "photo"
        case .video: "film"
        }
    }
}

private struct ModelSelectionSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let operation: CreativeOperation
    @Binding var selection: String
    @State private var query = ""
    @State private var scope = "全部"

    private var allModels: [ModelDescriptor] { store.selectableModels(for: operation) }
    private var filteredModels: [ModelDescriptor] {
        allModels.filter { model in
            let matchesQuery = query.isEmpty
                || model.id.localizedCaseInsensitiveContains(query)
                || model.owner.localizedCaseInsensitiveContains(query)
            let profile = store.profile(for: model.id) ?? CapabilityRegistry.profile(for: model.id)
            let matchesScope = switch scope {
            case "可用于当前": profile.isConfigured && profile.operations.contains(operation)
            case "正式/本地": [.modelHub, .localProfile].contains(profile.source) && profile.operations.contains(operation)
            default: true
            }
            return matchesQuery && matchesScope
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("选择\(operation.title)模型").font(.vsTitle(23))
                    Text("当前厂商或 ModelHub 的可用目录完整显示；能力匹配模型排在前面，不兼容项可查看但不能误选。")
                        .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding(22)

            Divider()

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    TextField("搜索模型 ID 或供应商", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Picker("范围", selection: $scope) {
                        ForEach(["全部", "可用于当前", "正式/本地"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 245)
                }
                HStack {
                    Text("显示 \(filteredModels.count) / \(allModels.count) 个可用模型")
                    Spacer()
                    if !selection.isEmpty { Text("当前：\(selection)").lineLimit(1).truncationMode(.middle) }
                }
                .font(.vsBody(10)).foregroundStyle(VSColor.muted)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)

            List(filteredModels) { model in
                Button { choose(model) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selection == model.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection == model.id ? VSColor.vermilion : VSColor.muted)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.id).font(.vsLabel(11)).lineLimit(1).truncationMode(.middle)
                            Text(model.owner).font(.vsBody(9)).foregroundStyle(VSColor.muted)
                        }
                        Spacer()
                        Text(status(for: model))
                            .font(.vsBody(9))
                            .foregroundStyle(statusColor(for: model))
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .disabled(!store.canSelectModel(model.id, for: operation))
                .accessibilityLabel("选择模型 \(model.id)，\(status(for: model))")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Divider()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                Text("496 个目录模型均显示匹配状态：正式声明、本地档案、内置高置信匹配或当前不支持。映栈不会因点选而静默扩充模型能力；图片和视频创建前仍会显示模型、参数和可能计费确认。")
                    .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                Spacer()
            }
            .padding(18)
        }
        .frame(width: 820, height: 680)
        .background(PaperBackground())
    }

    private func choose(_ model: ModelDescriptor) {
        if store.selectModel(model.id, for: operation) {
            selection = model.id
            dismiss()
        }
    }

    private func status(for model: ModelDescriptor) -> String {
        let profile = store.profile(for: model.id) ?? CapabilityRegistry.profile(for: model.id)
        if profile.isConfigured && profile.operations.contains(operation) { return profile.source.rawValue }
        if profile.source == .unsupported { return profile.source.rawValue }
        if profile.source == .unknown { return "尚未匹配" }
        if !profile.operations.isEmpty { return "仅支持\(profile.operations.map(\.title).sorted().joined(separator: " · "))" }
        return profile.source.rawValue
    }

    private func statusColor(for model: ModelDescriptor) -> Color {
        let profile = store.profile(for: model.id) ?? CapabilityRegistry.profile(for: model.id)
        return profile.isConfigured && profile.operations.contains(operation) ? VSColor.moss : VSColor.muted
    }
}
