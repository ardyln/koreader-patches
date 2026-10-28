# KOReader on a Boox: no more ANRs, pushing instead of waiting, and an event loop that sleeps

A KOReader setup on a Boox Go Color 7 Gen 2 (Android 13) talking to Home Assistant: telemetry
through [hatelemetry](https://github.com/hudsonbrendon/hatelemetry.koplugin), library and progress
sync through [CWNGSync](https://github.com/new-usemame/Calibre-Web-NextGen) (Calibre-Web NextGen),
and IKEA BILRESA buttons in Home Assistant turning pages. It kept showing "KOReader isn't
responding", Home Assistant was minutes behind the device, and the reader never slept while
KOReader was open. This is what was wrong and what the patches in this repository change.
Everything was measured on that device.

## 1. The ANRs

Android logged 11 "Input dispatching timed out" ANRs in one evening while reading. The traces
showed KOReader's Lua thread (it runs the UI and every plugin) in three places:

- `poll()` inside LuaSocket, i.e. waiting on the network (18 of 23 traces);
- `fread` and `unlinkat`, i.e. file I/O (the rest).

Both plugins send HTTP on that thread:

- **hatelemetry** posts a snapshot to a Home Assistant webhook on open/close, sleep/wake and
  every `interval` seconds, with a 6 s timeout.
- **CWNGSync** pushes progress 10 s after every 5 page turns (2/5 s timeouts), reports the device's
  book list around every open and close (10/30 s timeouts), and downloads books. One ANR was a
  12 s placeholder download while opening a book. Its client has an `AsyncHTTP` Spore middleware
  that was written for KOReader's old Turbo looper; with the looper gone, it returns early and
  every call blocks.

The network itself was fine (Wi-Fi ping ~15 ms, HTTP ~70 ms). The ANRs came from individual slow
requests and downloads that happened while a finger was on the screen: anything over 5 s is an ANR.

## 2. User patches, and why the F-Droid build couldn't have them

KOReader runs `.lua` files from `koreader/patches/` at startup, and plugin updates don't touch
them, so fixes there survive plugin updates. But `frontend/userpatch.lua` makes them a no-op in
the **F-Droid** build (`if android.prop.flavor == "fdroid" then return userpatch`). The device moved
to the build from KOReader's GitHub releases.

Two traps during that switch:

- Two KOReader builds sharing `/sdcard/koreader` don't mix. The older F-Droid build, opened once
  by habit after a reboot, saved the settings with its own `last_migration_date`. The newer build
  then replayed its one-time migrations, and the 2026-05-12 one rebuilt the HTTP Inspector
  settings without `autostart`. Uninstall the old build.
- KOReader's Lua side doesn't start while the screen is off. Wake the device before starting
  KOReader over adb.

## 3. Requests off the UI thread (`2-hatelemetry-background-requests.lua`, `2-cwngsync-background-requests.lua`)

KOReader ships the pieces: `ffi/util.runInSubProcess` forks, the child does the blocking work and
writes its result into a pipe, and the parent polls the child from `UIManager:scheduleIn`.

- **hatelemetry**: every push runs in a child; commands in Home Assistant's reply are applied on the
  UI thread. One push at a time; a push requested meanwhile goes out when it finishes. It also keeps
  a single periodic loop: KOReader re-loads plugins on every file manager/reader switch, and each
  copy used to start its own loop.
- **CWNGSync**: the patch gives `AsyncHTTP` a working implementation. Spore already supports an
  async middleware (return a coroutine and the request is suspended until resumed), so the child
  does the HTTP request and a poll resumes the request with the response. A transport error is
  raised again in the caller, so the client's own error handling sees the same message as before.
  The sleep-screen sync calls blocking methods that return values, so it runs in a coroutine whose
  `authorize` and sleep-screen requests wait for a child. Results come back as a Lua literal:
  rapidjson refused the server's capability table ("unencodable result"), which surfaced as
  `persistence_failed`.

Test: each plugin pointed at an address that never answers, with a key press every 1.5 s for 30 s.

| Plugin | Without patch | With patch |
|---|---|---|
| hatelemetry (10 s interval) | ANR | none; every push timed out in a child |
| CWNGSync (startup sync) | ANR | none; calls failed in parallel with the usual error text |

Not covered: CWNGSync's book and placeholder downloads and the checksum after a download. Their
callers use the result straight away, so they need a change in the plugin itself.

Don't test CWNGSync by changing its server URL: it treats another server as another account, sets
aside the downloaded books and clears the placeholders (they come back when the URL is restored).

## 4. Push when something changes (`2-hatelemetry-push-on-change.lua`)

Home Assistant doesn't poll; the plugin pushes on a timer, so Home Assistant lagged up to 5
minutes behind a page turn and got identical snapshots while nothing happened. The patch pushes on
KOReader's own events: a page turn (4 s after the last turn, and at most every 30 s while reading
on), charging, front light on/off, brightness and warmth (the power device's setters are wrapped;
there is no event), Wi-Fi connected, highlights. Battery level alone is read every 5 minutes. A
push goes out only if a tracked field differs from the last snapshot sent; fields that change by
themselves (reading minutes, estimates) ride along. The plugin's own timer becomes a heartbeat
(1800 s here).

Measured: a page turn reached Home Assistant in 4.6 s; an open book left alone sent nothing for
3 minutes; two quick page turns produced one push.

## 5. Commands from Home Assistant, instantly (`2-hatelemetry-command-listener.lua`)

The buttons used KOReader's HTTP Inspector, which is a debugging tool: no authentication and every
KOReader event exposed to the network. The integration's own controls (front light, notify text,
...) were queued until the plugin's next push.

