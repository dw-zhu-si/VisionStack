import AppKit
import SwiftUI

@MainActor
private final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()
    weak var store: AppStore?
}

private final class VisionStackAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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

private struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("显示映栈主窗口") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}

@main
struct VisionStackApp: App {
    @NSApplicationDelegateAdaptor(VisionStackAppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore

    init() {
        #if DEBUG
        if UIAuditHarness.isEnabled {
            _store = StateObject(wrappedValue: UIAuditHarness.makeStore())
            return
        }
        #endif
        _store = StateObject(wrappedValue: AppStore(
            automaticallyImportsLocalMediaSkills: CommandLine.arguments.contains("--import-local-media-skills"),
            distributionProfile: .current
        ))
    }

    var body: some Scene {
        Window("映栈", id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1060, minHeight: 700)
                .preferredColorScheme(.light)
                .task {
                    #if DEBUG
                    if UIAuditHarness.isEnabled { await store.flushPersistence(); return }
                    #endif
                    await store.bootstrap()
                }
                .onAppear { AppTerminationCoordinator.shared.store = store }
        }
        .defaultSize(width: 1380, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            MainWindowCommands()
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(store.persistenceBlockReason != nil)
            }
            CommandGroup(replacing: .newItem) {
                Button("新建对话") { store.createConversation(); store.requestStudio(.chat) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.persistenceBlockReason != nil)
            }
            CommandMenu("创作") {
                ForEach(StudioMode.allCases) { mode in
                    Button("切换到\(mode.title)") { store.requestStudio(mode) }
                        .keyboardShortcut(KeyEquivalent(mode.shortcut), modifiers: .command)
                        .disabled(store.persistenceBlockReason != nil)
                }
            }
        }
    }
}
