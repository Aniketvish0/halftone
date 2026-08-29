# Testing disciplines

Rules earned from field failures. The bugs themselves, with root causes and
lessons, are catalogued in [BUGLOG.md](BUGLOG.md). Every rule below traces to a real bug the
user hit that the test suite missed. Check this list before shipping any
change; add a rule whenever a field report exposes a new class.

## 1. Test lifecycle edges, not steady states
Every field bug so far lived in a transition: muting a call (not "call
active"), waking from sleep (not "asleep"), leaving fullscreen (not
"fullscreen"), toggling mid-linger (not "toggle off"). A detector or engine
change ships with its full lifecycle sequence as a test: every path from
active to inactive, not the endpoints.
(Source bugs: mid-call break after mute; wake stranding; stale fullscreen flag.)

## 2. Held states are the normal state
The user lives in holds (calls, fullscreen, video most of the day). Field
verification starts from a held state, not a quiet machine. A feature that
works on an idle desktop and breaks during a call is broken.
(Source bugs: reminders starved by suppression; idle firing mid-call.)

## 3. Interactions over units
Bugs appear between subsystems: idle x calls, toggles x fullscreen,
reminders x holds, glow x warn-lead. Test grids of combinations (see
toggleDetectionMatrix), not features one at a time.

## 4. Tests must drive the REAL code path
A test that reproduces the rule locally verifies the copy, not the code
(the cadence tests once passed while the engine's rule was broken). Expose
the real rule (static func, seam) and drive it. Seams are DEBUG-only.

## 5. Isolate tests from the machine
Real detectors see the real machine: a live call or fullscreen Space
pollutes assertions. Test seams REPLACE real detectors (never run alongside),
and the defaults store auto-isolates under the test runner. Restore any
preference a test touches; verify restoration in the same step that changes it.
(Source bugs: pauseOnMedia left off twice by test runs.)

## 6. Verify at the surface, measured, not eyeballed
Downscaled screenshots lie (invisible glow looked fine; wrong crops looked
broken). Measure: pixel-sample colors, query the window server for panel
existence/alpha, read CPU/wakeups from top. The probe binary
(.build/release/Halftone --probe N) is the primary field instrument.

## 7. Measure energy in the active state too
"0% idle" hid 10-19% CPU during breaks (the mesh regression). Every
animation/UI change gets measured DURING its visible phase. Claims about
render-server offloading are verified by measurement, never assumed
(animating MeshGradient points runs on the CPU; opacity crossfade does not).

## 8. Synthetic fixtures must match real hardware
The fullscreen helper filled the whole screen frame; real fullscreen on a
notched Mac never does (it stops below the camera housing). When a fixture
and reality can differ, verify against reality once before trusting the
fixture. Prefer window-server truth (Space type) over geometry heuristics.

## 9. Persist dates, never countdowns
Applies to tests too: anything timer-based must survive relaunch and sleep
in its test (reminder anchors, engine snapshot). In-memory phase is a bug
until proven otherwise.

## 10. Every field report becomes a named regression test before the fix ships
The test must fail on the pre-fix code. Name it after the scenario
(micHoldSurvivesMute, idleCancellationRestoresPendingCountdownExactly) so
the suite reads as a history of what reality taught us.

## 11. Every away/hold state must carry its own exit backstop
Notifications accelerate transitions; correctness may never depend on one
being delivered. A state whose only exit is a notification is a stranding
bug (the restart left "Away" stuck: the unlock notification was lost in the
boot race and nothing else could exit the state). Tests simulate
notification LOSS: lock without unlock, wake without sleep.
(Source bug: Away-while-typing after restart.)

## 12. Evidence must expire
Detection state that outlives its evidence is a phantom factory. A call
seeded by one mic sample and sustained by unrelated audio showed "On a
call" indefinitely. Rules: seeding requires sustained evidence (>=2s mic),
survivorship requires identity continuity (same bundle ID), and every
inferred session carries a TTL. A nameless hold reason in the menu is a
regression signal: every hold must be attributable.
(Source bug: phantom "On a call" with no app name.)

## 13. UI reads must be tracked reads
@Observable reads inside escaping closures (TimelineView content) are not
reliably tracked: the view never invalidates on changes to them. Publish
display state through a stored observable model with a single writer, and
read it at body top level. Reflection latency is a correctness property:
assert it in tests (<=1 runloop turn).
(Source bug: icon lagging minutes behind state.)

## Field-verification checklist (pre-release)
- [ ] Full suite twice (flake check): ./Scripts/test.sh
- [ ] Steady-state CPU/wakeups/memory after settle (top -pid)
- [ ] Active-state CPU during a real break/glow cycle
- [ ] Probe against the live machine state, ideally during a hold
- [ ] Every preference the session touched verified restored, one by one
- [ ] DMG mounts and reports the right version before gh release
- [ ] Double-launch storm: two rapid opens -> exactly one instance
- [ ] Menu names the app during any call hold (nameless = regression)
