local logger = C.TLog:forTag("multitode/itd_net.lua")

_G.multitode = _G.multitode or {}
multitode.itdNet = multitode.itdNet or {}

local itdNet = multitode.itdNet

itdNet.handlersRegistered = itdNet.handlersRegistered or false

-- Per-env boot marker (see 02_multitode_api.appendEnvMarker): counts which
-- environments executed this file - the scenario A/B question for the owner
-- gate below.
pcall(function()
    if multitode.net ~= nil and multitode.net.appendEnvMarker ~= nil then
        multitode.net.appendEnvMarker("boot80")
    end
end)

local MIN_ACTION_LEAD_TICKS = 2

-- A speed_state is the epoch-ordered authority for hostSpeed. Heartbeats and
-- delayed SPD ScriptActions can arrive after a newer speed_state and stomp
-- hostSpeed back to an older rate (observed: epoch=2 speed=2 -> 8ms later
-- "Client speed enforced 2x -> 1x"). Ignore a heartbeat speed write when
-- (a) its epoch is behind the stored speed_state epoch, or
-- (b) speed_state landed within GRACE_SEC and the heartbeat disagrees.
local SPEED_STATE_GRACE_SEC = 2.0

local function hb_speed_is_stale(payload, hbSpeed)
    local itd = multitode.itd
    if itd == nil or hbSpeed == nil then
        return false
    end
    local payloadEpoch = payload ~= nil and tonumber(payload.epoch) or nil
    local stateEpoch = tonumber(itd.speedStateEpoch)
    if payloadEpoch ~= nil and stateEpoch ~= nil and payloadEpoch < stateEpoch then
        return true
    end
    if itd.speedStateMode ~= true then
        return false
    end
    local stateAt = tonumber(itd.speedStateAt) or 0
    if stateAt <= 0 then
        return false
    end
    local now = (os.clock and os.clock()) or 0
    if (now - stateAt) >= SPEED_STATE_GRACE_SEC then
        return false
    end
    local hostSpeed = tonumber(itd.hostSpeed)
    if hostSpeed == nil then
        return false
    end
    return math.abs(hostSpeed - hbSpeed) >= 0.001
end

local actionClassByType = {
    BT = C.BuildTowerAction,
    UT = C.UpgradeTowerAction,
    ST = C.SellTowerAction,
    CTAS = C.ChangeTowerAimStrategyAction,
    STA = C.SelectTowerAbilityAction,
    SGTA = C.SelectGlobalTowerAbilityAction,
    CTB = C.CustomTowerButtonAction,
    TTE = C.ToggleTowerEnabledAction,
    GUT = C.GlobalUpgradeTowerAction,
    CW = C.CallWaveAction,
    UA = C.UseAbilityAction,
    BM = C.BuildMinerAction,
    UM = C.UpgradeMinerAction,
    SM = C.SellMinerAction,
    GUM = C.GlobalUpgradeMinerAction,
    BMO = C.BuildModifierAction,
    SMO = C.SellModifierAction,
    CMB = C.CustomModifierButtonAction,
    CU = C.CoreUpgradeAction,
    SGB = C.SelectGameplayBonusAction,
    RRB = C.ReRollBonusesAction,
    EBC = C.EncounterBirdClickAction,
    EBD = C.EncounterBirdDeclineAction
}

local function deserialize_action(payload, actionType, actionJson)
    local actionClass
    if actionType == "SPD" then
        -- Speed is HOST-AUTHORITATIVE: the host may push any speed, including the
        -- engine's pause / slow-motion value (0.0667), and clients obey it. A true
        -- freeze (0) is also allowed when the host explicitly marks frozen=true
        -- (bonus vote / stage freeze) — coercing it to 1 desynced host and client.
        local speedValue = tonumber(payload.speed)
        local frozen = payload.frozen == true
        if frozen then
            speedValue = 0
        elseif speedValue == nil or speedValue < 0 then
            speedValue = 1
        elseif speedValue > 0 and speedValue < 0.05 and not frozen then
            -- sub-floor non-zero still snaps to 1 (engine cannot resume from ~0.01)
            speedValue = 1
        end
        -- hostSpeed is always learned and the client applies the authoritative
        -- rate immediately. There is no local catch-up correction to bypass.
        local applySpeed = speedValue
        -- Delayed SPD can land after a newer speed_state and stomp hostSpeed
        -- (the same race that produced "enforced 2x -> 1x" 8ms after epoch=2).
        -- During the speed_state grace window, only apply if it agrees with
        -- the already-authoritative hostSpeed.
        return C.ScriptAction.new_S(
            "local _itd = multitode.itd"
            .. " if _itd then"
            .. " local _stateAt = tonumber(_itd.speedStateAt) or 0"
            .. " local _now = (os.clock and os.clock()) or 0"
            .. " local _host = tonumber(_itd.hostSpeed)"
            .. " local _recent = _itd.speedStateMode == true and _stateAt > 0"
            .. " and (_now - _stateAt) < " .. tostring(SPEED_STATE_GRACE_SEC)
            .. " local _agree = _host ~= nil and math.abs(_host - " .. applySpeed .. ") < 0.001"
            .. " if (not _recent) or _agree then"
            .. " _itd.hostSpeed = " .. applySpeed
            .. " _itd.lastSpeed = " .. applySpeed
            .. " S.state:setGameSpeed(" .. applySpeed .. ")"
            .. " end end")
    else
        actionClass = actionClassByType[actionType]

        if actionClass == nil then
            logger:w(
                "No registered class for action type %s",
                tostring(actionType)
            )
            return nil
        end
    end

    local jsonValue = C.JsonReader.new():parse(actionJson)
    return actionClass.new_JV(jsonValue)
end

