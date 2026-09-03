# Bug log

Every field bug, what caused it, and the lesson. Companion to
[TESTING.md](TESTING.md) (which holds the rules these bugs produced) and the
release notes (which hold the user-facing summaries). Newest first.

Format: what you saw / root cause / the lesson.

---

## 19. Phantom "On a call" every morning after boot (2026-09-03)

**Saw:** Cold boot, no call anywhere, menu bar shows the call icon with the
countdown still running. A fresh probe found the mic holder: PID 866,
`corespeechd`, Apple's speech daemon (Siri readiness and dictation). It
grabs the mic for a few seconds at a time, most reliably right after boot.
**Cause:** It passed every seeding rule. CoreAudio reports it with a real
bundle ID (`com.apple.CoreSpeech`), so the "anonymous processes cannot
seed" rule did not apply. It was not on the ignore list. And it holds the
mic longer than the 2s seed window. Each capture re-seeded a call.
**Lesson:** "Named" is not the same as "trusted"; a system daemon has a
bundle ID too. The structural rule that was missing: a call is two-way
audio. Speech recognition captures the mic while nothing in its app family
produces output. Seeding now requires family output as well as sustained
capture, and the speech stack is on the built-in ignore list as a second
layer. Also from the same trace session: fullscreen and focus-app exits
were wrongly on the 60s media linger; only media flaps, so only media
earns the long linger. And the post-hangup survivorship poll ran every
30s, which stacked up to 30s of lag on a browser call ending; it now polls
at 2s for the first minute.

## 18. Memory leak: 69MB footprint, 28,956 leaked objects (v0.0.9 hotfix)

**Saw:** Activity Monitor showed 69MB after 3 days of uptime (peak 266MB).
**Cause:** Two CoreFoundation "Create Rule" violations. APIs with Copy/Create
in their name return +1 objects the caller must release; Swift's automatic
bridging does not know that. `readBundleID` leaked one CFString per CoreAudio
bundle-ID read; the fullscreen check typed `SLSCopyManagedDisplaySpaces` as
returning `CFArray`, leaking one array per Space check (every 30s while
fullscreen).
**Lesson:** Swift-level review (retain cycles, weak captures) cannot see
C-interop contract violations. Any CF-returning call gets audited against the
Create Rule, and `leaks` must run against a long-lived process — a fresh one
cannot show accumulation. Equal counts of two leaked CF types is the
fingerprint of a leaking call site, not general fragmentation.

## 17. Countdown number disappeared after sleep (v0.0.9)

**Saw:** Menu bar showed the icon with no number; snapshot's due date was
5.3 hours in the past.
**Cause:** The engine timer used a CPU-clock deadline (`deadline:`), which
suspends during sleep. A due date passing mid-sleep left the timer frozen and
the state stale; the label hides past-due numbers by design, so the number
vanished.
**Lesson:** `DispatchSourceTimer.schedule(deadline:)` does not advance during
sleep; use `wallDeadline:` for wall-clock appointments. Any date-anchored
system must ask "what happens if this date passes while the process is
suspended?"

## 16. Long break ended 2 minutes early, showing "Away" (v0.0.9)

**Saw:** Sat still through a 5-minute long break; at 3 minutes the break
ended with the completion sound and the menu showed "Away".
**Cause:** My own fix for bug 15, one day earlier. It made walking away
during a break complete the break — but "walking away" was detected by HID
stillness (180s threshold), and sitting still through a 300s break IS 180s of
stillness. Complying with the app's own instruction triggered the bug.
**Lesson:** A fix's detection signal must be able to distinguish the bug case
from correct behavior. Stillness cannot distinguish "left the desk" from
"resting eyes as told." In-break stillness is now suppressed; only lock/sleep
(unambiguous evidence) end a break early.

## 15. "0m" frozen after a long break taken away from desk (v0.0.9)

**Saw:** Went away as a long break started, returned 30+ min later: menu
stuck at "0m" for minutes.
**Cause:** Three stacked gaps: going away mid-break was ignored (the engine
completed the break and scheduled a cycle at an empty desk), the return
credit was dropped by a state guard, and the due date then passed during
lid-closed sleep with a suspended timer.
**Lesson:** Every (state x event) cell needs an explicit decision. The
`default: break` that swallowed `.inBreak` in the away handler hid a real
case; exhaustive switches force the decision at compile time.

## 14. Timer frozen at "20m" while typing (v0.0.8)

