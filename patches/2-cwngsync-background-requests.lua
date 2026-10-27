--[[--
User patch for cwngsync.koplugin (Calibre-Web NextGen sync, https://github.com/new-usemame/Calibre-Web-NextGen,
tested with 4.1.48; the code it touches is unchanged in 4.1.56).

CWNGSync's client sends its JSON calls (progress push/pull, inventory, library
manifest, annotations, deliveries, collections, pairing) through a Spore
middleware called AsyncHTTP. That middleware was written for KOReader's old
Turbo looper; with the looper gone it returns early and every call runs on
KOReader's UI thread. A slow server or a waking Wi-Fi then freezes KOReader
for up to the call's timeout (30 s for an inventory report), and on Android a
freeze over 5 s while you touch the screen is an ANR.

This patch gives AsyncHTTP a working implementation: the HTTP request runs in
a subprocess (ffi/util runInSubProcess), the calling coroutine is suspended
the way Spore already supports for async middlewares, and a UIManager poll
resumes it with the response. Callbacks run on the UI thread as before, and a
transport error surfaces as the same raised error the client already catches.

The sleep screen sync (run at every sync) uses blocking calls that return
their result directly: authorize and the sleep screen requests. The patch runs
that sync in a coroutine and lets those two calls wait for a subprocess there;
the sync's own busy flag keeps a second one from starting meanwhile.

Not covered: book and placeholder downloads (download_file, download_delivery)
and the checksum taken after a download. Their callers use the result right
away, so they still block; that needs a change in the plugin itself.

It turns itself off if the client marks its own background transport
(CWNGSyncClient.background_http).
--]]--

local PluginLoader = require("pluginloader")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")

local POLL_INTERVAL = 0.2 -- s between checks on the subprocess
local DEADLINE = 120      -- s before a subprocess that hasn't finished is killed (socket timeouts end it sooner)

-- Collect the child (no zombie) and close the pipe without blocking the UI.
local function reap(pid, read_fd)
    if ffiutil.isSubProcessDone(pid) then
        if read_fd then ffiutil.readAllFromFD(read_fd) end -- child gone: pipe at EOF
        return
    end
    UIManager:scheduleIn(POLL_INTERVAL, function() reap(pid, read_fd) end)
end

-- A response that raises `err` when Spore looks at it, so the error reaches the
-- client's pcall exactly as a raise from the inline request would.
local function raisingResponse(err)
    return setmetatable({}, { __index = function() error(err, 0) end })
end

-- Child output: "OK\n<status>\n<headers json>\n<body>" or "ERR\n<message>".
local function decodeResponse(out, rapidjson)
    local status, headers_json, body = out:match("^OK\n(%d+)\n([^\n]*)\n(.*)$")
    if status then
        local ok, headers = pcall(rapidjson.decode, headers_json)
        return { status = tonumber(status), headers = ok and headers or {}, body = body }
    end
    return raisingResponse(out:match("^ERR\n(.*)$") or "no response from server")
end

local function backgroundAsyncHTTP(args, req)
    -- Only the client's coroutine-wrapped calls can wait; anything else goes inline as before.
    if not args.thread then return end
    local Protocols = require("Spore.Protocols")
    local rapidjson = require("rapidjson")
    req:finalize()

    local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
        local ok, res = pcall(Protocols.request, req)
        local out
        if ok and type(res) == "table" then
            local hok, headers = pcall(rapidjson.encode, res.headers or {})
            out = "OK\n" .. tostring(res.status) .. "\n" .. (hok and headers or "{}") .. "\n" .. (res.body or "")
        else
            out = "ERR\n" .. tostring(res)
        end
        ffiutil.writeToFD(write_fd, out, true)
    end, true)
    if not pid then
        -- No fork: send it inline, as the plugin did before.
        return Protocols.request(req)
    end

    local result
    local waited = 0
    local function poll()
        local ready = ffiutil.getNonBlockingReadSize(read_fd)
        if (ready and ready > 0) or ffiutil.isSubProcessDone(pid) then
            -- The child writes once its request is done and exits right after,
            -- so this read doesn't wait on the network.
            local out = ffiutil.readAllFromFD(read_fd)
            reap(pid, nil)
            result = out ~= "" and decodeResponse(out, rapidjson) or raisingResponse("no response from server")
            result.request = rawget(result, "status") and req or nil
            local ok, err = coroutine.resume(args.thread)
            if not ok then logger.warn("cwngsync background patch: request handler failed:", err) end
            return
        end
        waited = waited + POLL_INTERVAL
        if waited >= DEADLINE then
            ffiutil.terminateSubProcess(pid)
            reap(pid, read_fd)
            result = raisingResponse("timeout")
            coroutine.resume(args.thread)
            return
        end
        UIManager:scheduleIn(POLL_INTERVAL, poll)
    end
    UIManager:scheduleIn(POLL_INTERVAL, poll)
    -- Spore yields the calling coroutine on a returned thread and, once resumed,
    -- takes the response from it.
    return coroutine.create(function() coroutine.yield(result) end)
end

-- Coroutines this patch runs. Blocking client calls made inside one of them
-- wait for a subprocess instead of blocking the UI; anywhere else they run as before.
local suspendable = setmetatable({}, { __mode = "k" })

