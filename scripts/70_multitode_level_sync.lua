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
levelSync.chunkAssemblyTimeout = levelSync.chunkAssemblyTimeout or 0
levelSync.nextStartupSyncId = levelSync.nextStartupSyncId or 1
levelSync.lastAppliedStartupSyncId = levelSync.lastAppliedStartupSyncId or 0
levelSync.lastReceivedStartupSyncId = levelSync.lastReceivedStartupSyncId or 0
levelSync.pendingSyncAcks = levelSync.pendingSyncAcks or {}
levelSync.syncAckTimeout = levelSync.syncAckTimeout or 0

local SNAPSHOT_CHUNK_SIZE = 32000

-- Game.i has no wall-clock field exposed to Lua; os.clock() is monotonic and
-- sandbox-safe, good enough for ack/assembly timeouts.
local function now_sec()
    if os.clock then
        return os.clock()
    end
    return 0
end

local function should_handle_client_level_sync()
    return multitode.state().role == "CLIENT"
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
    -- Accept when the snapshot id is >= the announced one: the host can advance its
    -- counter between the announce and the snapshot payload (logs showed
    -- load_level id=1 / snapshot id=2), and strict equality made the client wait
    -- forever until a manual resync.
    local snapshotSyncId = tonumber(snapshotSync.startup_sync_id) or 0
    if pendingStartupSyncId ~= nil and snapshotSyncId < tonumber(pendingStartupSyncId) then
        logger:i(
            "Waiting for matching startup_sync_id: load_level=%s sync_id=%s snapshot_sync_id=%s",
            tostring(levelName),
            tostring(pendingStartupSyncId),
            tostring(snapshotSync.startup_sync_id)
        )
        return false
    end

    -- Never swap the game screen while the pointer is busy. The build menu keeps a
    -- tower reference that goes null during the screen replacement, so a click that
    -- lands in that window throws an NPE and kills the game (observed when a forced
    -- resync arrived while a tower was being placed). Wait for a short idle gap.
    local nowMs = 0
    pcall(function() nowMs = multitode.now_ms() end)
    local pointerBusy = false
    pcall(function()
        local input = C.Gdx.input
        if input ~= nil then
            pointerBusy = input:isTouched() or input:isButtonPressed(0)
        end
    end)
    if pointerBusy then
        levelSync.pointerBusyAt = nowMs
        return false
    end
    if nowMs > 0 and levelSync.pointerBusyAt ~= nil and (nowMs - levelSync.pointerBusyAt) < 500 then
        return false
    end

    -- Guard against a nil/empty snapshot (failed capture) — restoring nil would
    -- throw and leave the client stuck with pending state forever.
    if snapshotSync.snapshot_base64 == nil or tostring(snapshotSync.snapshot_base64) == "" then
        logger:w("Pending snapshot for id=%s is empty; requesting a fresh one",
            tostring(snapshotSync.startup_sync_id))
        clear_pending_client_level_sync()
        pcall(function()
            multitode.net.sendToHost("itd", "resync_request", {
                reason = "empty_snapshot",
                startup_sync_id = snapshotSync.startup_sync_id
            })
        end)
        return false
    end

    multitode.restoreGameSnapshotBase64(snapshotSync.snapshot_base64, snapshotSync.game_start_timestamp)
    -- the snapshot restore replaces the particle system, so put the live tile
    -- marks (ours, not the engine's) back instead of letting them vanish
    pcall(function() multitode.getApi():respawnTileMarks() end)
    levelSync.lastAppliedStartupSyncId = tonumber(snapshotSync.startup_sync_id) or levelSync.lastAppliedStartupSyncId
    logger:i("Started synced level %s from snapshot id=%s", tostring(levelName), tostring(snapshotSync.startup_sync_id))
    -- Seed convergence check: the snapshot carries RNG state, so the local
    -- seed must equal the host's announced seed (compare logs on mismatch).
    pcall(function()
        local scr = C.Game.i.screenManager:getCurrentScreen()
        if scr ~= nil and C.GameScreen:_isInstance(scr) and scr.S ~= nil
                and scr.S.gameState ~= nil then
            logger:i("Applied snapshot id=%s local seed=%s", tostring(snapshotSync.startup_sync_id),
                tostring(scr.S.gameState:getSeed()))
        end
    end)
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
    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo == nil or not sessionInfo.sessionActive then
        return
    end

    local role = multitode.state().role
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

    -- Dedup on level + game start only. The sync id climbs on every announce,
    -- so including it would fail this check forever - and every StateRestore /
    -- SystemsSetup call would blast a fresh snapshot at the client (we once
    -- watched 8 restores in 60 seconds: speed blips, jumping ticks). resyncNow
    -- still forces a new announce by clearing the key. The payload builds
    -- after the check too: it snapshots the whole game (base64), no point
    -- doing that work for a call we're about to drop.
    local gameStartTimestamp = nil
    pcall(function() gameStartTimestamp = currentScreen.S.gameState.gameStartTimestamp end)
    local startupKey = string.format(
        "%s:%s",
        tostring(levelName),
        tostring(gameStartTimestamp)
    )
    if levelName == levelSync.lastAnnouncedLevelName and startupKey == levelSync.lastBroadcastedStartupSyncKey then
        return
    end

    local startupPayload = build_startup_sync_payload(currentScreen, levelName)

    -- Locked-level guard, enforced HERE because this is the moment a level becomes a
    -- multiplayer level. The previous guard lived in lobby.set_level(), which is not on the
    -- path the game uses when the host starts a level from its own menu - which is why a
    -- locked level still went through with "Any map" switched off. If this host has not
    -- unlocked the level, it is not announced and no client is dragged into it. The lab
    -- switch exists so this can be deliberately bypassed for testing.
    local lockCheck = nil
    pcall(function()
        if multitode.lobby ~= nil then lockCheck = multitode.lobby.level_is_unlocked end
    end)
    if type(lockCheck) == "function" then
        local unlocked = nil
        pcall(function() unlocked = lockCheck(levelName) end)
        if unlocked == false then
            pcall(function()
                multitode.slog("LEVEL", "refusing to announce locked level " .. tostring(levelName))
                logger:w("Not announcing level %s: this host has not unlocked it", tostring(levelName))
                if multitode.show_toast ~= nil then
                    multitode.show_toast("That level is not unlocked on this host")
                end
            end)
            return
        end
    end

    levelSync.lastAnnouncedLevelName = levelName
    levelSync.lastBroadcastedStartupSyncKey = startupKey
    levelSync.nextStartupSyncId = levelSync.nextStartupSyncId + 1

    -- Desync watchdog fuel: log the authoritative seed so host/client logs can
    -- be compared. Same seed + same snapshot bytes = same enemies, by design.
    pcall(function()
        local seed = currentScreen.S.gameState:getSeed()
        logger:i("Announcing level %s sync_id=%s seed=%s", tostring(levelName),
            tostring(startupPayload.startup_sync_id), tostring(seed))
    end)

    -- Check if any peers are connected
    local hasPeers = multitode.getApi():hasPeers()

    -- Broadcast level announcement
    multitode.net.broadcast("itd", "load_level", {
        level_name = levelName,
        startup_sync_id = startupPayload.startup_sync_id
    })

    if hasPeers then
        -- Store snapshot data for sending after clients acknowledge
        levelSync.pendingSnapshotPayload = startupPayload
        local ackNowMs = 0
        pcall(function() ackNowMs = multitode.now_ms() end)
        if ackNowMs <= 0 then ackNowMs = now_sec() * 1000 end
        levelSync.syncAckTimeout = ackNowMs + 8000 -- 8s of REAL time
        levelSync.pendingSyncAcks = {}
        logger:i("Broadcasted load_level for %s, waiting for client acks...", tostring(levelName))
    else
        -- No peers, send snapshot immediately
        broadcast_snapshot_chunks(startupPayload)
        logger:i("Broadcasted load_level for %s (no peers)", tostring(levelName))
    end
end

local function schedule_level_announce()
    C.Threads:i():postRunnable(C.Runnable(function()
        local ok, err = pcall(maybe_announce_current_level)
        if not ok then
            logger:e("Failed to announce current level: %s", tostring(err))
        end
    end))
end

-- Task 7: on-demand mid-game resync. Host rebuilds the snapshot from live
-- state and pushes it through the normal ack/chunk/apply flow with a fresh
-- sync id, so clients converge without restarting the match.
function levelSync.resyncNow()
    local role = multitode.state().role
    if role ~= "HOST" and role ~= "HOST_AND_CLIENT" then
        error("only the host can broadcast a resync")
    end

    levelSync.lastAnnouncedLevelName = nil
    levelSync.lastBroadcastedStartupSyncKey = nil
    levelSync.pendingSnapshotPayload = nil
    levelSync.pendingSyncAcks = {}
    levelSync.syncAckTimeout = 0
    pcall(function()
        multitode.slog("RESYNC", "host broadcasting fresh snapshot")
    end)
    maybe_announce_current_level()
    logger:i("Resync broadcast requested")
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
            -- Already applied this (or an older) sync. Re-ack so a host that
            -- lost our previous ack still releases the snapshot wait, but do
            -- not rebuild pending state for a stale id.
            pcall(function()
                multitode.net.sendToHost("itd", "level_ack", {
                    startup_sync_id = startupSyncId
                })
            end)
            return
        end

        levelSync.pendingClientLevelName = {
            level_name = levelName,
            startup_sync_id = startupSyncId
        }
        -- Ack the announcement immediately. The host waits for every client
        -- before it ships the snapshot, so acking only on level_snapshot_begin
        -- deadlocked the handshake into the 5s timeout and left every client
        -- ~5 seconds (154 ticks) behind the host - that offset is what made the
        -- host see the client's buildings first and desynced the waves.
        multitode.net.sendToHost("itd", "level_ack", {
            startup_sync_id = startupSyncId
        })
        maybe_start_pending_client_level()
    end)

    -- Host receives ack from client that they received the level announcement
    multitode.net.onHost("itd", "level_ack", function(ctx, payload)
        if payload == nil then return end
        local startupSyncId = tonumber(payload.startup_sync_id) or 0
        -- Ignore acks for a different (stale) sync id — they must not release
        -- the wait for the CURRENT pending snapshot.
        local pending = levelSync.pendingSnapshotPayload
        if pending ~= nil then
            local pendingId = tonumber(pending.startup_sync_id) or 0
            if startupSyncId ~= 0 and startupSyncId ~= pendingId then
                logger:w("Ignoring level_ack id=%s (pending id=%s)",
                    tostring(startupSyncId), tostring(pendingId))
                return
            end
        end
        levelSync.pendingSyncAcks[ctx.senderPlayerId] = true

        -- Check if all connected peers have acked
        local peerCount = multitode.getApi():getConnectedPeerCount()
        local ackCount = 0
        for _ in pairs(levelSync.pendingSyncAcks) do ackCount = ackCount + 1 end

        if ackCount >= peerCount and levelSync.pendingSnapshotPayload then
            -- Rebuild the snapshot at SEND time if the level/timestamp moved
            -- during the ack wait — shipping the pre-wait bytes would restore
            -- a stale world.
            local snap = levelSync.pendingSnapshotPayload
            local liveName = get_current_basic_level_name()
            if liveName ~= nil and snap.level_name ~= liveName then
                logger:w("Level changed during ack wait (%s -> %s); re-announcing",
                    tostring(snap.level_name), tostring(liveName))
                levelSync.pendingSnapshotPayload = nil
                levelSync.pendingSyncAcks = {}
                levelSync.syncAckTimeout = 0
                levelSync.lastAnnouncedLevelName = nil
                levelSync.lastBroadcastedStartupSyncKey = nil
                schedule_level_announce()
                return
            end
            -- All clients ready, send the snapshot
            broadcast_snapshot_chunks(levelSync.pendingSnapshotPayload)
            levelSync.pendingSnapshotPayload = nil
            levelSync.pendingSyncAcks = {}
            levelSync.syncAckTimeout = 0
            logger:i("All clients acked, sent snapshot")
        end
    end)

    -- Task 7: a client can ask the host for a fresh mid-game snapshot.
    multitode.net.onHost("itd", "resync_request", function(ctx, _)
        logger:i("Resync requested by player %s", tostring(ctx.senderPlayerId))
        pcall(function()
            multitode.slog("RESYNC", string.format("requested by player %s", tostring(ctx.senderPlayerId)))
        end)
        local ok, err = pcall(levelSync.resyncNow)
        if not ok then
            logger:e("Resync failed: %s", tostring(err))
        end
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
        if startupSyncId <= levelSync.lastAppliedStartupSyncId then
            return
        end
        -- Drop a true duplicate begin only while we are already assembling the
        -- SAME id. If assembly timed out (pendingClientSnapshotChunks cleared)
        -- or lastReceived was set without a live assembly, allow a re-begin.
        if startupSyncId == levelSync.lastReceivedStartupSyncId
                and levelSync.pendingClientSnapshotChunks ~= nil
                and tonumber(levelSync.pendingClientSnapshotChunks.startup_sync_id) == startupSyncId then
            -- Re-ack (host may have missed the first) but do not reset chunks.
            pcall(function()
                multitode.net.sendToHost("itd", "level_ack", {
                    startup_sync_id = startupSyncId
                })
            end)
            return
        end
        if startupSyncId < levelSync.lastReceivedStartupSyncId then
            return
        end

        -- Send ack to host
        multitode.net.sendToHost("itd", "level_ack", {
            startup_sync_id = startupSyncId
        })

        levelSync.pendingClientSnapshotChunks = {
            startup_sync_id = startupSyncId,
            level_name = payload.level_name,
            game_start_timestamp = payload.game_start_timestamp,
            total_chunks = payload.total_chunks,
            chunks = {}
        }
        levelSync.lastReceivedStartupSyncId = startupSyncId
        levelSync.chunkAssemblyTimeout = now_sec() + 30.0 -- 30 second timeout
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

    C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
        -- Timeout check for pending snapshot acks (host side)
        local tickNowMs = 0
        pcall(function() tickNowMs = multitode.now_ms() end)
        if tickNowMs <= 0 then tickNowMs = now_sec() * 1000 end
        if levelSync.syncAckTimeout > 0 and tickNowMs > levelSync.syncAckTimeout then
            if levelSync.pendingSnapshotPayload then
                -- Rebuild at timeout send-time if the live level moved on.
                local snap = levelSync.pendingSnapshotPayload
                local liveName = get_current_basic_level_name()
                if liveName ~= nil and snap.level_name ~= liveName then
                    logger:w("Level changed during ack timeout; re-announcing instead of shipping stale snapshot")
                    levelSync.pendingSnapshotPayload = nil
                    levelSync.pendingSyncAcks = {}
                    levelSync.syncAckTimeout = 0
                    levelSync.lastAnnouncedLevelName = nil
                    levelSync.lastBroadcastedStartupSyncKey = nil
                    schedule_level_announce()
                else
                    logger:w("Sync ack timeout, sending snapshot anyway")
                    broadcast_snapshot_chunks(levelSync.pendingSnapshotPayload)
                    levelSync.pendingSnapshotPayload = nil
                    levelSync.pendingSyncAcks = {}
                    levelSync.syncAckTimeout = 0
                end
            end
        end

        -- Timeout check for incomplete chunk assembly (client side)
        if levelSync.pendingClientSnapshotChunks and levelSync.chunkAssemblyTimeout > 0 and now_sec() > levelSync.chunkAssemblyTimeout then
            local timedOutId = levelSync.pendingClientSnapshotChunks.startup_sync_id
            logger:w("Chunk assembly timeout for startup_sync_id=%s, discarding",
                tostring(timedOutId))
            levelSync.pendingClientSnapshotChunks = nil
            levelSync.chunkAssemblyTimeout = 0
            -- Ask the host to re-send instead of sitting on a half-assembled
            -- snapshot forever (the old path just discarded and stalled).
            pcall(function()
                multitode.net.sendToHost("itd", "resync_request", {
                    reason = "chunk_timeout",
                    startup_sync_id = timedOutId
                })
                multitode.slog("RESYNC", "chunk timeout -> requested re-send id=" .. tostring(timedOutId))
            end)
        end

        -- Client never received begin after load_level: request a resync so the
        -- host re-announces rather than leaving us on the old level.
        if levelSync.pendingClientLevelName ~= nil
                and levelSync.pendingClientSnapshotChunks == nil
                and levelSync.pendingClientSnapshotSync == nil then
            levelSync.beginWaitAt = levelSync.beginWaitAt or now_sec()
            if now_sec() - levelSync.beginWaitAt > 12.0 then
                local waitId = levelSync.pendingClientLevelName.startup_sync_id
                levelSync.beginWaitAt = nil
                pcall(function()
                    multitode.net.sendToHost("itd", "resync_request", {
                        reason = "begin_timeout",
                        startup_sync_id = waitId
                    })
                    multitode.slog("RESYNC", "no snapshot begin -> requested resync id=" .. tostring(waitId))
                end)
            end
        else
            levelSync.beginWaitAt = nil
        end
    end))

    levelSync.handlersRegistered = true
    logger:i("Multitode level sync loaded")
end

ensure_handlers_registered()
