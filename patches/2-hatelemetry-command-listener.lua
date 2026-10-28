--[[--
User patch for hatelemetry.koplugin (https://github.com/hudsonbrendon/hatelemetry.koplugin, v0.4.0).

A small authenticated command endpoint, so Home Assistant (or a button
automation) can send commands to KOReader the moment they happen. The plugin
otherwise only receives commands in the reply to its next push, and the
alternative, KOReader's HTTP Inspector, is a debugging tool: no authentication,
and it exposes every KOReader event.

    POST /command   body: {"type": ...} | [{...}, ...] | {"commands": [...]}
    POST /push      push telemetry now (Home Assistant then gets queued commands back)
    GET  /state     the current telemetry snapshot as JSON

Every request needs "Authorization: Bearer <token>". The port (default 8081),
bind address (default "*", or "127.0.0.1" for local only) and token live in
the "hatelemetry_listener" setting; the token is generated on first start.

Commands are the plugin's own (set_frontlight, set_warmth, set_frontlight_power,
page_turn, goto_page, goto_chapter, toggle_bookmark, set_dark_mode, refresh,
show_message, set_wifi, sync_now, suspend, restart), run by the plugin's own
commands.lua, plus two here: toggle_dark_mode and push_now.

The listener costs nothing while idle: KOReader polls the socket in its event
loop, as it does for the HTTP Inspector. It stops on suspend and restarts on
resume. A command counts as user activity: KOReader's own timers reset, and on
Android the screen timeout restarts as if the screen had been touched.
--]]--

local Device = require("device")
local Event = require("ui/event")
local PluginLoader = require("pluginloader")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local SETTINGS_KEY = "hatelemetry_listener"

-- Lives in this file, not on the plugin, because the plugin table is replaced on every reload.
local state = {
    plugin = nil,    -- the current plugin instance
    Commands = nil,  -- the plugin's commands.lua
    server = nil,    -- SimpleTCPServer while listening
    queue = nil,     -- its UIManager ZMQ handle
}

