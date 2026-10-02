local logger = C.TLog:forTag("multitode/desync_detection.lua")

_G.multitode = _G.multitode or {}
multitode.desyncDetection = multitode.desyncDetection or {}

local detection = multitode.desyncDetection

detection.installedSession = nil
detection.lastHostHeartbeatTick = detection.lastHostHeartbeatTick or -1
detection.lastClientHeartbeatTickByPlayer = detection.lastClientHeartbeatTickByPlayer or {}
detection.pendingHostHeartbeats = detection.pendingHostHeartbeats or {}

local HEARTBEAT_INTERVAL_TICKS = 60

-- TODO: FIX NOT WORKING (nil?)
local function get_current_systems()
    local currentScreen = C.Game.i.screenManager:getCurrentScreen()
    if currentScreen == nil or not C.GameScreen:_isInstance(currentScreen) then
        return nil
    end

    return currentScreen.S
end

local function get_current_tick()
    local systems = get_current_systems()
    if systems == nil or systems.state == nil or systems.state.updateNumber == nil then
        return -1
    end

    return tonumber(systems.state.updateNumber) or -1
end

local function reset_heartbeat_state()
    detection.lastHostHeartbeatTick = -1
    detection.lastClientHeartbeatTickByPlayer = {}
    detection.pendingHostHeartbeats = {}
    multitode.clearStateHashSamples()
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

local function handle_host_heartbeat(_, payload)
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
end

local function handle_client_heartbeat(ctx, payload)
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
    else
        logger:i(
            "No desync for player %s at tick %s",
            tostring(playerId),
            tostring(tick)
        )
    end
end

local function install_heartbeat_listener()
    local systems = get_current_systems()
    if (systems == nil or systems.events == nil) or (detection.installedSession == systems) then
        logger:i(
            "Aborting heartbeat install | Systems present: %s | Already installed: %s",
            tostring(systems == nil),
            tostring(detection.installedSession == systems)
        )
        return
    end

    reset_heartbeat_state()
    systems.events:getListeners(C.GameStateTick):addStateAffectingWithPriority(C.Listener(function(_)
        local tick = tonumber(systems.state.updateNumber) or -1
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

    detection.installedSession = systems
    logger:i("Installed state heartbeat listener every %s ticks", tostring(HEARTBEAT_INTERVAL_TICKS))
end

local function schedule_heartbeat_install()
    C.Threads:i():postRunnable(C.Runnable(function()
        install_heartbeat_listener()
    end))
end

multitode.net.on("itd", "state_heartbeat", function(ctx, payload)
    if ctx.receiverContext == "CLIENT" then
        handle_host_heartbeat(ctx, payload)
    elseif ctx.receiverContext == "HOST" then
        handle_client_heartbeat(ctx, payload)
    end
end)

C.Game.EVENTS:getListeners(C.SystemsSetup):add(C.Listener(function(_)
    schedule_heartbeat_install()
end))

C.Game.EVENTS:getListeners(C.SystemsStateRestore):add(C.Listener(function(_)
    schedule_heartbeat_install()
end))

install_heartbeat_listener()
logger:i("Multitode desync detection loaded")