local function get_current_systems()
    local currentScreen = C.Game.i.screenManager:getCurrentScreen()
    if currentScreen == nil or not C.GameScreen:_isInstance(currentScreen) then
        return nil
    end

    local gameScreen = currentScreen
    return gameScreen.S
end

local function get_current_tick()
    local systems = get_current_systems()
    if systems == nil or systems.state == nil or systems.state.updateNumber == nil then
        return -1
    end

    return tonumber(systems.state.updateNumber) or -1
end

local function compute_effective_target(targetTick)
    local systems = get_current_systems()
    if systems == nil or systems.state == nil then
        return targetTick
    end

    local currentTick = get_current_tick()
    local effectiveTargetTick = targetTick
    if currentTick >= 0 then
        local minimumTargetTick = currentTick + MIN_ACTION_LEAD_TICKS
        if effectiveTargetTick < minimumTargetTick then
            effectiveTargetTick = minimumTargetTick
        end
    end
    return effectiveTargetTick
end

local function lag_ms_of(envelope)
    local sentWall = envelope ~= nil and tonumber(envelope.sent_wall) or nil
    if sentWall == nil or os.clock == nil then
        return nil
    end
    return math.floor((os.clock() - sentWall) * 1000)
end

local function enqueue_authoritative_action(envelope, sourceLabel)
    local targetTick = tonumber(envelope.target_tick)
    if targetTick == nil then
        error("missing target_tick")
    end

    local payload = envelope.payload or {}
    local actionType = payload.queuedType
    local actionJson = payload.actionJson
    if actionType == nil or actionJson == nil then
        error("missing queued action serialization")
    end

    local systems = get_current_systems()
    if systems == nil or systems.state == nil then
        logger:w("Dropping authoritative action before game systems are ready")
        return false
    end

    local currentTick = get_current_tick()
    local effectiveTargetTick = targetTick
    -- The host is the ONLY side allowed to choose a target tick.  It stamps
    -- action_request before broadcasting.  A client must enqueue the exact
    -- announced tick; independently moving a late action forward makes the
    -- same action execute on different simulation ticks on the two peers.
        if currentTick >= 0 and effectiveTargetTick <= currentTick then
            logger:w(
                "%s dropping stale authoritative action %s for tick %s (current=%s)",
                tostring(sourceLabel),
                tostring(payload.queuedAction),
                tostring(targetTick),
                tostring(currentTick)
            )
            pcall(function()
                multitode.slog("ACT", string.format(
                    "STALE-DROP %s req=%s target=%s cur=%s",
                    tostring(payload.queuedAction), tostring(envelope.tick),
                    tostring(targetTick), tostring(currentTick)))
            end)
            -- A late action cannot be made deterministic after the fact. Ask the
            -- host for a fresh snapshot rather than executing it on a guessed tick.
            local isClient = false
            pcall(function()
                local state = multitode.state()
                isClient = state ~= nil and tostring(state.role) == "CLIENT"
            end)
            if isClient then
                pcall(function()
                    multitode.net.sendToHost("itd", "sync_request", {
                        err = currentTick - targetTick
                    })
                end)
            else
                -- Host-side late apply: re-stamp to the earliest legal future tick
                -- and push a corrected action_apply so both peers converge again
                -- instead of the host silently losing its own action.
                local restamped = currentTick + MIN_ACTION_LEAD_TICKS
                payload.target_tick = restamped
                pcall(function()
                    multitode.slog("ACT", string.format(
                        "HOST-RESTAMP %s target=%s -> %s",
                        tostring(payload.queuedAction), tostring(targetTick),
                        tostring(restamped)))
                    multitode.net.broadcast("itd", "action_apply", payload)
                    local action2 = deserialize_action(payload, actionType, actionJson)
                    if action2 ~= nil then
                        multitode.approveQueuedAction(restamped, tostring(action2))
                        systems.state:pushAction(action2, restamped)
                    end
                end)
            end
            return false
        end

    local action = deserialize_action(payload, actionType, actionJson)
    if action == nil then
        return false
    end

    local actionString = tostring(action)
    multitode.approveQueuedAction(effectiveTargetTick, actionString)
    systems.state:pushAction(action, effectiveTargetTick)

    logger:i(
        "%s queued authoritative action %s for tick %s",
        tostring(sourceLabel),
        tostring(actionString),
        tostring(effectiveTargetTick)
    )
    pcall(function()
        local lag = lag_ms_of(envelope)
        multitode.slog("ACT", string.format(
            "APPLY %s capTick=%s announced=%s eff=%s cur=%s dTicks=%s lagMs=%s",
            tostring(actionString), tostring(envelope.tick), tostring(targetTick),
            tostring(effectiveTargetTick), tostring(currentTick),
            tostring(tonumber(envelope.tick) ~= nil and (effectiveTargetTick - tonumber(envelope.tick)) or "?"),
            lag ~= nil and tostring(lag) or "?"))
    end)

    return true
end

-- ============================================================
-- Cross-env state bridge (scenario B)                        --
-- ============================================================
-- On a snapshot-restored client the gameplay env is born by Kryo unserialization:
-- its files never re-execute, so it has NO dispatch listener and this file's
-- handlers only ever run in the global env, whose 70_multitode_itd never loaded.
-- The gameplay env's serialized S.events listeners (guard/probe/pause mirror)
-- therefore read a frozen itd table. Publish every state transition to the
-- shared BridgeApi settings (whitelisted, per-process, in-memory map) so the
-- gameplay env can sync itself from scripts/game/70_multitode_itd.lua.
-- Value format: "<body>|<epochMs>"; readers reject anything older than 2 s,
-- which also neutralizes values persisted to disk by earlier runs.
local function bridge_publish(key, body)
    pcall(function()
        local System = luajava.bindClass("java.lang.System")
        local api = multitode.getApi()
        if api ~= nil then
            api:setSetting(key, tostring(body) .. "|" .. tostring(System:currentTimeMillis()))
        end
    end)
