import AppKit
import SwiftUI

@MainActor
private final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()
    weak var store: AppStore?
}

private final class VisionStackAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            if let store = AppTerminationCoordinator.shared.store { await store.flushPersistence() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct VisionStackApp: App {
    @NSApplicationDelegateAdaptor(VisionStackAppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore(
        automaticallyImportsLocalMediaSkills: CommandLine.arguments.contains("--import-local-media-skills"),
        distributionProfile: .current
    )

    var body: some Scene {
        WindowGroup("映栈") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1060, minHeight: 700)
                .preferredColorScheme(.light)
                .task { await store.bootstrap() }
                .onAppear { AppTerminationCoordinator.shared.store = store }
        }
        .defaultSize(width: 1380, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(store.persistenceBlockReason != nil)
            }
            CommandGroup(replacing: .newItem) {
                Button("新建对话") { store.createConversation() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.persistenceBlockReason != nil)
            }
            CommandMenu("创作") {
                ForEach(StudioMode.allCases) { mode in
                    Button("切换到\(mode.title)") { store.mode = mode }
                        .keyboardShortcut(KeyEquivalent(mode.shortcut), modifiers: .command)
                        .disabled(store.persistenceBlockReason != nil)
                }
            }
        }
    }
}
