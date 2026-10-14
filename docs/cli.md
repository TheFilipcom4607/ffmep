# The ffmep command line

Everything the app converts, the `ffmep` command converts too: same engine, same
bundled ffmpeg, same background removal, same presets. It's built for scripts and
for AI assistants as much as for people: every command takes `--json`, results go to
stdout and messages to stderr, and the exit status says how it went.

```bash
ffmep convert clip.mov --to mp4 --max-size 25MB
```

## Installing

With Homebrew, `brew install TheFilipcom4607/tap/ffmep` puts `ffmep` on your PATH
along with the app.

From the DMG, link the binary inside the app:

```bash
sudo ln -sf /Applications/ffmep.app/Contents/MacOS/ffmep /usr/local/bin/ffmep
```

It's one binary. In a terminal it's the command line, and a bare `ffmep` prints help;
opened from Finder, the Dock or `open`, it's the app. A built-from-source copy works the same way:
`swift run ffmep convert …`.

## Commands

| Command | What it does |
|---|---|
| `ffmep convert FILE…` | Convert files or folders |
| `ffmep info FILE…` | Kind, size, dimensions, length, codecs, metadata, Live Photo, what it converts to |
| `ffmep formats` | Every output format with its codecs and what it supports |
| `ffmep presets` | The presets saved in the app |
| `ffmep model [status\|install\|remove]` | The optional BiRefNet background model |
| `ffmep version` | The version (`--json` adds the ffmpeg in use) |
| `ffmep help [COMMAND]` | Help, also `ffmep COMMAND --help` |

## convert

```
ffmep convert FILE|FOLDER… [options]
```

Each file is saved next to its original unless `--output` names a folder. Folders are
searched recursively, hidden files skipped. Nothing is ever overwritten: if the name is
taken, the new file gets ` (1)` added. Files are written under a hidden name and only
renamed into place once they're complete.

**Starting settings.** Without `--preset` or `--app-settings`, each kind of file starts
from fixed defaults: images to WebP, videos to MP4 (HEVC), audio to MP3, all at balanced
quality, metadata kept. So a command does the same thing on every Mac, whatever the app's
inspector is set to. The options below are applied on top.

| Option | Values |
|---|---|
| `-t, --to FORMAT` | `webp jpeg png heic gif` · `mp4 mov mkv webm` · `mp3 m4a wav flac alac opus`. A video to an audio format keeps its sound. `same` keeps each image's own format and just compresses it (RAW and TIFF become JPEG; PNG and GIF have no quality to lower, so they barely shrink). |
| `-p, --preset NAME` | A preset from `ffmep presets`, matched ignoring case |
| `--app-settings` | Start from the app's inspector settings instead |
| `-q, --quality Q` | `small`, `balanced`, `high` or `0`–`100` |
| `-s, --max-size SIZE` | `25MB`, `500KB`, `1.5GB` (decimal, like Finder). Not for PNG, GIF, WAV, FLAC, ALAC or ProRes. |
| `-c, --codec CODEC` | `h264`, `hevc`, `prores` (MOV), `vp9` (WebM), `av1` (MKV, WebM). Default: the format's first, see `ffmep formats` |
| `--max-compression` | Software H.264/HEVC: slower, smaller |
| `-r, --resize SIZE` | `4k` `1080p` `720p` `480p` (shorter side) · `2048` (fit in 2048×2048) · `1920x1080` (fit in box) · `1280x` · `x720` · `50%` (images) · `original` |
| `--upscale` | Let `--resize` enlarge; otherwise it only shrinks |
| `--fps FPS` | `60 30 24 15 10`, only ever lowers |
| `--rotate DEG` | `90`, `-90`, `180`, clockwise |
| `--flip DIR` | `horizontal`, `vertical`, `both` |
| `-b, --background STYLE` | `keep`, `transparent`, `white`. Cuts out the subject; formats without alpha get white. |
| `--model MODEL` | `birefnet` (if installed) or `vision` |
| `--live-photo MODE` | `still`, `gif`, `video`. Pass the `.HEIC` and `.MOV` together. |
| `-m, --metadata MODE` | `keep`, `remove-location`, `remove-all` (audio: `keep` or `remove-all`) |
| `--strip-metadata` | Same as `--metadata remove-all` |
| `-o, --output FOLDER` | Save there, created if missing |
| `-n, --name TEMPLATE` | `{name}`, `{format}`, `{date}`; default `{name}` |
| `--replace` | Trash each original once its replacement is safely written, and take its name |
| `-j, --jobs N` | Files at once per lane (images, audio, hardware video, software video). Default: the app's setting |
| `--dry-run` | Show the output paths, settings and ffmpeg commands without converting |
| `--json` | One JSON report on stdout at the end |
| `--quiet` | Only errors on stderr |

