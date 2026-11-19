import AppKit
import SwiftUI

@main
struct ImlaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            MenuIcon(controller: delegate.controller)
        }
        Window("Imla Settings", id: "settings") {
            SettingsView(controller: delegate.controller)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private var overlay: OverlayWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayWindow(controller: controller)
        NotificationCenter.default.addObserver(forName: .imlaHotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.registerHotkey() }
        }
    }
}

private struct MenuIcon: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        Image(systemName: controller.phase == .listening ? "waveform.circle.fill" : "waveform")
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(controller.phase == .listening ? "Stop Dictation" : "Start Dictation  (\(controller.config.hotkey.displayString))") {
            controller.toggle()
        }
        Toggle("Polish with LLM", isOn: $controller.config.llmCleanup)
        Menu("Recent Dictations") {
            if controller.history.isEmpty {
                Text("None yet")
            }
            // Click to copy. The full text is in Settings → History.
            ForEach(controller.history.prefix(10)) { item in
                Button(Self.title(item)) { controller.copy(item.final) }
            }
            Divider()
            Button("Show History…") { openSettings(tab: 2) }
        }
        Divider()
        Button("Settings…") { openSettings(tab: 0) }
        .keyboardShortcut(",")
        Button("Quit Imla") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func openSettings(tab: Int) {
        controller.settingsTab = tab
        openWindow(id: "settings")
        NSApp.activate()
    }

    private static func title(_ item: HistoryItem) -> String {
        let text = item.final.replacingOccurrences(of: "\n", with: " ")
        return text.count > 60 ? text.prefix(60) + "…" : text
    }
}

/// SwiftUI's `@State` macro needs Xcode's macro plugin, which the Command Line
/// Tools lack. The underlying property wrapper works the same.
typealias ViewState = SwiftUI.State