**Saw:** Countdown showed 20m indefinitely; break eventually fired all at
once when typing paused.
**Cause:** The typing-hold feature deferred a due break while input was
fresh, retrying every 5s with no ceiling. Using Claude Code means typing
continuously, so the deferral looped forever; the display froze because the
engine never transitioned and the display only published on transitions.
**Lesson:** Any retry loop needs a ceiling. Any "wait for a quiet moment"
heuristic must ask: what if the moment never comes? And displays derived from
state must update during deferrals, not only on state changes.

## 13. Countdown frozen at "20m" always (v0.0.8)

**Saw:** Same frozen countdown, no typing involved.
**Cause:** The menu-bar redesign published a pre-computed minute count
(`.minutes(20)`) once per state change. The label rendered that frozen
number; nothing recomputed it as time passed.
**Lesson:** Never publish a derived value that decays with time — publish
the anchor (the end date) and derive at render time. "20 minutes" is a fact
about a moment; the due date is a fact, period.

## 12. Phantom "On a call (Arc Helper)" for hours (v0.0.7 hotfix)

**Saw:** Call icon with a browser helper named, no call in progress, for
5+ hours.
**Cause:** A browser tab held getUserMedia continuously (stuck WebRTC
session). Continuous mic = continuous call under the session rules; there
was no ceiling.
**Lesson:** Evidence-based inference still needs bounds. No real call runs
5 hours without one mute or mic release; encode the reality check
(2-hour continuous ceiling), and quarantine expired sources so they cannot
instantly re-qualify.

## 11. Break fired within 15s of opening the laptop (v0.0.7 hotfix)

**Saw:** Lid open after 30+ min asleep; long break slammed on screen almost
immediately.
**Cause:** Snapshot restore saw a past-due date and started the break
directly, without crediting the absence as a break already taken.
**Lesson:** Restoring persisted state after time has passed is a re-entry
path: it needs the same absence-crediting rules as live returns, not just
"resume where we left off."

## 10. "Away" stuck while typing + phantom call + minutes-long lag (v0.0.7)

**Saw:** After a laptop restart: moon icon while actively typing; then a
nameless "On a call"; menu bar minutes behind reality.
**Cause:** Three independent designs failing together, found by full audit
(24 defects): (a) lock/sleep entered the engine's idle state behind the idle
monitor's back, leaving exit callbacks structurally unreachable; (b) call
survivorship seeded from a one-frame mic blip and survived on ANY same-PID
audio with no TTL; (c) menu-bar hold state was read inside a TimelineView
closure SwiftUI doesn't reliably track, so hold flips never invalidated the
view (worst case 60s; unbounded when fullscreen hid the menu bar).
**Lesson:** The three biggest ones in the project. (a) One owner per fact:
if two components both track "is the user away," they WILL desync — make one
the authority and the other a consumer. (b) Inference needs evidence rules:
minimum duration to establish, identity to sustain, TTL to expire. (c)
@Observable reads inside escaping closures are not tracked; publish through
a stored model read at body top level. Bonus: the single-instance guard was
check-then-act (TOCTOU) and a restart is exactly the double-launch window —
use an atomic lock file.

## 9. Posture reminders never fired (v0.0.6)

**Saw:** Posture enabled at 45 min for days; never saw one.
**Cause:** Cadence timers were in-memory; every app relaunch and sleep reset
the phase to zero. A 45-minute interval never completed on a machine that
relaunches or sleeps more often than that.
**Lesson:** Persist the date, never the countdown — the same principle the
break engine was built on applied to every timer. If a timer's phase matters,
its next-fire time belongs on disk.

## 8. Reminders never appeared during normal work (v0.0.6)

