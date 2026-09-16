import SwiftUI

struct QualityControl: View {
    let kind: MediaKind
    @Binding var settings: ConversionSettings

    var body: some View {
        Section {
            if settings.showsQuality {
                Picker("Quality", selection: presetBinding) {
                    ForEach(QualityPreset.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(settings.usesTargetSize)

                Slider(value: $settings.quality, in: 0...100) {
                    Text("Quality")
                } minimumValueLabel: {
                    Text("Smaller")
                } maximumValueLabel: {
                    Text("Better")
                }
                .labelsHidden()
                .disabled(settings.usesTargetSize)

                if settings.supportsTargetSize {
                    Toggle(isOn: $settings.targetSizeEnabled) {
                        Text("Limit File Size")
                        Text(targetHint)
                    }
                    if settings.targetSizeEnabled {
                        LabeledContent("Maximum Size") {
                            HStack(spacing: 4) {
                                TextField("Size", value: $settings.targetSizeMB, format: .number.precision(.fractionLength(0...2)))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("MB")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text(settings.format == .gif ? "Uses an optimized 256-color palette" : "Lossless — identical to the original")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Quality")
        }
    }

    private var presetBinding: Binding<QualityPreset?> {
        Binding(
            get: { settings.preset },
            set: { if let preset = $0 { settings.quality = preset.value } }
        )
    }

    private var targetHint: String {
        if kind == .image || settings.format.isStillImage {
            return "Picks the best quality that fits"
        }
        if settings.format.isAudio {
            return "Bitrate is based on each file's length"
        }
        return settings.usesSoftwareVideo ? "Two-pass encode based on length" : "Bitrate is based on length (approximate)"
    }
}
