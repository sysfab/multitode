local logger = C.TLog:forTag("multitode/desync_detection.lua")

_G.multitode = _G.multitode or {}
multitode.desyncDetection = multitode.desyncDetection or {}

local detection = multitode.desyncDetection

detection.installedSessionKey = detection.installedSessionKey or nil
detection.lastHostHeartbeatTick = detection.lastHostHeartbeatTick or -1
detection.lastClientHeartbeatTickByPlayer = detection.lastClientHeartbeatTickByPlayer or {}
detection.pendingHostHeartbeats = detection.pendingHostHeartbeats or {}
detection.renderProbeRegistered = detection.renderProbeRegistered or false
detection.lifecycleListenersRegistered = detection.lifecycleListenersRegistered or false
detection.nextResyncId = detection.nextResyncId or 1
detection.hostResync = detection.hostResync or nil
detection.clientResync = detection.clientResync or nil

local HEARTBEAT_INTERVAL_TICKS = 60
local MAX_TICK_DRIFT = HEARTBEAT_INTERVAL_TICKS
local SNAPSHOT_CHUNK_SIZE = 32000

local function get_current_systems()
    local currentScreen = C.Game.i.screenManager:getCurrentScreen()
    if currentScreen ~= nil and C.GameScreen:_isInstance(currentScreen) then
        return currentScreen.S
    end

    -- Game scripts load while the new GameScreen is still being constructed.
    if S ~= nil and S.events ~= nil and S.state ~= nil then
        return S
    end

    return nil
end

local function get_current_tick()
    local systems = get_current_systems()
    if systems == nil or systems.state == nil or systems.state.updateNumber == nil then
        return -1
    end

    return tonumber(systems.state.updateNumber) or -1
end

local function get_session_key(systems)
    if systems == nil or systems.gameState == nil then
        return nil
    end
    return tostring(systems.gameState.gameStartTimestamp) .. ":" .. tostring(systems)
end

local function reset_heartbeat_state()
    detection.lastHostHeartbeatTick = -1
    detection.lastClientHeartbeatTickByPlayer = {}
    detection.pendingHostHeartbeats = {}
    multitode.clearStateHashSamples()
end

function detection.isResyncInProgress()
    return detection.hostResync ~= nil or detection.clientResync ~= nil
end

local function set_game_speed(systems, speed)
    if multitode.itd ~= nil then
        multitode.itd.lastSpeed = speed
    end
    systems.state:setGameSpeed(speed)
end

local function finish_host_resync()
    local resync = detection.hostResync
    if resync == nil then
        return
    end

    multitode.net.broadcast("itd", "resync_resume", {
        resync_id = resync.resync_id,
        game_speed = resync.game_speed
    })
    local systems = get_current_systems()
    if systems ~= nil then
        set_game_speed(systems, resync.game_speed)
    end
    detection.hostResync = nil
    reset_heartbeat_state()
    logger:i("Completed resync %s and resumed at speed %s", tostring(resync.resync_id), tostring(resync.game_speed))
end