**Saw:** Blink/posture enabled, never seen.
**Cause:** Fires landing while suppressed (call, fullscreen, video — most of
the user's day) were silently dropped; and the timers stopped on a hold
transition and never restarted.
**Lesson:** Suppression should defer, not drop, when the event still matters
after the blocker clears. And "start/stop on state change" leaks stopped
timers whenever a state change is missed; prefer always-running with a gate.

## 7. Countdown restarted mid-call (v0.0.6)

**Saw:** 20-min countdown restarted to 20:00 while sitting on a call.
**Cause:** Hands-still listening crossed the 180s idle threshold (suppression
only covered media, not calls); the "return" then credited the away time as
a break and started a fresh cycle.
**Lesson:** Engagement (mic, camera, share, media) is presence evidence, not
just break-hold input — wire it into idle suppression raw, independent of
user toggles. And distinguish "user returned" from "the away call was wrong":
a retraction restores; a return credits.

## 6. Two minutes to return to timer after a WhatsApp call (v0.0.6)

**Saw:** Call ended; icon stayed on the person for 2+ minutes.
**Cause:** Two stacked delays: WhatsApp itself holds the macOS mic 30-90s
after hangup (verified live, unfixable), plus our 60s linger applied to the
mic like everything else.
**Lesson:** Per-signal semantics matter: the mic is stable evidence (open
through silences), so its release means the activity ended — long linger is
wrong for it. Also: when the OS or another app adds latency you can't fix,
NAME the culprit in the UI ("On a call (WhatsApp)") so the user sees an
explanation instead of a mystery.

## 5. Break fired during a muted call (v0.0.6)

**Saw:** Long break fired mid-call, right after muting.
**Cause:** My per-signal linger fix from the day before. Muting releases the
mic while the call continues; the 10s "stable" linger then dropped the hold.
**Lesson:** A call is an audio SESSION (mic + output from the same app), not
a mic state. Fixing a delay by tuning a constant traded a 2-minute annoyance
for a mid-call interruption — fix the model, not the number.

## 4. Fullscreen detection never worked on this Mac (v0.0.5)

**Saw:** On a real fullscreen Space, no hold, countdown ticking.
**Cause:** On notched MacBooks a real fullscreen window and a maximized
window have IDENTICAL geometry (both render below the camera housing), so
the geometry check — tuned earlier to kill a maximized-window false positive
— could never match real fullscreen on this hardware.
**Lesson:** Synthetic fixtures must match real hardware: my test helper
filled the whole screen frame; real fullscreen never does on a notch. Prefer
the system's own truth (window server Space type) over geometry heuristics.
Also: a fix that kills a false positive can create a false negative — test
both directions.

## 3. Wrong icon while watching YouTube; sleep icon while working (v0.0.5)

**Saw:** Person (call) icon during a video; moon icon mid-video.
**Cause:** All hold reasons mapped to one icon; and idle suppression was
gated on the video hold-toggle, which a previous test run had left disabled
(test pollution of live preferences).
**Lesson:** Icons must name their reason (and a nameless reason is a
regression signal). Tests must never write the live preference domain —
isolate the store under the test runner, and verify restoration in the same
step that changes a preference.

## 2. Menu bar icon invisible on first run (v0.0.1)

**Saw:** App running, no icon anywhere.
**Cause:** Crowded notched menu bar: macOS hides the lowest-priority item,
and a brand-new app's item is lowest priority. Also NSStatusBarButton
ignores subview Auto Layout constraints, so the label had zero width.
**Lesson:** Menu bar real estate is contested; seed a preferred position and
drive the item's length explicitly from the SwiftUI fitting size.

## 1. Break overlay burned CPU after dismissal (v0.0.1)

**Saw:** 3-6% CPU after a break ended.
**Cause:** Ordered-out panels kept live NSHostingViews whose TimelineView
animations kept rendering invisibly.
**Lesson:** `orderOut` hides a window; it does not stop its SwiftUI content.
Nil the contentView on teardown. Corollary discovered later (v0.0.4): the
claim "the render server animates this for free" must be MEASURED during the
visible phase — animating MeshGradient points ran 10-19% CPU on the main
thread while "idle" measured 0%.

---

## The recurring patterns (what to actually learn)

1. **Transitions, not states.** Nearly every bug lived in a lifecycle edge:
   mute, wake, un-fullscreen, walking away mid-break, restart. Testing the
   steady states on either side missed all of them.
2. **Two owners of one fact will desync.** The away/idle bugs all reduce to
   two components independently tracking presence. One authority, everyone
   else consumes.
3. **Derived values decay; anchors don't.** Frozen "20m", reset cadences,
   suspended timers — all from storing a countdown instead of a date.
4. **Inference needs evidence rules AND bounds.** Seeding thresholds,
   identity continuity, TTLs, ceilings. A heuristic without an expiry
   becomes a phantom factory.
5. **My fixes caused four of the bugs** (5, 13, 14, 16). Every fix that
   tunes behavior in one scenario must be tested against the neighboring
   scenarios it changes — the review-then-field-test pipeline exists because
   self-review alone missed these.
6. **The user found what tests could not.** Ten-plus bugs were only visible
   on a real machine with real calls, real sleep cycles, a notch, and a
   dictation daemon. Field use is a test layer, not an afterthought.
