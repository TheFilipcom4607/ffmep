import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PresetSettings()
                .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500)
        .frame(minHeight: 460)
        .background(ClearsInitialFocus())
    }
}

/// Settings otherwise opens with the File Name field focused and {name} selected, one keystroke
/// away from rewriting the template. `defaultFocus` doesn't unseat AppKit here, so ask the window.
private struct ClearsInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FocusClearingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class FocusClearingView: NSView {
        private var cleared = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !cleared, let window else { return }
            cleared = true
            // The text field claims first responder as the window goes on screen, so wait for it.
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                TextField("File Name", text: $state.nameTemplate, prompt: Text(OutputNaming.defaultTemplate))
                LabeledContent("Example") {
                    Text(example)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } header: {
                Text("Converted Files")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(OutputNaming.tokens.map { "\($0.token) \($0.meaning)" }.joined(separator: " · "))
                    Text("If a file with that name exists, the original file type or a number is added. Replace Originals keeps the original name.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("FFmpeg") {
                Picker("Source", selection: $state.ffmpegSource) {
                    ForEach(FFmpegSource.allCases) { Text($0.title).tag($0) }
                }
                if state.ffmpegSource == .custom {
                    LabeledContent("Path") {
                        HStack {
                            TextField("/path/to/ffmpeg", text: $state.customFFmpegPath)
                                .labelsHidden()
                                .onSubmit { Task { await state.reloadTools() } }
                            Button("Choose…") { chooseCustomBinary() }
                        }
                    }
                }
                if state.isLoadingTools {
                    LabeledContent("Version") {
                        ProgressView().controlSize(.small)
                    }
                } else if let tools = state.tools {
                    LabeledContent {
                        Text(tools.version)
                            .textSelection(.enabled)
                    } label: {
                        Text("Version")
                        Text(tools.ffmpeg.deletingLastPathComponent().path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(tools.ffmpeg.path)
                    }
                } else {
                    LabeledContent("Version") {
                        Text("Not Found").foregroundStyle(.red)
                    }
                }
                if let tools = state.tools {
                    let missing = ["libwebp", "libx265", "libsvtav1", "libvpx-vp9", "libopus", "libmp3lame", "hevc_videotoolbox"]
                        .filter { !tools.has($0) }
                    if !missing.isEmpty {
                        Label("Missing encoders: \(missing.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let warning = state.toolsWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                LimitStepper(title: "Images", value: $state.limits.image, range: 1...32)
                LimitStepper(title: "Audio", value: $state.limits.audio, range: 1...16)
                LimitStepper(title: "Video (Hardware Encoding)", value: $state.limits.hardwareVideo, range: 1...6)
                LimitStepper(title: "Video (Software Encoding)", value: $state.limits.softwareVideo, range: 1...4)
            } header: {
                Text("Performance")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("How many files of each type are converted at the same time.")
                    Spacer()
                    Button("Restore Defaults") { state.limits = .default }
                        .disabled(state.limits == .default)
                }
                .foregroundStyle(.secondary)
            }

            Section {
                SubjectModelRow(store: state.subjectModel, showsInstalled: true)
            } header: {
                Text("Background Removal")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BiRefNet cuts out subjects with much cleaner edges and runs entirely on this Mac. Without it, ffmep uses Apple's built-in subject detection.")
                    HStack(spacing: 4) {
                        Text("BiRefNet by Peng Zheng et al., MIT License.")
                        Link("Learn More", destination: SubjectModel.projectURL)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("File List") {
                Toggle(isOn: $state.removeConvertedFiles) {
                    Text("Remove Converted Files Automatically")
                    Text("Files that convert successfully leave the list when converting finishes. Files that fail stay so you can try again.")
                }
            }

            Section("Notifications") {
                Toggle(isOn: $state.notificationsEnabled) {
                    Text("Notify When Finished")
                    Text("Shows a notification when files finish converting while ffmep is in the background.")
                }
            }

            Section("Updates") {
                Toggle(isOn: $state.checksForUpdates) {
                    Text("Check Automatically")
                    Text("Asks GitHub once a day whether a newer version exists, and nothing else. Turn it off and ffmep makes no network connections at all.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var example: String {
        let name = OutputNaming.baseName(template: state.nameTemplate, source: URL(fileURLWithPath: "IMG_1234.HEIC"), format: .webp)
        return "IMG_1234.HEIC → \(name).\(OutputFormat.webp.fileExtension)"
    }

    private func chooseCustomBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose an ffmpeg binary (ffprobe must be in the same folder)"
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            state.customFFmpegPath = url.path
            Task { await state.reloadTools() }
        }
    }
}

private struct PresetSettings: View {
    @Environment(AppState.self) private var state
    @State private var deleting: Preset?

    var body: some View {
        Form {
            ForEach(MediaKind.allCases) { kind in
                let presets = state.presets(for: kind)
                Section(kind.title) {
                    if presets.isEmpty {
                        Text("No \(kind.title.lowercased()) presets")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(presets) { preset in
                        HStack {
                            TextField("Name", text: nameBinding(preset.id))
                                .labelsHidden()
                            Text(summary(preset.settings))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Button {
                                deleting = preset
                            } label: {
                                Label("Delete", systemImage: "minus.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete “\(preset.name)”")
                        }
                    }
                }
            }
            Section {
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Create presets with the Preset menu in the inspector. They also appear in the Shortcuts app.")
                    Spacer()
                    Button("Add Examples") { addExamples() }
                        .disabled(Preset.examples.allSatisfy { example in state.presets.contains { $0.name == example.name && $0.kind == example.kind } })
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: deletingBinding) {
            Button("Delete", role: .destructive) {
                if let deleting { state.deletePreset(id: deleting.id) }
            }
        } message: {
            Text("Shortcuts that use this preset will stop working.")
        }
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    /// Looked up by id, so deleting a row never leaves a binding pointing at the wrong preset.
    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { state.presets.first { $0.id == id }?.name ?? "" },
            set: { name in
                if let index = state.presets.firstIndex(where: { $0.id == id }) { state.presets[index].name = name }
            }
        )
    }

    private func summary(_ settings: ConversionSettings) -> String {
        var parts = [settings.format.title]
        if settings.usesTargetSize {
            parts.append("\(settings.targetSizeMB.formatted()) MB")
        } else if let preset = settings.preset, settings.showsQuality {
            parts.append(preset.title)
        }
        switch settings.resize {
        case .original: break
        case .custom: parts.append("\(settings.customWidth)×\(settings.customHeight)")
        case .percent: parts.append("\(settings.percent)%")
        default: parts.append(settings.resize.title)
        }
        return parts.joined(separator: ", ")
    }

    private func addExamples() {
        for example in Preset.examples where !state.presets.contains(where: { $0.name == example.name && $0.kind == example.kind }) {
            state.presets.append(example)
        }
    }
}

private struct AboutView: View {
    @Environment(AppState.self) private var state

    private var buildInfo: String? {
        let candidates = [
            Bundle.main.url(forResource: "BUILDINFO", withExtension: "txt"),
            FFmpegLocator.bundledDirectory().appendingPathComponent("BUILDINFO.txt"),
        ]
        return candidates.compactMap { $0 }.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("ffmep")
                        .font(.title.weight(.semibold))
                    Text(Bundle.ffmepVersion)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Fast video, audio and image conversion for Apple silicon.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            // Only ever a row here: an update is worth knowing about, not worth interrupting for.
            if let update = state.updates.available {
                Section {
                    LabeledContent {
                        Link("Download", destination: UpdateCheck.releasePage)
                    } label: {
                        Text("Version \(update.version) is available")
                    }
                }
            }

            Section {
                Text("The bundled ffmpeg and ffprobe are built from FFmpeg with x264, x265, SVT-AV1, libvpx, Opus, LAME, libwebp and dav1d. Because x264 and x265 are included, these binaries are licensed under the GNU General Public License, version 3 or later.")
                Text("ffmep runs them as separate programs. Source code for FFmpeg and each library is available from the official project sites, and the exact versions plus the build script (scripts/build-ffmpeg.sh) are included with ffmep’s source.")
                    .foregroundStyle(.secondary)
                if let buildInfo {
                    Text(buildInfo.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Licenses")
            } footer: {
                HStack {
                    Spacer()
                    Link("FFmpeg Source", destination: URL(string: "https://ffmpeg.org/download.html")!)
                    Button("View GPL License") { openLicense() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openLicense() {
        let candidates = [
            Bundle.main.url(forResource: "LICENSE-GPL", withExtension: "txt"),
            FFmpegLocator.bundledDirectory().appendingPathComponent("licenses/COPYING.GPLv3"),
        ]
        if let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A stepper row showing its current value, as in System Settings.
private struct LimitStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("\(value)")
                    .monospacedDigit()
                Stepper(title, value: $value, in: range)
                    .labelsHidden()
            }
        }
    }
}
