local logger = C.TLog:forTag("multitode/multitode.getApi().lua")

local jsonReader = C.JsonReader.new()

local autoDispatchRegistered = false

local function escape_json_string(value)
    return tostring(value)
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\b", "\\b")
        :gsub("\f", "\\f")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
end

local function is_dense_array(value)
    local count = 0
    local maxIndex = 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false, 0
        end
        count = count + 1
        if key > maxIndex then
            maxIndex = key
        end
    end

    -- An empty table has no keys: encode as {} (object), not [] (array).
    -- Receivers that read payload.x on an intended-object payload got nil
    -- when the empty table round-tripped as a JSON array.
    if count == 0 then
        return false, 0
    end

    return maxIndex == count, count
end

local encode_json_value

local function encode_json_table(value)
    local isArray, size = is_dense_array(value)
    local parts = {}

    if isArray then
        for index = 1, size do
            parts[#parts + 1] = encode_json_value(value[index])
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    -- Sort keys for deterministic output. Numeric keys (sparse maps such as
    -- poll.votes[playerId]) are legal here — JSON object keys are strings.
    local keyed = {}
    for key, itemValue in pairs(value) do
        local stringKey
        if type(key) == "string" then
            stringKey = key
        elseif type(key) == "number"
            and key == key
            and key ~= math.huge
            and key ~= -math.huge then
            stringKey = tostring(key)
        else
            error("json object keys must be strings")
        end
        keyed[stringKey] = itemValue
    end

    local keys = {}
    for key, _ in pairs(keyed) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
        parts[#parts + 1] = '"' .. escape_json_string(key) .. '":' .. encode_json_value(keyed[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encode_json_value = function(value)
    local valueType = type(value)
    if valueType == "nil" then
        return "null"
    end
    if valueType == "boolean" then
        return value and "true" or "false"
    end
    if valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("json numbers must be finite")
        end
        return tostring(value)
    end
    if valueType == "string" then
        return '"' .. escape_json_string(value) .. '"'
    end
    if valueType == "table" then
        return encode_json_table(value)
    end

    error("unsupported json value type: " .. valueType)
end

local function decode_json_value(jsonValue)
    if jsonValue:isNull() then
        return nil
    end
    if jsonValue:isBoolean() then
        return jsonValue:asBoolean()
    end
    if jsonValue:isDouble() then
        return jsonValue:asDouble()
    end
    if jsonValue:isLong() then
        return jsonValue:asLong()
    end
    if jsonValue:isString() then
        return jsonValue:asString()
    end
    if jsonValue:isArray() then
        local result = {}
        local child = jsonValue.child
        while child ~= nil do
            result[#result + 1] = decode_json_value(child)
            child = child.next
        end
        return result
    end
    if jsonValue:isObject() then
        local result = {}
        local child = jsonValue.child
        while child ~= nil do
            result[child.name] = decode_json_value(child)
            child = child.next
        end
        return result
    end

    error("unsupported JsonValue type")
end

local function assert_user_channel(messageChannel)
    if messageChannel == nil or tostring(messageChannel) == "" then
        error("messageChannel must not be blank")
    end
    if tostring(messageChannel) == "system" then
        error("messageChannel 'system' is reserved")
    end
end

local function apply_config_value(api, key, value)
    if key == "role" then
        api:configureRole(value)
    elseif key == "name" or key == "playerName" then
        api:setPlayerName(tostring(value))
    elseif key == "host" then
        api:setHost(tostring(value))
    elseif key == "port" then
        local numberValue = tonumber(value)
        if numberValue == nil then
            error("port must be a number")
        end
        multitode.getApi():setPort(numberValue)
    else
        error("unsupported config key: " .. tostring(key))
    end
end

local function create_config_table(api)
    return {
        role = api:getConfiguredRoleName(),
        name = api:getPlayerName(),
        host = api:getHost(),
        port = api:getPort(),
    }
end

_G.multitode = _G.multitode or {}
multitode.net = multitode.net or {
    handlers = {}
}

local bridgeApiClass
local api
multitode.getApi = function()
    if bridgeApiClass == nil then
        bridgeApiClass = luajava.bindClass("dev.multitode.bridge.shared.BridgeApi")
    end

    if api == nil then
        api = bridgeApiClass.INSTANCE
    end

    return api
end

multitode.version = multitode.getApi():getVersion()

-- Wall-clock milliseconds. os.clock() is per-process CPU time, which is useless
-- for debounce / timeout logic (and for cross-instance comparisons).
multitode.now_ms = function()
    local ok, System = pcall(luajava.bindClass, "java.lang.System")
    if not ok or System == nil then
        return 0
    end
    local okTime, value = pcall(function()
        return System:currentTimeMillis()
    end)
    if okTime and value ~= nil then
        return tonumber(value) or 0
    end
    return 0
end

multitode.init = function(role)
    if role ~= nil then
        multitode.getApi():configureRole(role)
    end

    multitode.getApi():initialize()
    logger:i("Bridge initialized with role %s", multitode.getApi():getRoleName())
end

multitode.start = function(role)
    if role ~= nil then
        multitode.getApi():configureRole(role)
    end
    local bridge = multitode.getApi():start()
    logger:i("Bridge started as %s (%s)", multitode.getApi():getRoleName(), multitode.getApi():getLifecycleStateName())
    return bridge
end

multitode.stop = function()
    multitode.getApi():stop()
    logger:i("Bridge stopped")
end

multitode.state = function()
    local api = multitode.getApi()
    return {
        initialized = api:isInitialized(),
        role = api:getRoleName(),
        lifecycleState = api:getLifecycleStateName()
    }
end

multitode.configure = function(config)
    if config == nil then
        return create_config_table(multitode.getApi())
    end

    for key, value in pairs(config) do
        apply_config_value(multitode.getApi(), key, value)
    end

    logger:i("Bridge config updated: %s", multitode.getApi():describeConfig())
    return create_config_table(multitode.getApi())
end

multitode.resetConfig = function()
    multitode.getApi():resetConfig()
    logger:i("Bridge config reset: %s", multitode.getApi():describeConfig())
    return create_config_table(multitode.getApi())
end

multitode.getConfig = function()
    return create_config_table(multitode.getApi())
end

multitode.saveConfig = function()
    multitode.getApi():saveConfig()
    logger:i("Bridge config saved to %s", multitode.getApi():getConfigFilePath())
end

multitode.loadConfig = function()
    local loaded = multitode.getApi():loadConfig()
    if loaded then
        logger:i("Bridge config loaded from %s", multitode.getApi():getConfigFilePath())
    else
        logger:i("Bridge config file not found at %s", multitode.getApi():getConfigFilePath())
    end

    return loaded, create_config_table(multitode.getApi())
end

multitode.validateConfig = function()
    local validationError = multitode.getApi():getConfigValidationError()
    if validationError == nil then
        return true, nil
    end

    return false, validationError
end

multitode.getSessionInfo = function()
    local api = multitode.getApi()
    return {
        sessionId = api:getSessionId(),
        localPlayerId = api:getLocalPlayerId(),
        connectionState = api:getConnectionStateName(),
        sessionActive = api:isSessionActive(),
        connectedPeerCount = api:getConnectedPeerCount()
    }
end

multitode.describeSession = function()
    return multitode.getApi():describeSession()
end

multitode.describePeers = function()
    return multitode.getApi():describePeers()
end

multitode.hasPeers = function()
    return multitode.getApi():hasPeers()
end

multitode.net.encodePayload = function(payload)
    if type(payload) ~= "table" then
        error("payload must be a table")
    end
    return encode_json_value(payload)
end

multitode.net.decodePayload = function(payloadJson)
    return decode_json_value(jsonReader:parse(payloadJson))
end

multitode.net.on = function(messageChannel, messageName, handler)
    assert_user_channel(messageChannel)
    if type(messageName) ~= "string" or messageName == "" then
        error("messageName must be a non-empty string")
    end
    if type(handler) ~= "function" then
        error("handler must be a function")
    end

    local channelHandlers = multitode.net.handlers[messageChannel]
    if channelHandlers == nil then
        channelHandlers = {}
        multitode.net.handlers[messageChannel] = channelHandlers
    end

    channelHandlers[messageName] = handler
end

multitode.net.onHost = function(messageChannel, messageName, handler)
    multitode.net.on(messageChannel, messageName, function(ctx, payload)
        if ctx.receiverContext ~= "HOST" then
            return
        end

        handler(ctx, payload)
    end)
end

-- Sender ids come from the bridge, Lua can't pick them. The host's loopback
-- client always grabs playerId 1 at startup (before any remote HELLO lands),
-- so host mail arrives as sender 1; anything else on a client envelope means
-- a relay bug or a spoof.
multitode.net.HOST_SENDER_PLAYER_ID = 1

multitode.net.onClient = function(messageChannel, messageName, handler)
    multitode.net.on(messageChannel, messageName, function(ctx, payload)
        if ctx.receiverContext ~= "CLIENT" then
            return
        end

        -- Only the host may drive client-side handlers.
        if tonumber(ctx.senderPlayerId) ~= multitode.net.HOST_SENDER_PLAYER_ID then
            logger:w(
                "Rejected %s/%s from non-host sender=%s (receiver=%s)",
                tostring(messageChannel), tostring(messageName),
                tostring(ctx.senderPlayerId), tostring(ctx.receiverContext)
            )
            return
        end

        handler(ctx, payload)
    end)
end

multitode.net.sendToHost = function(messageChannel, messageName, payload)
    assert_user_channel(messageChannel)
    local sent = multitode.getApi():sendLuaMessageToHost(messageChannel, messageName, multitode.net.encodePayload(payload))
    if not sent then
        error("failed to send message to host")
    end
end

multitode.net.sendToPeer = function(playerId, messageChannel, messageName, payload)
    assert_user_channel(messageChannel)
    local sent = multitode.getApi():sendLuaMessageToPeer(tonumber(playerId), messageChannel, messageName, multitode.net.encodePayload(payload))
    if not sent then
        error("failed to send message to peer")
    end
end

multitode.net.broadcast = function(messageChannel, messageName, payload)
    assert_user_channel(messageChannel)
    -- A fan-out may legitimately reach zero peers (host playing alone), so this
    -- returns the send result instead of raising: callers use it as a flag.
    return multitode.getApi():broadcastLuaMessage(messageChannel, messageName, multitode.net.encodePayload(payload))
end

multitode.net.getPendingCount = function()
    return multitode.getApi():getPendingLuaMessageCount()
end

multitode.net.poll = function()
    local rawMessageJson = multitode.getApi():pollInboundLuaMessageJson()
    if rawMessageJson == nil then
        return nil
    end

    return decode_json_value(jsonReader:parse(rawMessageJson))
end

-- ============================================================
-- Per-env append-only markers (clobber-proof diagnostics)    --
-- ============================================================
-- log.txt is written by BOTH game processes through the shared-file space
-- padding scheme, so whole line blocks get overwritten and absence of a line
-- proves nothing. Each Lua env appends to its OWN file instead: one file per
-- env (name embeds the env's multitode table identity + first-marker
-- timestamp, so two processes and two envs never share a file). Count files
-- and lines to answer "which scripts executed in which environment".
multitode.net.appendEnvMarker = function(tag)
    pcall(function()
        local System = luajava.bindClass("java.lang.System")
        if multitode.net._markerPath == nil then
            -- System.identityHashCode is BLACKLISTED (-m:) like getProperty, so
            -- derive the env id from tostring(table) -> "table: <hex>" instead;
            -- the timestamp suffix already guarantees one file per env per boot.
            local envHex = string.match(tostring(multitode), "table: (%x+)") or "noid"
            multitode.net._markerPath = string.format(
                "cache/script-data/multitode/envboot-%s-%d.log",
                envHex,
                System:currentTimeMillis()
            )
        end
        -- NOTE: Files.local() is not on the LuaJ whitelist (and `local` is a
        -- Lua keyword anyway), so use the whitelisted script file API, exactly
        -- like scripts/misc/loot-benchmarking-bot.lua does. SFileHandle only
        -- allows a fixed set of roots - "cache/script-data/" is one of them.
        C.SFileHandle.new(multitode.net._markerPath):writeString(
            string.format("%d %s\n", System:currentTimeMillis(), tostring(tag)),
            true
        )
    end)
end

-- ============================================================
-- Single-owner gate for inbound drains + heartbeat           --
-- ============================================================
-- This file executes in BOTH the ScriptManager (global) env and the ScriptSystem
-- (game) env, and each registers its own auto-dispatch Render listener on the
-- JVM-global event bus. Uncoordinated, both envs drain the same inbound queue,
-- so a speed_state/pause_state handler runs in whichever env polled first -
-- typically the global env, whose70_multitode_itd never loaded, leaving an
-- empty itd there while the real game env (guard, mirror) never sees the
-- message. Observed consequence: client guard enforcing a stale 8x against an
-- actual 1x ("Client speed enforced 1x -> 8x" loop) and pause mirrors never
-- applying.
--
-- Ownership rule. Verified against the bundled LuaJ: LuaUserdata.raweq falls
-- through to m_instance.equals() when metatables match (both null by default),
-- and GameSystemProvider does not override equals - so plain Lua `==` between
-- two JavaInstance wrappers of the same Java object IS a true identity test,
-- even across Globals. CoerceJavaToLua builds a fresh JavaInstance per coerce,
-- which is why identityHashCode over the wrapper would have been wrong here.
--   * current screen is a GameScreen with live systems -> owner is the env
--     whose global S is that same GameSystemProvider (the current game env;
--     the global env and stale game envs from earlier levels fail this test)
--   * otherwise (menu / editor / no screen) -> owner is an env with no global
--     S (the global env; MapEditorScreen sets S only while editing)
-- The owner advertises via the shared BridgeApi setting (NOT the JVM system
-- property - System.setProperty/getProperty are whitelist-blacklisted)
--   multitode.net.owner = "<env table>|<currentTimeMillis>"
-- (BridgeApi INSTANCE is per-process, so host and client never interfere),
-- refreshed only by an env that just found itself the owner, at most once per
-- second (each write persists the settings file). A non-owner backs off only
-- while that claim is FRESH (< 2 s) AND written by a DIFFERENT env; with no
-- fresh foreign claim it FAILS OPEN (returns true). Fail-open is the safety
-- property: if the game env never runs this gate at all (scenario B - it has
-- no dispatch listener of its own), message draining keeps behaving exactly
-- as before instead of stalling forever.
multitode.net._ownerState = "unknown"
multitode.net.env_owns_messages = function()
    local mine = nil
    local scrSid = "no-game-screen"
    pcall(function()
        local scr = C.Game.i.screenManager:getCurrentScreen()
        if scr ~= nil and C.GameScreen:_isInstance(scr) and scr.S ~= nil then
            scrSid = tostring(scr.S)
            -- Belt and suspenders: `==` goes through LuaUserdata.raweq, which
            -- only compares the underlying objects when BOTH wrappers have
            -- equal metatables; tostring() instead uses the underlying
            -- object's own toString() (no metatables involved), and
            -- GameSystemProvider does not override toString - so the string
            -- form is a metatable-proof identity test.
            mine = (S == scr.S) or (tostring(S) == scrSid)
        else
            mine = (S == nil)
        end
    end)

    local okSys, System = pcall(luajava.bindClass, "java.lang.System")
    if not okSys or System == nil then
        return true -- no coordination possible -> behave as before
    end

    local myId = tostring(multitode)
    if mine == true then
        -- java.lang.System.setProperty/getProperty are BLACKLISTED on the LuaJ
        -- whitelist (-m: lines in res/luaj/whitelist.txt), so the property path
        -- silently pcall-failed and every gate call fell through to fail-open.
        -- BridgeApi.setSetting/getSetting are whitelisted (+m:) and shared by
        -- all envs in this process (per-JVM INSTANCE); writes persist a small
        -- properties file, so throttle to one write per second.
        local nowMs = System:currentTimeMillis()
        if multitode.net._ownerLastWriteMs == nil
                or (nowMs - multitode.net._ownerLastWriteMs) >= 1000 then
            pcall(function()
                multitode.getApi():setSetting(
                    "multitode.net.owner",
                    myId .. "|" .. tostring(nowMs)
                )
                multitode.net._ownerLastWriteMs = nowMs
            end)
        end
        if multitode.net._ownerState ~= "owner" then
            multitode.net._ownerState = "owner"
            pcall(function()
                logger:i("Message ownership: this env is the OWNER t=%s", myId)
            end)
        end
        return true
    end

    local backedOff = false
    pcall(function()
        local claim = multitode.getApi():getSetting("multitode.net.owner", "")
        if claim ~= nil and claim ~= "" then
            local id, ts = string.match(claim, "^(.-)|(%d+)$")
            ts = tonumber(ts)
            if id ~= nil and ts ~= nil and id ~= myId
                    and (System:currentTimeMillis() - ts) < 2000 then
                backedOff = true
            end
        end
    end)
    local state = backedOff and "backed-off" or "fail-open"
    if multitode.net._ownerState ~= state then
        multitode.net._ownerState = state
        pcall(function()
            -- S/screenS make identity failures diagnosable from one line:
            -- if S is nil here during gameplay, the gate ran in the global
            -- env; if S == screenS differs by content, the identity test
            -- itself is the problem.
            logger:i(
                "Message ownership: this env %s t=%s S=%s screenS=%s",
                state, myId, tostring(S), scrSid
            )
        end)
    end
    return not backedOff
end

multitode.net.dispatchPending = function(limit)
    -- Owner gate: only the current owning env may drain the inbound queue.
    -- Missing gate function or probe errors fail open (drain as before).
    if multitode.net.env_owns_messages ~= nil then
        local okGate, owns = pcall(multitode.net.env_owns_messages)
        if okGate and owns == false then
            return 0
        end
    end

    -- nil used to return immediately (silent no-op). Default to the same
    -- budget as enableAutoDispatch so callers that pass nil still drain.
    if limit == nil then
        limit = 128
    end

    local processed = 0
    local maxCount = limit

    while processed < maxCount do
        local envelope = multitode.net.poll()
        if envelope == nil then
            break
        end

        local channelHandlers = multitode.net.handlers[envelope.messageChannel]
        local handler = channelHandlers and channelHandlers[envelope.messageName] or nil
        if handler ~= nil then
            local ok, handlerErr = pcall(handler, {
                receiverContext = envelope.receiverContext,
                messageChannel = envelope.messageChannel,
                messageName = envelope.messageName,
                senderPlayerId = envelope.senderPlayerId
            }, envelope.payload)
            if not ok then
                logger:e(
                    "Handler error for %s/%s: %s",
                    tostring(envelope.messageChannel),
                    tostring(envelope.messageName),
                    tostring(handlerErr)
                )
            end
        else
            logger:w(
                "No Lua message handler for %s/%s (receiver=%s sender=%s)",
                tostring(envelope.messageChannel),
                tostring(envelope.messageName),
                tostring(envelope.receiverContext),
                tostring(envelope.senderPlayerId)
            )
        end
        processed = processed + 1
    end

    return processed
end

multitode.net.enableAutoDispatch = function(limit)
    if autoDispatchRegistered or limit == nil then
        return
    end

    local Render = com.prineside.tdi2.events.global.Render.class
    C.Game.EVENTS:getListeners(Render):add(C.Listener(function(_)
        -- Once-per-env marker: proves this env registered a dispatch listener
        -- on the JVM-global bus at all (the scenario A question). It fires
        -- even when the owner gate below rejects the drain, because listener
        -- registration - not message processing - is what we are counting.
        if not multitode.net._dispatchRanMarker then
            multitode.net._dispatchRanMarker = true
            multitode.net.appendEnvMarker("dispatch-listener-ran")
        end
        multitode.net.dispatchPending(limit)
    end))
    autoDispatchRegistered = true
    logger:i("Enabled automatic message dispatch")
    multitode.net.appendEnvMarker("dispatch-listener-registered")
end

multitode.approveQueuedAction = function(targetTick, actionString)
    multitode.getApi():approveQueuedAction(tonumber(targetTick), tostring(actionString))
end

multitode.consumeApprovedQueuedAction = function(targetTick, actionString)
    return multitode.getApi():consumeApprovedQueuedAction(tonumber(targetTick), tostring(actionString))
end

multitode.resetApprovedQueuedActions = function()
    multitode.getApi():resetApprovedQueuedActions()
end

multitode.savePendingStartupSync = function(payload)
    multitode.getApi():savePendingStartupSyncJson(encode_json_value(payload))
end

multitode.getPendingStartupSync = function()
    local rawJson = multitode.getApi():getPendingStartupSyncJson()
    if rawJson == nil then
        return nil
    end

    return decode_json_value(jsonReader:parse(rawJson))
end

multitode.clearPendingStartupSync = function()
    multitode.getApi():clearPendingStartupSync()
end

multitode.reconnect = function()
    multitode.getApi():reconnect()
    logger:i("Bridge reconnect requested")
end

multitode.getLatency = function()
    return multitode.getApi():getLatencyMillis()
end

multitode.captureCurrentGameSnapshotBase64 = function()
    return multitode.getApi():captureCurrentGameSnapshotBase64()
end

multitode.restoreGameSnapshotBase64 = function(snapshotBase64, gameStartTimestamp)
    multitode.getApi():restoreGameSnapshotBase64(tostring(snapshotBase64), tonumber(gameStartTimestamp) or 0)
end

multitode.isInitialized = function()
    return multitode.getApi():isInitialized()
end

multitode.describe = function()
    local state = multitode.state()
    return string.format(
        "Multitode bridge initialized=%s role=%s lifecycle=%s",
        tostring(state.initialized),
        tostring(state.role),
        tostring(state.lifecycleState)
    )
end

multitode.net.enableAutoDispatch(128)

-- Per-env boot marker. This file executes once per ScriptEnvironment
-- (ScriptManager global env + ScriptSystem game env), and each env gets a
-- fresh multitode table. Count these lines to see how many environments ran
-- this script; comparing addresses confirms they are distinct envs.
pcall(function()
    logger:i("env boot 02 t=%s", tostring(multitode))
end)
multitode.net.appendEnvMarker("boot02")

-- ============================================================
-- Super-log diagnostics (default ON; toggle in Settings UI) --
-- ============================================================
multitode._superlog = true
multitode._superlogSessionInstalled = multitode._superlogSessionInstalled or nil

multitode.setSuperlog = function(on)
    multitode._superlog = not not on
    logger:i("Super-log diagnostics %s", multitode._superlog and "ENABLED" or "DISABLED")
end

multitode.superlogOn = function()
    return multitode._superlog ~= false
end

multitode.slog = function(category, message)
    if multitode._superlog == false then
        return
    end
    local role = "?"
    pcall(function()
        local st = multitode.state()
        if st ~= nil and st.role ~= nil then
            role = tostring(st.role)
        end
    end)
    logger:i("SUPERLOG [%s] %s %s", role, tostring(category), tostring(message))
end

-- Best-effort probe of live match state. Returns a table of strings, or nil
-- when no game screen is active. Every accessor is pcall-guarded: unknown
-- engine details must never break the game, they just show as "?".
multitode.superlog_probe_state = function()
    local ok, result = pcall(function()
        local scr = C.Game.i.screenManager:getCurrentScreen()
        if scr == nil or not C.GameScreen:_isInstance(scr) or scr.S == nil then
            return nil
        end
        local sys = scr.S
        local out = {}

        if sys.state ~= nil and sys.state.updateNumber ~= nil then
            out.tick = tostring(tonumber(sys.state.updateNumber) or "?")
        else
            out.tick = "?"
        end

        out.wave = "?"
        pcall(function()
            if sys.wave ~= nil then
                if sys.wave.wave ~= nil and sys.wave.wave.waveNumber ~= nil then
                    out.wave = tostring(sys.wave.wave.waveNumber)
                elseif sys.wave.getCompletedWavesCount ~= nil then
                    out.wave = "done:" .. tostring(sys.wave:getCompletedWavesCount())
                end
            end
        end)

        out.money = "?"
        pcall(function()
            if sys.gameState ~= nil and sys.gameState.getMoney ~= nil then
                out.money = tostring(sys.gameState:getMoney())
            end
        end)

        out.lives = "?"
        pcall(function()
            if sys.gameState ~= nil then
                if sys.gameState.getHealth ~= nil then
                    out.lives = tostring(sys.gameState:getHealth())
                elseif sys.gameState.getLives ~= nil then
                    out.lives = tostring(sys.gameState:getLives())
                elseif sys.gameState.lives ~= nil then
                    out.lives = tostring(sys.gameState.lives)
                end
            end
        end)

        out.kills = "?"
        pcall(function()
            if sys.statistics ~= nil and C.StatisticsType ~= nil and C.StatisticsType.EK ~= nil then
                out.kills = tostring(sys.statistics:getStatistic(C.StatisticsType.EK))
            end
        end)

        out.enemies = "?"
        pcall(function()
            if sys.map ~= nil and sys.map.spawnedEnemies ~= nil
                and sys.map.spawnedEnemies.size ~= nil then
                out.enemies = tostring(sys.map.spawnedEnemies.size)
            elseif sys.enemy ~= nil then
                if sys.enemy.enemiesArray ~= nil and sys.enemy.enemiesArray.size ~= nil then
                    out.enemies = tostring(sys.enemy.enemiesArray.size)
                elseif sys.enemy.getEnemyCount ~= nil then
                    out.enemies = tostring(sys.enemy:getEnemyCount())
                end
            end
        end)

        out.towers = "?"
        pcall(function()
            if sys.tower ~= nil then
                if sys.tower.towers ~= nil and sys.tower.towers.size ~= nil then
                    out.towers = tostring(sys.tower.towers.size)
                elseif sys.tower.towersArray ~= nil and sys.tower.towersArray.size ~= nil then
                    out.towers = tostring(sys.tower.towersArray.size)
                elseif sys.tower.getTowerCount ~= nil then
                    out.towers = tostring(sys.tower:getTowerCount())
                end
            end
        end)

        out.speed = "?"
        pcall(function()
            if sys.state ~= nil and sys.state.getGameSpeed ~= nil then
                out.speed = tostring(sys.state:getGameSpeed())
            end
        end)

        return out
    end)
    if not ok or result == nil then
        return nil
    end
    return result
end

multitode.superlog_state_hash = function()
    local st = multitode.superlog_probe_state()
    if st == nil then
        return nil
    end
    return string.format("t=%s|w=%s|m=%s|l=%s|k=%s|e=%s|tw=%s",
        st.tick, st.wave, st.money, st.lives, st.kills, st.enemies, st.towers)
end

-- Periodic STATE line (every ~150 ticks) + resync of the per-session listener.
-- SystemsSetup/StateRestore may fire before the game screen is current, so
-- installation is retried lazily: the heartbeat driver calls
-- multitode.superlog_maybe_install() every frame until it sticks.
multitode.superlog_maybe_install = function()
    local ok, scr = pcall(function()
        return C.Game.i.screenManager:getCurrentScreen()
    end)
    if not ok or scr == nil then
        return false
    end
    local okGame = pcall(function()
        return C.GameScreen:_isInstance(scr)
    end)
    if not okGame then
        return false
    end
    if multitode._superlogSessionInstalled == scr then
        return true
    end
    local okS = pcall(function()
        return scr.S ~= nil and scr.S.events ~= nil
    end)
    if not okS then
        return false
    end
    local installed = false
    pcall(function()
        local lastLoggedTick = -1000
        scr.S.events:getListeners(C.GameStateTick):add(C.Listener(function(_)
            local st = multitode.superlog_probe_state()
            if st == nil then
                return
            end
            local tickNum = tonumber(st.tick) or -1
            if tickNum - lastLoggedTick < 150 then
                return
            end
            lastLoggedTick = tickNum
            local rtt = "?"
            local pending = "?"
            pcall(function()
                local v = multitode.getApi():getLatencyMillis()
                if v ~= nil and tonumber(v) ~= nil and tonumber(v) >= 0 then
                    rtt = tostring(math.floor(tonumber(v)))
                elseif tonumber(multitode.luaRttMs or -1) ~= nil
                        and tonumber(multitode.luaRttMs) >= 0 then
                    -- Java has no sample (reported as -1 = "never measured"):
                    -- show the Lua message-path probe instead of a fake 0/-1.
                    rtt = math.floor(multitode.luaRttMs) .. "(lua)"
                end
            end)
            pcall(function()
                pending = tostring(multitode.getApi():getPendingLuaMessageCount())
            end)
            multitode.slog("STATE", string.format(
                "tick=%s wave=%s money=%s lives=%s kills=%s enemies=%s towers=%s speed=%sx rtt=%sms pending=%s",
                st.tick, st.wave, st.money, st.lives, st.kills,
                st.enemies, st.towers, st.speed, rtt, pending))
        end))
        installed = true
    end)
    if installed then
        multitode._superlogSessionInstalled = scr
    end
    return installed
end

local function superlog_install_for_session()
    if C.Game == nil or C.Game.EVENTS == nil then
        return
    end

    local function install()
        multitode.superlog_maybe_install()
    end

    pcall(function()
        C.Game.EVENTS:getListeners(C.SystemsSetup):add(C.Listener(function(_)
            install()
        end))
    end)
    pcall(function()
        C.Game.EVENTS:getListeners(C.SystemsStateRestore):add(C.Listener(function(_)
            install()
        end))
    end)
end

superlog_install_for_session()

-- Bootstrap config --
local loaded, config = multitode.loadConfig()
if not loaded then
    return
end

local valid, validationError = multitode.validateConfig()
if not valid then
    logger:e("Saved bridge config is invalid: %s", validationError)
    return
end

logger:i("Saved bridge config applied: role=%s player=%s", tostring(config.role), tostring(config.name))

local state = multitode.state()
if (state.initialized and state.lifecycleState == "RUNNING") ~= true then
    multitode.start()
end
----------------------

logger:i("# Multitode "..multitode.version)
logger:i("Lua API loaded")