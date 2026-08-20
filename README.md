<div align="center">

# ◐ Halftone

**Smart break reminders for macOS — free, native, zero-compromise.**

Look away. Your eyes will thank you.

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138)](#building-from-source)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

</div>

---

Halftone reminds you to rest your eyes (20-20-20) and step away — but **never
interrupts what matters**. It detects calls, meetings, screen recording, video,
and fullscreen apps, and quietly holds your break until you're actually free.

## Why Halftone

- **Never interrupts.** Automatic Smart Pause during:
  - 🎤 Calls & meetings (any app using the microphone — Zoom, Meet, Teams, FaceTime, huddles)
  - 📷 Camera use
  - 🖥 Screen sharing & recording (including in-app shares)
  - ▶️ Video playback
  - ⛶ Fullscreen apps & games
  - 🎯 Apps you choose (deep-focus list)
- **Genuinely lightweight.** 0.0% CPU and ~0 wakeups at idle, ~14 MB RAM.
  All detection is event-driven — no polling loops. Countdown text in the menu
  bar is rendered by the system, not the app.
- **Honest about you stepping away.** Walk off for 3 minutes and it counts as
  your break. Watching a video doesn't count as "away".
- **Office hours.** Reminders only when you want them.
- **Every single behavior is toggleable, live.** No restart, ever.
- **Private.** No network access, no analytics, no accounts. Nothing leaves your Mac.
- **No permission dialogs.** Every detection signal uses public, TCC-free APIs.

## Install

Download `Halftone.app.zip` from [Releases](../../releases), unzip, drag to
`/Applications`, and open.

> **First launch:** this build is self-signed (no Apple Developer fee is paid
> for a free app), so macOS will warn you. Either right-click → Open → Open,
> or if that's not offered:
> ```sh
> xattr -dr com.apple.quarantine /Applications/Halftone.app
> ```

## Requirements

macOS 26 (Tahoe) or later, Apple silicon.

## Usage

Halftone lives in your menu bar (◐ icon + countdown).

| Menu bar icon | Meaning |
|---|---|
| ◐ `18m` | Working — next break in 18 minutes |
| 👤 | Break held — you're on a call / sharing / watching |
| 🌙 | You're away — time counts as your break |
| ⏸ | Paused by you |
| 🌅 | Outside office hours |

A glass pill warns you ~30s before each break (snoozable). The break itself is
a full-screen overlay on every display with a countdown — skip or snooze
anytime (strictness levels coming in a later release).

**Settings** (from the menu): break cadence & lengths, every Smart Pause
signal individually, post-activity linger, natural-break threshold, office
hours, launch at login.

## Building from source

No Xcode required — just Command Line Tools:

```sh
git clone https://github.com/Aniketvish0/halftone.git
cd halftone
./Scripts/bundle.sh release
open build/Halftone.app
```

### Diagnostics

```sh
.build/release/Halftone --probe 30   # live Smart Pause detector state
```

## Roadmap

- **v0.0.1 (this)** — break engine, menu bar, overlay, Smart Pause, idle, office hours
- **Phase 3** — ambient pre-break glow, blink & posture reminders, strictness levels, custom break screens
- **Phase 4** — Shortcuts/AppIntents, shell hooks, URL scheme, planned breaks
- **Phase 5** — local stats: heatmaps, trends, screen score (SQLite, exportable)
- **Phase 6** — website-level stats, lock-screen countdown

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the engineering deep-dive:
state machine design, the event-driven detection layer, energy engineering,
and the research notes ([detection APIs](docs/RESEARCH-detection.md),
[overlay/shell](docs/RESEARCH-overlay-shell.md)).

## License

MIT
