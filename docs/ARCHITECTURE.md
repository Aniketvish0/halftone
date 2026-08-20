# Halftone — Architecture
> A free, native LookAway-superset for macOS 26+.
> Owner: Aniket. Built with SwiftPM + CLT (no Xcode).
> Status file. Last verified sweep: 2026-08-20 (pre-v0.0.1).

## 0. Product thesis
LookAway's moat = automatic context detection (never interrupt a call/meeting/recording)
+ gentle enforcement + native polish. We replicate the full feature set, then exceed it in:
1. **Detection engine** — first-class, event-driven, zero-config smart pause (user's #1 ask)
2. **Ambient pre-break mode** — screen-edge glow / gradual pressure instead of abrupt popups
3. **Deep stats** — hourly heatmaps, trends, SQLite you can query, CSV export
4. **Hyper-scriptability** — AppIntents, URL scheme, shell hooks on every event, config file

Non-goals: iPhone sync, App Store, sandboxing, macOS < 26.

## 0.5 Implementation status (v0.0.1 — through Phase 2)

Legend: ✅ done+tested · ☑️ done, works, light testing · ⬜ not built

| Feature | Status | How it was tested |
|---|---|---|
| Break engine state machine | ✅ | Full lifecycle observed at 1-min intervals; multi-cycle |
| Menu bar icon + countdown | ✅ | Screenshot-verified render; per-minute label + final-minute live ticker |
| Menu (break now/pause/resume/settings/quit) | ✅ | Manual + state-dependent items verified |
| Warning pill (pre-break heads-up) | ✅ | On-screen verified, snooze works, window-server geometry checked |
| Full-screen overlay, all displays/Spaces | ✅ | On-screen verified incl. over fullscreen; level/behavior via CGWindowList |
| Skip / Snooze 15m | ✅ | User-confirmed + state transitions observed |
| Overlay fade + content teardown | ✅ | CPU leak found & fixed; 0.0% post-break re-measured |
| Settings: intervals/durations/lead/sounds | ✅ | Live re-schedule on change verified |
| Launch at login (SMAppService) | ☑️ | API wired; needs one logout/login cycle to observe |
| Session resume across relaunch | ✅ | Due-date identical across kill+relaunch (automated check) |
| Sleep/wake revalidation | ☑️ | Code path exercised via willSleep/didWake notifications; no overnight soak yet |
| Smart Pause: mic (calls) | ✅ | Real mic capture -> flag in ~1s -> released |
| Smart Pause: camera | ✅ | Photo Booth -> flag -> released on quit |
| Smart Pause: screen share/record | ✅ | Real screencapture -V recording -> on/off observed |
| Full lifecycle (working→pill→overlay→working) | ✅ | Automated observation over multiple cycles |
| Toggles apply without restart | ✅ | screenCaptured: OFF -> 0 events, ON -> detected (probe) |
| Smart Pause: video playing | ✅* | Simulated player (audio+assertion) incl. browser bundle-family match. *Real-app spot-checks pending |
| Smart Pause: fullscreen | ✅ | False positive (maximized) found & fixed; real fullscreen verified |
| Smart Pause: focus-app list | ☑️ | Detector + picker built; brief manual check |
| Per-signal runtime toggles | ✅ | Detectors start/stop live on preference change (probe-verified) |
| Post-activity linger | ✅ | Hold persisted after mic stopped, released after window |
| Held break fires after hold clears | ✅ | Probe + state observation |
| Call mid-break ends break | ☑️ | Code path; not yet provoked in real use |
| Idle natural breaks + crediting | ✅ | Idle threshold crossing + return observed via probe |
| Watching video ≠ away | ✅ | Suppression check in probe |
| Lock/sleep = away | ✅ | Real lock/unlock observed via probe during test |
| Office hours | ☑️ | Boundary logic unit-style verified; no multi-day soak |
| Single instance guard | ✅ | Duplicate-launch scenario reproduced & fixed |
| Energy: 0.0% CPU / 0 wakeups idle | ✅ | top sampling, all detectors enabled, repeated |
| --probe diagnostics mode | ✅ | Used for all detector verification |

Phase 3+ (not built): ambient pre-break glow, blink/posture, strictness levels,
custom messages/backgrounds, AppIntents/Shortcuts, shell hooks, planned breaks,
stats/GRDB, website stats, lock-screen countdown.

## 1. Feature matrix (parity target = LookAway 2.4.1)
| Area | LookAway | Ours (target phase) |
|---|---|---|
| Short/long break scheduling | yes | P1 |
| Pre-break heads-up countdown | yes | P1 (ambient glow P3) |
| Skip / snooze +N / limits | yes | P1 basic, P2 limits |
| Idle = natural break | yes | P2 |
| Smart Pause: mic/camera (calls) | yes | P2 |
| Smart Pause: video playback | yes | P2 |
| Smart Pause: screen share/rec | yes | P2 |
| Smart Pause: fullscreen apps/games | yes | P2 |
| Smart Pause: deep-focus app list | yes | P2 |
| Smart Pause: typing/dragging (opt) | yes | P4 |
| Office hours | yes | P2 |
| Planned breaks (clock-time) | yes | P4 |
| Custom on-demand breaks | yes | P4 |
| Overtime nudges | yes | P4 |
| Blink reminders | yes | P3 |
| Posture nudges | yes | P3 |
| Break lock / strictness levels | yes | P3 |
| Custom messages/backgrounds | yes | P3 |
| Stats dashboard + Screen Score | yes | P5 (ours deeper) |
| App usage stats | yes | P5 |
| Website usage stats | yes | P6 (needs automation perms) |
| Shortcuts / AppleScript | yes | P4 (AppIntents), sdef later |
| Focus Filters | yes | P4 |
| Lock-screen countdown (SkyLight SPI) | yes (26+) | P6, feature-flagged |
| iPhone Mirror | yes | SKIPPED (decision) |
| Menu bar Quick Look panel | yes | P1 basic, P3 polished |
| Sessions resume after restart | yes | P2 |
| Launch at login | yes | P1 |

## 2. Process architecture
Single LSUIElement app. Modules (SwiftPM targets):

```
┌────────────────────────────────────────────────────────────┐
│  App (LSUIElement, @main, AppDelegate)                     │
│                                                            │
│  ┌──────────────┐   state    ┌──────────────────────────┐ │
│  │ BreakEngine  │◄──────────►│ ContextEngine            │ │
│  │ (state       │  signals   │ (smart pause detectors,  │ │
│  │  machine +   │            │  all event-driven)       │ │
│  │  scheduler)  │            └──────────────────────────┘ │
│  └──┬───────┬───┘                                          │
│     │       │ events                                       │
│     │       ▼                                              │
│     │   ┌──────────┐  ┌───────────┐  ┌─────────────────┐  │
│     │   │ StatsStore│  │ Hooks     │  │ AppIntents      │  │
│     │   │ (GRDB)    │  │ (shell/URL)│ │ (Shortcuts)     │  │
│     │   └──────────┘  └───────────┘  └─────────────────┘  │
│     ▼ UI                                                   │
│  ┌──────────────┐ ┌───────────────┐ ┌──────────────────┐  │
│  │ MenuBar      │ │ OverlayKit    │ │ SettingsUI       │  │
│  │ (NSStatusItem│ │ (per-screen   │ │ (Settings scene, │  │
│  │ +NSHostingV.)│ │  NSPanels)    │ │  grouped forms)  │  │
│  └──────────────┘ └───────────────┘ └──────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

### BreakEngine — the state machine
States: `working(until:) → warning(breakAt:) → inBreak(kind, until:) → done → working`
plus `paused(reason:)` (user/context/officeHours) and `idle`.
- Single source of truth, @MainActor @Observable.
- Scheduler: one DispatchSourceTimer armed for THE NEXT event only (not per-second ticks);
  leeway = 1-5s for energy. All UI countdowns rendered by system (Text(timerInterval:)).
- Context signals shift state: e.g. `inMeeting` → postpone break, extend working.
- Persisted snapshot (resume after relaunch).

### ContextEngine — detection (FILL FROM DETECTION REPORT)
- Each detector = an isolated `ContextDetector` publishing `ContextSignal` (Set<ContextFlag>).
- Flags: .micActive, .cameraActive, .screenShared, .mediaPlaying, .frontmostFullscreen,
  .deepFocusApp, .userIdle(duration), .screenLocked, .onBattery, .focusModeOn
- Policy layer maps flags -> PauseDecision (per-user toggles).

## 3. UI direction
- macOS 26 Liquid Glass native: glassEffect chrome on floating controls, MeshGradient
  animated break backgrounds, behind-window NSVisualEffectView blur base.
- Menu bar: SF Symbol icon + optional system-rendered countdown.
- Break overlay: full-bleed mesh gradient + big timer + one glass button (skip/snooze),
  long-hold-to-skip ring for strict mode.
- Settings: native Settings scene, grouped forms, sidebar-free tabs.

## 4. Build system (no Xcode)
- SwiftPM executable target. `Scripts/bundle.sh`: swift build -c release →
  assemble .app (Contents/MacOS, Info.plist, Resources, icon) → codesign -s - (ad-hoc).
- Info.plist: LSUIElement=YES, NSMicrophoneUsageDescription etc. as needed by detectors.
- VERIFIED 2026-08-20: glassEffect/MeshGradient/Text(timerInterval:) compile w/ CLT 26.5 SDK.

## 5. Phases
- **P1 — usable day 1**: engine core, menu bar w/ live countdown, basic overlay (all
  screens, fade, skip/snooze), settings (intervals, durations, launch-at-login), persistence
  of prefs. Install & live with it.
- **P2 — never interrupts (user's top ask)**: ContextEngine detectors (mic, camera, screen
  share, media, fullscreen, deep-focus list, idle natural breaks), office hours, resume state.
- **P3 — feel**: liquid-glass polish pass, animated mesh backgrounds, ambient pre-break glow
  mode, blink + posture reminders, strictness levels, custom messages.
- **P4 — power**: AppIntents/Shortcuts, URL scheme, shell hooks, Focus Filter, planned
  breaks, on-demand custom breaks, overtime nudges, typing/drag hold.
- **P5 — insight**: GRDB stats (sessions, breaks, outcomes, app usage), dashboard window
  with heatmaps/trends/Screen-Score-like metric, CSV/SQL export.
- **P6 — flourishes**: website stats (browser automation), lock-screen countdown via
  SkyLight SPI (flagged), Sparkle if ever distributed.

## 6. Detection engine details (from RESEARCH-detection.md)
All signals event-driven, zero TCC prompts except browser URLs (P6):

| Signal | API | Mode | Perms |
|---|---|---|---|
| Mic in use (per-app) | CoreAudio process objects: IsRunningInput + BundleID | listener | none |
| Camera in use | CMIO DeviceIsRunningSomewhere + listener (recheck-on-hint, debounce) | listener | none |
| Audio playing (per-app) | CoreAudio process objects: IsRunningOutput | listener | none |
| Video playing | audioOutput && IOPMCopyAssertionsByProcess PreventUserIdleDisplaySleep | 10s cached poll | none |
| Screen share/record | SLSIsScreenWatcherPresent (dlsym) + SLS notify 1502/1503, slow poll belt | listener+poll | none |
| Fullscreen frontmost | CGWindowList geometry vs NSScreen, re-eval on space/app-activate notifs | event | none |
| Idle | secondsSinceLastEventType, endpoint-scheduled (no ticking) | self-timer | none |
| Lock/sleep/wake | DistributedNotificationCenter + NSWorkspace notifs | event | none |
| Frontmost app usage | didActivateApplicationNotification interval accounting | event | none |
| Typing/drag hold | secondsSinceLastEventType(.keyDown/.leftMouseDragged) at fire moment | on-demand | none |
| Focus mode | SetFocusFilterIntent (only supported route; Assertions.json dead on 26) | system-push | user setup |
| Power | IOPSNotificationCreateRunLoopSource + isLowPowerModeEnabled | event | none |

Smart Pause = mic ∨ camera ∨ screenWatcher ∨ fullscreen ∨ video ∨ deepFocusApp ∨ focusFilter,
with configurable post-activity linger (default 60s) and idle-aware break crediting.

MediaRemote (now-playing metadata) is entitlement-dead since 15.4 — deliberately NOT used;
CoreAudio output activity + display-sleep assertions replace it fully for pause purposes.

### Energy contract
- Steady state 0.0% CPU: no ticking timers anywhere; one DispatchSourceTimer armed at the
  next state-machine endpoint (leeway 30s), tightened only while a visible countdown runs.
- App Nap embraced: beginActivity only when break <2min or overlay visible.
- All menu-bar countdowns system-rendered via Text(timerInterval:) — zero app wakeups.
- Listener queues: .utility QoS, 200-500ms debounce, coalesced recompute.