local function settings()
    local s = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    if type(s.token) ~= "string" or #s.token < 32 then
        local f = io.open("/dev/urandom", "rb")
        local bytes = f and f:read(24)
        if f then f:close() end
        if not bytes or #bytes < 24 then return nil end
        s.token = (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
        s.port = tonumber(s.port) or 8081
        s.host = type(s.host) == "string" and s.host or "*"
        G_reader_settings:saveSetting(SETTINGS_KEY, s)
        G_reader_settings:flush() -- written now, so it can be copied to Home Assistant
        logger.info("[HATelemetry]: listener token generated (see hatelemetry_listener in settings.reader.lua)")
    end
    s.port = tonumber(s.port) or 8081
    s.host = type(s.host) == "string" and s.host or "*"
    return s
end

-- Android: restart the screen-off countdown like a touch would. KOReader's custom
-- timeout is Android's own setting, which only counts from the last touch; the
-- "keep screen on" flag is a wake lock that pokes that timer when released.
local function pokeScreenTimeout()
    if not Device:isAndroid() then return end
    local ok, android = pcall(require, "android")
    local timeout = G_reader_settings:readSetting("android_screen_timeout")
    if not ok or type(timeout) ~= "number" or timeout <= 0 then return end
    android.timeout.set(-1)
    UIManager:scheduleIn(1, function() android.timeout.set(timeout) end)
end

local REASONS = { [200] = "OK", [400] = "Bad Request", [401] = "Unauthorized", [404] = "Not Found", [503] = "Service Unavailable" }

local function respond(client, code, body)
    body = body or ""
    state.server:send(table.concat({
        "HTTP/1.1 " .. code .. " " .. (REASONS[code] or ""),
        "Content-Type: application/json",
        "Content-Length: " .. #body,
        "Connection: close",
        "", body,
    }, "\r\n"), client)
end

local function runCommands(cmds)
    local plugin = state.plugin
    local applied = 0
    for _, cmd in ipairs(cmds) do
        if type(cmd) == "table" and type(cmd.type) == "string" then
            if cmd.type == "toggle_dark_mode" then
                UIManager:broadcastEvent(Event:new("ToggleNightMode"))
            elseif cmd.type == "push_now" then
                plugin:push(true)
            else
                state.Commands.apply(cmd, plugin:commandDeps())
            end
            applied = applied + 1
        end
    end
    return applied
end

local function onRequest(data, client)
    local rapidjson = require("rapidjson")
    local method, path = data:match("^(%u+) ([^ ]+) HTTP/")
    local headers = {}
    for name, value in data:gmatch("\n([^:\r\n]+):%s*([^\r\n]*)") do headers[name:lower()] = value end

    local s = settings()
    if not (s and headers["authorization"] == "Bearer " .. s.token) then
        respond(client, 401, '{"ok":false,"error":"unauthorized"}')
        return
    end
    if not state.plugin then
        respond(client, 503, '{"ok":false,"error":"plugin not ready"}')
        return
    end
    path = path and path:gsub("%?.*$", "")

    if method == "GET" and path == "/state" then
        local ok, snap = pcall(state.plugin.collect, state.plugin, true)
        respond(client, ok and 200 or 503, ok and rapidjson.encode(snap) or '{"ok":false}')
        return
    end
    if method == "POST" and path == "/push" then
        state.plugin:push(true)
        respond(client, 200, '{"ok":true}')
        return
    end
    if method == "POST" and path == "/command" then
        local len = tonumber(headers["content-length"]) or 0
        local body = len > 0 and len < 65536 and client:receive(len) or nil
        local ok, decoded = pcall(rapidjson.decode, body or "")
        if not ok or type(decoded) ~= "table" then
            respond(client, 400, '{"ok":false,"error":"body must be JSON"}')
            return
        end
        local cmds = decoded.commands or (decoded.type and { decoded }) or decoded
        local applied = runCommands(cmds)
        respond(client, 200, rapidjson.encode({ ok = true, applied = applied }))
        pokeScreenTimeout()
        -- Like a key press: resets KOReader's own standby/suspend timers.
        return Event:new("InputEvent")
    end
    respond(client, 404, '{"ok":false,"error":"not found"}')
end

local function stop()
    if state.queue then UIManager:removeZMQ(state.queue); state.queue = nil end
    if state.server then pcall(state.server.stop, state.server); state.server = nil end
end

local function start()
    if state.server then return end
    local s = settings()
    if not s then
        logger.warn("[HATelemetry]: listener not started, no token")
        return
    end
    local Server = require("ui/message/simpletcpserver")
    local server = Server:new{
        host = s.host,
        port = s.port,
        receiveCallback = function(data, client)
            local ok, ev = pcall(onRequest, data, client)
            if not ok then
                logger.warn("[HATelemetry]: listener request failed:", ev)
                pcall(client.close, client)
                return
            end
            return ev
        end,
    }
    local ok, err = server:start()
    if not ok then
        logger.warn("[HATelemetry]: listener could not start:", err)
        return
    end
    state.server = server
    state.queue = UIManager:insertZMQ(server)
    logger.info("[HATelemetry]: listening for commands on", s.host .. ":" .. s.port)
end

local function patchPlugin(HATelemetry)
    if HATelemetry.commandListener or HATelemetry._command_listener_patch then return end
    local orig_init, orig_onSuspend, orig_onResume = HATelemetry.init, HATelemetry.onSuspend, HATelemetry.onResume
    if not (orig_init and orig_onSuspend and orig_onResume and HATelemetry.commandDeps and HATelemetry.path) then
        logger.warn("hatelemetry listener patch: plugin layout changed, not applied")
        return
    end
    -- The plugin's own command handler, loaded from its folder (a pure module).
    local ok, Commands = pcall(dofile, HATelemetry.path .. "/commands.lua")
    if not ok or type(Commands) ~= "table" or type(Commands.apply) ~= "function" then
        logger.warn("hatelemetry listener patch: commands.lua not usable, not applied")
        return
    end
    HATelemetry._command_listener_patch = true
    state.Commands = Commands

    HATelemetry.init = function(self, ...)
        local ret = orig_init(self, ...)
        -- KOReader re-creates the plugin on each file manager/reader switch; the listener stays up.
        state.plugin = self
        if self.settings and self.settings.enabled then start() end
        return ret
    end
    HATelemetry.onSuspend = function(self, ...)
        stop()
        return orig_onSuspend(self, ...)
    end
    HATelemetry.onResume = function(self, ...)
        if self.settings and self.settings.enabled then start() end
        return orig_onResume(self, ...)
    end
end

local orig_createPluginInstance = PluginLoader.createPluginInstance
PluginLoader.createPluginInstance = function(this, plugin, attr)
    if plugin.name == "hatelemetry" then
        local ok, err = pcall(patchPlugin, plugin)
        if not ok then logger.warn("hatelemetry listener patch failed:", err) end
    end
    return orig_createPluginInstance(this, plugin, attr)
end
