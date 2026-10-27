--[[--
User patch for hatelemetry.koplugin (https://github.com/hudsonbrendon/hatelemetry.koplugin, v0.4.0).

1. Sends telemetry from a subprocess. The plugin posted to Home Assistant with
   socket.http on KOReader's UI thread, so a slow or unreachable server froze
   KOReader for up to the 6 s timeout; on Android a freeze over 5 s while you
   touch the screen is an ANR ("Input dispatching timed out").
2. Keeps one periodic push loop. KOReader loads the plugin afresh for every
   file manager / reader switch, and each copy started a loop of its own.

It turns itself off when the plugin already sends in the background (the
upstream change adds HATelemetry.runInBackground), so it can stay installed
after an update. Commands from Home Assistant still run on the UI thread.
"Test connection" in the plugin menu still blocks; it is only run by hand.
--]]--

local PluginLoader = require("pluginloader")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")
local userpatch = require("userpatch")

local POLL_INTERVAL = 0.5 -- s between checks on the subprocess
local DEADLINE = 30       -- s before a subprocess that hasn't finished is killed

-- Lives in this file, not on the plugin, because the plugin table is replaced on every reload.
local state = {
    busy = false,     -- a push is in flight
    pending = nil,    -- { plugin = instance, reading = bool }: the latest push asked for meanwhile
    loop_fn = nil,    -- pushLoop of the copy that owns the periodic loop
}

-- Collect the child (no zombie) and close the pipe without blocking the UI.
local function reap(pid, read_fd)
    if ffiutil.isSubProcessDone(pid) then
        if read_fd then ffiutil.readAllFromFD(read_fd) end -- child gone: pipe at EOF
        return
    end
    UIManager:scheduleIn(POLL_INTERVAL, function() reap(pid, read_fd) end)
end

-- Run task() (returns a string) in a subprocess; on_done(output|nil, err|nil) runs on the UI thread.
local function runInBackground(task, on_done)
    local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, out = pcall(task)
        ffiutil.writeToFD(write_fd, ok and type(out) == "string" and out or "", true)
    end, true)
    if not pid then
        local ok, out = pcall(task) -- no fork: block as before rather than drop the push
        if ok then on_done(out, nil) else on_done(nil, tostring(out)) end
        return
    end
    local waited = 0
    local function poll()
        local ready = ffiutil.getNonBlockingReadSize(read_fd)
        if (ready and ready > 0) or ffiutil.isSubProcessDone(pid) then
            -- The child writes only after its request and closes the pipe right
            -- after, so this read doesn't wait on the network.
            local out = ffiutil.readAllFromFD(read_fd)
            reap(pid, nil)
            if out ~= "" then on_done(out, nil) else on_done(nil, "subprocess returned nothing") end
            return
        end
        waited = waited + POLL_INTERVAL
        if waited >= DEADLINE then
            ffiutil.terminateSubProcess(pid)
            reap(pid, read_fd)
            on_done(nil, "timeout")
            return
        end
        UIManager:scheduleIn(POLL_INTERVAL, poll)
    end
    UIManager:scheduleIn(POLL_INTERVAL, poll)
end

local function patchPlugin(HATelemetry)
    if HATelemetry.runInBackground or HATelemetry._background_patch then return end
    local orig_push, orig_pushLoop = HATelemetry.push, HATelemetry.pushLoop
    -- The plugin's own modules and config, exactly as main.lua captured them.
    local ha_config = userpatch.getUpValue(orig_push, "ha_config")
    local HAWebhook = userpatch.getUpValue(orig_push, "HAWebhook")
    local HAClient = userpatch.getUpValue(orig_push, "HAClient")
    local Commands = userpatch.getUpValue(orig_push, "Commands")
    local Sensors = userpatch.getUpValue(orig_push, "Sensors")
    local NetworkMgr = userpatch.getUpValue(orig_push, "NetworkMgr")
    if not (ha_config and HAWebhook and HAClient and Commands and Sensors and NetworkMgr) then
        logger.warn("hatelemetry background patch: plugin layout changed, not applied")
        return
    end
    HATelemetry._background_patch = true
    local rapidjson = require("rapidjson")

    local function finished()
        state.busy = false
        local nxt = state.pending
        state.pending = nil
        if nxt then nxt.plugin:push(nxt.reading) end
    end

    HATelemetry.push = function(self, reading)
        if not NetworkMgr:isConnected() then
            if not self._offline_logged then
                logger.info("[HATelemetry]: sem rede, pulando envio")
                self._offline_logged = true
            end
            return
        end
        self._offline_logged = false

        -- One request at a time; a push asked for meanwhile is sent once it finishes.
        if state.busy then
            state.pending = { plugin = self, reading = reading }
            return
        end
        local snap = self:collect(reading)
        state.busy = true

        local use_webhook = ha_config.webhook_id ~= nil
            and ha_config.webhook_id ~= ""
            and ha_config.webhook_id ~= "ColeSeuWebhookIdAqui"

        if use_webhook then
            runInBackground(function()
                -- The plugin's own post(): ok, commands, err, kind.
                local ok_post, commands, post_err = HAWebhook.post(ha_config, snap)
                return rapidjson.encode({ ok = ok_post, commands = commands, err = post_err })
            end, function(out, err)
                local decoded = out and select(2, pcall(rapidjson.decode, out))
                if type(decoded) ~= "table" then
                    logger.info("[HATelemetry]: webhook falhou -", err or "invalid subprocess output")
                elseif not decoded.ok then
                    logger.info("[HATelemetry]: webhook falhou -", decoded.err)
                elseif type(decoded.commands) == "table" and #decoded.commands > 0 then
                    Commands.apply_all(decoded.commands, self:commandDeps())
                end
                finished()
            end)
            return
        end

        -- Legacy mode: one POST per entity to /api/states, all in the same subprocess.
        local entities = Sensors.build(snap, { prefix = self.settings.entity_prefix })
        runInBackground(function()
            local failures = { "done" } -- "done" first, so no failures still reaches the UI side
            for _, entity in ipairs(entities) do
                local ok_post, err, kind = HAClient.post(ha_config, entity)
                if not ok_post then
                    table.insert(failures, entity.entity_id .. " - " .. tostring(err))
                    if kind == "connection" then break end
                end
            end
            return table.concat(failures, "\n")
        end, function(out, err)
            if not out then
                logger.info("[HATelemetry]: push falhou -", err)
            else
                for line in out:gmatch("[^\n]+") do
                    if line ~= "done" then logger.info("[HATelemetry]: push falhou para", line) end
                end
            end
            finished()
        end)
    end

    HATelemetry.pushLoop = function(self, skip_first)
        -- Stop the loop a previous copy of the plugin left scheduled, then this copy's own.
        if state.loop_fn and state.loop_fn ~= HATelemetry.pushLoop then
            UIManager:unschedule(state.loop_fn)
        end
        state.loop_fn = HATelemetry.pushLoop
        UIManager:unschedule(HATelemetry.pushLoop)
        return orig_pushLoop(self, skip_first)
    end
end

-- Patch before the plugin is instantiated, so its first push (in init) already
-- goes through the subprocess. (userpatch.registerPatchPluginFunc runs after init.)
local orig_createPluginInstance = PluginLoader.createPluginInstance
PluginLoader.createPluginInstance = function(this, plugin, attr)
    if plugin.name == "hatelemetry" then
        local ok, err = pcall(patchPlugin, plugin)
        if not ok then logger.warn("hatelemetry background patch failed:", err) end
    end
    return orig_createPluginInstance(this, plugin, attr)
end
