<div align="center">
<img src="docs/icon.png" width="120" alt="">

<h1>ffmep</h1>

<p>
  <strong>ffmpeg, as a Mac app that feels like it shipped with the Mac.<br>
  Drop files in, pick a format, convert. Plus HEIC and WebP,<br>
  Live Photos, and background removal that runs on your machine.</strong>
</p>

<p>
  <img src="https://img.shields.io/badge/macOS-14%2B-1d1d1f?style=flat-square&logo=apple&logoColor=white" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Apple%20silicon-required-1d1d1f?style=flat-square" alt="Apple silicon required">
  <img src="https://img.shields.io/badge/license-GPLv3-1d1d1f?style=flat-square" alt="GPLv3">
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/window-dark.png">
  <img src="docs/window-light.png" width="820" alt="The ffmep window after converting eight cat photos to WebP with transparent backgrounds. Each row shows the old and new size, like 22.2 MB to 124 KB for a DNG, and the inspector on the right holds the format, quality, size, Live Photo and background settings.">
</picture>

</div>

<p align="center">
  <sub>Eight photos in, eight transparent WebPs out, 30.7 MB lighter. JPEG, HEIC and a RAW DNG<br>
  all in one batch, cut out with BiRefNet on this Mac.</sub>
</p>

ffmpeg can do nearly anything, as long as you remember the flags. ffmep is the
flags, remembered. It uses stock macOS controls and Liquid Glass on macOS 26, so
it looks like something Apple could have shipped.

It also does a few things ffmpeg alone makes awkward: photos from an iPhone,
WebP in both directions, Live Photos, and cutting the subject out of a picture.

---

## Install

From a clone of this repo:

```bash
scripts/build-ffmpeg.sh
```

```bash
VERSION=1.0.0 scripts/make-app.sh
```

The first script builds a static arm64 ffmpeg and ffprobe into `vendor/`. It takes
a while the first time, and re-runs skip whatever already finished. It needs the
Xcode command line tools and `brew install cmake meson ninja pkgconf`.

The second builds the app, bundles that ffmpeg, signs it ad-hoc and writes
`build/ffmep.app` and `build/ffmep.zip`. Use `CONFIG=debug` for a debug build in
`build/debug/`.

Needs an Apple silicon Mac running macOS 14 or later. Build with the macOS 26 SDK
or newer to get Liquid Glass.

> [!TIP]
> The build is signed ad-hoc, so Gatekeeper will refuse the first launch. Right-click
> `ffmep.app` and choose **Open** once, and it will start normally after that.

---

## What it does

- **Video** to MP4, MOV, MKV, WebM or GIF, as H.264, HEVC, ProRes, VP9 or AV1.
  H.264, HEVC and ProRes go through VideoToolbox when the Mac has a hardware
  encoder for them, so they finish in a fraction of the time.
- **Audio** to MP3, AAC, WAV, FLAC, ALAC or Opus, including pulling the soundtrack
  out of a video.
- **Images** to WebP, JPEG, PNG or HEIC. Anything ImageIO can open goes in,
  RAW DNGs included. JPEG, PNG and HEIC are written by ImageIO directly, WebP by
  the bundled ffmpeg.
- **A file size instead of a quality.** Turn on **Limit File Size**, type 10 MB,
  and ffmep works out the bitrate that fits. Or skip it and use the slider, with
  Small, Balanced and High to start from.
- **Resize, rotate, flip, change the frame rate**, or squeeze out every last byte
  with maximum compression.
- **Presets** for the things you do often. It comes with ones for Discord, WhatsApp
  and email size limits, ProRes for editing, web images, Discord emoji and more,
  and you can save your own from the inspector.
- **Your own file names**, like `{name} (web)` or `{date} {name}`.
- **Shortcuts.** A Convert Files action takes files, a preset or a format, and hands
  back the converted files for the next step.
- **A queue that keeps moving.** Images, audio, hardware video and software video
  each get their own lane with their own limit, so a slow AV1 encode doesn't hold
  up a folder of photos.
- **Save next to the originals**, into a folder, or replace the originals. Replaced
  files go to the Trash, and only once the new file is safely written.

### Metadata

Photos and videos carry more than pixels: where they were taken, when, the camera
and its serial number, sometimes your name. **Metadata** has three settings:

- **Keep** everything, including the location and capture date iPhone videos keep in
  Apple's own tags, which ffmpeg drops unless it's told not to.
- **Remove Location** takes out GPS and place names, and keeps the rest.
- **Remove All** takes out all of it.

Whichever you pick, each converted file says what it lost, like *Removed location,
date and serial number*. ffmep can't write metadata into WebP or GIF, so those
always lose it, and the file says so instead of leaving you to find out.

The tests convert geotagged photos and iPhone-style videos to every format and check
what's left in each file, so a leak shows up as a failing test.

### Live Photos

Drop in a Live Photo, the `.HEIC` and the `.mov` together, and it shows up as one
row with a Live Photo badge. Export the still, the motion as an MP4, or the motion
as an animated GIF.

<div align="center">
  <img src="docs/live-photo.gif" width="400" alt="An animated GIF of a grey British Shorthair sitting on top of a PC case, looking at the camera and blinking.">
</div>

