--[[--
User patch for KOReader on Android: sleep after N minutes without any input,
counting remote commands as input.

KOReader's custom screen timeout on Android is the system screen-off timeout,
and Android counts it from the last touch only. Page turns sent from Home
Assistant (HTTP Inspector, or the hatelemetry command listener) don't count,
so with a timeout the device sleeps under you while you read with a remote,
and with "keep screen on" it never sleeps at all.

This patch keeps the screen on while you are active and runs its own idle
timer, reset by every input KOReader sees: touches, keys, and requests on its
event-loop sockets (both remote command servers). After IDLE minutes it hands
back to Android with the shortest system timeout; Android, counting from the
last touch, then sleeps right away. After waking, the first input switches
back to "keep screen on".

The idle time is the "android_idle_sleep_minutes" setting (default 10).
KOReader's own screen timeout setting should stay on "keep screen on".
--]]--

local Device = require("device")
if not Device:isAndroid() then return end

local UIManager = require("ui/uimanager")
local logger = require("logger")
local android = require("android")
local time = require("ui/time")

local KEEP_ON = -1
local HAND_BACK = 2 * 60 * 1000 -- shortest timeout the launcher accepts

local idle_s = (tonumber(G_reader_settings:readSetting("android_idle_sleep_minutes")) or 10) * 60
local last_input = UIManager:getElapsedTimeSinceBoot()
local handed_back = false
local check

local function keepOn()
    android.timeout.set(KEEP_ON)
    handed_back = false
end

check = function()
    local idle = time.to_number(UIManager:getElapsedTimeSinceBoot() - last_input)
    if idle >= idle_s then
        logger.info("idle sleep: no input for", math.floor(idle / 60), "min, handing the screen timeout back to Android")
        handed_back = true
        android.timeout.set(HAND_BACK)
    else
        UIManager:scheduleIn(idle_s - idle, check)
    end
end

UIManager.event_hook:register("InputEvent", function()
    last_input = UIManager:getElapsedTimeSinceBoot()
    if handed_back then
        keepOn()
        UIManager:unschedule(check)
        UIManager:scheduleIn(idle_s, check)
    end
end)

keepOn()
UIManager:scheduleIn(idle_s, check)
