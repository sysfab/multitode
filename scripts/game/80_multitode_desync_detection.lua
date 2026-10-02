local logger = C.TLog:forTag("multitode/desync_detection.lua")

_G.multitode = _G.multitode or {}
multitode.desyncDetection = multitode.desyncDetection or {}

local detection = multitode.desyncDetection

detection.installedSession = nil
detection.lastHostHeartbeatTick = detection.lastHostHeartbeatTick or -1
detection.lastClientHeartbeatTickByPlayer = detection.lastClientHeartbeatTickByPlayer or {}
detection.pendingHostHeartbeats = detection.pendingHostHeartbeats or {}

local HEARTBEAT_INTERVAL_TICKS = 120

local function reset_heartbeat_state()
    detection.lastHostHeartbeatTick = -1
    detection.lastClientHeartbeatTickByPlayer = {}
    detection.pendingHostHeartbeats = {}
    multitode.clearStateHashSamples()
end

local function get_current_tick()
    if S == nil or S.state == nil or S.state.updateNumber == nil then
        return -1
    end

    return tonumber(S.state.updateNumber) or -1
end

local function get_hash_sample(tick)
    local ok, stateHash = pcall(multitode.getCurrentGameStateHash)
    if not ok then
        logger:e("Failed to calculate state hash at tick %s: %s", tostring(tick), tostring(stateHash))
        return nil
    end

    multitode.saveStateHashSample(tick, stateHash)
    return stateHash
end

local function compare_host_heartbeat(tick, hostHash)
    local localHash = multitode.getStateHashSample(tick)
    if localHash == nil then
        logger:w("Discarding host heartbeat for tick %s without a local hash sample", tostring(tick))
        detection.lastHostHeartbeatTick = tick
        return
    end

    detection.lastHostHeartbeatTick = tick
    if localHash ~= hostHash then
        logger:e(
            "DESYNC detected at tick %s: host hash=%s local hash=%s",
            tostring(tick),
            tostring(hostHash),
            tostring(localHash)
        )
    end
end

local function process_pending_host_heartbeat(tick)
    local hostHash = detection.pendingHostHeartbeats[tick]
    if hostHash == nil then
        return
    end

    detection.pendingHostHeartbeats[tick] = nil
    compare_host_heartbeat(tick, hostHash)
end

local function validate_heartbeat(payload)
    if payload == nil then
        return nil, nil
    end

    local tick = tonumber(payload.tick)
    local stateHash = payload.state_hash
    if tick == nil or tick < 0 or tick ~= math.floor(tick) or stateHash == nil or stateHash == "" then
        return nil, nil
    end

    return tick, tostring(stateHash)
end

local function install_heartbeat_listener()
    if S == nil or S.events == nil or detection.installedSession == S then
        return
    end

    reset_heartbeat_state()
    S.events:getListeners(C.GameStateTick):addStateAffectingWithPriority(C.Listener(function(_)
        local tick = get_current_tick()
        if tick < 0 or tick % HEARTBEAT_INTERVAL_TICKS ~= 0 then
            return
        end

        local stateHash = get_hash_sample(tick)
        if stateHash == nil then
            return
        end

        process_pending_host_heartbeat(tick)

        local role = multitode.state().role
        local heartbeat = { tick = tick, state_hash = stateHash }
        if role == "CLIENT" then
            multitode.net.sendToHost("itd", "state_heartbeat", heartbeat)
        elseif role == "HOST_AND_CLIENT" or role == "HOST" then
            multitode.net.broadcast("itd", "state_heartbeat", heartbeat)
        end
    end), C.EventListeners.PRIORITY_HIGHEST)

    detection.installedSession = S
    logger:i("Installed state heartbeat listener every %s ticks", tostring(HEARTBEAT_INTERVAL_TICKS))
end

multitode.net.onClient("itd", "state_heartbeat", function(_, payload)
    if multitode.state().role ~= "CLIENT" then
        return
    end

    local tick, hostHash = validate_heartbeat(payload)
    if tick == nil or tick <= detection.lastHostHeartbeatTick then
        return
    end

    local currentTick = get_current_tick()
    if currentTick >= tick then
        compare_host_heartbeat(tick, hostHash)
    else
        detection.pendingHostHeartbeats[tick] = hostHash
    end
end)

multitode.net.onHost("itd", "state_heartbeat", function(ctx, payload)
    local tick, clientHash = validate_heartbeat(payload)
    if tick == nil then
        return
    end

    local playerId = tonumber(ctx.senderPlayerId) or 0
    local lastTick = detection.lastClientHeartbeatTickByPlayer[playerId] or -1
    if tick <= lastTick then
        return
    end

    detection.lastClientHeartbeatTickByPlayer[playerId] = tick
    local hostHash = multitode.getStateHashSample(tick)
    if hostHash == nil then
        logger:w("Discarding player %s heartbeat for tick %s without a host hash sample", tostring(playerId), tostring(tick))
        return
    end
    if hostHash ~= clientHash then
        logger:e(
            "DESYNC detected for player %s at tick %s: host hash=%s client hash=%s",
            tostring(playerId),
            tostring(tick),
            tostring(hostHash),
            tostring(clientHash)
        )
    end
end)

C.Game.EVENTS:getListeners(C.SystemsSetup):add(C.Listener(function(_)
    install_heartbeat_listener()
end))

C.Game.EVENTS:getListeners(C.SystemsStateRestore):add(C.Listener(function(_)
    install_heartbeat_listener()
end))

install_heartbeat_listener()
logger:i("Multitode desync detection loaded")