local function pack(...) return { n = select("#", ...), ... } end

-- Return values cross the pipe as a Lua literal. JSON can't carry everything the
-- client returns (rapidjson refused the server capability table). Strings,
-- numbers, booleans and tables are kept; functions and userdata are dropped.
local function serialize(v, depth)
    local t = type(v)
    if t == "string" then return string.format("%q", v)
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then
        if v ~= v then return "0/0" elseif v == math.huge then return "1/0" elseif v == -math.huge then return "-1/0" end
        return string.format("%.17g", v)
    elseif t == "table" and depth < 32 then
        local parts = {}
        for k, val in pairs(v) do
            local ks, vs = serialize(k, depth + 1), serialize(val, depth + 1)
            if ks and vs then parts[#parts + 1] = "[" .. ks .. "]=" .. vs end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return nil
end

local function deserialize(text)
    local f = loadstring("return " .. text)
    if not f then return nil end
    setfenv(f, {})
    local ok, v = pcall(f)
    return ok and v or nil
end

-- Wrap a blocking client method: inside a suspendable coroutine, run it in a
-- subprocess (files it writes land on the same storage) and hand its return
-- values back as a Lua literal; a raise is re-raised in the caller.
local function waitInSubprocess(orig)
    return function(self, ...)
        local co = coroutine.running()
        if not (co and suspendable[co]) then return orig(self, ...) end
        local args = pack(...)
        local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
            local r = pack(pcall(orig, self, unpack(args, 1, args.n)))
            local o
            if r[1] then
                o = { n = r.n - 1 }
                for i = 2, r.n do o[i - 1] = r[i] end
            else
                o = { err = tostring(r[2]) }
            end
            ffiutil.writeToFD(write_fd, serialize(o, 0), true)
        end, true)
        if not pid then return orig(self, ...) end

        local waited = 0
        local function poll()
            local ready = ffiutil.getNonBlockingReadSize(read_fd)
            local res
            if (ready and ready > 0) or ffiutil.isSubProcessDone(pid) then
                local out = ffiutil.readAllFromFD(read_fd)
                reap(pid, nil)
                local decoded = deserialize(out)
                res = type(decoded) == "table" and decoded or { err = "no response from server" }
            else
                waited = waited + POLL_INTERVAL
                if waited < DEADLINE then
                    UIManager:scheduleIn(POLL_INTERVAL, poll)
                    return
                end
                ffiutil.terminateSubProcess(pid)
                reap(pid, read_fd)
                res = { err = "timeout" }
            end
            local ok, err = coroutine.resume(co, res)
            if not ok then logger.warn("cwngsync background patch: suspended call failed:", err) end
        end
        UIManager:scheduleIn(POLL_INTERVAL, poll)

        local res = coroutine.yield()
        if res.err then error(res.err, 0) end
        return unpack(res, 1, res.n or 0)
    end
end

-- Run a plugin method in a suspendable coroutine. Only for methods whose
-- callers ignore the return value.
local function runSuspendable(orig)
    return function(self, ...)
        local co = coroutine.create(orig)
        suspendable[co] = true
        local ok, err = coroutine.resume(co, self, ...)
        if not ok then logger.warn("cwngsync background patch: background run failed:", err) end
    end
end

local function patchClient(plugin)
    local Client = package.loaded["CWNGSyncClient"]
    if Client == nil and plugin.path then
        -- Normally loaded already (cwng_setup_flow requires it while main.lua loads).
        local saved = package.path
        package.path = plugin.path .. "/?.lua;" .. saved
        local ok, mod = pcall(require, "CWNGSyncClient")
        package.path = saved
        Client = ok and mod or nil
    end
    if type(Client) ~= "table" or Client.background_http or Client._background_patch then return end
    if type(Client.init) ~= "function" then
        logger.warn("cwngsync background patch: client layout changed, not applied")
        return
    end
    Client._background_patch = true
    for _, name in ipairs({ "authorize", "_sleep_screen_request" }) do
        if type(Client[name]) == "function" then Client[name] = waitInSubprocess(Client[name]) end
    end
    local orig_init = Client.init
    Client.init = function(self, ...)
        local ret = orig_init(self, ...)
        -- init() (re)defines the middleware each time a client is created; replace it after.
        local mw = package.loaded["Spore.Middleware.AsyncHTTP"]
        if type(mw) == "table" then mw.call = backgroundAsyncHTTP end
        return ret
    end
end

-- main.lua has required CWNGSyncClient by the time the plugin is instantiated;
-- the module stays cached across plugin reloads, so this patches it once.
local orig_createPluginInstance = PluginLoader.createPluginInstance
PluginLoader.createPluginInstance = function(this, plugin, attr)
    if plugin.name == "cwngsync" then
        local ok, err = pcall(patchClient, plugin)
        if not ok then logger.warn("cwngsync background patch failed:", err) end
        -- The plugin table is fresh on every load; its callers ignore the result.
        if type(plugin.syncSleepScreen) == "function" and not plugin._background_sleep_sync then
            plugin._background_sleep_sync = true
            plugin.syncSleepScreen = runSuspendable(plugin.syncSleepScreen)
        end
    end
    return orig_createPluginInstance(this, plugin, attr)
end
