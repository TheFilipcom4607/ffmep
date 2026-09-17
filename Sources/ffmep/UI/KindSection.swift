import SwiftUI

/// The inspector sections for one media type.
struct KindSettingsView: View {
    @Environment(AppState.self) private var state
    let kind: MediaKind
    @Binding var settings: ConversionSettings

    var body: some View {
        Section("Output") {
            PresetPicker(kind: kind, settings: $settings)
            Picker("Format", selection: $settings.format) {
                let choices = OutputFormat.choices(for: kind)
                if kind == .video {
                    Section {
                        ForEach(choices.filter { !$0.isAudio }) { Text($0.title).tag($0) }
                    }
                    Section("Audio Only") {
                        ForEach(choices.filter(\.isAudio)) { Text($0.title).tag($0) }
                    }
                } else {
                    ForEach(choices) { Text($0.title).tag($0) }
                }
            }
            if settings.format.isVideoContainer {
                Picker("Codec", selection: Binding(get: { settings.effectiveCodec }, set: { settings.videoCodec = $0 })) {
                    ForEach(settings.format.codecChoices) { Text($0.title).tag($0) }
                }
            }
        }

        QualityControl(kind: kind, settings: $settings)

        if !settings.format.isAudio {
            ResizeControl(kind: kind, settings: $settings)
        }

        if kind == .image {
            Section {
                Picker("Live Photos", selection: $settings.livePhotoMode) {
                    ForEach(LivePhotoMode.allCases) { Text($0.title).tag($0) }
                }
                .help("A Live Photo is a still plus a short video. Other photos are unaffected.")

                Picker("Background", selection: $settings.background) {
                    ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                }
                .help("Detects the subject on this Mac and removes everything behind it.")
                .onChange(of: settings.background) { _, style in
                    if style.removesBackground { state.offerSubjectModelIfNeeded() }
                }
                if settings.background.removesBackground, state.subjectModel.isInstalled {
                    Picker("Model", selection: $settings.subjectDetector) {
                        ForEach(SubjectDetector.allCases) { Text($0.title).tag($0) }
                    }
                    .help("BiRefNet has cleaner edges on hair and fur. Apple Vision is faster.")
                }
                if settings.background == .transparent, !settings.format.supportsAlpha {
                    Label("\(settings.format.title) can’t store transparency, so the background will be white.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                if settings.background.removesBackground, !state.subjectModel.isInstalled {
                    SubjectModelRow(store: state.subjectModel)
                }
            } header: {
                Text("Photo")
            } footer: {
                if settings.background.removesBackground {
                    if !state.subjectModel.isInstalled {
                        Text("The subject is detected on this Mac.")
                    } else if settings.subjectDetector == .vision {
                        Text("The subject is detected with Apple Vision, on this Mac. It’s faster, with softer edges than BiRefNet.")
                    } else {
                        Text("The subject is detected with BiRefNet, on this Mac.")
                    }
                }
            }
        }

        MoreOptions(kind: kind, settings: $settings)
    }
}
