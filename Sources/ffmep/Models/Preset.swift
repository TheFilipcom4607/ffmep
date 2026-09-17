import Foundation

/// Named settings for one media type, picked in the inspector or from Shortcuts.
struct Preset: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var kind: MediaKind
    var settings: ConversionSettings

    /// What new installs start with, and what Settings → Presets → Add Examples restores.
    /// Size limits checked September 2026; targets sit a little under each limit.
    static var examples: [Preset] {
        func preset(_ kind: MediaKind, _ name: String, _ format: OutputFormat, _ change: (inout ConversionSettings) -> Void) -> Preset {
            var settings = ConversionSettings(format: format)
            change(&settings)
            return Preset(name: name, kind: kind, settings: settings)
        }
        /// H.264 plays everywhere, including in-app players that still stumble on HEVC.
        func sized(_ megabytes: Double, _ resize: ResizeOption) -> (inout ConversionSettings) -> Void {
            { s in
                s.videoCodec = .h264
                s.resize = resize
                s.targetSizeEnabled = true
                s.targetSizeMB = megabytes
            }
        }

        func sharedPhoto(_ s: inout ConversionSettings) {
            s.quality = QualityPreset.high.value
            s.resize = .custom
            s.customWidth = 4096
            s.customHeight = 4096
            s.metadata = .removeLocation
        }

        return [
            // Free accounts can upload 20 MB.
            preset(.video, "Discord (20 MB)", .mp4, sized(19, .p1080)),
            // Sent as a video rather than a document, WhatsApp takes 16 MB.
            preset(.video, "WhatsApp (16 MB)", .mp4, sized(15, .p720)),
            // Gmail allows 25 MB, but encoding the attachment adds about a third.
            preset(.video, "Email (25 MB)", .mp4, sized(17, .p720)),
            preset(.video, "Smaller File (HEVC)", .mp4) { s in
                s.videoCodec = .hevc
                s.quality = QualityPreset.high.value
            },
            preset(.video, "For Editing (ProRes)", .mov) { s in
                s.videoCodec = .prores
            },
            preset(.video, "GIF", .gif) { s in
                s.resize = .p480
                s.frameRate = .fps15
            },
            // WhatsApp turns GIFs into looping videos and tends to reject or freeze big ones.
            // 480 px at 15 fps is the size that reliably sends and stays animated.
            preset(.video, "WhatsApp GIF", .gif) { s in
                s.resize = .custom
                s.customWidth = 480
                s.customHeight = 480
                s.frameRate = .fps15
                s.metadata = .removeAll
            },
            preset(.video, "Extract Audio (MP3)", .mp3) { s in
                s.quality = QualityPreset.high.value
            },

            preset(.audio, "AAC 256 kbps", .m4a) { s in
                s.quality = QualityPreset.high.value
            },
            preset(.audio, "Voice (Small MP3)", .mp3) { s in
                s.quality = 15
            },
            preset(.audio, "Lossless (FLAC)", .flac) { _ in },

            preset(.image, "Web", .webp) { s in
                s.resize = .custom
                s.customWidth = 2048
                s.customHeight = 2048
                s.metadata = .removeAll
            },
            // Discord uploads HEIC but can't preview it, so photos go out as JPEG, without location
            // for public servers. 4096 px stays far under the upload limit.
            preset(.image, "Discord", .jpeg, sharedPhoto),
            // WhatsApp sends WebP as a sticker and scales photos to 4096 px at most, even in HD.
            preset(.image, "WhatsApp", .jpeg, sharedPhoto),
            preset(.image, "JPEG Without Location", .jpeg) { s in
                s.quality = QualityPreset.high.value
                s.metadata = .removeLocation
            },
            preset(.image, "Cutout (PNG)", .png) { s in
                s.background = .transparent
            },
            // Discord shows emoji at 32 px but recommends 128 px, under 256 KB.
            preset(.image, "Discord Emoji", .png) { s in
                s.resize = .custom
                s.customWidth = 128
                s.customHeight = 128
                s.metadata = .removeAll
            },
        ]
    }
}