Without `--json`, stdout gets the path of each converted file, one per line, so the
output pipes on:

```bash
ffmep convert *.heic --to jpeg --quiet | xargs -I{} cp {} ~/Shared
```

### Exit status

| Code | Meaning |
|---|---|
| 0 | Every file that could be converted was, and at least one was |
| 1 | A file failed, or nothing was converted |
| 2 | A mistake in the command: unknown option, bad value, missing file |
| 130 | Stopped with Ctrl-C; unfinished files are removed |

Files that aren't media, or can't take the options (a video asked to become a JPEG),
are skipped and reported, and don't fail the run by themselves. So
`ffmep convert ~/Downloads --to webp` converts the images and skips the rest.

### JSON report

```json
{
  "ok": true,
  "dryRun": false,
  "converted": 1,
  "failed": 0,
  "skipped": 1,
  "cancelled": 0,
  "savedBytes": 721304,
  "files": [
    {
      "input": "/Users/me/clip.mov",
      "status": "converted",
      "kind": "video",
      "format": "mp4",
      "output": "/Users/me/clip.mp4",
      "inputBytes": 1209061,
      "outputBytes": 487757,
      "note": "Kept the original 64 kbps",
      "removedMetadata": ["location", "date"]
    },
    {
      "input": "/Users/me/notes.txt",
      "status": "skipped",
      "error": "Not a video, audio file or image"
    }
  ]
}
```

`status` is `converted`, `failed`, `skipped`, `cancelled`, or `planned` in a dry run.
Failed files carry `error` and, when ffmpeg said more, `detail`. `removedMetadata` lists
what the original had and the new file doesn't, whether you asked for it or the format
can't hold it (WebP and GIF hold none). A dry run adds `engine`, `settings` and, for video
and audio, the exact ffmpeg `commands`.

## Examples

```bash
# Fit a video under Discord's free limit
ffmep convert clip.mov --to mp4 --codec h264 --max-size 19MB --resize 1080p

# A folder of iPhone photos for the web, without location, into a new folder
ffmep convert ~/Pictures/Trip --to jpeg --resize 2048 --metadata remove-location -o ~/Desktop/Trip

# Keep a JPEG a JPEG, but under 500 KB and without its location
ffmep convert trip.jpg --to same --max-size 500KB --metadata remove-location

# Shrink photos without changing their format, replacing the originals
ffmep convert ~/Pictures/Trip --to same --quality small --replace

# Cut the subject out
ffmep convert cat.heic --to png --background transparent

# A Live Photo as a GIF
ffmep convert IMG_0001.HEIC IMG_0001.MOV --live-photo gif --resize 480p

# The soundtrack of a video
ffmep convert talk.mp4 --to m4a --quality high

# With a preset from the app, checking first
ffmep convert talk.mp4 --preset "Discord (20 MB)" --dry-run

# What's in a file before sharing it
ffmep info IMG_0001.HEIC --json
```

## For AI assistants

- Start with `ffmep formats --json`: it lists every format, its codecs, whether it takes
  `--quality` and `--max-size`, and the values every option accepts.
- `ffmep info FILE --json` tells you the kind, dimensions, duration and metadata before
  you pick options.
- Use `--dry-run --json` to check a plan, then run the same command without `--dry-run`.
- Use `--json` and read `files[].output` for the new paths; never guess them, since a
  taken name gets ` (1)` added.
- Mistakes exit with 2 and say what's wrong on stderr, including the nearest option name
  for a typo.

## What it shares with the app

The command line reads, and never changes, the app's presets, inspector settings
(for `--app-settings`), ffmpeg choice (bundled, Homebrew or a custom path) and queue
limits. Replacing originals only happens with `--replace`. It makes no network
connections, except `ffmep model install`, which downloads BiRefNet from GitHub.
