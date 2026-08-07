# App lifecycle and responsiveness

What happens between tapping the icon and a usable interface, what runs where,
and the rules that keep the main thread free.

Written because this went wrong in a specific and instructive way: the app used
to await a sync over ~130 HealthKit types before the first screen could finish
appearing — the heaviest work in the app, scheduled at the exact moment somebody
is trying to touch it.

---

## Startup, in order

| Stage | Who paints it | Blocking? |
|---|---|---|
| Process start → first frame | **iOS**, from `UILaunchScreen` | Nothing app-side can run here |
| First frame → usable interface | `BootView`, if it earns its place | Waits on the view cache only |
| Behind the interface | Observers, sync, figure refresh | Never blocks the UI |

### The launch screen is the only fix for the blank frame

`UILaunchScreen` was an empty dictionary, which means "plain system background" —
white in light mode, **black in dark**, for as long as the process takes to draw.
No SwiftUI view can reach that frame: it is painted before any app code runs. The
only fix is to name a colour, which now matches the background the app opens onto
so the handover is not a visible jump.

### The boot screen only appears if the app is slow

`BootProgress` waits **250ms** before showing anything. On a normal launch it
never appears at all — showing a progress bar for 200ms makes an app feel *less*
responsive, not more. Once it has appeared it stays a minimum of 350ms so it
cannot flash, and a **4-second watchdog** dismisses it whatever is outstanding.
Boot is allowed to be slow; it is not allowed to be indefinite.

It reports one step, because there is now only one thing the interface waits on.
Anything else on that bar would be padding to look busy.

### Cache first

Everything the first screen draws used to come from a network round trip, so
every launch showed placeholder text until it landed — on a bad connection that
*was* the experience of opening the app.

The snapshot, trend series and insight status are written to disk after each
successful fetch (`view-cache.json`) and restored at launch, off the main thread.
The refresh still happens; it is simply no longer between the user and the app.

**A cache obliges two things.** Say how old it is — the "Updated …" line
describes the *figures*, not the sync, because a screen of yesterday's numbers
under a line claiming everything happened a minute ago is the specific dishonesty
a cache invites. And protect it: caching health summaries means writing health
figures to disk, so `StateStore` sets complete-until-first-authentication
protection on every write.

### Then, behind the interface

Observer registration (~130 types), the full sync, and the figure refresh, in a
retained `Task(priority: .background)` so every piece of UI work preempts it. The
handle is retained so a second `.task` — a tab switch, a scene re-activation —
joins the run already in flight rather than starting a second sync.

---

## Resuming is not launching

`.task` fires once for the lifetime of the view, so an app resumed after two days
showed two-day-old figures until something else happened to refresh them.

`scenePhase` now handles it, and deliberately does **not** re-run launch:
re-registering observers and re-syncing every time somebody glances at the app is
how a phone gets warm in a pocket. On `.active` it refreshes the figures only if
they are older than five minutes, and drains whatever the observers flagged while
the app was away. On `.background` it flushes the log.

---

## Main-thread rules

`SyncEngine` is `@MainActor`, so **every non-`async` call inside it is a hang of
exactly its own duration**, and `Task.yield()` between calls cannot break up a
single one. The rules that follow from that:

**Normalisation happens where HealthKit hands the data over.**
`HKAnchoredObjectQuery` already delivers on a background queue; the reader
normalises inside its own results handler and returns `[HealthRecord]` values.
That removes the last per-sample CPU work from the main thread — and it is the
safer boundary anyway, since `HKSample` is a non-`Sendable` Objective-C object
that Swift 6 will refuse to let cross actors.

**File work is `nonisolated async`.** Called with `await` from the main actor, a
nonisolated async function runs on the cooperative pool rather than inheriting the
caller's actor. Spooling, the outbox listing and count, and the archive prune all
work that way. Spooling is still *awaited*, because the caller advances its sync
anchor immediately afterwards and an anchor past data that is not yet on disk
turns any failure into silent loss.

**Locks stay in synchronous frames.** Taking an `NSLock` inside an `async`
function is a warning today and an error in Swift 6, because the compiler cannot
tell whether it is held across a suspension — and one held across an `await`
deadlocks as soon as two tasks want it. Critical sections are extracted so there
is no `await` they could straddle.

**Progress publishing is throttled.** `phase` is `@Published` on an object seven
views observe, and `ObservableObject` has no per-property tracking: every
assignment invalidates all of them. A sync assigned it ~130 times. Progress now
lands at most every 200ms; terminal states are never throttled, because a
swallowed `.idle` leaves a spinner turning over a finished sync.

**Nothing expensive in a view `body`.** Four computed properties were doing real
work on every evaluation — reading the anchor store behind a lock, re-sorting ~170
metrics, formatting relative dates per cell. `CoverageGrid` re-sorted its whole
grid on every *tap*, because selecting a cell mutates `@State`. Resolve once in
`init` and hold the result.

**Charts need a derivable mark dimension.** A `BarMark` against a bare `Date` has
nothing to compute a bar width from, so Charts guesses per mark, per layout pass,
per bar, and logs *"falling back to a fixed dimension size"*. Name the unit:
`.value("Day", point.day, unit: .day)`.

**Keyboard avoidance is a scene-wide geometry change.** A keyboard raised on one
tab re-lays-out views alive behind other tabs. Screens that take no text input
should say so: `.ignoresSafeArea(.keyboard, edges: .bottom)`.

---

## Two traps in observing state

**Nested `ObservableObject` changes do not propagate.** `BootProgress` is
published *by* `AppServices`, and changes to it do not invalidate views observing
`AppServices`. The boot screen rendered, updated its own label and bar — and
stayed on screen for ever, because the view holding `if !isFinished` never
re-evaluated. The condition has to live in a view that observes the object
itself. It compiles, it renders, and it is invisible until you launch it.

**An async read can overwrite a newer write.** Moving the queue count off the main
thread made `refreshCounts()` fire-and-forget, so a read could still be in flight
when delivery finished and published zero — then land last and put the number
back up. An empty outbox under a UI reporting three batches stuck: uploads working
perfectly and the interface insisting otherwise. Every writer now goes through one
path with a request token, and a read superseded while in flight discards its own
result.

---

## Measuring it

`Log.blocking(_:_:over:)` times a synchronous block and reports only when it held
the main thread longer than a threshold, because Xcode's hang detector says a
hang happened and not which call did it. Filter the console on the `perf`
category; silence means the instrumented paths are clear.

Two things to know before trusting a number:

- **Debugger-attached figures are inflated.** Every hang line says
  `App is being debugged, do not track this hang` — the detector is telling you it
  is not reporting them precisely because the debugger distorts timing. Test a
  Release build launched from the home screen.
- **The app's own log is the better source, and it flushes on a debounce.**
  Persistence is debounced two seconds so a large sync does not rewrite the file
  thousands of times, and the cost was the tail — the part that says how a session
  ended. It is flushed on backgrounding now. Pull it off a connected device with:

  ```bash
  xcrun devicectl device copy from --device <udid> \
    --domain-type appDataContainer --domain-identifier com.lionelchong.HealthExporter \
    --source "Library/Application Support/HealthExporter/sync.log" --destination ./sync.log
  ```

  The same command reaches `anchors.json` and `Documents/Outbox`, which is how you
  tell a stuck queue from a stuck counter.
