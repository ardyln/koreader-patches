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
| `2-hatelemetry-push-on-change.lua` | hatelemetry.koplugin v0.4.0 | pushes when something changes, driven by KOReader events (page turn after 4 s, at most every 30 s while reading on; charging, front light, warmth, Wi-Fi, highlights) plus a battery read every 5 min; the plugin's timer becomes a heartbeat | n/a |
| `2-hatelemetry-command-listener.lua` | hatelemetry.koplugin v0.4.0 | an authenticated command endpoint (`POST /command`, `POST /push`, `GET /state`, port 8081) running the plugin's own commands, so Home Assistant can send them instantly instead of waiting for the next push; replaces the HTTP Inspector for remote control | n/a |
| `2-android-idle-sleep.lua` | KOReader on Android | sleeps after N idle minutes (`android_idle_sleep_minutes`, default 10; 5 here) counting remote commands as activity; keep KOReader's own screen timeout on "keep screen on" | n/a |
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
changed (`[HATelemetry]: changed, pushing: ...`). Pushes are driven by KOReader's events (page
turn, charging, front light on/off and brightness/warmth, Wi-Fi connected, highlights) plus a
battery-level read every 5 minutes; no snapshot polling.

## Command listener

`2-hatelemetry-command-listener.lua` listens on `*:8081` (set `host = "127.0.0.1"` in the
`hatelemetry_listener` setting for local only). Every request needs
`Authorization: Bearer <token>`; the token is generated on first start and written to
`settings.reader.lua` under `hatelemetry_listener`. Example from Home Assistant:

```yaml
rest_command:
  koreader_command:
    url: "http://<device>:8081/command"
    method: POST
    headers:
      Authorization: !secret koreader_listener_auth   # "Bearer <token>"
    content_type: application/json
    payload: "{{ command | tojson }}"
```

`command` is one of the plugin's commands (`{"type": "page_turn", "value": 1}`,
`{"type": "set_frontlight", "value": 40}`, `{"type": "show_message", "text": "Hi"}`, ...) or
`toggle_dark_mode` / `push_now`. Measured over Tailscale: 0.15 s per command. Each command also
counts as activity for `2-android-idle-sleep.lua`.

### Keep-alive and polling

The listener keeps HTTP connections open between requests (one TCP handshake less per command;
measured 14 ms per request on a kept-open connection). KOReader polls registered servers every
50 ms (`UIManager.ZMQ_TIMEOUT`) for as long as one runs: ~1000 wakeups of the UI thread per 30 s
of idle reading on the Boox. The patch polls every 250 ms when idle and 50 ms for 30 s after any
input (120 wakeups per 30 s). With the KOReader change proposed upstream (`input_android`
`addFd`, and UIManager watching a server's fd instead of polling it) the listener and the HTTP
Inspector cost nothing while idle: 0 wakeups and 0 CPU per 30 s, commands drawn immediately.

## Idle sleep on Android

KOReader's custom screen timeout is Android's own, counted from the last touch, so remote page
turns don't keep the device awake; "keep screen on" never lets it sleep. `2-android-idle-sleep.lua`
keeps the screen on and sleeps after `android_idle_sleep_minutes` without any input, touches and
remote commands alike, then restores "keep screen on" at the first input after waking. On a Boox
Go Color 7 Gen 2 the device went to sleep about 2 minutes after the idle time ran out (Android's
shortest timeout runs once more after the hand-over).

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
