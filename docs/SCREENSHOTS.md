# Screenshots

The images in [screenshots/](screenshots/) are produced by
`HealthExporterUITests/ScreenshotTests.swift`, not taken by hand. Taking them by
hand means they go stale the moment the UI moves and nobody but the person with
that phone can refresh them.

**They must never show a real health record.** These files are committed. The
capture runs against a throwaway server holding generated data, and the numbers
in them belong to nobody.

---

## What you need

A server the phone can reach over **HTTPS** — `SinkConfiguration.endpoint`
returns nil for anything else, which disables the Sign In button — holding
enough history for a 7-day window and a 28-day baseline to both be full. Roughly
twelve weeks.

Three things make a local one work:

**A certificate the Simulator trusts.** Issue a local CA and a leaf for
`localhost`, then hand the CA to the device:

```bash
xcrun simctl keychain <device> add-root-cert ca.pem
```

That is narrower than it looks — it trusts that CA on that simulator only. It is
also why no ATS exception is needed: the certificate validates normally.

**TLS in front of Django.** `manage.py runserver` does not speak it. Anything
that terminates TLS and forwards to it will do.

**Data.** Twelve weeks of it, with a deliberate gap in one metric so the "stopped
arriving" path is visible rather than theoretical — `04-data.png` shows Blood
Oxygen not seen in 48 hours, which is the whole freshness design in one line.

---

## Running it

```bash
TEST_RUNNER_SCREENSHOT_SERVER=https://localhost:8443 \
TEST_RUNNER_SCREENSHOT_USER=demo \
TEST_RUNNER_SCREENSHOT_PASSWORD=... \
  xcodebuild test -project HealthExporter.xcodeproj -scheme HealthExporter \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -resultBundlePath /tmp/shots.xcresult \
    -only-testing:HealthExporterUITests/ScreenshotTests
```

Then pull the images out and downscale them — native @3x is 1206×2622 and about
300 KB each, which is more than a README should carry:

```bash
xcrun xcresulttool export attachments --path /tmp/shots.xcresult --output-path /tmp/shots
# names are in /tmp/shots/manifest.json
sips -Z 900 docs/screenshots/*.png
```

`ScreenshotTests` holds two tests. `testCaptureEveryTab` photographs the four
tabs; `testServerUnreachableAlert` signs in, repoints the URL at a port nothing
listens on, relaunches, and checks the startup alert appears with all three of
its buttons. The second is the only runtime coverage that check has — the
condition needs a signed-in app pointed at a dead server, which no unit test can
arrange.

The tests **skip** unless `SCREENSHOT_SERVER` is set, so an ordinary
`xcodebuild test` on a machine with no demo server does not fail on a fixture it
cannot reach.

---

## Five things that will bite you

**`TEST_RUNNER_` is not decoration.** `xcodebuild` does not pass the host's
environment to a test running on the simulator. Variables prefixed
`TEST_RUNNER_` are forwarded with the prefix stripped; without it the test reads
nothing and quietly skips, and the run still reports success.

**Do not disable code signing.** `CODE_SIGNING_ALLOWED=NO` drops the
entitlements, and the Keychain then fails every write with `OSStatus -34018`
(`errSecMissingEntitlement`). Sign-in appears to do nothing, because the token
it obtained could not be stored. Ad-hoc signing is enough:
`CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`.

**The Simulator Keychain outlives the app.** It is device-wide, so uninstalling
does not clear the token and the app opens already signed in — with no Username
field, which is not an obvious thing to debug. The test signs out first, and
deliberately sets the server URL *before* doing so: sign-out revokes against
whatever server is configured, and that ordering guarantees the request goes to
the throwaway instance rather than to whatever the leftover token belongs to.

**A SwiftUI `Toggle` in a `List` publishes two elements** — the full-width
labelled row and the control inside it — and only the control responds to a tap.
`app.switches["Upload automatically"].tap()` lands in the middle of the label
and changes nothing, silently. Tap the nested switch.

**The test relaunches the app after signing in.** Launch fetches the snapshot
before the test has a valid token, so those requests 401 and the screens keep
the resulting error line — correctly; it was true when it happened. It is still
on screen after a successful sign-in until something re-fetches. A fresh launch
is both a cleaner picture and a more representative one.

---

## HealthKit is not part of this

The Simulator has no Health data and `simctl privacy` has no `health` service to
grant, so the Today tab keeps its "Grant Health access to begin" card. That is
honest — it is what the app looks like on a device that has not been granted
access — and everything below it is real analysis of the data on the server.

---

## The "before" shot

`docs/design/before-summary.png` is the old Summary tab, kept deliberately: the
teardown board in [design/](design/) argues against it, and that argument stops
making sense the moment the image is refreshed to the screen that replaced it.
It is the one screenshot here that must **not** be regenerated.