local function start_host_resync(reason)
    if detection.hostResync ~= nil then
        return false
    end

    local role = multitode.state().role
    if role ~= "HOST" and role ~= "HOST_AND_CLIENT" then
        return false
    end

    local systems = get_current_systems()
    if systems == nil then
        return false
    end

    local resyncId = detection.nextResyncId
    detection.nextResyncId = detection.nextResyncId + 1
    local gameSpeed = systems.state:getNonAnimatedGameSpeed()
    set_game_speed(systems, 0)

    local snapshotOk, snapshotBase64 = pcall(multitode.captureCurrentGameSnapshotBase64)
    if not snapshotOk then
        set_game_speed(systems, gameSpeed)
        logger:e("Failed to capture resync snapshot: %s", tostring(snapshotBase64))
        return false
    end
    local totalLength = #snapshotBase64
    local totalChunks = math.max(1, math.ceil(totalLength / SNAPSHOT_CHUNK_SIZE))
    local sessionInfo = multitode.getSessionInfo()
    local expectedAcks = math.max(0, sessionInfo and sessionInfo.connectedPeerCount or 0)
    if role == "HOST_AND_CLIENT" then
        expectedAcks = math.max(0, expectedAcks - 1)
    end
    detection.hostResync = {
        resync_id = resyncId,
        game_speed = gameSpeed,
        expected_acks = expectedAcks,
        acknowledged_players = {}
    }

    multitode.net.broadcast("itd", "resync_begin", {
        resync_id = resyncId,
        snapshot_tick = systems.state.updateNumber,
        game_start_timestamp = systems.gameState.gameStartTimestamp,
        next_action_sequence = multitode.itdNet.getNextActionSequence(),
        pending_approvals = multitode.itdNet.getPendingApprovals(systems.state.updateNumber),
        total_chunks = totalChunks,
        total_length = totalLength,
        reason = tostring(reason)
    })
    for index = 1, totalChunks do
        local startOffset = (index - 1) * SNAPSHOT_CHUNK_SIZE + 1
        local endOffset = math.min(index * SNAPSHOT_CHUNK_SIZE, totalLength)
        multitode.net.broadcast("itd", "resync_chunk", {
            resync_id = resyncId,
            index = index,
            data = string.sub(snapshotBase64, startOffset, endOffset)
        })
    end

    logger:w(
        "Started resync %s at tick %s for %s clients: %s",
        tostring(resyncId),
        tostring(systems.state.updateNumber),
        tostring(expectedAcks),
        tostring(reason)
    )
    if expectedAcks == 0 then
        finish_host_resync()
    end
    return true
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
        multitode.net.sendToHost("itd", "resync_request", {
            tick = tick,
            host_hash = hostHash,
            client_hash = localHash
        })
    else
        logger:i("No desync with host at tick %s", tostring(tick))
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
    local hostTick = get_current_tick()
    local tickDrift = math.abs(hostTick - tick)
    if hostTick >= 0 and tickDrift > MAX_TICK_DRIFT then
        logger:e(
            "DESYNC detected for player %s: tick drift host=%s client=%s delta=%s",
            tostring(playerId),
            tostring(hostTick),
            tostring(tick),
            tostring(tickDrift)
        )
        start_host_resync(
            "player " .. tostring(playerId)
                .. " tick drift host=" .. tostring(hostTick)
                .. " client=" .. tostring(tick)
        )
        return
    end

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
        start_host_resync("player " .. tostring(playerId) .. " hash mismatch at tick " .. tostring(tick))
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
    local sessionKey = get_session_key(systems)
    if systems == nil or systems.events == nil or detection.installedSessionKey == sessionKey then
        return
    end

    reset_heartbeat_state()
    systems.events:getListeners(C.GameStateTick):addWithPriority(C.Listener(function(_)
        local currentSystems = get_current_systems()
        if currentSystems == nil then
            return
        end

        local tick = tonumber(currentSystems.state.updateNumber) or -1
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

    detection.installedSessionKey = sessionKey
    logger:i("Installed state heartbeat listener every %s ticks", tostring(HEARTBEAT_INTERVAL_TICKS))
end

local function schedule_heartbeat_install()
    C.Threads:i():postRunnable(C.Runnable(function()
        install_heartbeat_listener()
    end))
end

function detection.reinstallHeartbeat()
    detection.installedSessionKey = nil
    install_heartbeat_listener()
end

multitode.net.on("itd", "state_heartbeat", function(ctx, payload)
    if ctx.receiverContext == "CLIENT" then
        handle_host_heartbeat(ctx, payload)
    elseif ctx.receiverContext == "HOST" then
        handle_client_heartbeat(ctx, payload)
    end
end)

multitode.net.onHost("itd", "resync_request", function(ctx, payload)
    local tick = payload and tonumber(payload.tick) or -1
    start_host_resync("requested by player " .. tostring(ctx.senderPlayerId) .. " at tick " .. tostring(tick))
end)

multitode.net.onClient("itd", "resync_begin", function(_, payload)
    if multitode.state().role ~= "CLIENT" or payload == nil then
        return
    end

    local resyncId = tonumber(payload.resync_id)
    local totalChunks = tonumber(payload.total_chunks)
    local totalLength = tonumber(payload.total_length)
    if resyncId == nil or totalChunks == nil or totalChunks < 1 or totalLength == nil or totalLength < 1 then
        logger:e("Received invalid resync_begin payload")
        return
    end

    local systems = get_current_systems()
    if systems ~= nil then
        set_game_speed(systems, 0)
    end
    detection.clientResync = {
        resync_id = resyncId,
        snapshot_tick = tonumber(payload.snapshot_tick),
        game_start_timestamp = payload.game_start_timestamp,
        next_action_sequence = payload.next_action_sequence,
        pending_approvals = payload.pending_approvals,
        total_chunks = totalChunks,
        total_length = totalLength,
        chunks = {}
    }
    logger:w("Receiving resync %s from tick %s (%s chunks)", tostring(resyncId), tostring(payload.snapshot_tick), tostring(totalChunks))
end)

multitode.net.onClient("itd", "resync_chunk", function(_, payload)
    if multitode.state().role ~= "CLIENT" or payload == nil then
        return
    end

    local resync = detection.clientResync
    if resync == nil or tonumber(payload.resync_id) ~= resync.resync_id then
        return
    end

    local index = tonumber(payload.index)
    if index == nil or index < 1 or index > resync.total_chunks or payload.data == nil then
        logger:e("Received invalid chunk for resync %s", tostring(resync.resync_id))
        return
    end
    resync.chunks[index] = payload.data

    for chunkIndex = 1, resync.total_chunks do
        if resync.chunks[chunkIndex] == nil then
            return
        end
    end

    local snapshotBase64 = table.concat(resync.chunks, "")
    if #snapshotBase64 ~= resync.total_length then
        logger:e(
            "Resync %s snapshot length mismatch: expected=%s actual=%s",
            tostring(resync.resync_id),
            tostring(resync.total_length),
            tostring(#snapshotBase64)
        )
        detection.clientResync = nil
        return
    end

    local resyncId = resync.resync_id
    multitode.restoreGameSnapshotBase64(snapshotBase64, resync.game_start_timestamp)
    multitode.itdNet.resetClientActionSequence(resync.next_action_sequence)
    multitode.itdNet.restorePendingApprovals(resync.pending_approvals)
    multitode.itdNet.reinstallSessionListeners()
    detection.reinstallHeartbeat()
    reset_heartbeat_state()
    multitode.net.sendToHost("itd", "resync_ready", { resync_id = resyncId })
    logger:i("Restored resync %s at tick %s", tostring(resyncId), tostring(resync.snapshot_tick))
end)

multitode.net.onHost("itd", "resync_ready", function(ctx, payload)
    local resync = detection.hostResync
    if resync == nil or payload == nil or tonumber(payload.resync_id) ~= resync.resync_id then
        return
    end

    local playerId = tonumber(ctx.senderPlayerId) or 0
    if not resync.acknowledged_players[playerId] then
        resync.acknowledged_players[playerId] = true
        resync.expected_acks = resync.expected_acks - 1
    end
    logger:i("Player %s is ready for resync %s; remaining=%s", tostring(playerId), tostring(resync.resync_id), tostring(resync.expected_acks))
    if resync.expected_acks <= 0 then
        finish_host_resync()
    end
end)

multitode.net.onClient("itd", "resync_resume", function(_, payload)
    if multitode.state().role ~= "CLIENT" or payload == nil then
        return
    end

    local resync = detection.clientResync
    if resync == nil or tonumber(payload.resync_id) ~= resync.resync_id then
        return
    end
    local systems = get_current_systems()
    if systems ~= nil then
        set_game_speed(systems, tonumber(payload.game_speed) or 1)
    end
    detection.clientResync = nil
    reset_heartbeat_state()
    logger:i("Completed resync %s", tostring(payload.resync_id))
end)

if not detection.lifecycleListenersRegistered then
    C.Game.EVENTS:getListeners(C.SystemsSetup):add(C.Listener(function(_)
        schedule_heartbeat_install()
    end))

    C.Game.EVENTS:getListeners(C.SystemsStateRestore):add(C.Listener(function(_)
        detection.installedSessionKey = nil
        schedule_heartbeat_install()
    end))
    detection.lifecycleListenersRegistered = true
end

if not detection.renderProbeRegistered then
    local Render = com.prineside.tdi2.events.global.Render.class
    C.Game.EVENTS:getListeners(Render):add(C.Listener(function(_)
        local systems = get_current_systems()
        if systems ~= nil and get_session_key(systems) ~= detection.installedSessionKey then
            install_heartbeat_listener()
        end
    end))
    detection.renderProbeRegistered = true
end

install_heartbeat_listener()
logger:i("Multitode desync detection loaded")