The listener is a small authenticated endpoint: `POST /command` runs the plugin's own commands
(plus `toggle_dark_mode` and `push_now`), `POST /push` pushes now, `GET /state` returns the
snapshot. A Bearer token is generated on first start. Connections are kept open (HTTP keep-alive).
In Home Assistant the button `rest_command`s point at it, and an automation on `call_service` for
the integration's entities calls `/push`, so queued commands come back in the push's reply.

Measured: a command in 0.15 s over Tailscale, 14 ms on a kept-open connection; a `notify` message on
screen 2.1 s after Home Assistant sent it.

## 6. Sleeping while reading with a remote (`2-android-idle-sleep.lua`)

KOReader's custom screen timeout on Android writes Android's own screen-off timeout, which counts
from the last touch. Remote page turns don't count, so the device slept under a remote reader;
"keep screen on" was the workaround, and with it the device never slept. Toggling "keep screen on"
briefly to poke the timer doesn't work on this build (tested: Android still slept two minutes
after the last touch).

The patch keeps the screen on and runs its own idle timer, reset by every input KOReader sees
(touches, keys, requests on its sockets). After N idle minutes it hands back the shortest system
timeout; Android, counting from the last touch, sleeps about 2 minutes later. The first input after
waking turns "keep screen on" back on.

## 7. The event loop that never slept

With any server registered with UIManager (`insertZMQ`; the HTTP Inspector, or the listener),
UIManager caps every input wait at `ZMQ_TIMEOUT`, 50 ms, for as long as it runs. Measured on the
device with a book open and nothing happening: **1004 wake-ups of the UI thread per 30 s**.

The listener patch polls every 250 ms when idle and 50 ms for 30 s after input: 120 wake-ups per
30 s. The proper fix is in KOReader; `upstream/` has the change as two commits, tested on the
device by replacing the installed files:

- **koreader-base** `ffi/input_android.lua`: `input.addFd(fd)` / `input.removeFd(fd)` register a
  file descriptor with the app's ALooper under a new ident. When it's readable, `waitForEvent`
  returns `false, EAGAIN`. Not `ETIME`: `Input:waitEvent` takes `ETIME` as "a gesture timer may have
  expired" and could fire a hold timer early.
- **koreader**: `UIManager:insertZMQ` registers `zmq:getFd()` when the backend can watch it, and the
  50 ms cap applies only to ZMQs that can't be watched. `Input:waitEvent` returns to UIManager on
  `EAGAIN`. After `processZMQs` handles an event, input polling returns at once: without that, a
  page turn sent from Home Assistant was applied but not drawn until the next touch (found while
  testing). `SimpleTCPServer` exposes its listening fd.

| | 30 s idle, book open |
|---|---|
| stock KOReader with a server registered | 1004 wake-ups, 140 ms CPU |
| listener patch, adaptive polling | 120 wake-ups, 30 ms CPU |
| with the KOReader change | **0 wake-ups, 0 CPU** |

With the change, the HTTP Inspector's `GotoViewRel` and the listener's commands were drawn
immediately, taps and night mode behaved as before, and idle stayed at 0 with both servers running.
Only the Android backend gets `addFd`; other platforms keep polling.

## 8. Small things that cost time

- On Onyx, F12 opens the system brightness panel, which takes focus from KOReader. Use Scroll Lock
  as a harmless key for tests.
- KOReader's "next page" moves one screen, not one page, in a zoomed PDF. To put a reader back after
  a test, stop KOReader without saving and reopen the book: it restores the saved per-page offset.
- Wi-Fi power saving put the device's ping at 40-97 ms; each new connection costs one of those
  round trips.

## Open

- CWNGSync downloads and the post-download checksum still block.
- The fd wake-up only exists for Android; the Linux input backend could do the same.
- Telemetry and commands over Bluetooth LE (BTHome advertisements, a GATT command service) would
  let Wi-Fi stay off; worth it only if Wi-Fi turns out to be a meaningful share of the drain.
