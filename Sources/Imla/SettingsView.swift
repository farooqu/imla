import AppKit
import AVFoundation
import ImlaCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        TabView(selection: $controller.settingsTab) {
            GeneralTab(controller: controller).tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            VocabularyTab(controller: controller).tabItem { Label("Vocabulary", systemImage: "character.book.closed") }.tag(1)
            HistoryTab(controller: controller).tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(2)
        }
        .frame(width: 640, height: 520)
        // A menu bar app has no Dock icon; show one only while Settings is open,
        // so the window can be found with Cmd-Tab and the Dock.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

private struct GeneralTab: View {
    @ObservedObject var controller: DictationController
    @ViewState private var llmStatus: String?
    @ViewState private var trusted = Paster.canPaste
    @ViewState private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Start / stop dictation") {
                    HotkeyRecorder(hotkey: $controller.config.hotkey)
                }
                if !controller.hotkeyRegistered {
                    Text("That shortcut is taken by another app. Choose another.").foregroundStyle(.red).font(.caption)
                }
                Text("Tap to start and tap again to finish, or hold while you talk. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play sounds", isOn: $controller.config.playSounds)
                Toggle("Show live transcript instead of the waveform", isOn: $controller.config.liveTranscript)
            }
            Section("Speech recognition") {
                LabeledContent("Nemotron Speech Streaming English 0.6B") {
                    ModelStatus(state: controller.modelState, url: NemotronModel.url,
                                downloadBytes: NemotronModel.downloadBytes, install: controller.installModel)
                }
                Text("Runs on this Mac. The model is kept in NeMo-Speech's shared cache, so other apps using it share one copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cleanup") {
                Toggle("Polish with LLM: remove fillers and apply self-corrections", isOn: $controller.config.llmCleanup)
                Picker("Model", selection: $controller.config.cleanupEngine) {
                    Text("Built-in").tag(CleanupEngine.builtIn)
                    Text("Ollama").tag(CleanupEngine.ollama)
                }
                .pickerStyle(.segmented)
                .disabled(!controller.config.llmCleanup)
                switch controller.config.cleanupEngine {
                case .builtIn:
                    LabeledContent("S1-mini by Superwhisper") {
                        ModelStatus(state: controller.cleanupModelState, url: S1MiniModel.url,
                                    downloadBytes: S1MiniModel.downloadBytes, install: controller.installCleanupModel)
                    }
                    .disabled(!controller.config.llmCleanup)
                    Text("Runs on this Mac. The model is kept in the Hugging Face cache, so other apps using it share one copy.")
                        .font(.caption).foregroundStyle(.secondary)
                case .ollama:
                    TextField("Ollama URL", text: $controller.config.ollamaURL)
                    TextField("Model", text: $controller.config.ollamaModel, prompt: Text("such as gemma3:4b"))
                    StatusRow(label: "Check model", status: llmStatus) { llmStatus = await checkLLM() }
                }
            }
            Section("Permissions") {
                LabeledContent("Microphone") {
                    PermissionBadge(granted: mic == .authorized) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
                LabeledContent("Accessibility (to paste)") {
                    PermissionBadge(granted: trusted) {
                        Paster.requestAccessibility()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = Paster.canPaste
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private func checkLLM() async -> String {
        let c = controller.config
        guard let base = URL(string: c.ollamaURL),
              let (data, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("api/tags")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "❌ Unreachable" }
        let names = (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let model = c.ollamaModel.trimmingCharacters(in: .whitespaces)
        let have = names.isEmpty ? "none" : names.joined(separator: ", ")
        if model.isEmpty { return "⚠️ Enter a model name. Have: \(have)" }
        return names.contains(model) ? "✅ \(model) available" : "⚠️ Model not found. Have: \(have)"
    }
}

private struct ModelStatus: View {
    let state: DictationController.ModelState
    let url: URL
    let downloadBytes: Int64
    let install: () -> Void

    var body: some View {
        switch state {
        case .ready:
            HStack {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.borderless)
            }
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
        case .missing:
            Button("Download (\(ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)))", action: install)
        case .installing(let progress):
            ProgressView(value: progress) { Text(progress < 0.99 ? "Downloading…" : "Preparing…").font(.caption) }
                .frame(width: 180)
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).multilineTextAlignment(.trailing)
                Button("Try Again", action: install)
            }
        }
    }
}

private struct StatusRow: View {
    let label: String
    let status: String?
    let action: () async -> Void
    @ViewState private var running = false

    var body: some View {
        HStack {
            Button(label) { running = true; Task { await action(); running = false } }.disabled(running)
            if running { ProgressView().controlSize(.small) }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
        }
    }
}

private struct PermissionBadge: View {
    let granted: Bool
    let open: () -> Void

    var body: some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Button("Grant…", action: open)
        }
    }
}

private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @ViewState private var recording = false
    @ViewState private var monitor: Any?

    var body: some View {
        Button(recording ? "Press a shortcut…" : hotkey.displayString) {
            recording ? end() : begin()
        }
        .font(.system(.body, design: .rounded).weight(.medium))
        .onDisappear(perform: end)
    }

    private func begin() {
        recording = true
        // Let the recorder see the current shortcut instead of triggering dictation.
        HotkeyCenter.shared.unregister(1)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { end(); return nil }
            if let key = Hotkey(event: event) { hotkey = key; end() }
            return nil
        }
    }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { NotificationCenter.default.post(name: .imlaHotkeyChanged, object: nil) }
        recording = false
    }
}

extension Notification.Name {
    static let imlaHotkeyChanged = Notification.Name("imlaHotkeyChanged")
}

private struct VocabularyTab: View {
    @ObservedObject var controller: DictationController
    @ViewState private var selection = Set<VocabularyEntry.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terms you use. Recognition is biased toward every term while you speak. "
                 + "“Sounds like” spellings are replaced with the term after recognition. Ollama cleanup also gets the whole list.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Table($controller.config.vocabulary, selection: $selection) {
                TableColumn("Term") { $entry in TextField("Term", text: $entry.term) }
                TableColumn("Sounds like (comma-separated)") { $entry in
                    TextField("misheard as…", text: Binding(
                        get: { entry.soundsLike.joined(separator: ", ") },
                        set: { entry.soundsLike = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                }
            }
            HStack {
                Button { controller.config.vocabulary.append(VocabularyEntry(term: "")) } label: { Image(systemName: "plus") }
                Button { controller.config.vocabulary.removeAll { selection.contains($0.id) } } label: { Image(systemName: "minus") }
                    .disabled(selection.isEmpty)
                Spacer()
                Button("Reveal config file") { NSWorkspace.shared.activateFileViewerSelecting([ImlaConfig.fileURL]) }
            }
        }
        .padding()
    }
}

private struct HistoryTab: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        if controller.history.isEmpty {
            ContentUnavailableView("No dictations yet", systemImage: "waveform",
                                   description: Text("Press \(controller.config.hotkey.displayString) in any app to start."))
        } else {
            List(controller.history) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        if let app = item.app { Text("→ \(app)").font(.caption).foregroundStyle(.secondary) }
                        Text(String(format: "%.0fs", item.seconds)).font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Button("Copy") { controller.copy(item.final) }.buttonStyle(.borderless)
                    }
                    Text(item.final).textSelection(.enabled)
                    if item.raw != item.final {
                        Text("Heard: " + item.raw).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
