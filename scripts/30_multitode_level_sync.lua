local logger = C.TLog:forTag("multitode/level_sync.lua")

_G.multitode = _G.multitode or {}
multitode.levelSync = multitode.levelSync or {}

local levelSync = multitode.levelSync

levelSync.handlersRegistered = levelSync.handlersRegistered or false
levelSync.lastAnnouncedLevelName = levelSync.lastAnnouncedLevelName or nil
levelSync.screenListenerRegistered = levelSync.screenListenerRegistered or false
levelSync.lastBroadcastedStartupSyncKey = levelSync.lastBroadcastedStartupSyncKey or nil
levelSync.pendingClientLevelName = levelSync.pendingClientLevelName or nil
levelSync.pendingClientSnapshotSync = levelSync.pendingClientSnapshotSync or nil
levelSync.pendingClientSnapshotChunks = levelSync.pendingClientSnapshotChunks or nil
levelSync.nextStartupSyncId = levelSync.nextStartupSyncId or 1
levelSync.lastAppliedStartupSyncId = levelSync.lastAppliedStartupSyncId or 0
levelSync.lastReceivedStartupSyncId = levelSync.lastReceivedStartupSyncId or 0

local SNAPSHOT_CHUNK_SIZE = 32000

local function get_role()
    local ok, state = pcall(multitode.state)
    if not ok or state == nil then
        return nil
    end

    return state.role
end

local function get_session_info()
    local ok, info = pcall(multitode.getSessionInfo)
    if not ok then
        return nil
    end

    return info
end

local function should_handle_client_level_sync()
    local role = get_role()
    return role == "CLIENT"
end

local function get_current_basic_level_name()
    local currentScreen = C.Game.i.screenManager:getCurrentScreen()
    if currentScreen == nil or not C.GameScreen:_isInstance(currentScreen) then
        return nil
    end

    local gameScreen = currentScreen
    if gameScreen.S == nil or gameScreen.S.gameState == nil then
        return nil
    end

    return gameScreen.S.gameState.basicLevelName
end

local function start_basic_level(levelName)
    local basicLevel = C.Game.i.basicLevelManager:getLevel(levelName)
    if basicLevel == nil then
        logger:e("Failed to start synced level %s: level not found", tostring(levelName))
        return false
    end

    C.Game.i.screenManager:startNewBasicLevel(basicLevel, nil)
    logger:i("Started synced level %s", tostring(levelName))
    return true
end

local function clear_pending_client_level_sync()
    levelSync.pendingClientLevelName = nil
    levelSync.pendingClientSnapshotSync = nil
    levelSync.pendingClientSnapshotChunks = nil
end

local function maybe_start_pending_client_level()
    local pendingLevel = levelSync.pendingClientLevelName
    local snapshotSync = levelSync.pendingClientSnapshotSync
    if pendingLevel == nil or snapshotSync == nil then
        return false
    end

    local levelName = pendingLevel.level_name
    local pendingStartupSyncId = pendingLevel.startup_sync_id
    if pendingStartupSyncId ~= nil and pendingStartupSyncId <= levelSync.lastAppliedStartupSyncId then
        clear_pending_client_level_sync()
        return false
    end

    if snapshotSync.level_name ~= nil and snapshotSync.level_name ~= levelName then
        logger:i(
            "Waiting for matching level_snapshot_sync: load_level=%s snapshot_sync=%s",
            tostring(levelName),
            tostring(snapshotSync.level_name)
        )
        return false
    end
    if pendingStartupSyncId ~= nil and snapshotSync.startup_sync_id ~= nil and snapshotSync.startup_sync_id ~= pendingStartupSyncId then
        logger:i(
            "Waiting for matching startup_sync_id: load_level=%s sync_id=%s snapshot_sync_id=%s",
            tostring(levelName),
            tostring(pendingStartupSyncId),
            tostring(snapshotSync.startup_sync_id)
        )
        return false
    end

    multitode.restoreGameSnapshotBase64(snapshotSync.snapshot_base64, snapshotSync.game_start_timestamp)
    levelSync.lastAppliedStartupSyncId = tonumber(snapshotSync.startup_sync_id) or levelSync.lastAppliedStartupSyncId
    logger:i("Started synced level %s from snapshot id=%s", tostring(levelName), tostring(snapshotSync.startup_sync_id))
    clear_pending_client_level_sync()
    return true
end

local function build_startup_sync_payload(gameScreen, levelName)
    local payload = {
        startup_sync_id = levelSync.nextStartupSyncId,
        level_name = levelName,
        game_start_timestamp = gameScreen.S.gameState.gameStartTimestamp,
        snapshot_base64 = multitode.captureCurrentGameSnapshotBase64(),
    }

    return payload
end

local function broadcast_snapshot_chunks(startupPayload)
    local snapshotBase64 = startupPayload.snapshot_base64
    local totalLength = #snapshotBase64
    local totalChunks = math.max(1, math.ceil(totalLength / SNAPSHOT_CHUNK_SIZE))

    multitode.net.broadcast("itd", "level_snapshot_begin", {
        startup_sync_id = startupPayload.startup_sync_id,
        level_name = startupPayload.level_name,
        game_start_timestamp = startupPayload.game_start_timestamp,
        total_chunks = totalChunks,
        total_length = totalLength
    })

    for index = 1, totalChunks do
        local startOffset = (index - 1) * SNAPSHOT_CHUNK_SIZE + 1
        local endOffset = math.min(index * SNAPSHOT_CHUNK_SIZE, totalLength)
        multitode.net.broadcast("itd", "level_snapshot_chunk", {
            startup_sync_id = startupPayload.startup_sync_id,
            index = index,
            total_chunks = totalChunks,
            data = string.sub(snapshotBase64, startOffset, endOffset)
        })
    end
