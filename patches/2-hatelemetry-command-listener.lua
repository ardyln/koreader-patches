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

Connections are kept open between requests (HTTP keep-alive), saving the TCP
handshake on each command. KOReader polls the server in its event loop, like the
HTTP Inspector, but every 250 ms when idle instead of every 50 ms (50 ms for 30 s
after any input). On a KOReader whose input backend can watch file descriptors
(Android, with the change proposed upstream) it isn't polled at all: KOReader
wakes when a connection or request arrives. It stops on suspend and restarts on
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
    server = nil,    -- Server while listening
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

-- The client's connection stays open (HTTP keep-alive), so the next command
-- skips the TCP handshake: one Wi-Fi round trip less.
local function respond(c, req, code, body)
    body = body or ""
    local close = (req.headers["connection"] or ""):lower() == "close"
    c.sock:settimeout(1)
    c.sock:send(table.concat({
        "HTTP/1.1 " .. code .. " " .. (REASONS[code] or ""),
        "Content-Type: application/json",
        "Content-Length: " .. #body,
        close and "Connection: close" or "Connection: keep-alive",
        "", body,
    }, "\r\n"))
    c.sock:settimeout(0)
    if close then c.close = true end
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

local function onRequest(req, c)
    local rapidjson = require("rapidjson")
    local s = settings()
    if not (s and req.headers["authorization"] == "Bearer " .. s.token) then
        respond(c, req, 401, '{"ok":false,"error":"unauthorized"}')
        return
    end
    if not state.plugin then
        respond(c, req, 503, '{"ok":false,"error":"plugin not ready"}')
        return
    end
    local path = req.path and req.path:gsub("%?.*$", "")

    if req.method == "GET" and path == "/state" then
        local ok, snap = pcall(state.plugin.collect, state.plugin, true)
        respond(c, req, ok and 200 or 503, ok and rapidjson.encode(snap) or '{"ok":false}')
        return
    end
    if req.method == "POST" and path == "/push" then
        state.plugin:push(true)
        respond(c, req, 200, '{"ok":true}')
        return
    end
    if req.method == "POST" and path == "/command" then
        local ok, decoded = pcall(rapidjson.decode, req.body)
        if not ok or type(decoded) ~= "table" then
            respond(c, req, 400, '{"ok":false,"error":"body must be JSON"}')
            return
        end
        local cmds = decoded.commands or (decoded.type and { decoded }) or decoded
        local applied = runCommands(cmds)
        respond(c, req, 200, rapidjson.encode({ ok = true, applied = applied }))
        pokeScreenTimeout()
        -- Like a key press: resets KOReader's own standby/suspend timers.
        return Event:new("InputEvent")
    end
    respond(c, req, 404, '{"ok":false,"error":"not found"}')
end

-- A small non-blocking HTTP/1.1 server with keep-alive. UIManager calls
-- waitEvent() on every loop pass (it's registered like a ZMQ); one select()
-- with no timeout covers the listening socket and every open connection.
local KEEPALIVE_IDLE = 30 -- s an idle connection stays open
local MAX_REQUEST = 65536 -- bytes

local Server = {}
Server.__index = Server

function Server.new(host, port)
    return setmetatable({ host = host, port = port, clients = {} }, Server)
end

function Server:start()
    local listener, err = require("socket").bind(self.host, self.port)
    if not listener then return false, err end
    listener:settimeout(0)
    self.listener = listener
    return true
end

-- With a KOReader whose input backend can watch file descriptors (Input.input.addFd),
-- UIManager registers getFd() and wakes up on new connections; open connections are
-- registered here, so a request on one wakes it too. Without it, UIManager polls waitEvent().
local backend = require("device").input.input

function Server:getFd()
    return self.listener and self.listener:getfd()
end

local function watch(c)
    if backend.addFd and backend.addFd(c.sock:getfd()) then c.watched = true end
end

local function dropClient(self, c)
    self.clients[c] = nil
    if c.watched then backend.removeFd(c.sock:getfd()) end
    pcall(c.sock.close, c.sock)
end

function Server:stop()
    for c in pairs(self.clients) do dropClient(self, c) end
    self.clients = {}
    if self.listener then self.listener:close(); self.listener = nil end
end

-- The next complete request in the client's buffer, or nil.
local function takeRequest(c)
    local head_end = c.buf:find("\r\n\r\n", 1, true)
    if not head_end then return nil end
    local head = c.buf:sub(1, head_end - 1)
    local headers = {}
    for name, value in head:gmatch("\n([^:\r\n]+):%s*([^\r\n]*)") do headers[name:lower()] = value end
    local len = tonumber(headers["content-length"]) or 0
    if #c.buf < head_end + 3 + len then return nil end
    local req = {
        headers = headers,
        body = c.buf:sub(head_end + 4, head_end + 3 + len),
    }
    req.method, req.path = head:match("^(%u+) ([^ ]+) HTTP/")
    c.buf = c.buf:sub(head_end + 4 + len)
    return req
end

-- UIManager keeps calling this until it returns nil.
function Server:waitEvent()
    if not self.listener then return end
    local now = os.time()
    local sock = self.listener:accept()
    if sock then
        sock:settimeout(0)
        local c = { sock = sock, buf = "", last = now }
        self.clients[c] = true
        watch(c)
    end
    for c in pairs(self.clients) do
        local data, err, partial = c.sock:receive(8192)
        local got = data or partial
        if got and #got > 0 then
            c.buf = c.buf .. got
            c.last = now
        end
        if err == "closed" or #c.buf > MAX_REQUEST then
            dropClient(self, c)
        else
            local req = takeRequest(c)
            if req then
                local ok, ev = pcall(onRequest, req, c)
                if not ok then
                    logger.warn("[HATelemetry]: listener request failed:", ev)
                    c.close = true
                end
                if c.close then dropClient(self, c) end
                if ok and ev then return ev end
            elseif now - c.last > KEEPALIVE_IDLE then
                dropClient(self, c)
            end
        end
    end
end

-- UIManager wakes every ZMQ_TIMEOUT to call waitEvent() while a server is registered.
-- Poll fast for a while after any input (touch, key or command), slower when idle.
local FAST_ZMQ_US = 50 * 1000
local SLOW_ZMQ_US = 250 * 1000
local FAST_WINDOW = 30 -- s
local function slowPoll() UIManager.ZMQ_TIMEOUT = SLOW_ZMQ_US end
UIManager.event_hook:register("InputEvent", function()
    UIManager.ZMQ_TIMEOUT = FAST_ZMQ_US
    UIManager:unschedule(slowPoll)
    UIManager:scheduleIn(FAST_WINDOW, slowPoll)
end)

local function stop()
    if state.server then
        UIManager:removeZMQ(state.server)
        pcall(state.server.stop, state.server)
        state.server = nil
    end
end

local function start()
    if state.server then return end
    local s = settings()
    if not s then
        logger.warn("[HATelemetry]: listener not started, no token")
        return
    end
    local server = Server.new(s.host, s.port)
    local ok, err = server:start()
    if not ok then
        logger.warn("[HATelemetry]: listener could not start:", err)
        return
    end
    state.server = server
    UIManager:insertZMQ(server)
    slowPoll()
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
