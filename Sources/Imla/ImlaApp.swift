import AppKit
import Combine
import ImlaCore
import Sparkle
import SwiftUI

@main
struct ImlaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller, updater: delegate.updater)
        } label: {
            MenuIcon(controller: delegate.controller)
        }
        Window("Imla Settings", id: "settings") {
            SettingsView(controller: delegate.controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        // A first launch explains each permission before asking, then downloads the models.
        Window("Welcome to Imla", id: "welcome") {
            WelcomeView(controller: delegate.controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(WelcomeView.isNeeded ? .presented : .suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    let controller = DictationController()
    /// Release builds carry an update feed; local builds don't, so they never replace themselves.
    private(set) var updater: SPUStandardUpdaterController?
    private var overlay: OverlayWindow?
    private var pendingInstall: AnyCancellable?

    override init() {
        super.init()
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
    }

    /// Sparkle installs an update it downloaded in the background when the app quits, and
    /// a menu bar app rarely quits. Until then, Check for Updates offers that download again
    /// instead of looking for a newer release. So install it as soon as Imla is idle.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            // Idle comes after a dictation's paste and clipboard restore.
            pendingInstall = controller.$phase.first { $0 == .idle }.sink { _ in install() }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayWindow(controller: controller)
        NotificationCenter.default.addObserver(forName: .imlaHotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.registerHotkey() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.unloadModels()
    }
}

private struct MenuIcon: View {
    @ObservedObject var controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let progress = controller.downloadProgress {
                Image(nsImage: Self.ring(progress))
            } else {
                Image(systemName: controller.phase == .listening ? "waveform.circle.fill" : "waveform")
            }
        }
        .onAppear { controller.showSettingsWindow = { openWindow(id: "settings") } }
    }

    /// A download progress ring, drawn as a template image so it matches the menu bar.
    private static func ring(_ progress: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let inset = rect.insetBy(dx: 2, dy: 2), center = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.withAlphaComponent(0.3).setStroke()
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2
            track.stroke()
            NSColor.black.setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: inset.width / 2, startAngle: 90, endAngle: 90 - 360 * max(0.02, progress), clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: DictationController
    let updater: SPUStandardUpdaterController?

    var body: some View {
        if let progress = controller.downloadProgress {
            Text("Downloading models… \(Int(progress * 100))%")
            Divider()
        } else if !controller.missingModels.isEmpty {
            Button("Download Models (\(ByteCountFormatter.string(fromByteCount: controller.missingModels.reduce(0, +), countStyle: .file)))") {
                controller.installModels()
            }
            Divider()
        }
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
            Button("Show History…") { controller.openSettings(tab: 2) }
        }
        Divider()
        Button("Settings…") { controller.openSettings() }
        .keyboardShortcut(",")
        if let updater {
            Button("Check for Updates…") { updater.checkForUpdates(nil) }
        }
        Button("Quit Imla") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private static func title(_ item: HistoryItem) -> String {
        let text = item.final.replacingOccurrences(of: "\n", with: " ")
        return text.count > 60 ? text.prefix(60) + "…" : text
    }
}

/// SwiftUI's `@State` macro needs Xcode's macro plugin, which the Command Line
/// Tools lack. The underlying property wrapper works the same.
typealias ViewState = SwiftUI.State
