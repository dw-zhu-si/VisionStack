import SwiftUI

enum VSColor {
    static let ink = Color(red: 0.10, green: 0.09, blue: 0.08)
    static let charcoal = Color(red: 0.16, green: 0.14, blue: 0.12)
    static let paper = Color(red: 0.96, green: 0.93, blue: 0.87)
    static let canvas = Color(red: 0.91, green: 0.87, blue: 0.79)
    static let vermilion = Color(red: 0.83, green: 0.20, blue: 0.10)
    static let orange = Color(red: 0.94, green: 0.43, blue: 0.12)
    static let moss = Color(red: 0.29, green: 0.39, blue: 0.25)
    static let muted = Color(red: 0.34, green: 0.31, blue: 0.27)
}
extension Font {
    static func vsTitle(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static func vsBody(_ size: CGFloat) -> Font { .custom("Avenir Next", size: max(size, 11)) }
    static func vsLabel(_ size: CGFloat) -> Font { .custom("Avenir Next Demi Bold", size: max(size, 10)) }
}
struct PaperBackground: View {
    var body: some View {
        ZStack {
            VSColor.paper
            LinearGradient(colors: [Color.white.opacity(0.34), Color.clear, VSColor.orange.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                for x in stride(from: 0.0, through: size.width, by: 44) {
                    for y in stride(from: 0.0, through: size.height, by: 44) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(VSColor.ink.opacity(0.06)))
                    }
                }
            }
        }.ignoresSafeArea()
    }
}
struct StudioCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(18).background(Color.white.opacity(0.74))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(VSColor.ink.opacity(0.12))
                    .allowsHitTesting(false)
            }
    }
}
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.vsLabel(13)).foregroundStyle(isEnabled ? Color.white : VSColor.muted)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(isEnabled ? (configuration.isPressed ? VSColor.charcoal : VSColor.vermilion) : VSColor.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1).opacity(isEnabled ? 1 : 0.62)
    }
}
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.vsLabel(10)).tracking(1.1).foregroundStyle(VSColor.muted) }
}
struct StatusPill: View {
    let title: String; let color: Color
    var body: some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 7, height: 7); Text(title).font(.vsLabel(10)) }
            .foregroundStyle(VSColor.ink)
            .padding(.horizontal, 10).padding(.vertical, 6).background(color.opacity(0.12)).clipShape(Capsule())
    }
}
struct CapabilityNote: View {
    let profile: CapabilityProfile?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: profile == nil ? "minus.circle" : (profile?.source == .modelHub ? "checkmark.seal.fill" : "info.circle.fill"))
            Text(profile?.source.rawValue ?? "未选择模型"); Spacer()
            if profile?.source == .localProfile { Text("可在设置中校正") }
        }
        .font(.vsBody(11)).foregroundStyle(color).padding(10).background(color.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 9))
    }
    private var color: Color { profile == nil ? VSColor.muted : (profile?.source == .modelHub ? VSColor.moss : VSColor.orange) }
}
struct ModelUnavailableCard: View {
    @EnvironmentObject private var store: AppStore
    let operation: CreativeOperation
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: store.connection.isConnected ? "slider.horizontal.3" : "bolt.horizontal.circle").font(.vsLabel(12)).foregroundStyle(VSColor.vermilion)
            Text(detail).font(.vsBody(11)).foregroundStyle(VSColor.muted)
            Button(store.connection.isConnected ? "配置模型能力" : "打开连接设置") { store.showingSettings = true }
                .buttonStyle(.plain).font(.vsLabel(11)).foregroundStyle(VSColor.vermilion)
        }.padding(14).background(VSColor.vermilion.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 11))
    }
    private var title: String { store.connection.isConnected ? "没有已配置的\(operation.title)模型" : "模型服务尚未连接" }
    private var detail: String {
        store.connection.isConnected ? "当前连接尚未声明此能力，可在设置中建立经过确认的本地档案。" : (store.connection.detail ?? "连接厂商 API，或启动 ModelHub 并检查本机地址与 Token 后再继续。")
    }
}