end

local function should_handle_client_action_apply()
    local ok, state = pcall(multitode.state)
    if not ok or state == nil then
        return false
    end

    return state.role == "CLIENT"
end

local function apply_client_pause_state(paused, authoritativeSpeed)
    local itd = multitode.itd
    if itd == nil then
        itd = {}
        multitode.itd = itd
    end
    itd.hostPaused = paused and true or false
    -- Publish BEFORE the engine pause/resume below: the gameplay env's
    -- GamePaused/GameResumed listener runs synchronously during pauseGame()/
    -- resumeGame() and force-syncs this value on entry.
    bridge_publish("multitode.sync.paused", paused and "1" or "0")
    if itd.applyPauseMirror ~= nil then
        local ok, err = pcall(itd.applyPauseMirror, paused)
        pcall(function()
            multitode.slog("CTRL", "pause module apply=" .. tostring(ok)
                .. " err=" .. tostring(err) .. " t=" .. tostring(itd))
        end)
    else
        -- No mirror installed in THIS env (applyPauseMirror is set only by
        -- scripts/game/70_multitode_itd.lua). If this logs, the message was
        -- consumed by an env that does not own gameplay state.
        pcall(function()
            multitode.slog("CTRL", "pause module apply=SKIPPED no-mirror t="
                .. tostring(itd))
        end)
    end
    -- Keep the actual engine state authoritative even if the gameplay module
    -- was installed late. The heartbeat can arrive before the 70_ listeners
    -- have attached to the current GameScreen.
    local systems = get_current_systems()
    if systems ~= nil and systems.gameState ~= nil then
        pcall(function()
            if paused then
                if not systems.gameState:isPaused() then
                    systems.gameState:pauseGame()
                end
            elseif systems.gameState:isPaused() then
                systems.gameState:resumeGame()
            end
        end)
        pcall(function()
            multitode.slog("CTRL", "pause engine target=" .. tostring(paused)
                .. " isPaused=" .. tostring(systems.gameState:isPaused())
                .. " tick=" .. tostring(systems.state.updateNumber))
        end)
    end
    -- Apply authoritative speed on resume AND while paused when provided:
    -- a frozen (0) speed must stick; a resume must restore the host rate.
    local speed = tonumber(authoritativeSpeed)
    if speed ~= nil and (speed >= 0.05 or (paused and speed >= 0)) then
        if not paused or speed >= 0 then
            pcall(function()
                itd.suppressSpeedCapture = true
                itd.hostSpeed = speed
                itd.lastSpeed = speed
                local control = get_current_systems()
                if control ~= nil and control.state ~= nil then
                    control.state:setGameSpeed(speed)
                end
            end)
        end
    end
end

-- Host: when the run ends, the freeze is authoritative. Tell everyone and push a
-- fresh snapshot, so no client keeps playing a world where the host is already
-- dead (that mismatch was the "host died, client continued" desync).
function host_check_game_over()
    if not is_host_role_for_heartbeat() then
        return
    end
    local systems = get_current_systems()
    if systems == nil then
        return
    end

    local over = false
    pcall(function()
        over = systems.gameState:isGameOver() == true
    end)
    if not over then
        itdNet.gameOverReported = false
        return
    end
    if itdNet.gameOverReported then
        return
    end

    itdNet.gameOverReported = true
    pcall(function()
        multitode.slog("DESYNC", "local game over - broadcasting and forcing a resync")
        multitode.net.broadcast("itd", "game_over", { tick = systems.state.updateNumber })
    end)
    pcall(function()
        if multitode.levelSync ~= nil and multitode.levelSync.resyncNow ~= nil then
            multitode.levelSync.resyncNow()
        end
    end)
end

