import Foundation

enum Help {
    static func text(for command: String?) -> String {
        switch command {
        case "convert": convert
        case "info": info
        case "formats": formats
        case "presets": presets
        case "model": model
        case "version", "--version": "Usage: ffmep version [--json]\n\nPrints ffmep's version. --json adds the ffmpeg it uses."
        default: overview
        }
    }

    static let overview = """
    ffmep: convert video, audio and images on this Mac.

    Usage: ffmep <command> [options]

    Commands:
      convert FILE…     Convert files or folders (see `ffmep convert --help`)
      info FILE…        Show a file's kind, size, length, codecs and metadata
      formats           List the output formats and what each supports
      presets           List the presets saved in the app
      model             Install or remove the BiRefNet background model
      version           Print the version
      help [COMMAND]    Show help for a command

    Examples:
      ffmep convert clip.mov --to mp4 --max-size 25MB
      ffmep convert ~/Pictures/Trip --to jpeg --resize 2048 --metadata remove-location -o ~/Desktop/Trip
      ffmep convert photo.heic --to png --background transparent
      ffmep convert song.flac --to m4a --quality high --json

    Every command takes --json for output a script or an assistant can read.
    Opened from Finder or with `open -a ffmep`, it’s the app.
    """

    static let convert = """
    Usage: ffmep convert FILE|FOLDER… [options]

    Converts each file and saves the result next to the original, or into --output.
    Folders are searched recursively. Nothing is ever overwritten: a taken name gets
    “ (1)” added. The paths of the new files are printed on stdout, one per line,
    progress and messages on stderr.

    Without --preset or --app-settings, each kind of file starts from the defaults
    (images to WebP, videos to MP4 with HEVC, audio to MP3, balanced quality), so the
    same command does the same thing on any Mac.

    What to make:
      -t, --to FORMAT          webp jpeg png heic gif · mp4 mov mkv webm · mp3 m4a wav flac alac opus
                               same: each image keeps its own format, just smaller (RAW
                               and TIFF become JPEG). PNG and GIF barely shrink.
                               A video converted to an audio format keeps just its sound.
      -p, --preset NAME        Start from a preset saved in the app (see `ffmep presets`)
          --app-settings       Start from the settings in the app's inspector
      -q, --quality Q          small, balanced, high, or 0–100
      -s, --max-size SIZE      Aim for a file size, like 25MB or 500KB (not PNG, GIF,
                               WAV, FLAC, ALAC or ProRes)
      -c, --codec CODEC        h264, hevc, prores (MOV), vp9 (WebM), av1 (MKV, WebM)
          --max-compression    Slower, smaller: software encoding for H.264 and HEVC

    Size and shape:
      -r, --resize SIZE        1080p, 720p, 480p, 4k: the shorter side, for video
                               2048: fit within 2048×2048    1920x1080: fit within that box
                               1280x: 1280 wide              x720: 720 high
                               50%: half size (images)       original
          --upscale            Let --resize enlarge smaller files (normally it only shrinks)
          --fps FPS            60, 30, 24, 15 or 10. Only ever lowers the frame rate.
          --rotate DEGREES     90, -90 or 180, clockwise
          --flip DIRECTION     horizontal, vertical or both

    Photos:
      -b, --background STYLE   keep, transparent or white: cut the subject out on this Mac.
                               Formats without transparency, like JPEG, get white.
          --model MODEL        birefnet (when installed, see `ffmep model`) or vision
          --live-photo MODE    still, gif or video: what to export from a Live Photo
                               (the .HEIC and .MOV of the same name, passed together)

    Metadata:
      -m, --metadata MODE      keep, remove-location or remove-all (default keep)
          --strip-metadata     The same as --metadata remove-all

    Where it goes:
      -o, --output FOLDER      Save into this folder, made if it doesn't exist
      -n, --name TEMPLATE      Output name without extension: {name}, {format}, {date}.
                               Default {name}, so photo.heic becomes photo.webp.
          --replace            Move each original to the Trash once its replacement is
                               written, and give the new file the original's name

    Running:
      -j, --jobs N             How many files convert at once in each lane (images,
                               audio, hardware video, software video). Default: the app's
                               setting.
          --dry-run            Print what would be made, and the ffmpeg commands for video
                               and audio, without converting
          --json               Print one JSON report on stdout when done
          --quiet              Only print errors (and the new paths on stdout)

    Exit status: 0 when every file converted, 1 when any failed or none converted,
    2 for a mistake in the command, 130 when stopped with Ctrl-C (unfinished files are
    removed). Files that aren't media, or can't take the options (a video asked to
    become a JPEG), are skipped and reported.

    Examples:
      ffmep convert *.mov --to mp4 --codec h264 --max-size 19MB --resize 1080p
      ffmep convert IMG_0001.HEIC IMG_0001.MOV --live-photo gif --resize 480p
      ffmep convert ~/Pictures/Trip --to same --quality small --replace
      ffmep convert recording.mov --to mp3 --quality high
      ffmep convert ~/Desktop/Screens --to webp --quality 80 --strip-metadata --json
      ffmep convert talk.mp4 --preset "Discord (20 MB)" --dry-run
    """

    static let info = """
    Usage: ffmep info FILE|FOLDER… [--json]

    Shows each file's kind, size, dimensions, length, frame rate and codecs, the
    metadata it carries (location, date, camera, serial number, owner, track info,
    artwork), whether it's a Live Photo still, and the formats it can be converted to.
    """

    static let formats = """
    Usage: ffmep formats [--json]

    Lists every output format with its codecs, and whether it has a quality setting,
    can aim for a file size, can hold transparency and keeps metadata. --json also
    lists the values each convert option accepts.
    """

    static let presets = """
    Usage: ffmep presets [--json]

    Lists the presets saved in the app, by kind of file. Use one with
    `ffmep convert FILE --preset NAME`; other options are applied on top of it.
    --json includes each preset's full settings.
    """

    static let model = """
    Usage: ffmep model [status|install|remove] [--json]

    BiRefNet is an optional 408 MB background model with much cleaner edges than Apple
    Vision on fur, hair and anything thin. It runs on this Mac.

      status     Whether it's installed (the default)
      install    Download it from GitHub, check it and compile it for this Mac
      remove     Delete it; background removal then uses Apple Vision
    """
}
