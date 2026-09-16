# ffmep

A fast, native macOS app for ffmpeg. Drop in videos, audio or photos, pick a format, and convert. It also handles a few things plain ffmpeg makes awkward: HEIC and WebP, Live Photos, and background removal.

Built with SwiftUI and stock macOS controls, including Liquid Glass on macOS 26. Apple silicon only.

## Features

- **Video**: MP4, MOV, MKV, WebM and GIF, encoded as H.264, HEVC, ProRes, VP9 or AV1. H.264, HEVC and ProRes use VideoToolbox hardware encoding when your Mac supports it.
- **Audio**: MP3, AAC (M4A), WAV, FLAC, ALAC and Opus. You can also pull the audio track out of a video.
- **Images**: HEIC, WebP, JPEG and PNG. ImageIO handles the formats it can write, and the bundled ffmpeg handles the rest.
- **Live Photos**: ffmep pairs a Live Photo's still with its video and can export the still, an animated GIF or an MP4.
- **Background removal**: set the background to white or transparent. Removal runs on your Mac with Apple's Vision framework. You can also download [BiRefNet](https://github.com/TheFilipcom4607/birefnet-coreml), a larger model that cuts out subjects more cleanly.
- **Target size**: enter a file size and ffmep works out the bitrate. There's also a quality slider with Small, Balanced and High presets.
- **Resize, rotate, flip, frame rate, strip metadata** and a maximum compression mode.
- **Parallel queue**: images, audio, hardware video and software video run in separate lanes, each with its own concurrency limit.
- **Bundled ffmpeg**: the app ships a static arm64 ffmpeg 9 build with x264, x265, SVT-AV1, libvpx, Opus, LAME, libwebp and dav1d. In Settings, you can switch to Homebrew's ffmpeg or a custom path.

## Requirements

- macOS 14 or later on Apple silicon
- For building: Xcode command line tools with the macOS 26 SDK or later, plus `brew install cmake meson ninja pkgconf` to build ffmpeg

## Building

```bash
# 1. Build the static ffmpeg + ffprobe into vendor/ (slow the first time; re-runs skip finished steps)
scripts/build-ffmpeg.sh

# 2. Build and package build/ffmep.app and build/ffmep.zip
VERSION=1.0.0 scripts/make-app.sh
```

`CONFIG=debug scripts/make-app.sh` builds a debug app into `build/debug/ffmep.app` instead.

`make-app.sh` updates the SDK version recorded in the binary. SwiftPM records the deployment target there, and with that value macOS 26 runs the app in legacy appearance mode, without Liquid Glass.

## Tests

```bash
swift test
```

Integration tests are skipped unless you point them at a folder of sample files:

```bash
FFMEP_FIXTURES=/path/to/fixtures swift test --filter IntegrationTests
```

By default they use the bundled ffmpeg in `vendor/`. Set `FFMEP_FFMPEG=homebrew` to use Homebrew's instead.

## BiRefNet model

The optional background removal model is BiRefNet converted to Core ML. It's hosted at [TheFilipcom4607/birefnet-coreml](https://github.com/TheFilipcom4607/birefnet-coreml). The conversion scripts are in [`scripts/birefnet`](scripts/birefnet), with usage notes at the top of `convert.py`.

## License

ffmep is licensed under the [GNU GPL v3](LICENSE). The bundled ffmpeg is built with `--enable-gpl --enable-version3`, so it's GPLv3 too. Its license files are in [`vendor/licenses`](vendor/licenses), and the exact sources and versions are listed in [`vendor/BUILDINFO.txt`](vendor/BUILDINFO.txt) and `scripts/build-ffmpeg.sh`.