local function ensure_handlers_registered()
    if itdNet.handlersRegistered then
        return
    end

    multitode.net.onHost("itd", "action_request", function(ctx, payload)
        logger:i(
            "Host received action %s from player %s at tick %s target_tick=%s",
            tostring(payload.action),
            tostring(ctx.senderPlayerId),
            tostring(payload.tick),
            tostring(payload.target_tick)
        )

        -- Host-side duplicate guard: the very same capture delivered twice (same
    -- capture tick + same bytes) must not be broadcast twice — the second
    -- apply would hit an occupied tile or charge twice. Intentional rapid
    -- taps always carry a different capture tick and pass through.
    itdNet.recentReqs = itdNet.recentReqs or {}
    -- The signature must include the QUEUE INDEX. Two different actions of the same type
    -- captured in the same tick (rapid-fire clicking - "upgrade, upgrade") carry the same
    -- action text, so a signature without the index makes them look like one duplicate
    -- capture and the second one is dropped. That is exactly a fast upgrade going missing:
    -- the host ended at level 2 while the client stayed at level 1. A genuine duplicate
    -- delivery has the same tick AND the same index AND the same bytes, so adding the index
    -- keeps the guard honest while letting two real actions through.
    local reqSig = tostring(payload.action)
        .. "|" .. tostring(payload.payload and payload.payload.queuedIndex)
        .. "|" .. tostring(payload.payload and payload.payload.actionJson)
    local reqTick = tonumber(payload.tick) or -1
    local dup = false
    local freshReqs = {}
    for _, entry in ipairs(itdNet.recentReqs) do
        if reqTick >= 0 and entry.tick >= 0 and math.abs(reqTick - entry.tick) <= 120 then
            freshReqs[#freshReqs + 1] = entry
            if entry.sig == reqSig and entry.tick == reqTick then
                dup = true
            end
        end
    end
    itdNet.recentReqs = freshReqs
    if dup then
        pcall(function()
            multitode.slog("ACT", string.format("DEDUP-DROP %s req=%s (identical capture already seen)",
                tostring(payload.action), tostring(payload.tick)))
        end)
        return
    end
    freshReqs[#freshReqs + 1] = { tick = reqTick, sig = reqSig }

        -- Host stamps the single authoritative target tick BEFORE broadcasting,
        -- so both sides converge on the same tick instead of adjusting
        -- independently (same action on different ticks = combat desync).
        -- compute_effective_target only raises a late announce to a minimum future
        -- tick; after this stamp the value is frozen for the broadcast.
        local announced = tonumber(payload.target_tick)
        local effective = compute_effective_target(announced)
        if effective ~= announced then
            payload.target_tick = effective
            pcall(function()
                multitode.slog("ACT", string.format(
                    "HOST-STAMP %s req=%s announced=%s authoritative=%s",
                    tostring(payload.action), tostring(payload.tick),
                    tostring(announced), tostring(effective)))
            end)
        end

        multitode.net.broadcast("itd", "action_apply", payload)
        enqueue_authoritative_action(payload, "Host")
    end)

    multitode.net.onClient("itd", "action_apply", function(_, payload)
        if not should_handle_client_action_apply() then
            return
        end

        enqueue_authoritative_action(payload, "Client")
    end)

    multitode.net.onClient("itd", "pause_state", function(_, payload)
        if not should_handle_client_action_apply() or payload == nil then
            return
        end
        local itd = multitode.itd
        if itd == nil then
            return
        end
        apply_client_pause_state(payload.paused == true, payload.speed)
    end)

    multitode.net.onClient("itd", "speed_state", function(_, payload)
        if not should_handle_client_action_apply() or payload == nil then
            pcall(function()
                multitode.slog("CTRL", string.format(
                    "speed state skip reason=%s t=%s",
                    payload == nil and "nil-payload" or "role-not-client",
                    tostring(multitode.itd)))
            end)
            return
        end
        local speed = tonumber(payload.speed)
        local frozen = payload.frozen == true
        if frozen then
            speed = 0
        elseif speed == nil or (speed > 0 and speed < 0.05) then
            pcall(function()
                multitode.slog("CTRL", string.format(
                    "speed state skip reason=invalid-speed speed=%s t=%s",
                    tostring(payload.speed), tostring(multitode.itd)))
            end)
            return
        elseif speed ~= nil and speed < 0 and not frozen then
            pcall(function()
                multitode.slog("CTRL", string.format(
                    "speed state skip reason=negative-speed speed=%s t=%s",
                    tostring(speed), tostring(multitode.itd)))
            end)
            return
        end
        local itd = multitode.itd
        local systems = get_current_systems()
        if itd == nil or systems == nil or systems.state == nil then
            pcall(function()
                multitode.slog("CTRL", string.format(
                    "speed state skip reason=no-target itd=%s systems=%s t=%s",
                    tostring(itd ~= nil), tostring(systems ~= nil),
                    tostring(multitode.itd)))
            end)
            return
        end
        local epoch = tonumber(payload.epoch) or 0
        if itd.speedStateEpoch ~= nil and epoch < (tonumber(itd.speedStateEpoch) or 0) then
            pcall(function()
                multitode.slog("CTRL", string.format(
                    "speed state skip reason=stale-epoch epoch=%s have=%s t=%s",
                    tostring(epoch), tostring(itd.speedStateEpoch), tostring(itd)))
            end)
            return
        end
        itd.speedStateEpoch = epoch
        itd.speedStateMode = true
        itd.speedStateAt = (os.clock and os.clock()) or 0
        itd.speedStateSpeed = speed
        itd.hostSpeed = speed
        itd.lastSpeed = speed
        bridge_publish("multitode.sync.speed", tostring(speed) .. "|" .. tostring(epoch))
        pcall(function()
            multitode.slog("CTRL", string.format(
                "speed state epoch=%s speed=%s frozen=%s tick=%s hs=%s t=%s",
                tostring(epoch), tostring(speed),
                tostring(frozen), tostring(payload.tick),
                tostring(itd.hostSpeed), tostring(itd)))
        end)
        if itd.hostPaused or itd.bonusPauseActive
            or (itd.challenge ~= nil and itd.challenge.active) then
            return
        end
        pcall(function()
            itd.suppressSpeedCapture = true
            systems.state:setGameSpeed(speed)
        end)
    end)

    multitode.net.onHost("itd", "challenge_request", function(_, payload)
        local itd = multitode.itd
        if itd == nil or itd.hostReceiveChallengeRequest == nil or payload == nil then
            return
        end
        pcall(itd.hostReceiveChallengeRequest, tonumber(payload.birdIdx))
    end)

    multitode.net.onClient("itd", "challenge_open", function(_, payload)
        if not should_handle_client_action_apply() then
            return
        end
        local itd = multitode.itd
        if itd == nil or itd.applyChallengeOpen == nil then
            return
        end
        pcall(itd.applyChallengeOpen, payload)
    end)

    multitode.net.onHost("itd", "challenge_decision", function(_, payload)
        local itd = multitode.itd
        if itd == nil or itd.challenge == nil or payload == nil then
            return
        end
        if itd.hostResolveChallenge == nil then
            return
        end
        -- Host arbitrates the first decision, then resolves authoritatively.
        pcall(itd.hostResolveChallenge, tonumber(payload.birdIdx),
            payload.accepted == true)
    end)

    multitode.net.onClient("itd", "challenge_resolve", function(_, payload)
        if not should_handle_client_action_apply() then
            return
        end
        local itd = multitode.itd
        if itd == nil or itd.applyChallengeResolve == nil then
            return
        end
        pcall(itd.applyChallengeResolve, payload)
    end)

    multitode.net.onClient("itd", "encounter_colors", function(_, payload)
        if not should_handle_client_action_apply() then
            return
        end
        local itd = multitode.itd
        if itd == nil or itd.applyEncounterColors == nil then
            return
        end
        pcall(itd.applyEncounterColors, payload)
    end)

    -- Task 5: client receives the host tick heartbeat and observes the
    -- authoritative host rate. It never injects local boost/slow-motion
    -- corrections; a hopeless gap asks for a fresh snapshot instead.
    multitode.net.onHost("itd", "sync_request", function(_, payload)
        pcall(function()
            multitode.slog("DESYNC", "client requested a resync (their err=" ..
                tostring(payload ~= nil and payload.err or "?") .. ")")
        end)
        pcall(function()
            if multitode.levelSync ~= nil and multitode.levelSync.resyncNow ~= nil then
                multitode.levelSync.resyncNow()
            end
        end)
    end)

    -- the host's run ended; the accompanying resync reconciles us to its state
    multitode.net.onClient("itd", "game_over", function(_, payload)
        pcall(function()
            multitode.slog("DESYNC", "host reported game over (tick=" ..
                tostring(payload ~= nil and payload.tick or "?") .. ")")
        end)
        itdNet.hostGameOver = true
    end)

    multitode.net.onClient("itd", "tick_heartbeat", function(_, payload)
        if not should_handle_client_action_apply() then
            return
        end
        if payload == nil or tonumber(payload.tick) == nil then
            return
        end

        local hostTick = tonumber(payload.tick)
        local payloadPaused = payload.paused == true
        pcall(function()
            multitode.slog("CTRL", string.format("heartbeat recv tick=%s speed=%s paused=%s",
                tostring(hostTick), tostring(payload.speed), tostring(payloadPaused)))
        end)
        local itdState = multitode.itd
        if itdState == nil or payloadPaused ~= (itdState.hostPaused == true) then
            apply_client_pause_state(payloadPaused, payload.speed)
        end
        local heartbeatSpeed = payload.speed ~= nil and tonumber(payload.speed) or nil
        local heartbeatFrozen = payload.frozen == true
        if heartbeatFrozen then
            heartbeatSpeed = 0
        end
        if not payloadPaused and heartbeatSpeed ~= nil and (heartbeatSpeed >= 0.05 or heartbeatFrozen) then
            local controlState = multitode.itd
            local specialPause = controlState ~= nil
                and (controlState.bonusPauseActive == true
                    or (controlState.challenge ~= nil and controlState.challenge.active == true))
            if not specialPause then
                local controlSystems = get_current_systems()
                if controlSystems ~= nil and controlSystems.state ~= nil then
                    local currentControlSpeed = nil
                    pcall(function()
                        currentControlSpeed = tonumber(controlSystems.state:getGameSpeed())
                    end)
                    if currentControlSpeed == nil
                            or math.abs(currentControlSpeed - heartbeatSpeed) >= 0.001 then
                        if hb_speed_is_stale(payload, heartbeatSpeed) then
                            -- Stale heartbeat vs a newer speed_state: do not
                            -- adopt its hostSpeed or steer the engine with it.
                            pcall(function()
                                multitode.slog("HB", string.format(
                                    "STALE-SPEED skip speed=%s stateEpoch=%s stateSpeed=%s",
                                    tostring(heartbeatSpeed),
                                    tostring(controlState and controlState.speedStateEpoch),
                                    tostring(controlState and controlState.hostSpeed)))
                            end)
                        else
                            if controlState ~= nil then
                                controlState.suppressSpeedCapture = true
                                controlState.hostSpeed = heartbeatSpeed
                                controlState.lastSpeed = heartbeatSpeed
                                bridge_publish("multitode.sync.hb", tostring(heartbeatSpeed))
                            end
                            pcall(function()
                                controlSystems.state:setGameSpeed(heartbeatSpeed)
                            end)
                        end
                    end
                end
            end
        end
        -- Do not classify frame drift while the host is paused. The engine may
        -- service one queued update at speed=0 on one peer; judging that window
        -- produced false resyncs and speed corrections before the host resumed.
        if payloadPaused or (itdState ~= nil and itdState.hostPaused == true) then
            pcall(function()
                multitode.slog("HB", string.format(
                    "PAUSE-WINDOW skip drift host=%s local=%s",
                    tostring(hostTick), tostring(get_current_tick())))
            end)
            return
        end
        local cur = get_current_tick()
        if cur < 0 then
            return
        end
        local err = hostTick - cur

        -- Resync landed? (we asked for one, and the gap is now gone) -> tell the
        -- player how far out of step they were.
        if multitode.pendingResyncNotice ~= nil and math.abs(err) < 20 then
            local wasErr = multitode.pendingResyncNotice
            multitode.pendingResyncNotice = nil
            pcall(function()
                if multitode.show_toast ~= nil then
                    multitode.show_toast("Resynced (was " .. tostring(wasErr) .. " ticks off)")
                end
            end)
        end

        -- Desync watchdog. The host's run ending (game over) froze the host while
        -- the client kept playing, leaving it thousands of ticks behind forever;
        -- that is what the "host died, client kept going" desync was. Log WHY when
        -- drift appears, and force a resync when it is hopeless.
        pcall(function()
            local absErr = math.abs(err)
            local nowMs = 0
            pcall(function() nowMs = multitode.now_ms() end)
            itdNet.desyncDiagAt = itdNet.desyncDiagAt or 0
            itdNet.syncRequestAt = itdNet.syncRequestAt or 0

            if absErr >= 100 and (nowMs - itdNet.desyncDiagAt) > 15000 then
                itdNet.desyncDiagAt = nowMs
                local systems = get_current_systems()
                local localSpeed, paused, over, wave = "?", "?", "?", "?"
                pcall(function() localSpeed = tostring(systems.state:getGameSpeed()) end)
                pcall(function() paused = tostring(systems.gameState:isPaused()) end)
                pcall(function() over = tostring(systems.gameState:isGameOver()) end)
                pcall(function() wave = tostring(systems.wave.getWaveNumber()) end)
                multitode.slog("DESYNC", string.format(
                    "err=%s host=%s local=%s hostSpeed=%s localSpeed=%s paused=%s localGameOver=%s wave=%s pending=%s",
                    tostring(err), tostring(hostTick), tostring(cur), tostring(payload.speed),
                    localSpeed, paused, over, wave,
                    tostring(itdNet and #(itdNet.queued or {}))))
            end

            if absErr >= 200 and (nowMs - itdNet.syncRequestAt) > 20000 then
                itdNet.syncRequestAt = nowMs
                multitode.slog("DESYNC", "forcing a resync (err=" .. tostring(err) .. ")")
                multitode.net.sendToHost("itd", "sync_request", { err = err })
                -- remember it so we can tell the player once the resync lands
                multitode.pendingResyncNotice = err
            end
        end)
        local itd = multitode.itd
        local hostSpeed = payload.speed ~= nil and tostring(payload.speed) or "?"
            pcall(function()
                if payload.speed ~= nil and tonumber(payload.speed) ~= nil then
                    local speedState = multitode.itd
                    if speedState == nil then
                        speedState = {}
                        multitode.itd = speedState
                    end
                    local hbSpeed = tonumber(payload.speed)
                    if not hb_speed_is_stale(payload, hbSpeed) then
                        speedState.hostSpeed = hbSpeed
                        -- Heartbeat is a backup for hostSpeed only; it must not
                        -- clear a fresher speed_state's dedicated fields.
                        if speedState.speedStateMode ~= true then
                            speedState.speedStateSpeed = hbSpeed
                        end
                    end
                end
            end)
        pcall(function()
            multitode.slog("HB", string.format("RECV host=%s local=%s err=%s hostSpeed=%sx",
                tostring(hostTick), tostring(cur), tostring(err), hostSpeed))
        end)
        if itd == nil then
            -- Module state can be missing when this handler runs from a different
            -- Lua script execution than the one that loaded 70_multitode_itd.lua.
            -- Create it instead of silently skipping the control path.
            itd = {}
            multitode.itd = itd
            pcall(function()
                multitode.slog("HB", "SKIP-WARN itd was nil here, created a fresh table")
            end)
        end
        -- Do not steer a client by changing its local simulation rate.  A tick
        -- gap is not a reason to inject 0.5x/0.75x (or 2x/4x): the host's rate
        -- is authoritative, and those writes are exactly what produced the
        -- repeated CORRECT SLOW loop and the slow-motion desync.  The event
        -- listener in 70_ handles genuine client input; this path only observes
        -- the host tick and the host speed.
        itd.correctionSpeed = nil
        itdNet.correctionActive = false
        multitode.hbCorrectionActive = false
    end)

    -- Open item #5: client-side latency visibility. Java's PING echo may report
    -- -1 on a client ("never measured"), so the client also probes the ACTUAL
    -- Lua message path: stamp os.clock, host echoes the payload verbatim,
    -- client computes the round trip. Distinct names per direction (trap: one
    -- handler per channel+name).
    multitode.net.onHost("itd", "rtt_probe", function(ctx, payload)
        if payload == nil or payload.t == nil then
            return
        end
        pcall(function()
            multitode.net.sendToPeer(ctx.senderPlayerId, "itd", "rtt_reply", { t = payload.t })
        end)
    end)
    multitode.net.onClient("itd", "rtt_reply", function(_, payload)
        if payload == nil or tonumber(payload.t) == nil then
            return
        end
        local rtt = (tonumber(payload.t) - ((os.clock and os.clock()) or 0)) * 1000
        -- os.clock is per-process CPU time; within this process the delta is
        -- a valid monotonic elapsed measure, so rtt >= 0 always.
        if rtt >= 0 and rtt < 60000 then
            multitode.luaRttMs = rtt
        end
    end)

    -- Task 6: host compares a client's hash against its own live state, but
    -- ONLY when both hashes are from nearby ticks — comparing a 5s-old client
    -- hash against live host state is a guaranteed false MISMATCH.
    multitode.net.onHost("itd", "state_hash", function(ctx, payload)
        if payload == nil or payload.hash == nil then
            return
        end
        pcall(function()
            local clientTick = tonumber(payload.tick) or -1
            if clientTick < 0 then
                return
            end
            -- Compare against OUR OWN recorded hash for that tick. The client hashed tick T,
            -- so only our sample of tick T is comparable - our live state has moved on
            -- (money, lives and kills all change every tick). No sample for T means the
            -- client is ahead of us or the sample aged out, so skip and wait for the next
            -- report rather than inventing a verdict.
            local own = nil
            pcall(function()
                own = multitode.getApi():getStateHashSampleJson(clientTick)
            end)
            if own == nil or own == "" then
                multitode.slog("HASH", string.format("CMP-SKIP from=%s tick=%s (no local sample for that tick)",
                    tostring(ctx.senderPlayerId), tostring(clientTick)))
                return
            end
            local match = (own ~= nil and own == tostring(payload.hash))
            multitode.slog("HASH", string.format("CMP from=%s client=[%s] host=[%s] %s",
                tostring(ctx.senderPlayerId), tostring(payload.hash),
                tostring(own), match and "MATCH" or "MISMATCH"))

            -- DETECT AND REPAIR: a real mismatch means the two worlds diverged (any
            -- cause - pause spam, a hitch, a missed action). Repair it automatically
            -- instead of letting the gap accumulate, rate-limited so it cannot thrash.
            local autoResyncOn = true
            pcall(function()
                if multitode.itd ~= nil and multitode.itd.autoResyncOnMismatch == false then
                    autoResyncOn = false
                end
            end)
            -- A hash is one sample, so a lone mismatch can be a phase artefact (the two sides
            -- sampled a tick apart). Require two in a row before paying for a full snapshot
            -- rebuild: fewer visible jumps, same guarantee that real drift gets caught. Any
            -- matching sample clears the streak.
            if not match and autoResyncOn then
                itdNet.mismatchStreak = (itdNet.mismatchStreak or 0) + 1
            else
                itdNet.mismatchStreak = 0
            end
            if not match and autoResyncOn and (itdNet.mismatchStreak or 0) >= 2 then
                local nowMs = 0
                pcall(function() nowMs = multitode.now_ms() end)
                if nowMs > 0 and (nowMs - (itdNet.lastAutoResyncAt or 0)) > 15000 then
                    itdNet.lastAutoResyncAt = nowMs
                    pcall(function()
                        multitode.slog("DESYNC", string.format(
                            "hash mismatch x%s in a row -> automatic resync",
                            tostring(itdNet.mismatchStreak)))
                        if multitode.levelSync ~= nil and multitode.levelSync.resyncNow ~= nil then
                            multitode.levelSync.resyncNow()
                        end
                    end)
                end
            end
        end)
    end)

    itdNet.handlersRegistered = true
    logger:i("Multitode ITD network handlers loaded")
end

local function is_host_role_for_heartbeat()
    local ok, st = pcall(multitode.state)
    return ok and st ~= nil and (st.role == "HOST" or st.role == "HOST_AND_CLIENT")
end

local function now_sec_float()
    if os.clock ~= nil then
        return os.clock()
    end
    return 0
end

-- Task 5+6 driver: host heartbeat every 2s, hashes every 10s each side.
local function heartbeat_and_hash_tick()
    -- Owner gate (same rule as dispatchPending in 02_): only the env that
    -- currently owns inbound message processing may drive the heartbeat/hash
    -- pipeline. Both envs register this Render listener, and without the gate
    -- a stale env could send heartbeats from a different (or no) game state.
    -- Fail-open on a missing gate function or probe error, exactly like
    -- dispatchPending: scenario B (game env never runs 02_/this gate) must
    -- keep behaving as before instead of stalling heartbeats.
    if multitode.net ~= nil and multitode.net.env_owns_messages ~= nil then
        local okGate, owns = pcall(multitode.net.env_owns_messages)
        if okGate and owns == false then
            return
        end
    end
    -- Record our own state hash for every tick, so a client's report can be checked against
    -- the state we really had AT THAT TICK. Comparing it against our live state instead was
    -- invalid (money/lives/kills move every tick), which is why this produced either phantom
    -- mismatches or - once an exact-tick guard was added - no detection at all.
    if is_host_role_for_heartbeat() then
        local recTick = get_current_tick()
        if recTick >= 0 and recTick ~= itdNet.lastRecordedHashTick then
            local recorded = false
            if multitode.superlog_state_hash ~= nil then
                pcall(function()
                    local h = multitode.superlog_state_hash()
                    if h ~= nil then
                        multitode.getApi():saveStateHashSampleJson(recTick, h)
                        recorded = true
                    end
                end)
            end
            itdNet.lastRecordedHashTick = recTick
            if not recorded and not itdNet.hashRecordWarned then
                -- Without this, detection just silently never runs, which is how a real
                -- divergence (a missing tower) went unreported.
                itdNet.hashRecordWarned = true
                pcall(function()
                    multitode.slog("HASH", "recording unavailable: state hash or tick missing")
                    logger:w("State-hash recording is not working - divergence detection is off")
                end)
            end
        end
    end
    -- Self-healing STATE emitter install (02_): retries until a game screen
    -- with live systems exists.
    if multitode.superlog_maybe_install ~= nil then
        pcall(multitode.superlog_maybe_install)
    end

    local tick = get_current_tick()
    if tick < 0 then
        return
    end

    local now = now_sec_float()
    if is_host_role_for_heartbeat() then
        if host_check_game_over ~= nil then
            pcall(host_check_game_over)
        end

        local hbPeriod = 1.0
        pcall(function()
            -- Default 0.5s: corrections then arrive small and often instead of rarely and large.
            -- This only changes how often drift is measured/repaired (one tiny packet each time);
            -- it does not change how much drift exists. Configurable in the MOD window.
            hbPeriod = 0.5
            if multitode.itd ~= nil and tonumber(multitode.itd.heartbeatPeriodSec) ~= nil then
                hbPeriod = tonumber(multitode.itd.heartbeatPeriodSec)
            end
        end)
        if now - (itdNet.lastHeartbeatSentAt or 0) >= hbPeriod then
            itdNet.lastHeartbeatSentAt = now
            local speed = nil
            local speedOk = false
            local paused = false
            local systems = nil
            pcall(function()
                systems = get_current_systems()
                if systems ~= nil and systems.state ~= nil then
                    local raw = nil
                    if systems.state.getNonAnimatedGameSpeed ~= nil then
                        raw = systems.state:getNonAnimatedGameSpeed()
                    else
                        raw = systems.state:getGameSpeed()
                    end
                    if raw ~= nil and tonumber(raw) ~= nil then
                        speed = tonumber(raw)
                        speedOk = true
                    end
                end
                paused = systems ~= nil and systems.gameState ~= nil
                    and systems.gameState:isPaused() == true
            end)
            -- Never default a missing reading to 1x: that pushes clients down
            -- to 1x whenever systems are briefly unavailable (the 2x bug).
            -- Omit the field instead; the client keeps its last hostSpeed.
            local frozen = false
            if speedOk and speed < 0.05 then
                frozen = true
            end
            local payload = {
                tick = tick,
                paused = paused,
                frozen = frozen
            }
            if speedOk then
                payload.speed = speed
            end
            pcall(function()
                local itdSend = multitode.itd
                if itdSend ~= nil and itdSend.speedStateEpoch ~= nil then
                    payload.epoch = itdSend.speedStateEpoch
                end
            end)
            multitode.net.broadcast("itd", "tick_heartbeat", payload)
            pcall(function()
                local speedStr = payload.speed ~= nil and tostring(payload.speed) or "omitted"
                multitode.slog("CTRL", string.format("heartbeat send tick=%s speed=%s paused=%s frozen=%s",
                    tostring(tick), tostring(speedStr), tostring(paused), tostring(frozen)))
                multitode.slog("HB", string.format("SEND tick=%s%s", tostring(tick),
                    frozen and " FROZEN"
                    or (payload.speed ~= nil and (" speed=" .. tostring(payload.speed) .. "x") or " (speed omitted)")))
            end)
        end
        if now - (itdNet.lastHashSentAt or 0) >= 10.0 then
            itdNet.lastHashSentAt = now
            pcall(function()
                if multitode.superlog_state_hash ~= nil then
                    local h = multitode.superlog_state_hash()
                    if h ~= nil then
                        multitode.slog("HASH", "HOST [" .. h .. "]")
                    end
                end
            end)
        end
    elseif should_handle_client_action_apply() then
        -- Message-path RTT probe (open item #5): every 2s, echo a stamped
        -- payload through the host. Fills multitode.luaRttMs for display and
        -- as the lead-time fallback when Java reports no sample.
        if now - (itdNet.lastRttProbeAt or 0) >= 2.0 then
            itdNet.lastRttProbeAt = now
            pcall(function()
                multitode.net.sendToHost("itd", "rtt_probe", {
                    t = (os.clock and os.clock()) or 0
                })
            end)
        end
        if now - (itdNet.lastHashSentAt or 0) >= 10.0 then
            itdNet.lastHashSentAt = now
            pcall(function()
                if multitode.superlog_state_hash ~= nil then
                    local h = multitode.superlog_state_hash()
                    if h ~= nil then
                        multitode.slog("HASH", "CLIENT-SEND [" .. h .. "]")
                        multitode.net.sendToHost("itd", "state_hash", { hash = h, tick = tick })
                    end
                end
            end)
        end
    end
end

-- The engine may re-execute scripts in a fresh Lua env on game start while
-- old Java-side listeners stay alive. Lua flags don't survive that, but a JVM
-- system property does — so only the first execution ever drives the heartbeat.
-- On a re-execution in a NEW env the old property would block the new listener
-- forever while the old listener's closures point at dead upvalues. Stamp the
-- property with an env-generation counter: a fresh script load bumps it and
-- claims the driver again (the old Render listener becomes a no-op once its
-- captured tables are stale — heartbeat_and_hash_tick is re-bound each load).
local function claim_heartbeat_driver()
    local ok, System = pcall(luajava.bindClass, "java.lang.System")
    if not ok or System == nil then
        return true
    end
    -- Always claim within this Lua env: itdNet.heartbeatRegistered is per-env.
    if itdNet.heartbeatRegistered then
        return false
    end
    local gen = nil
    pcall(function()
        gen = tonumber(System:getProperty("multitode.hb.driver.gen") or "0") or 0
        gen = gen + 1
        System:setProperty("multitode.hb.driver.gen", tostring(gen))
        System:setProperty("multitode.hb.driver", "1")
    end)
    if gen == nil then
        -- Property bridge failed: still bump a process-local counter so two
        -- listeners in the same env cannot both believe they are current.
        gen = (tonumber(itdNet.heartbeatGen) or 0) + 1
    end
    itdNet.heartbeatGen = gen
    -- Stamp the gen we will compare against INSIDE the listener. If the
    -- property write failed, fall back to comparing against itdNet so a
    -- later re-execution that does bump the property still wins.
    itdNet.heartbeatGenAtClaim = gen
    return true
end

if claim_heartbeat_driver() then
    itdNet.heartbeatRegistered = true
    local myGen = itdNet.heartbeatGen
    pcall(function()
        C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
            -- Script re-executions leave the previous Render listener alive.
            -- Only the driver whose gen matches the current system property
            -- may run; stale listeners no-op (fixes paired HB SEND).
            local alive = true
            pcall(function()
                local Sys = luajava.bindClass("java.lang.System")
                local raw = Sys:getProperty("multitode.hb.driver.gen")
                local currentGen = tonumber(raw or "0") or 0
                if raw == nil or raw == "" then
                    -- Property unavailable: allow only the latest claim in
                    -- this env (itdNet.heartbeatGen was bumped by claim).
                    if myGen ~= nil and itdNet.heartbeatGen ~= nil
                            and myGen ~= itdNet.heartbeatGen then
                        alive = false
                    end
                elseif myGen ~= nil and currentGen ~= myGen then
                    alive = false
                end
            end)
            if not alive then
                return
            end
            local ok, err = pcall(heartbeat_and_hash_tick)
            if not ok then
                logger:w("Heartbeat tick failed: %s", tostring(err))
            end
        end))
    end)
    logger:i("Heartbeat driver claimed by this script execution gen=%s", tostring(myGen))
    pcall(function()
        if multitode.net ~= nil and multitode.net.appendEnvMarker ~= nil then
            multitode.net.appendEnvMarker("hb-claimed")
        end
    end)
end

ensure_handlers_registered()
