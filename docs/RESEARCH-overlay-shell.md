# Research: Overlay, Menu Bar, Shell Engineering (agent report, 2026-08-20)

## Overlay window (break screen)
- Borderless, non-activating NSPanel subclass, ONE PER NSScreen.
- level = .screenSaver (1000). CGShieldingWindowLevel() only for hard-lock mode.
- collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
  - .fullScreenAuxiliary is REQUIRED to appear over other apps' fullscreen Spaces.
- hidesOnDeactivate = false (NSPanel default would hide it).
- override canBecomeKey = true (borderless refuses key by default); canBecomeMain = false.
- ignoresMouseEvents = true during pre-break tint phase; false when break locks.
- Rebuild panels on NSApplication.didChangeScreenParametersNotification — DEBOUNCE ~0.5s
  (fires for dock changes; Mac minis can emit hundreds of ghost events). Diff NSScreen sets.
- Fade: NSAnimationContext animator alphaValue; MUST orderOut in completion (invisible
  window still eats clicks otherwise).
- Reference impls: jordanbaird/Ice MenuBarOverlayPanel.swift (best), alin23/Lunar OSDWindow.swift,
  Cindori floating-panel article, samarsault/LookAway (minimal skeleton).

## sharingType
- .none is legacy; ScreenCaptureKit display capture ignores it on macOS 15+.
- DECISION: leave default. Solve screen-share awkwardness by pausing breaks during calls.

## Blocking model
- Default: key window captures keys + long-hold-to-skip (LongPressGesture ring).
- Opt-in strict: NSApp.presentationOptions kiosk flags ([.hideDock, .hideMenuBar,
  .disableProcessSwitching]); .disableProcessSwitching REQUIRES hideDock. Restore by
  SUBTRACTING flags (Munki pattern). NEVER .disableForceQuit by default.

## Menu bar
- Hybrid: NSStatusItem + NSHostingView (not MenuBarExtra — .menu style blocks run loop,
  timers stall; no programmatic control).
- ZERO-CPU countdown: Text(timerInterval:countsDown:) — SYSTEM renders ticks out-of-process.
- Per-minute compact label: TimelineView(.periodic(by: 60)).
- LSUIElement = YES.

## Settings UI
- Native Settings scene + TabView toolbar style + .formStyle(.grouped); macOS 26 gives
  Liquid Glass automatically when built with Xcode 26 SDK.
- Luminare (Loop's lib) rejected: GPL-3.0 + diverges from native Tahoe look.

## Liquid Glass APIs (macOS 26)
- .glassEffect(_:in:), GlassEffectContainer, glassEffectID/Union, .buttonStyle(.glass/.glassProminent),
  NSGlassEffectView. HIG: glass for floating controls, NOT content. MeshGradient behind.

## Visuals (cheap GPU)
- MeshGradient (macOS 15+) animated slowly via control points.
- Metal shader via .colorEffect(ShaderLibrary...) + TimelineView time — GPU only, no diffing.
  twostraws/Inferno as shader library. Avoid TimelineView(.animation) for long-lived overlays.
- Behind-window blur: NSVisualEffectView (.hudWindow/.fullScreenUI, .behindWindow) wrapped
  in NSViewRepresentable UNDER the SwiftUI content (SwiftUI materials only blur in-window).

## Shell
- Launch at login: SMAppService.mainApp.register(); read .status live.
- Updates: Sparkle 2, UNSANDBOXED (dramatically simpler; we need event taps anyway).
- Signing: ad-hoc (codesign -s -) for personal use now; Developer ID + notarize only if distributed.

## Persistence
- GRDB (SQLite). Tables: break_event(id, kind, scheduled_at, started_at, ended_at, outcome),
  app_usage(bundle_id, date, seconds). ValueObservation -> reactive SwiftUI charts.
- @AppStorage/UserDefaults for prefs only.

## Automation
- AppIntents: StartBreakIntent, SkipBreakIntent, PauseIntent; openAppWhenRun = false;
  AppShortcutsProvider. (Siri phrases flaky on macOS; Shortcuts actions reliable.)
- Focus Filter: SetFocusFilterIntent (+ known macOS 26.5 breakage reports — test).
  NOTE: extension targets complicate SwiftPM-only builds — may need main-app intent route.
- AppleScript optional later (sdef + NSScriptCommand); `shortcuts run` CLI covers most.

## Lock-screen countdown (LookAway 2.4 parity, LATE phase, feature-flagged)
- Private SkyLight SPI: SLSSpaceCreate + SLSSpaceSetAbsoluteLevel(400) + SLSSpaceAddWindows.
- Package: Lakr233/SkyLightWindow (used in prod by Ebullioscopic/Atoll).
- Direct-distribution only; can break any point release; dlsym nil-check + feature flag.