<p align="center">
  <sub>A Live Photo, exported as a GIF at 480p. No trimming, no Photos app, no third-party site.</sub>
</p>

### Background removal

Set **Background** to **Transparent** or **White** and ffmep cuts the subject out
before converting. Formats without transparency, like JPEG, get white instead.

It works straight away with Apple's Vision framework. The first time you use it,
ffmep offers to download [BiRefNet](https://github.com/TheFilipcom4607/birefnet-coreml),
a 408 MB Core ML model with much cleaner edges on fur, hair and anything thin.
Once it's installed, **Model** picks between the two for each conversion: BiRefNet for
the cleanest edges, or Apple Vision when speed matters more, since Vision is many times
faster. Either way it runs on your Mac, and the model can be removed again from Settings.

<div align="center">
  <img src="docs/background-removal.png" width="820" alt="Four cat photos on top: one sitting on a PC, a tabby on wooden stairs behind a metal railing, a grey cat on a shaggy rug next to an orange ball, and a tabby belly-up on a striped rug. Below each, the same cat cut out on a transparent checkerboard.">
</div>

<p align="center">
  <sub>Top: the originals. Bottom: what BiRefNet kept. The railing, the cables and the rug all go,<br>
  the whiskers and the ball stay.</sub>
</p>

### Nothing leaves your Mac

Every conversion, and background removal, runs on this Mac. The only thing ffmep
ever downloads is the optional BiRefNet model, and only after you say yes. There's no
account, no analytics and no update check. Turn Wi-Fi off and it works the same.

### The bundled ffmpeg

ffmpeg 9.0.1, static, arm64, linking nothing but system libraries. Built with
x264, x265, SVT-AV1, libvpx, Opus, LAME, libwebp and dav1d, plus VideoToolbox and
AudioToolbox. Exact versions are in [`vendor/BUILDINFO.txt`](vendor/BUILDINFO.txt).

Prefer your own? Settings can switch to Homebrew's ffmpeg or any path you like.

---

## Formats

| Put in | Get out |
|---|---|
| **Video**: anything ffmpeg reads, like MOV, MP4, MKV, WebM, AVI or an animated GIF | MP4 (HEVC, H.264), MOV (HEVC, H.264, ProRes), MKV (HEVC, H.264, AV1), WebM (VP9, AV1), GIF, or any audio format |
| **Audio**: anything ffmpeg reads, like MP3, AAC, WAV, FLAC, ALAC, Opus or OGG | MP3, M4A (AAC), WAV, FLAC, ALAC, Opus |
| **Images**: anything macOS opens, like HEIC, JPEG, PNG, WebP, TIFF or RAW, plus what ffmpeg decodes | WebP, JPEG, PNG, HEIC, GIF |

That's the whole list. If you need a conversion that isn't on it, or a file ffmep won't
open, [open an issue](https://github.com/TheFilipcom4607/ffmep/issues/new?template=conversion-request.yml).

---

## When to use something else

ffmep is small on purpose. Reach for something else when:

- **You're on an Intel Mac, or on macOS 13 or older.** ffmep needs Apple silicon and
  macOS 14.
- **You want a download that just opens.** There's no signed, notarized build yet, so
  you build it from this repo, and the first launch needs a right-click.
- **You need to edit, not convert.** There's no trimming, cropping or joining.
- **Your video has subtitles or several audio tracks.** Subtitle tracks are dropped.
  MOV and MKV keep every audio track, but MP4 and WebM keep only the first.
  [HandBrake](https://handbrake.fr) handles subtitles and tracks well.
- **You want to tune the encoder.** ffmep gives you a quality slider or a file size.
  HandBrake has far more settings, and ffmpeg itself has all of them.
- **You need a GIF under a set size.** GIF has no file size limit yet. A smaller size
  and frame rate help, but ffmep can't aim for a number.
- **Your audio has cover art you want to keep.** Converting audio drops it.
- **It isn't video, audio or an image.** Documents, PDFs and archives are out of scope.
- **You want it in another language.** It's English only for now.

---

## Development

```bash
swift test
```

The integration tests run real conversions and are skipped unless you point them
at a folder of sample files:

```bash
FFMEP_FIXTURES=/path/to/fixtures swift test --filter IntegrationTests
```

They use the ffmpeg in `vendor/` by default, or Homebrew's with `FFMEP_FFMPEG=homebrew`.
The metadata tests make their own sample files, so they run whenever `vendor/` has
an ffmpeg.

`make-app.sh` also fixes one thing SwiftPM gets wrong for this app. SwiftPM records
the deployment target as the SDK version in the binary, and macOS 26 then runs the
app in legacy appearance mode, without Liquid Glass. The script writes the real SDK
version back in with `vtool`.

It also makes the Shortcuts action visible. Shortcuts reads a `Metadata.appintents`
bundle that Xcode normally generates, and SwiftPM doesn't, so the script runs Apple's
`appintentsmetadataprocessor` on the constant values the compiler writes out.

The BiRefNet conversion scripts live in [`scripts/birefnet`](scripts/birefnet), with
usage notes at the top of `convert.py`.

---

## License

GPLv3, see [LICENSE](LICENSE). The bundled ffmpeg is built with `--enable-gpl` and
`--enable-version3`, so it is GPLv3 too. Its license files are in
[`vendor/licenses`](vendor/licenses).
