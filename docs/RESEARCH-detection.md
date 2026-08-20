# Research: Smart Pause Detection APIs (agent report, 2026-08-20)
Target macOS 26+ (we can assume all 14.4+ APIs unconditionally).

## The quiet hero: CoreAudio process objects (macOS 14.4+, public, no TCC)
- kAudioHardwarePropertyProcessObjectList on system object -> [AudioObjectID] per audio-using process
- Per object: kAudioProcessPropertyIsRunningInput (MIC IN USE), kAudioProcessPropertyIsRunningOutput
  (AUDIO PLAYING), kAudioProcessPropertyPID, kAudioProcessPropertyBundleID
- AudioObjectAddPropertyListenerBlock -> fully event-driven, near-zero CPU
- Covers BOTH meeting detection (mic) and media detection (output), per-app, no permissions
- Refs: OpenWhispr macos-mic-listener.swift, BetterCmdTab AudioActivityMonitor.swift,
  Epicenter ADR-0018

## 1. Mic in use (calls/meetings)
- Primary: process objects IsRunningInput (exclude own PID, ignore-list for BlackHole/Loopback)
- Fallback (not needed on 26): kAudioDevicePropertyDeviceIsRunningSomewhere per input device
- Re-enumerate on kAudioHardwarePropertyDevices changes (AirPods hotplug)

## 2. Camera in use
- CoreMediaIO kCMIODevicePropertyDeviceIsRunningSomewhere per video device +
  CMIOObjectAddPropertyListenerBlock; enumerate kCMIOHardwarePropertyDevices (hotplug)
- No TCC prompt (reading flag, not capturing). Boolean only — no "which app".
- GOTCHA: spurious callbacks on Apple Silicon (forum 697124) — treat callback as
  "recheck now" hint, re-read property, debounce. Fallback: 1s poll (trivial cost).

## 3. Media/video playback
- MediaRemote is DEAD for 3rd parties since macOS 15.4 (entitlement-gated to com.apple.*).
  perl-shim loophole (ungive/mediaremote-adapter) exists but fragile — skip; we don't need metadata.
- Signal A: process objects IsRunningOutput (audio playing, per-app). Debounce 2-3s.
- Signal B: IOPMCopyAssertionsByProcess() — PreventUserIdleDisplaySleep per PID = VIDEO
  (players/browsers hold it; music doesn't). Public, no perms. Poll ~10s, cache. Exclude own PID.
- VIDEO PLAYING = A && B for same/any process. Watching-not-idle = HID-idle && B.

## 4. Fullscreen app/game
- CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements]) — geometry/PID/layer
  need NO screen-recording permission (only kCGWindowName does). Match frontmost PID windows
  vs NSScreen frames (flip y! CG is top-left origin), layer <= 0, ~2px tolerance (notch!).
- Trigger re-eval ONLY on activeSpaceDidChangeNotification + didActivateApplicationNotification.
- Games: LSApplicationCategoryType == public.app-category.games as extra hint.
- Private corroboration (skip for now): CGSSpaceGetType == fullscreen (Ice Bridging.swift).

## 5. Screen share/recording (incl. Zoom/Meet in-app share)
- Primary: SLSIsScreenWatcherPresent() (SkyLight, private, dlsym + nil-check).
  Event-driven: SLSRegisterNotifyProc events 1502 (attach) / 1503 (detach). No unregister API.
  Keep slow 2s poll as belt-and-braces. Ref: openusage ScreenCaptureProbe.swift (copyable).
- Public fallback: CGSessionCopyCurrentDictionary()["CGSSessionScreenIsShared"] — ONLY catches
  macOS Screen Sharing/remote mgmt, NOT Zoom shares. Fallback only.
- Excludes: goes true for own SCK usage (we don't capture, fine).

## 6. Idle detection
- CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
- NO 1s polling: schedule next check at (lastInput + threshold - now) via DispatchSourceTimer,
  leeway 5s. Once away: 2s poll for return.
- Video-watching produces zero HID input — combine with signal 3B before treating as away.

## 7. Lock/sleep/wake (all event-driven, no perms)
- DistributedNotificationCenter: "com.apple.screenIsLocked"/"com.apple.screenIsUnlocked"
  (SPI names, stable 15+ yrs; truth-check via CGSessionCopyCurrentDictionary ScreenIsLocked)
- NSWorkspace.notificationCenter: screensDidSleep/Wake, willSleep/didWake, sessionDidResign/BecomeActive
- ON WAKE: recompute from Date — DispatchSourceTimer doesn't tick during sleep.
  STORE breakDueAt: Date, never remainingSeconds.

## 8. Frontmost app usage
- NSWorkspace didActivateApplicationNotification; use userInfo app (property may lag).
  Filter activationPolicy == .regular. Close/open intervals on activation/lock/sleep/idle.
  Coalesce sub-second flickers. Zero CPU between switches.

## 9. Browser URL stats (P6)
- AppleScript per browser (Safari: "URL of current tab of front window"; Chromium clones:
  "URL of active tab of front window"). Needs NSAppleEventsUsageDescription + Automation TCC
  per browser. Only query when browser is frontmost. NSAppleScript blocks — utility queue.
- Firefox: AX title only.

## 10. Typing/drag hold (P4)
- NO event tap, NO global monitor needed: at break-fire moment check
  secondsSinceLastEventType(.keyDown) and (.leftMouseDragged) < 3s => defer 15-30s, recheck.
  Zero permissions, zero CPU. (Almost certainly LookAway's method.)

## 11. Focus/DND
- No public query API even on 26. Assertions.json hack BROKE on Tahoe.
- Supported: SetFocusFilterIntent (user adds our filter per Focus mode). Needs testing on 26.5
  (reported breakage). Meetings already covered by mic detection anyway.

## 12. Power
- IOPSGetProvidingPowerSourceType() + IOPSNotificationCreateRunLoopSource (event-driven)
- ProcessInfo.processInfo.isLowPowerModeEnabled + NSProcessInfoPowerStateDidChange
  (NEVER instantiate ProcessInfo() — poisons singleton cache)

## Energy playbook
1. DispatchSourceTimer + leeway 30s for coarse; tighten to 1s/100ms only while countdown visible
2. Schedule ENDPOINTS, never tick. Recompute deadline on context-change events.
3. App Nap: beginActivity(.userInitiatedAllowingIdleSystemSleep) ONLY while break < 2min away
   or overlay showing; endActivity otherwise. Never .latencyCritical.
4. CoreAudio/CMIO listeners on .utility serial queues; debounce 200-500ms.
5. Steady state target: 0.0% CPU, process idle between callbacks + one coarse timer.

## Smart Pause formula (LookAway parity+)
pause = micActive(excl. self+ignored) || cameraActive || screenWatcherPresent
     || frontmostFullscreen || (audioOutputActive && displaySleepAsserted)  [video]
     || frontmostInDeepFocusList || focusFilterActive
with post-activity linger (e.g. 60s after mic drops) + idle-aware break crediting.
