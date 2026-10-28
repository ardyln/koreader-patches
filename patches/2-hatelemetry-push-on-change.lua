--[[--
User patch for hatelemetry.koplugin (https://github.com/hudsonbrendon/hatelemetry.koplugin, v0.4.0).

Pushes telemetry when something changes instead of only on a timer. The plugin
pushes on open/close, sleep/wake and every `interval` seconds (default 300),
whether or not anything changed, so Home Assistant lags up to that long behind
a page turn and still gets identical snapshots while nothing happens.

With this patch a push goes out when something changes, driven by KOReader's
own events, without polling the snapshot:
- page turn: PAGE_DEBOUNCE seconds after the last turn;
- charging/not charging, front light on/off, brightness, warmth, Wi-Fi
  connected, highlights/notes changed: EVENT_DEBOUNCE seconds after the event;
- battery: its level alone is read every BATTERY_INTERVAL seconds (cheap).
Each of these collects a snapshot locally and pushes only if a tracked field
differs from the last one sent. The plugin's own periodic push stays as a
heartbeat; set its interval high (e.g. 1800 s) in the plugin menu.

Fields that change by themselves as time passes (last_seen, reading minutes,
time-to-finish estimates, reading speed) don't trigger a push; they ride along
with the next one.

Works with or without 2-hatelemetry-background-requests.lua: it hooks collect(),
which every push calls, and leaves push() alone.
--]]--

local Device = require("device")
local PluginLoader = require("pluginloader")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local PAGE_DEBOUNCE = 4       -- s after the last page turn
local EVENT_DEBOUNCE = 2      -- s after a charging/light/network/annotation event
local BATTERY_INTERVAL = 300  -- s between battery level reads while awake

-- Snapshot fields that change with time alone.
local VOLATILE = {
    last_seen = true,
    reading_time_today_min = true,
    session_time_min = true,
    total_time_min = true,
    reading_speed_pph = true,
    time_to_finish_book_min = true,
    time_to_finish_chapter_min = true,
}

-- Lives in this file, not on the plugin, because the plugin table is replaced on every reload.
local state = {
    plugin = nil,   -- the current plugin instance
    last_sig = nil, -- signature of the last snapshot a push collected
    last_snap = nil, -- that snapshot's tracked fields, to log what changed
    battery_fn = nil, -- scheduled battery read
    check_fn = nil,   -- scheduled (debounced) change check
}

-- The tracked fields as strings, and a signature of them.
local function tracked(snap)
    if type(snap) ~= "table" then return nil end
    local fields, keys = {}, {}
    for k, v in pairs(snap) do
        if not VOLATILE[k] and type(v) ~= "table" and type(v) ~= "function" then
            fields[k] = tostring(v); keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. fields[k] end
    return table.concat(parts, ";"), fields
end

local function changedKeys(old, new)
    local out = {}
    for k, v in pairs(new) do if not old or old[k] ~= v then out[#out + 1] = k end end
    if old then for k in pairs(old) do if new[k] == nil then out[#out + 1] = k end end end
    table.sort(out)
    return table.concat(out, ", ")
end

local function patchPlugin(HATelemetry)
    if HATelemetry.pushOnChange or HATelemetry._push_on_change_patch then return end
    local orig_collect, orig_init = HATelemetry.collect, HATelemetry.init
    local orig_onPageUpdate = HATelemetry.onPageUpdate
    local orig_onSuspend, orig_onResume = HATelemetry.onSuspend, HATelemetry.onResume
    if not (orig_collect and orig_init and orig_onPageUpdate and orig_onSuspend and orig_onResume) then
        logger.warn("hatelemetry push-on-change patch: plugin layout changed, not applied")
        return
    end
    HATelemetry._push_on_change_patch = true

    -- Every push collects a snapshot right before sending it: remember what went out.
    HATelemetry.collect = function(self, reading_override)
        local snap = orig_collect(self, reading_override)
        state.last_sig, state.last_snap = tracked(snap)
        return snap
    end

    -- Collect locally (not recorded as sent) and push if a tracked field changed.
    local function checkNow()
        local plugin = state.plugin
        if not plugin or not plugin.settings or not plugin.settings.enabled then return end
        local ok, snap = pcall(orig_collect, plugin, true)
        if not ok then return end
        local sig, fields = tracked(snap)
        if sig and sig ~= state.last_sig then
            logger.info("[HATelemetry]: changed, pushing:", changedKeys(state.last_snap, fields))
            plugin:push(true)
        end
    end

    -- Debounced: a burst of events (or page turns) leads to one check.
    local function checkSoon(delay)
        if state.check_fn then UIManager:unschedule(state.check_fn) end
        state.check_fn = function()
            state.check_fn = nil
            checkNow()
        end
        UIManager:scheduleIn(delay, state.check_fn)
    end
    state.checkSoon = checkSoon

    local function stopChecks()
        if state.battery_fn then UIManager:unschedule(state.battery_fn); state.battery_fn = nil end
        if state.check_fn then UIManager:unschedule(state.check_fn); state.check_fn = nil end
    end

    -- Battery has no event: read just the level now and then, collect only if it moved.
    local function startBatteryReads()
        stopChecks()
        local powerd = Device:getPowerDevice()
        local fn
        fn = function()
            local ok, level = pcall(powerd.getCapacity, powerd)
            if ok and state.last_snap and tostring(level) ~= state.last_snap.battery_level then checkNow() end
            if state.battery_fn == fn then UIManager:scheduleIn(BATTERY_INTERVAL, fn) end
        end
        state.battery_fn = fn
        UIManager:scheduleIn(BATTERY_INTERVAL, fn)
    end

    HATelemetry.init = function(self, ...)
        local ret = orig_init(self, ...)
        -- KOReader re-creates the plugin on each file manager/reader switch; follow the newest copy.
        state.plugin = self
        startBatteryReads()
        return ret
    end

    HATelemetry.onPageUpdate = function(self, pageno)
        local ret = orig_onPageUpdate(self, pageno)
        checkSoon(PAGE_DEBOUNCE)
        return ret
    end

    for _, name in ipairs({ "onCharging", "onNotCharging", "onFrontlightStateChanged",
                            "onNetworkConnected", "onAnnotationsModified" }) do
        local orig = HATelemetry[name]
        HATelemetry[name] = function(self, ...)
            checkSoon(EVENT_DEBOUNCE)
            if orig then return orig(self, ...) end
        end
    end

    HATelemetry.onSuspend = function(self, ...)
        stopChecks()
        return orig_onSuspend(self, ...)
    end

    HATelemetry.onResume = function(self, ...)
        startBatteryReads()
        return orig_onResume(self, ...)
    end
end

-- Brightness and warmth changes have no event: wrap the power device's setters once.
local function wrapPowerd()
    local powerd = Device:getPowerDevice()
    if not powerd or powerd._push_on_change_wrapped then return end
    powerd._push_on_change_wrapped = true
    for _, name in ipairs({ "setIntensity", "setWarmth" }) do
        local orig = powerd[name]
        if type(orig) == "function" then
            powerd[name] = function(...)
                local ret = { orig(...) }
                if state.checkSoon then state.checkSoon(EVENT_DEBOUNCE) end
                return unpack(ret)
            end
        end
    end
end

-- Patch before the plugin is instantiated, so its init already starts the battery reads.
local orig_createPluginInstance = PluginLoader.createPluginInstance
PluginLoader.createPluginInstance = function(this, plugin, attr)
    if plugin.name == "hatelemetry" then
        local ok, err = pcall(patchPlugin, plugin)
        if not ok then logger.warn("hatelemetry push-on-change patch failed:", err) end
        pcall(wrapPowerd)
    end
    return orig_createPluginInstance(this, plugin, attr)
end