end

local function maybe_announce_current_level()
    local sessionInfo = get_session_info()
    if sessionInfo == nil or not sessionInfo.sessionActive then
        return
    end

    local role = get_role()
    if role ~= "HOST" and role ~= "HOST_AND_CLIENT" then
        return
    end

    local levelName = get_current_basic_level_name()
    if levelName == nil then
        return
    end

    local currentScreen = C.Game.i.screenManager:getCurrentScreen()
    if currentScreen == nil or not C.GameScreen:_isInstance(currentScreen) or currentScreen.S == nil then
        return
    end

    local startupPayload = build_startup_sync_payload(currentScreen, levelName)
    local startupKey = string.format(
        "%s:%s:%s",
        tostring(startupPayload.level_name),
        tostring(startupPayload.game_start_timestamp),
        tostring(startupPayload.startup_sync_id)
    )
    if levelName == levelSync.lastAnnouncedLevelName and startupKey == levelSync.lastBroadcastedStartupSyncKey then
        return
    end

    levelSync.lastAnnouncedLevelName = levelName
    levelSync.lastBroadcastedStartupSyncKey = startupKey
    levelSync.nextStartupSyncId = levelSync.nextStartupSyncId + 1
    multitode.net.broadcast("itd", "load_level", {
        level_name = levelName,
        startup_sync_id = startupPayload.startup_sync_id
    })
    broadcast_snapshot_chunks(startupPayload)
    logger:i("Broadcasted load_level for %s", tostring(levelName))
end

local function schedule_level_announce()
    C.Threads:i():postRunnable(C.Runnable(function()
        local ok, err = pcall(maybe_announce_current_level)
        if not ok then
            logger:e("Failed to announce current level: %s", tostring(err))
        end
    end))
end

local function ensure_handlers_registered()
    if levelSync.handlersRegistered then
        return
    end

    multitode.net.onClient("itd", "load_level", function(_, payload)
        if not should_handle_client_level_sync() then
            return
        end

        local levelName = payload and payload.level_name or nil
        if levelName == nil then
            logger:e("Received load_level without level_name")
            return
        end

        local startupSyncId = tonumber(payload.startup_sync_id) or 0
        if startupSyncId <= levelSync.lastAppliedStartupSyncId then
            return
        end

        levelSync.pendingClientLevelName = {
            level_name = levelName,
            startup_sync_id = startupSyncId
        }
        maybe_start_pending_client_level()
    end)

    multitode.net.onClient("itd", "level_snapshot_begin", function(_, payload)
        if not should_handle_client_level_sync() then
            return
        end

        if payload == nil or payload.level_name == nil then
            logger:e("Received level_snapshot_begin without level_name")
            return
        end

        local startupSyncId = tonumber(payload.startup_sync_id) or 0
        if startupSyncId <= levelSync.lastAppliedStartupSyncId or startupSyncId < levelSync.lastReceivedStartupSyncId then
            return
        end

        levelSync.pendingClientSnapshotChunks = {
            startup_sync_id = startupSyncId,
            level_name = payload.level_name,
            game_start_timestamp = payload.game_start_timestamp,
            total_chunks = payload.total_chunks,
            chunks = {}
        }
        levelSync.lastReceivedStartupSyncId = startupSyncId
        logger:i(
            "Receiving level snapshot for %s id=%s chunks=%s",
            tostring(payload.level_name),
            tostring(startupSyncId),
            tostring(payload.total_chunks)
        )
    end)

    multitode.net.onClient("itd", "level_snapshot_chunk", function(_, payload)
        if not should_handle_client_level_sync() then
            return
        end

        local assembly = levelSync.pendingClientSnapshotChunks
        if assembly == nil then
            return
        end
        if payload == nil or tonumber(payload.startup_sync_id) ~= assembly.startup_sync_id then
            return
        end

        assembly.chunks[payload.index] = payload.data
        local complete = true
        for index = 1, assembly.total_chunks do
            if assembly.chunks[index] == nil then
                complete = false
                break
            end
        end
        if not complete then
            return
        end

        levelSync.pendingClientSnapshotSync = {
            startup_sync_id = assembly.startup_sync_id,
            level_name = assembly.level_name,
            game_start_timestamp = assembly.game_start_timestamp,
            snapshot_base64 = table.concat(assembly.chunks, "")
        }
        levelSync.pendingClientSnapshotChunks = nil
        logger:i(
            "Stored pending level snapshot for %s id=%s",
            tostring(levelSync.pendingClientSnapshotSync.level_name),
            tostring(levelSync.pendingClientSnapshotSync.startup_sync_id)
        )
        maybe_start_pending_client_level()
    end)

    if not levelSync.screenListenerRegistered then
        C.Game.i.screenManager:addListener(C.ScreenManagerListener(function()
            schedule_level_announce()
        end))
        levelSync.screenListenerRegistered = true
    end

    C.Game.EVENTS:getListeners(C.SystemsSetup):add(C.Listener(function(_)
        schedule_level_announce()
    end))

    C.Game.EVENTS:getListeners(C.SystemsStateRestore):add(C.Listener(function(_)
        schedule_level_announce()
    end))

    levelSync.handlersRegistered = true
    logger:i("Multitode level sync loaded")
end

ensure_handlers_registered()
