import AVFoundation
import ImlaCore
import SwiftUI

/// The first-launch window: says what each permission is for before asking for it,
/// then downloads the models. Nothing is requested until its button is pressed.
struct WelcomeView: View {
    @ObservedObject var controller: DictationController
    @Environment(\.dismissWindow) private var dismissWindow
    @ViewState private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @ViewState private var trusted = Paster.canPaste

    static let doneKey = "welcomeDone"

    /// Shown at launch until it's finished or skipped once, and only while something is still missing.
    static var isNeeded: Bool {
        !UserDefaults.standard.bool(forKey: doneKey)
            && (!NemotronModel.isInstalled() || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || !Paster.canPaste)
    }

    private var modelsReady: Bool { controller.missingModels.isEmpty && controller.downloadProgress == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Imla").font(.title2.weight(.semibold))
                    Text("Three steps, and you can dictate into any app with \(controller.config.hotkey.displayString).")
                        .foregroundStyle(.secondary)
                }
            }

            Step(number: 1, title: "Microphone",
                 detail: "Imla listens only between pressing the shortcut and finishing. Speech is transcribed on this Mac; the audio is never saved or sent anywhere.",
                 done: mic == .authorized) {
                if mic == .notDetermined {
                    Button("Allow Microphone") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            Task { @MainActor in mic = AVCaptureDevice.authorizationStatus(for: .audio) }
                        }
                    }
                } else if mic != .authorized {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }

            Step(number: 2, title: Paster.permissionName,
                 detail: "Lets Imla find the text field your cursor is in and paste what you said there. macOS warns that apps with this access can read email, watch the keyboard, and control other apps, because it's one permission for all of that; Imla only finds the cursor and pastes. Turn on Imla in Privacy & Security → \(Paster.permissionName). Without it, dictations are copied to the clipboard instead.",
                 done: trusted) {
                Button("Open System Settings") {
                    Paster.requestAccessibility()
                    Paster.openPermissionSettings()
                }
            }

            Step(number: 3, title: "Models",
                 detail: "Speech recognition and cleanup run on this Mac. Download them once; they stay in shared caches other apps can use too.",
                 done: modelsReady) {
                if let progress = controller.downloadProgress {
                    ProgressView(value: progress) { Text("Downloading… \(Int(progress * 100))%").font(.caption) }
                        .frame(width: 160)
                } else if !controller.missingModels.isEmpty {
                    Button("Download (\(ByteCountFormatter.string(fromByteCount: controller.missingModels.reduce(0, +), countStyle: .file)))") {
                        controller.installModels()
                    }
                }
            }

            HStack {
                Spacer()
                let ready = mic == .authorized && trusted && modelsReady
                Button(ready ? "Start Dictating" : "Finish Later") {
                    UserDefaults.standard.set(true, forKey: Self.doneKey)
                    dismissWindow(id: "welcome")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        // Grants happen in System Settings, so check for them while the window is open.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            trusted = Paster.canPaste
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

private struct Step<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !done { action }
        }
    }
}
