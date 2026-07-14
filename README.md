# SaoTrack — Stem Splitter & Multi-Track Mixer

A native macOS app (Swift / SwiftUI) that splits a song or video into five
stems — **Vocals / Drums / Bass / Piano / Other** — lets you audition, mute,
solo, and rebalance them in a multi-track mixer, detects the song's
**Key & BPM**, and exports the result as **WAV 16-bit / 44.1 kHz** or
**MP3 320 kbps CBR**.

Typical uses: karaoke tracks (mute the vocals), acapellas (solo the vocals),
drum/bass extraction, remixing, mashup prep, and beat-synced video editing.

## Features

- **Load local files**: MP3, WAV, M4A, AAC, FLAC audio and MP4, MOV, MKV,
  WEBM video (the audio track is extracted). Drag & drop or file picker.
- **YouTube import**: paste a link, press *Download & Load* (via yt-dlp).
  Only download content you own or have the rights to use.
- **5-stem separation**: Demucs `htdemucs_6s`; the model's guitar stem is
  summed into *Other* so you always get exactly Vocals / Drums / Bass /
  Piano / Other. Optional *Automatically separate after loading*.
- **Multi-track mixer**: per-stem volume, mute, solo, individual stem export;
  all stems play in sample-accurate sync.
- **Player**: play / pause / stop, seek bar, time display, master volume,
  output device picker.
- **Detect Key & BPM**: built-in DSP (no extra tools) — chromagram +
  Krumhansl–Schmuckler key estimation, onset-autocorrelation tempo with
  octave-error correction. Results are estimates; live recordings, rubato,
  long intros, or key changes reduce accuracy, and BPM can occasionally fold
  to half/double the true tempo.
- **Export**: *Export Mix* (renders the current mix offline, respecting
  volumes/mutes/solos) and *Export All Stems* (`vocals.wav`, `drums.wav`,
  `bass.wav`, `piano.wav`, `other.wav`), each as WAV 16-bit/44.1 kHz or
  MP3 320 kbps.

## Requirements

- macOS 14 (Sonoma) or later, Xcode 15+
- [Homebrew](https://brew.sh) for the external tools

## Build

```bash
brew install xcodegen ffmpeg yt-dlp
pipx install demucs          # or: use the in-app "Create Managed Environment"

git clone https://github.com/olbboy/saotrack.git
cd saotrack
xcodegen generate
open SaoTrack.xcodeproj      # then Run (⌘R)
```

Command-line build instead of Xcode:

```bash
xcodebuild -project SaoTrack.xcodeproj -scheme SaoTrack -configuration Release build
```

## External tools

The app runs three external tools as subprocesses and finds them
automatically in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, and
its own managed environment. The **Setup** screen (gear icon) shows what was
found and gives copyable install commands.

| Tool | Used for | Install |
| --- | --- | --- |
| ffmpeg | MKV/WEBM audio extraction, MP3 320 encoding | `brew install ffmpeg` |
| yt-dlp | YouTube downloads | `brew install yt-dlp` |
| Demucs (Python) | AI stem separation | `pipx install demucs` — or in-app managed environment |

If you don't want to manage Python yourself, Setup → **Create Managed
Environment** builds a private virtualenv under
`~/Library/Application Support/SaoTrack/venv` and installs Demucs into it
(downloads PyTorch, roughly 2 GB).

### First separation run

Demucs downloads the `htdemucs_6s` model checkpoint (~300 MB) on first use —
the app shows a "Downloading separation model" stage. The model is cached in
`~/Library/Application Support/SaoTrack/torch`. Separation runs on CPU by
default; a Setup toggle enables experimental GPU (MPS) acceleration on
Apple Silicon.

## Notes

- **App Sandbox is disabled** on purpose: a sandboxed app cannot execute
  Homebrew binaries or Python. This build is meant for local/ad-hoc use,
  not Mac App Store distribution.
- The generated `SaoTrack.xcodeproj` is gitignored — re-run
  `xcodegen generate` after pulling changes to `project.yml`.
- Working files live in `~/Library/Application Support/SaoTrack/sessions`
  and are cleaned up on the next launch.

## Quick workflows

- **Karaoke**: load a song → *Separate Tracks* → mute **Vocals** →
  *Export Mix*.
- **Acapella**: separate → solo **Vocals** → *Export Mix* (or export the
  Vocals stem directly from its strip).
- **Mashup prep**: run *Detect Key & BPM* on both songs, pick compatible
  keys/tempos, export the stems you need and combine them in your DAW.
