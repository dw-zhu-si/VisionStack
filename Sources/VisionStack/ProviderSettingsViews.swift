import Foundation
import SwiftUI

struct ProviderConnectionEditorSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var kind: AIProviderKind = .openAICompatible
    @State private var baseURL = AIProviderKind.openAICompatible.defaultBaseURL
    @State private var apiKey = ""
    @State private var manualModelIDs = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加模型厂商").font(.vsTitle(22))
                    Text("任意厂商名称均可；协议决定请求格式，密钥只写入 Keychain。")
                        .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            StudioCard {
                VStack(alignment: .leading, spacing: 12) {
                    FieldLabel("连接协议")
                    Picker("连接协议", selection: $kind) {
                        ForEach(AIProviderKind.allCases) { value in Text(value.title).tag(value) }
                    }
                    .labelsHidden()
                    .onChange(of: kind) { oldValue, newValue in
                        if baseURL.isEmpty || baseURL == oldValue.defaultBaseURL { baseURL = newValue.defaultBaseURL }
                        if displayName.isEmpty { displayName = newValue.title }
                    }
                    Text(kind.summary).font(.vsBody(11)).foregroundStyle(VSColor.muted)

                    FieldLabel("厂商显示名称")
                    TextField("例如：我的图片厂商", text: $displayName).textFieldStyle(.roundedBorder)

                    FieldLabel(kind == .modelHub ? "ModelHub 回环地址" : "厂商 API 基址")
                    TextField(kind.defaultBaseURL, text: $baseURL).textFieldStyle(.roundedBorder)

                    FieldLabel(kind == .modelHub ? "网关 Bearer Token" : "API Key")
                    SecureField("只保存在 macOS Keychain", text: $apiKey).textFieldStyle(.roundedBorder)

                    FieldLabel("手动模型 ID（可选，每行一个）")
                    TextEditor(text: $manualModelIDs)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 92)
                        .padding(7)
                        .background(VSColor.canvas.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("当厂商模型目录为空或不完整时使用。模型能力仍需在映栈中确认；视频接口不统一的厂商建议交给 ModelHub 路由。")
                        .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                }
            }
            HStack(spacing: 12) {
                Link(destination: ProviderRecommendation.modelHubAppStoreURL) {
                    Label("在 App Store 查看 ModelHub", systemImage: "arrow.down.app")
                }
                Spacer()
                Button("取消") { dismiss() }
                Button(saving ? "正在测试…" : "测试连接并保存") {
                    saving = true
                    Task {
                        let ok = await store.saveProviderConnection(
                            displayName: displayName,
                            kind: kind,
                            baseURL: baseURL,
                            apiKey: apiKey,
                            manualModelIDs: parsedModelIDs
                        )
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(saving || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 650)
        .background(PaperBackground())
    }

    private var parsedModelIDs: [String] {
        manualModelIDs
            .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct ManualModelEditorSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var providerName = ""
    @State private var modelID = ""
    @State private var operations: Set<CreativeOperation> = [.chat]
    @State private var imageSizes = "1024x1024"
    @State private var qualities = "auto"
    @State private var videoResolutions = "720p"
    @State private var aspectRatios = "16:9"
    @State private var durations = "5"
    @State private var supportsReferenceImage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加任意厂商模型").font(.vsTitle(22))
                    Text("模型只加入当前连接；映栈不会把 API Key 写入项目历史。")
                        .font(.vsBody(11)).foregroundStyle(VSColor.muted)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            StudioCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            FieldLabel("厂商")
                            TextField("任意厂商名称", text: $providerName).textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            FieldLabel("模型 ID")
                            TextField("provider/model-id", text: $modelID).textFieldStyle(.roundedBorder)
                        }
                    }
                    FieldLabel("能力")
                    HStack {
                        ForEach(CreativeOperation.allCases) { operation in
                            Toggle(operation.title, isOn: Binding(
                                get: { operations.contains(operation) },
                                set: { enabled in
                                    if enabled { operations.insert(operation) }
                                    else { operations.remove(operation) }
                                }
                            )).toggleStyle(.checkbox)
                        }
                    }
                    if operations.contains(.image) {
                        HStack {
                            field("图片尺寸", $imageSizes, "1024x1024")
                            field("质量", $qualities, "auto, high")
                        }
                    }
                    if operations.contains(.video) {
                        HStack {
                            field("分辨率", $videoResolutions, "720p")
                            field("比例", $aspectRatios, "16:9")
                            field("时长（秒）", $durations, "5, 8")
                        }
                    }
                    if operations.contains(.image) || operations.contains(.video) {
                        Toggle("支持参考图输入", isOn: $supportsReferenceImage).toggleStyle(.checkbox)
                    }
                    Text("能力档案表示请求参数兼容性，不代表厂商已由映栈验证。真实调用前仍会显示计费与数据发送确认。")
                        .font(.vsBody(10)).foregroundStyle(VSColor.muted)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加模型") {
                    if store.registerManualModel(
                        providerName: providerName,
                        modelID: modelID,
                        operations: operations,
                        imageSizes: list(imageSizes),
                        qualities: list(qualities),
                        videoResolutions: list(videoResolutions),
                        aspectRatios: list(aspectRatios),
                        durations: list(durations).compactMap(Int.init),
                        supportsReferenceImage: supportsReferenceImage
                    ) { dismiss() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || operations.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 680)
        .background(PaperBackground())
        .onAppear { if providerName.isEmpty { providerName = store.activeProvider?.displayName ?? "" } }
    }

    private func field(_ label: String, _ value: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label)
            TextField(placeholder, text: value).textFieldStyle(.roundedBorder)
        }
    }

    private func list(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
