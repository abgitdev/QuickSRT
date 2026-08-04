import AppKit
import SwiftUI

@main
struct QuickSRTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear {
                    appDelegate.installShutdownHandler {
                        model.stopForShutdown()
                    }
                    var cleanup = TempWorkspace.cleanStaleJobs()
                    cleanup.merge(ModelStorage.cleanPartialDownloads())
                    model.presentCleanupReportIfNeeded(cleanup)
                    model.refreshModelStatus()
                }
                .onDisappear {
                    model.stopForShutdown()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(model.text(.aboutQuickSRT)) {
                    AboutPanel.show(model: model)
                }
            }
            CommandGroup(after: .appInfo) {
                Divider()
                Button(model.text(.deleteQuickSRTData)) {
                    model.requestDeleteQuickSRTData()
                }
                Button(model.text(.uninstallQuickSRT)) {
                    model.requestUninstallQuickSRT()
                }
            }
        }
    }
}

@MainActor
private enum AboutPanel {
    private static var windowController: NSWindowController?

    static func show(model: AppViewModel) {
        if windowController == nil {
            let content = AboutView()
                .environmentObject(model)
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.title = "QuickSRT"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 430, height: 340))
            window.center()
            windowController = NSWindowController(window: window)
        }

        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        let versionText = AppVersionInfo().displayText(language: model.appLanguage)
        let accessibilityText = TextKey.applicationAccessibilityFormat.formatted(
            language: model.appLanguage,
            arguments: [versionText]
        )

        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 82, height: 82)
                .accessibilityHidden(true)

            Text("QuickSRT")
                .font(.system(size: 24, weight: .semibold, design: .rounded))

            Text(versionText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel(accessibilityText)

            Text(model.text(.tagline))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 360)

            Divider()
                .padding(.horizontal, 34)

            HStack(spacing: 18) {
                Link("GitHub", destination: AppLinks.github)
                Link(model.text(.supportDevelopment), destination: AppLinks.koFi)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.top, 34)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(width: 430, height: 340)
        .background(.ultraThinMaterial)
        .environment(\.locale, Locale(identifier: model.appLanguage.localeIdentifier))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shutdownHandler: (() -> Void)?

    func installShutdownHandler(_ handler: @escaping () -> Void) {
        shutdownHandler = handler
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppLifecycleState.isDestructiveExit else { return .terminateNow }
        shutdownHandler?()
        let remainingPIDs = ProcessRegistry.shared.terminateAllAndWait()
        guard remainingPIDs.isEmpty else { return .terminateCancel }
        Self.cleanOwnedTransientData()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Failsafe for destructive exits and termination paths that bypassed the
        // normal handshake. Ordinary Cmd-Q has already emptied the registry.
        ProcessRegistry.shared.terminateAll()
    }

    private static func cleanOwnedTransientData() {
        if FileManager.default.fileExists(atPath: ProjectPaths.tempRoot.path) {
            _ = TempWorkspace.cleanStaleJobs()
        }
        if FileManager.default.fileExists(atPath: ProjectPaths.mlxWhisperModelsRoot.path) {
            _ = ModelStorage.cleanPartialDownloads()
        }
    }
}
