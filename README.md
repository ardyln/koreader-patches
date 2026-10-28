# KOReader user patches: background network requests

Two [KOReader user patches](https://koreader.rocks/user_guide/#L2-userpatches) that stop
sync plugins from freezing KOReader while they wait on the network.

Both plugins below send HTTP requests on KOReader's UI thread. While a request waits, KOReader
can't handle touches, and on Android a wait over 5 s while you touch the screen ends in an ANR
("KOReader isn't responding", logged as `Input dispatching timed out`). That happens whenever the
server is slow or unreachable, or Wi-Fi is still reconnecting after the device wakes.

The patches move the requests into a subprocess (`ffi/util` `runInSubProcess`) and poll it from
`UIManager`, so KOReader keeps handling input. Results are applied on the UI thread as before.

| Patch | Plugin | Covers | Still blocks |
|---|---|---|---|
| `2-hatelemetry-background-requests.lua` | [hatelemetry.koplugin](https://github.com/hudsonbrendon/hatelemetry.koplugin) v0.4.0 | every telemetry push (webhook and legacy REST); also keeps one periodic push loop across file manager/reader switches | "Test connection" in the menu |
| `2-hatelemetry-push-on-change.lua` | hatelemetry.koplugin v0.4.0 | pushes when something changes (page turn after 4 s, otherwise a local check every 60 s: page, book, battery, charging, front light, Wi-Fi, highlights); the plugin's timer becomes a heartbeat | n/a |
| `2-cwngsync-background-requests.lua` | cwngsync.koplugin ([Calibre-Web NextGen](https://github.com/new-usemame/Calibre-Web-NextGen)) 4.1.48 to 4.1.56 | the JSON calls (progress, inventory, library manifest, annotations, deliveries, collections, pairing) and the sleep screen sync | book/placeholder downloads and the checksum after a download |

Each patch turns itself off when the plugin already does this, so it can stay installed after
the plugin is updated.

## Install

Copy the `.lua` files from `patches/` into `koreader/patches/` and restart KOReader.

User patches don't run in the **F-Droid build** of KOReader (`org.koreader.launcher.fdroid`):
`userpatch.lua` makes them a no-op there. Use the build from KOReader's GitHub releases.

## Push on change

hatelemetry pushes on open/close, sleep/wake and every `interval` seconds, so Home Assistant lags
up to that long behind a page turn and gets identical snapshots while nothing happens. With
`2-hatelemetry-push-on-change.lua` a page turn reached Home Assistant in 4.6 s, and an open book
left alone sent nothing for 3 minutes. Raise the plugin's interval (menu: HA Telemetry → interval)
to e.g. 1800 s so the timer only acts as a heartbeat. Each change-driven push logs which fields
changed (`[HATelemetry]: changed, pushing: ...`).

## How it was checked

Boox Go Color 7 Gen 2, Android 13, KOReader 2026.07.1. Each plugin was pointed at an address
that never answers (10.255.255.1), so every request hung until its timeout, while Scroll Lock was
pressed every 1.5 s for 30 s:

| Plugin | Without patch | With patch |
|---|---|---|
| hatelemetry (10 s push interval) | ANR | no ANR; every push timed out in the subprocess |
| cwngsync (startup sync) | ANR | no ANR; calls failed in parallel with the usual error text |

Against the real servers both plugins sync as before.

Don't test cwngsync by changing its server URL. It treats a different server as a different
account: it sets aside the library's downloaded books and clears the placeholders, and brings
them back when the URL is restored.

## Upstream

These are stopgaps. `upstream/` holds the change proposed to hatelemetry itself; once the plugins
fix this themselves, delete the matching patch.
