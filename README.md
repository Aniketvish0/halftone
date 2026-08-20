<div align="center">

# ◐ Halftone

**Break reminders for macOS that know when you're on a call.**

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138)](#building-from-source)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

</div>

---

Every 20 minutes, Halftone asks you to look at something far away for 20
seconds. The idea is old and boring and it works. What most break apps get
wrong is the other part: they pop up mid-meeting, mid-recording, mid-movie,
and you turn them off within a week.

Halftone watches for that. If any app is using the microphone or camera, if
the screen is being shared or recorded, if a video is playing, or if the
frontmost app is fullscreen, the break waits. When you hang up, it fires a
short while later. You never configure any of this. It also never asks for
permissions, because every signal comes from public APIs that don't need any.

I built it because LookAway costs $19 and I wanted the detection parts to be
free. It's one binary, no network access, no analytics, no account.

## What it does

- Short breaks (20-20-20) and long breaks on separate cadences
- A small warning pill ~30 seconds before each break, with a snooze button
- Full-screen break overlay on every display, over fullscreen apps too
- Holds breaks during calls, camera use, screen sharing or recording, video
  playback, fullscreen apps, and any apps you pick yourself
- Counts stepping away from the Mac as a break. Watching a video with your
  hands off the keyboard does not count as stepping away
- Office hours, so it stays quiet on weekends if you want
- Every behavior above has its own toggle and applies immediately, no restart

The efficiency numbers, since this category attracts Electron apps that idle
at 2% CPU: Halftone idles at 0.0% CPU with about zero wakeups per second and
14 MB of memory, measured with all detectors on. The countdown in the menu
bar costs nothing because macOS renders it, not the app. Detection is
event-driven; there are no polling loops. (One exception: the screen-capture
check is a single window-server call every 2 seconds, because the
notification API for it can't be unregistered.)

## Install

Grab `Halftone.dmg` from [Releases](../../releases), open it, drag Halftone
to Applications.

This build is self-signed, so macOS will complain on first launch. I'm not
paying Apple $99/year for a free app. Right-click the app, choose Open, then
Open again. If your macOS version doesn't offer that escape hatch:

```sh
xattr -dr com.apple.quarantine /Applications/Halftone.app
```

Or skip the trust question entirely and [build from source](#building-from-source).

## Requirements

macOS 26 (Tahoe) or later, Apple silicon.

## The menu bar

| Icon | State |
|---|---|
| <img src="docs/assets/state-working.svg" width="18"> `18m` | Working. Next break in 18 minutes |
| <img src="docs/assets/state-held.svg" width="18"> | Break held. You're on a call, sharing, or watching something |
| <img src="docs/assets/state-away.svg" width="18"> | You're away. The time counts as your break |
| <img src="docs/assets/state-paused.svg" width="18"> | Paused by you |
| <img src="docs/assets/state-offhours.svg" width="18"> | Outside office hours |

Settings live behind the same menu: break cadence and length, each detection
signal, how long to keep holding after a call ends (default 60 s), the
away threshold, office hours, launch at login.

## Building from source

You need Command Line Tools, not Xcode:

```sh
git clone https://github.com/Aniketvish0/halftone.git
cd halftone
./Scripts/bundle.sh release
open build/Halftone.app
```

To watch the detection engine make decisions in real time:

```sh
.build/release/Halftone --probe 30
```

## Roadmap

v0.0.1 is the engine, the menu bar, the overlay, and detection. Next, in
order: a gentler pre-break ramp (screen-edge glow instead of a popup), blink
and posture reminders, strictness levels for people who skip too much,
Shortcuts and shell hooks, then local stats on SQLite with real heatmaps.
Further out: per-site usage stats and a countdown on the lock screen.

## How it works

The short version: one state machine, one armed timer, everything else is
callbacks. Mic and audio detection come from CoreAudio process objects, which
report per-app input/output activity without any TCC prompt. Camera state
comes from CoreMediaIO. Screen capture comes from the window server's watcher
flag, the same signal that drives the purple menu bar indicator. Video is
inferred from "an app is producing audio while also holding a display-sleep
assertion", which is how you detect playback now that Apple locked
MediaRemote to its own apps in macOS 15.4.

The long version, including the research notes and what didn't work, is in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/RESEARCH-detection.md](docs/RESEARCH-detection.md), and
[docs/RESEARCH-overlay-shell.md](docs/RESEARCH-overlay-shell.md).

## License

MIT
