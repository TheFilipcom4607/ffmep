import SwiftUI

struct MoreOptions: View {
    let kind: MediaKind
    @Binding var settings: ConversionSettings

    var body: some View {
        let format = settings.format
        Section("Options") {
            if format.isVideoContainer, settings.effectiveCodec != .prores {
                Toggle(isOn: $settings.maxCompression) {
                    Text("Maximum Compression")
                    Text(maxCompressionHint)
                }
            }

            if format != .gif, format != .webp {
                Toggle(isOn: $settings.stripMetadata) {
                    Text("Remove Metadata")
                    Text("Location, camera and date information")
                }
            }

            if !format.isAudio {
                Picker("Rotate", selection: $settings.rotation) {
                    ForEach(Rotation.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Flip") {
                    HStack(spacing: 6) {
                        Toggle(isOn: $settings.flipHorizontal) {
                            Image(systemName: "arrow.left.and.right")
                        }
                        .help("Flip Horizontally")
                        Toggle(isOn: $settings.flipVertical) {
                            Image(systemName: "arrow.up.and.down")
                        }
                        .help("Flip Vertically")
                    }
                    .toggleStyle(.button)
                }
            }

            if kind == .video, format.isVideoContainer || format == .gif {
                Picker("Frame Rate", selection: $settings.frameRate) {
                    ForEach(FrameRateOption.allCases) { option in
                        Text(option == .original && format == .gif ? "15 fps" : option.title).tag(option)
                    }
                }
            }
        }
    }

    private var maxCompressionHint: String {
        switch settings.effectiveCodec {
        case .hevc: "Slower x265 encode for smaller files"
        case .h264: "Slower x264 encode for smaller files"
        case .av1, .vp9: "Slower preset for smaller files"
        case .prores: ""
        }
    }
}
