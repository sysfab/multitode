local logger = C.TLog:forTag("multitode/itd.lua")

_G.multitode = _G.multitode or {}
multitode.itd = multitode.itd or {}

local itd = multitode.itd

itd.enforceInterception = true
itd.allowLocalActionDepth = 0
itd.installedSession = nil
itd.seenQueuedActions = itd.seenQueuedActions or {}
itd.lastSpeed = 1

-- Per-env boot marker: this file lives in scripts/game and only runs in the
-- ScriptSystem (game) environment. Its address identifies the env's itd table
-- for correlation with the t= addresses logged by 80_multitode_itd_net.
pcall(function()
    logger:i("env boot 70game t=%s itd=%s", tostring(multitode), tostring(itd))
end)
pcall(function()
    if multitode.net ~= nil and multitode.net.appendEnvMarker ~= nil then
        multitode.net.appendEnvMarker("boot70game")
    end
end)

-- ============================================================
-- Cross-env state bridge reader (scenario B)                --
-- ============================================================
-- On a snapshot-restored client this file never re-executes: the whole
-- scriptEnvironment is Kryo-unserialized, so no dispatch listener exists in
-- this env and 80_multitode_itd_net's handlers drain messages in the GLOBAL
-- env, whose itd table has no guard/mirror. The serialized S.events listeners
-- installed here (guard, probe, pause mirror) then read an itd frozen at
-- snapshot values. The writers publish each transition to shared BridgeApi
-- settings (whitelisted, per-process, in-memory); this reader pulls them back
-- into the local table. In scenario A the local env wrote the same values
-- itself, so every sync is a harmless re-adopt of identical state.
--   multitode.sync.paused = "<0|1>|<ms>"
--   multitode.sync.speed  = "<speed>|<epoch>|<ms>"
--   multitode.sync.hb     = "<speed>|<ms>"
-- Values older than 2 s are ignored, which also neutralizes settings persisted
-- to disk by earlier runs. Adoptions are keyed on the publish timestamp so a
-- re-sync never re-sets suppressSpeedCapture/lastSpeed for a message already
-- consumed (that would starve the probe's per-tick enforce path).
local function sync_state_from_bridge(t, force)
    if t == nil then
        return
    end
    local nowClock = (os.clock and os.clock()) or 0
    if not force and t._bridgeSyncAt ~= nil and (nowClock - t._bridgeSyncAt) < 0.1 then
        return
    end
    t._bridgeSyncAt = nowClock
    pcall(function()
        local api = multitode.getApi()
        if api == nil then
            return
        end
        local System = luajava.bindClass("java.lang.System")
        local nowMs = System:currentTimeMillis()
        local function readFresh(key)
            local raw = api:getSetting(key, "")
            if raw == nil or raw == "" then
                return nil, nil
            end
            local body, ts = string.match(raw, "^(.*)|(%d+)$")
            ts = tonumber(ts)
            if body == nil or ts == nil or (nowMs - ts) >= 2000 then
                return nil, nil
            end
            return body, ts
        end

        local pausedBody = readFresh("multitode.sync.paused")
        if pausedBody == "0" or pausedBody == "1" then
            t.hostPaused = pausedBody == "1"
        end

        local speedBody, speedTs = readFresh("multitode.sync.speed")
        if speedBody ~= nil and (t._bridgeSpeedPropMs == nil
                or speedTs > (t._bridgeSpeedPropMs or 0)) then
            local sp, ep = string.match(speedBody, "^([%d%.%-]+)|(%d+)$")
            sp = tonumber(sp)
            ep = tonumber(ep)
            if sp ~= nil and ep ~= nil and ep >= (tonumber(t.speedStateEpoch) or 0) then
                t._bridgeSpeedPropMs = speedTs
                t.speedStateEpoch = ep
                t.speedStateMode = true
                t.speedStateAt = nowClock
                t.speedStateSpeed = sp
                t.hostSpeed = sp
                t.lastSpeed = sp
            end
        end

        local hbBody, hbTs = readFresh("multitode.sync.hb")
        local hbSpeed = tonumber(hbBody)
        if hbSpeed ~= nil and (t._bridgeHbPropMs == nil or hbTs > (t._bridgeHbPropMs or 0))
                and (t._bridgeSpeedPropMs == nil or hbTs >= t._bridgeSpeedPropMs) then
            t._bridgeHbPropMs = hbTs
            t.suppressSpeedCapture = true
            t.hostSpeed = hbSpeed
            t.lastSpeed = hbSpeed
        end
    end)
end

-- Always read the LIVE module table. A file-level `local itd` captured at
-- load can diverge from multitode.itd after a script re-execution or a nil
-- re-create in 80_; the probe then enforced the stale hostSpeed (nil→1)
-- against an engine speed_state had just set to 2/4 — the 1s oscillation.
local function ITD()
    if multitode.itd == nil then
        multitode.itd = {}
    end
    pcall(sync_state_from_bridge, multitode.itd, false)
    return multitode.itd
end

-- Authoritative host rate for the client probe/guard. During the speed_state
-- grace window prefer the value speed_state just installed over hostSpeed,
-- which a duplicate/stale writer may have already clobbered.
local function authoritative_host_speed()
    local t = ITD()
    local stateSpeed = tonumber(t.speedStateSpeed)
    local stateAt = tonumber(t.speedStateAt) or 0
    local now = (os.clock and os.clock()) or 0
    if t.speedStateMode == true and stateSpeed ~= nil and stateAt > 0
            and (now - stateAt) < 2.0 then
        return stateSpeed, true
    end
    return tonumber(t.hostSpeed), false
end

itd.actionDelayMs = 1000 -- ceiling; adaptive lead (Task 3) lowers this by RTT
itd.minLeadMs = 120
itd.suppressSpeedCapture = false
itd.bonusPauseActive = false
itd.lastGoodSpeed = 1
itd.lastCleanupTick = 0

-- Adaptive lead: enough headroom for the round trip plus a margin, so the
-- target tick is still in the future when the apply lands. Localhost/LAN
-- collapses to ~120-200ms; high-ping links keep the safe 1000ms ceiling.
-- The raw ping spikes (GC pauses, window drags), so the lead follows an EMA.
local function compute_lead_ms()
    local rtt = 1000
    pcall(function()
        local v = multitode.getApi():getLatencyMillis()
        if v ~= nil and tonumber(v) ~= nil then
            rtt = tonumber(v)
        end
    end)
    -- -1 means "no RTT sample yet" (or a peer on an older build that does not
    -- echo pings): prefer the Lua-level message-path probe (multitode.luaRttMs,
    -- filled by the rtt_probe round trip in 80_multitode_itd_net.lua), then a
    -- conservative default, instead of collapsing the lead to its 120ms floor.
    if rtt < 0 then
        local luaRtt = tonumber(multitode.luaRttMs)
        if luaRtt ~= nil and luaRtt >= 0 then
            rtt = luaRtt
        else
            rtt = 250
        end
    end
    -- Clamp spike input: localhost stalls (GC, window drags) can report
    -- 1000ms+ pings that would pin the lead at max for minutes. Sustained
    -- real latency still raises the average; a single spike is clamped so it
    -- biases the EMA at most toward 250ms, never above.
    local emaInput = rtt
    if emaInput > 250 then
        emaInput = 250
    end
    if emaInput < 0 then
        emaInput = 0
    end
    if itd.rttEma == nil then
        itd.rttEma = emaInput
    else
        -- EMA toward the clamped sample. Sustained high RTT (multiple samples
        -- at the 250 clamp) still walks the average up; one spike only moves it
        -- by 30% of the gap to 250.
        itd.rttEma = itd.rttEma * 0.7 + emaInput * 0.3
    end
    local lead = itd.rttEma * 2 + 60
    if lead < itd.minLeadMs then
        lead = itd.minLeadMs
    end
    if lead > itd.actionDelayMs then
        lead = itd.actionDelayMs
    end
    return lead, itd.rttEma, rtt
end

local function authoritative_target_tick(currentTick)
    local leadMs = compute_lead_ms()
    local tickRate = 60
    pcall(function()
        if S ~= nil and S.gameValue ~= nil then
            tickRate = tonumber(S.gameValue:getTickRate()) or tickRate
        end
    end)
    if tickRate <= 0 then
        tickRate = 60
    end
    local speed = tonumber(itd.lastSpeed) or 1
    if speed <= 0 then
        -- Frozen (0) would divide by zero / invert the delay; treat as 1x for
        -- the lead-window math only. The engine still runs at 0 while frozen.
        speed = 1
    end
    -- Host-owned actions are delayed before they execute, rather than being
    -- executed locally now and merely announced to clients at a possibly-past
    -- tick. This is what keeps an action on the same simulation tick when a
    -- client is a few frames behind.
    -- Formula matches send_action_to_host: delayTicks = ceil(leadMs / msPerTick / speed)
    -- i.e. more speed → fewer wall-clock ticks of delay for the same leadMs.
    local msPerTick = (1000 / tickRate) * speed
    if msPerTick <= 0 then
        msPerTick = 1000 / tickRate
    end
    local delay = math.ceil(math.max(tonumber(leadMs) or 120, 120) / msPerTick)
    if delay < 2 then
        delay = 2
    end
    return (tonumber(currentTick) or 0) + delay
end

local function send_action_to_host(actionName, payload)
    local currentTick = S.state.updateNumber

    local leadMs, emaMs, rawRttMs = compute_lead_ms()
    local tickRate = 60
    pcall(function()
        tickRate = tonumber(S.gameValue:getTickRate()) or tickRate
    end)
    if tickRate <= 0 then
        tickRate = 60
    end
    local speed = tonumber(itd.lastSpeed) or 1
    if speed <= 0 then
        speed = 1
    end
    -- SAME formula as authoritative_target_tick: ceil(leadMs / ((1000/tickRate)*speed)).
    -- The previous code multiplied by speed and skipped the tickRate floor, so
    -- client and host computed different actionDelay for the same lead.
    local msPerTick = (1000 / tickRate) * speed
    if msPerTick <= 0 then
        msPerTick = 1000 / tickRate
    end
    local actionDelay = math.ceil(math.max(tonumber(leadMs) or 120, 120) / msPerTick)
    if actionDelay < 2 then
        actionDelay = 2
    end

    local envelope = {
        action = actionName,
        tick = currentTick,
        target_tick = currentTick + actionDelay,
        sent_wall = (os.clock and os.clock()) or 0,
        lead_ms = leadMs,
        payload = payload
    }
    pcall(function()
        multitode.slog("ACT", string.format("REQ %s capTick=%s tgt=%s lead=%sms rtt=%sms(raw=%sms)",
            tostring(actionName), tostring(currentTick),
            tostring(currentTick + actionDelay), tostring(math.floor(leadMs)),
            tostring(math.floor(emaMs or -1)), tostring(math.floor(rawRttMs or -1))))
    end)
    if multitode.state().role == "CLIENT" then
        multitode.net.sendToHost("itd", "action_request", envelope)
        return
    end

    local channelHandlers = multitode.net.handlers and multitode.net.handlers["itd"] or nil
    local handler = channelHandlers and channelHandlers["action_request"] or nil
    if handler == nil then
        error("missing itd/action_request host handler")
    end

    local sessionInfo = multitode.getSessionInfo()
    handler({
        receiverContext = "HOST",
        messageChannel = "itd",
        messageName = "action_request",
        senderPlayerId = sessionInfo.localPlayerId
    }, envelope)
end

local function capture_action(actionName, payload)
    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo == nil or not sessionInfo.sessionActive then
        return false
    end

    local ok, err = pcall(send_action_to_host, actionName, payload)
    if not ok then
        logger:e("Failed to capture action %s: %s", tostring(actionName), tostring(err))
        return false
    end

    return true
end

function itd.allowLocalActions(fn)
    itd.allowLocalActionDepth = itd.allowLocalActionDepth + 1
    local ok, result = pcall(fn)
    itd.allowLocalActionDepth = math.max(0, itd.allowLocalActionDepth - 1)
    if not ok then
        error(result)
    end

    return result
end

function itd.isAuthoritativeApplyActive()
    return itd.allowLocalActionDepth > 0
end

function itd.shouldBlockLocalAction()
    if itd.allowLocalActionDepth > 0 then
        return false
    end

    -- Never intercept actions during tutorial levels -- the game engine
    -- manages tutorial actions directly and interception causes desync.
    if S ~= nil and S.gameState ~= nil and S.gameState.basicLevelName ~= nil then
        local levelName = tostring(S.gameState.basicLevelName)
        if levelName:sub(1, 2) == "0." then
            return false
        end
    end

    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo == nil or not sessionInfo.sessionActive then
        return false
    end

    return itd.enforceInterception
end

function itd.setInterceptionEnabled(enabled)
    itd.enforceInterception = not not enabled
    itd.seenQueuedActions = {}
    multitode.resetApprovedQueuedActions()
    logger:i("ITD interception %s", itd.enforceInterception and "enabled" or "disabled")
end

local function serialize_action(action)
    local writer = C.StringWriter.new()
    local json = C.Json.new()
    json:setWriter(writer)
    json:writeObjectStart()
    local ok, err = pcall(function()
        action:toJson(json)
    end)
    if not ok then
        logger:w("Action %s does not expose toJson cleanly: %s", tostring(action), tostring(err))
    end
    json:writeObjectEnd()
    return writer:toString()
end

local function get_action_type_name(action)
    local okType, resultType = pcall(function()
        return action:getType()
    end)
    if okType and resultType ~= nil then
        return tostring(resultType)
    end

    return "unknown"
end

local function should_capture_queued_action(actionType, action)
    -- Bonus vote / host-only pick: consume SGB/RRB before the normal path so a
    -- client cannot select (and unpause) while the lobby is still deciding.
    if actionType == "SGB" or actionType == "RRB" then
        local bv = multitode.bonusVote
        if bv ~= nil and bv.onQueuedBonusAction ~= nil then
            local ok, consumed = pcall(bv.onQueuedBonusAction, action, actionType)
            if ok and consumed then
                return false, true
            end
        end
    end

    if actionType ~= "CW" then
        return true, false
    end

    if multitode.state().role ~= "CLIENT" then
        return true, false
    end

    if S.wave:isAutoForceWaveEnabled() then
        logger:i("Suppressing client auto-wave CallWave capture at tick=%s", tostring(S.state.updateNumber))
        return false, false
    end

    return true, false
end

local function neutralize_queued_action(actions, index, actionType, actionString)
    local ok, err = pcall(function()
        actions[index] = C.ScriptAction.new_S(string.format("-- multitode itd noop for %s", tostring(actionType)))
    end)
    if not ok then
        logger:e(
            "Failed to neutralize queued action type=%s index=%s action=%s: %s",
            tostring(actionType),
            tostring(index - 1),
            tostring(actionString),
            tostring(err)
        )
        return false
    end

    logger:i(
        "Neutralized queued action type=%s index=%s action=%s",
        tostring(actionType),
        tostring(index - 1),
        tostring(actionString)
    )
    return true
end

local function inspect_queued_actions()
    if itd.queuedProbeInstalled == S then
        return
    end
    itd.queuedProbeInstalled = S
    S.events:getListeners(C.GameStateTick):addStateAffectingWithPriority(C.Listener(function(_)
        itd = ITD()
        -- Periodic cleanup of seenQueuedActions to prevent memory leak
        local currentTick = S.state.updateNumber
        if currentTick - itd.lastCleanupTick > 300 then
            itd.seenQueuedActions = {}
            itd.lastCleanupTick = currentTick
            if multitode.getApi() then
                multitode.getApi():cleanupApprovedQueuedActions(currentTick)
                multitode.getApi():cleanupStateHashSamples(currentTick)
            end
        end

        -- Both roles need this loop. On a client it turns the player's actions into
        -- requests; on the host it is how the host's OWN actions reach the other players.
        -- It used to be client-only, so a host-built tower existed on the host and nowhere
        -- else - a desync where nothing illegal happened anywhere.
        local isClientHere = itd.shouldBlockLocalAction()
        local isHostHere = false
        pcall(function()
            local st = multitode.state()
            local info = multitode.getSessionInfo()
            isHostHere = st ~= nil and tostring(st.role) ~= "CLIENT"
                and info ~= nil and info.sessionActive == true
        end)
        if not isClientHere and not isHostHere then
            return
        end

        local actionsArray = S.state:getCurrentUpdateActions()
        if actionsArray == nil or actionsArray.size == nil or actionsArray.size <= 0 then
            return
        end

        local tick = S.state.updateNumber
        local actions = actionsArray.actions
        for i = 1, actionsArray.size do
            local action = actions[i]
            if action ~= nil then
                local actionType = get_action_type_name(action)
                local actionName = actionType
                if actionName ~= nil then
                    local actionString = tostring(action)
                    if multitode.consumeApprovedQueuedAction(tick, actionString) then
                        multitode.actStats = multitode.actStats or {}
                        multitode.actStats.allowed = (multitode.actStats.allowed or 0) + 1
                        logger:i(
                            "Allowed authoritative queued action tick=%s index=%s type=%s action=%s",
                            tostring(tick),
                            tostring(i - 1),
                            tostring(actionType),
                            actionString
                        )
                    else
                        local shouldCapture, forceNeutralize = should_capture_queued_action(actionType, action)
                        if not shouldCapture then
                            multitode.actStats = multitode.actStats or {}
                            multitode.actStats.unhandled = (multitode.actStats.unhandled or 0) + 1
                            -- Bonus-vote consumption neutralizes on BOTH roles (host's own
                            -- click becomes a vote, not an immediate SGB). CW auto-wave and
                            -- other suppressions still only defer on a pure client.
                            if forceNeutralize or (isClientHere and not isHostHere) then
                                neutralize_queued_action(actions, i, actionType, actionString)
                            end
                            -- on the host this action is authoritative exactly as it stands
                            goto continue
                        end

                        local actionKey = string.format("%s:%s:%s", tostring(tick), tostring(i - 1), actionString)
                        -- Keys are tick-scoped, so this table only ever grows during a long
                        -- run. Bound it: a lookup table that never shrinks is a slowdown
                        -- that creeps in after many waves with no error to point at it.
                        itd.seenQueuedActionCount = (itd.seenQueuedActionCount or 0) + 1
                        if itd.seenQueuedActionCount > 4000 then
                            itd.seenQueuedActionCount = 0
                            itd.seenQueuedActions = {}
                        end
                        if not itd.seenQueuedActions[actionKey] then
                            local actionJson = serialize_action(action)
                            logger:i(
                                "Queued action tick=%s index=%s type=%s action=%s",
                                tostring(tick),
                                tostring(i - 1),
                                tostring(actionType),
                                actionString
                            )
                            -- CAP: super-log line so a first click vs second click
                            -- can be told apart offline (open item: is a selection
                            -- action captured on click-1?).
                            pcall(function()
                                multitode.slog("CAP", string.format(
                                    "type=%s idx=%s tick=%s %s",
                                    tostring(actionType), tostring(i - 1),
                                    tostring(tick), actionString))
                            end)
                            local captureOk = true
                            if isHostHere then
                                -- Host-owned actions must be announced at a future authoritative
                                -- tick and enqueued locally at that same tick. Broadcasting the
                                -- current tick lets a lagging client either miss the action or
                                -- independently retarget it, which is a desync.
                                local targetTick = authoritative_target_tick(tick)
                                pcall(function()
                                    multitode.approveQueuedAction(targetTick, actionString)
                                    multitode.getApi():broadcastLuaMessage("itd", "action_apply",
                                        multitode.net.encodePayload({
                                            action = actionName,
                                            tick = tick,
                                            target_tick = targetTick,
                                            sent_wall = (os.clock and os.clock()) or 0,
                                            lead_ms = compute_lead_ms(),
                                            payload = {
                                                queuedType = actionType,
                                                queuedIndex = i - 1,
                                                queuedAction = actionString,
                                                actionJson = actionJson
                                            }
                                        }))
                                    S.state:pushAction(action, targetTick)
                                    -- Remove the original current-tick copy; only the future
                                    -- authoritative copy may execute.
                                    neutralize_queued_action(actions, i, actionType, actionString)
                                end)
                                multitode.actStats = multitode.actStats or {}
                                multitode.actStats.hostSent = (multitode.actStats.hostSent or 0) + 1
                                pcall(function()
                                    multitode.slog("ACT", string.format(
                                        "HOST-SEND %s capTick=%s target=%s idx=%s (host's own action)",
                                        tostring(actionName), tostring(tick), tostring(targetTick), tostring(i - 1)))
                                end)
                            else
                                multitode.actStats = multitode.actStats or {}
                                multitode.actStats.captured = (multitode.actStats.captured or 0) + 1
                                captureOk = capture_action(actionName, {
                                    queuedType = actionType,
                                    queuedIndex = i - 1,
                                    queuedAction = actionString,
                                    actionJson = actionJson
                                }) == true
                            end
                            -- Only mark handled when the send/broadcast succeeded.
                            -- Marking before a failed send made the next tick skip
                            -- retry AND still neutralize — the action was lost.
                            if captureOk then
                                itd.seenQueuedActions[actionKey] = true
                            else
                                itd.seenQueuedActions[actionKey] = nil
                            end
                        end

                        -- CRITICAL: a host instance also reports as a client here, so a bare
                        -- isClientHere check neutralized the host's OWN action right after
                        -- broadcasting it - the client placed the tower and the host did not.
                        -- Only defer to the host's copy when we are not the host.
                        -- Neutralize ONLY when this action was successfully handled
                        -- (seen + captured); a failed send leaves it in place for retry.
                        if isClientHere and not isHostHere and itd.seenQueuedActions[actionKey] then
                            neutralize_queued_action(actions, i, actionType, actionString)
                        end
                    end
                end
            end

            ::continue::
        end
    end), C.EventListeners.PRIORITY_HIGHEST)
end

local function is_client_role()
    local ok, state = pcall(multitode.state)
    return ok and state ~= nil and state.role == "CLIENT"
end

local function get_live_systems()
    local systems = nil
    pcall(function()
        local screen = C.Game.i.screenManager:getCurrentScreen()
        if screen ~= nil and C.GameScreen:_isInstance(screen) then
            systems = screen.S
        end
    end)
    if systems == nil and S ~= nil then
        systems = S
    end
    return systems
end

local function session_in_game()
    local ok, info = pcall(multitode.getSessionInfo)
    if not ok or info == nil or info.sessionActive ~= true then
        return false
    end
    local systems = get_live_systems()
    local okSys, inGame = pcall(function()
        if systems == nil or systems.gameState == nil then
            return false
        end
        -- Custom maps have a null basicLevelName; they are valid multiplayer
        -- gameplay. Only the explicit 0.* tutorial family is excluded.
        local basicName = systems.gameState.basicLevelName
        if basicName == nil then
            return true
        end
        return tostring(basicName):sub(1, 2) ~= "0."
    end)
    return okSys and inGame == true
end

local function is_host_here()
    local ok, st = pcall(multitode.state)
    local okInfo, info = pcall(multitode.getSessionInfo)
    return ok and st ~= nil and tostring(st.role) ~= "CLIENT"
        and okInfo and info ~= nil and info.sessionActive == true
end

local function find_layer_table(layerName)
    local root = nil
    pcall(function()
        local mainLayers = C.MainUiLayer.values
        local layerGroups = C.Game.i.uiManager.layers
        for i = 1, #mainLayers do
            local group = layerGroups[i]
            if group ~= nil and group.size ~= nil then
                for j = 1, group.size do
                    local layer = group:get(j - 1)
                    if layer ~= nil and tostring(layer.name) == layerName then
                        root = layer:getTable()
                        break
                    end
                end
            end
            if root ~= nil then
                break
            end
        end
    end)
    return root
end

local function visit_actor(actor, fn, depth)
    if actor == nil or fn == nil or (depth or 0) > 14 then
        return
    end
    pcall(fn, actor)
    local ok, children = pcall(function() return actor:getChildren() end)
    if ok and children ~= nil and children.size ~= nil then
        for i = 1, children.size do
            visit_actor(children.items[i], fn, (depth or 0) + 1)
        end
    end
end

-- Touchable tracking for lockdowns. setEnabled() is purely cosmetic on
-- RightSideMenuButton: clicked() runs the stored Runnable WITHOUT checking the
-- enabled flag (RightSideMenuButton.java:63-68), and touchDown/touchUp never
-- check it either - so a greyed-out pause-menu button (Restart / End game /
-- Main menu / Continue) still fires when clicked. A client could therefore
-- drive the whole pause menu during a host pause. Making the actor
-- Touchable.disabled removes it from Stage hit-testing entirely, which is the
-- real boundary. Each actor's original touchable value is recorded on lock and
-- restored on unlock so actors that were touchable-disabled by design stay
-- that way (an unconditional "restore to enabled" could turn a decorative
-- overlay into a click swallower).
local function track_actor_touchable(actor, wantEnabled)
    itd.touchableStore = itd.touchableStore or {}
    local store = itd.touchableStore
    if wantEnabled then
        for i = #store, 1, -1 do
            local entry = store[i]
            -- Lua `==` on two JavaInstance wrappers compares the underlying
            -- objects (LuaUserdata.raweq -> m_instance.equals), so wrappers
            -- re-created by visit_actor still match their recorded entry.
            if entry[1] == actor then
                if entry[2] ~= nil then
                    pcall(function() actor:setTouchable(entry[2]) end)
                end
                table.remove(store, i)
                return
            end
        end
        -- No record: the actor was never locked down here; leave it untouched.
        return
    end
    for i = 1, #store do
        if store[i][1] == actor then
            pcall(function() actor:setTouchable(C.Touchable.disabled) end)
            return
        end
    end
    local prev = nil
    pcall(function() prev = actor:getTouchable() end)
    store[#store + 1] = { actor, prev }
    pcall(function() actor:setTouchable(C.Touchable.disabled) end)
end

local function set_actor_enabled(actor, enabled)
    pcall(function()
        if C.RightSideMenuButton:_isInstance(actor)
            or C.ComplexButton:_isInstance(actor)
            or C.LabelToggleButton:_isInstance(actor)
            or C.PaddedImageButton:_isInstance(actor) then
            actor:setEnabled(enabled)
            track_actor_touchable(actor, enabled)
        elseif C.HorizontalSlider:_isInstance(actor) then
            track_actor_touchable(actor, enabled)
        end
    end)
end

local function find_actor_by_name(root, name, depth)
    if root == nil or (depth or 0) > 14 then
        return nil
    end
    local nodeName = nil
    pcall(function() nodeName = tostring(root:getName()) end)
    if nodeName == name then
        return root
    end
    local ok, children = pcall(function() return root:getChildren() end)
    if ok and children ~= nil and children.size ~= nil then
        for i = 1, children.size do
            local found = find_actor_by_name(children.items[i], name, (depth or 0) + 1)
            if found ~= nil then
                return found
            end
        end
    end
    return nil
end

local function set_pause_lockdown(locked)
    itd.pauseLockdown = locked and true or false
    local menu = find_layer_table("PauseMenu main")
    -- Re-check the layer every tick: nil (menu not built yet) or a new table
    -- (UI rebuilt) re-arms this lock, so rebuilt buttons can't come back
    -- unlocked on a client.
    itd.pauseLockdownMenu = menu
    if menu ~= nil then
        visit_actor(menu, function(actor)
            set_actor_enabled(actor, not locked)
        end, 0)
    end
    local main = find_layer_table("MainUi")
    if main ~= nil then
        local pauseButton = find_actor_by_name(main, "game_pause_button", 0)
        if pauseButton ~= nil then
            -- Same reasoning as the menu buttons: setEnabled is cosmetic, so
            -- also take the button out of hit-testing while locked down.
            pcall(function()
                pauseButton:setEnabled(not locked)
            end)
            track_actor_touchable(pauseButton, not locked)
        end
    end
    -- Track whether we actually found the layers. If not (menu still building),
    -- leave pauseLockdownApplied false so the next apply_pause_mirror pass retries.
    itd.pauseLockdownApplied = (menu ~= nil or main ~= nil)
end

-- A client must not be able to change the simulation rate locally.  Disabling
-- the speed button is only cosmetic; the GameSpeedChange guard below is the
-- actual writer boundary and also covers the native speed hotkeys.
local function set_client_speed_lockdown(locked)
    itd.clientSpeedLockdown = locked and true or false
    -- Whether we actually walked. Menu/speed group missing means retry next
    -- tick - the old one-shot at install could miss the button entirely and
    -- leave it (and hold-to-slow-mo) live for the whole match.
    itd.speedLockdownApplied = false
    local main = find_layer_table("MainUi")
    if main == nil then
        return
    end
    local speedGroup = find_actor_by_name(main, "game_speed_toggle_button", 0)
    if speedGroup == nil then
        return
    end
    visit_actor(speedGroup, function(actor)
        set_actor_enabled(actor, not locked)
    end, 0)
    itd.speedLockdownApplied = locked and true or false
end

local function install_client_speed_guard()
    if itd.speedGuardInstalled == S then
        return
    end
    S.events:getListeners(C.GameSpeedChange):add(C.Listener(function(_)
        itd = ITD()
        if not is_client_role() or itd.clientSpeedLockdown ~= true
            or itd.hostPaused == true or itd.bonusPauseActive == true
            or (itd.challenge ~= nil and itd.challenge.active == true) then
            return
        end
        local desired = authoritative_host_speed()
        if desired == nil or desired < 0 then
            if itd.speedStateMode == true then
                return
            end
            desired = 1
        end
        -- 0 is a legitimate host freeze (bonus). Never coerce it to 1 here;
        -- only special-pause paths may leave a runnable rate unenforced.
        if desired < 0.05 and desired >= 0 then
            desired = 0
        end
        local current = nil
        pcall(function() current = tonumber(S.state:getGameSpeed()) end)
        if current == nil or math.abs(current - desired) < 0.001 then
            return
        end
        itd.suppressSpeedCapture = true
        itd.lastSpeed = desired
        S.state:setGameSpeed(desired)
        pcall(function()
            multitode.slog("CTRL", string.format(
                "client speed guard %sx -> host %sx tick=%s",
                tostring(current), tostring(desired), tostring(S.state.updateNumber)))
        end)
    end))
    itd.speedGuardInstalled = S
end

itd.challenge = itd.challenge or {
    active = false,
    birdIdx = -1,
    resumeSpeed = 1,
    resolved = false,
    decisionSent = false
}
local CHALLENGE_DIALOG_ID = "multitode-challenge"

local function challenge_session_ok()
    if not session_in_game() then
        return false
    end
    if S == nil or S.randomEncounter == nil then
        return false
    end
    if itd.hostPaused then
        return false
    end
    if itd.challenge.active then
        return true
    end
    if multitode.itd ~= nil and multitode.itd.bonusPauseActive then
        return false
    end
    if multitode.bonusVote ~= nil and multitode.bonusVote.blocking then
        return false
    end
    return true
end

local function get_active_birds()
    local birds = nil
    pcall(function()
        birds = S.randomEncounter:getActiveBirds()
    end)
    return birds
end

local function get_bird(idx)
    local birds = get_active_birds()
    if birds == nil or birds.size == nil then
        return nil
    end
    idx = tonumber(idx) or -1
    if idx < 0 or idx >= birds.size then
        return nil
    end
    local bird = nil
    pcall(function() bird = birds:get(idx) end)
    return bird
end

local function set_challenge_speed(speed)
    pcall(function()
        itd.suppressSpeedCapture = true
        S.state:setGameSpeed(speed)
        itd.lastSpeed = speed
    end)
end

local function challenge_text()
    local text = "Accept the challenge?"
    pcall(function()
        text = tostring(C.Game.i.localeManager.i18n:get("encounter_bird_confirm_dialog"))
    end)
    return text
end

local function hide_challenge_dialog()
    pcall(function()
        local dlg = C.Dialog:i()
        if dlg ~= nil then
            local lastId = nil
            pcall(function() lastId = dlg:getLastConfirmId() end)
            if lastId == CHALLENGE_DIALOG_ID then
                dlg:hide()
            end
        end
    end)
end

local function clear_challenge()
    itd.challenge = {
        active = false,
        birdIdx = -1,
        resumeSpeed = 1,
        resolved = false,
        decisionSent = false
    }
end

local function cancel_challenge(reason)
    if not itd.challenge.active then
        return
    end
    hide_challenge_dialog()
    clear_challenge()
    pcall(function()
        multitode.slog("BIRD", "challenge cancelled (" .. tostring(reason) .. ")")
    end)
end

local function resolve_challenge(idx, accepted)
    local ch = itd.challenge
    if not ch.active or ch.resolved then
        return
    end
    if tonumber(idx) ~= tonumber(ch.birdIdx) then
        return
    end
    ch.resolved = true
    local resume = tonumber(ch.resumeSpeed) or 1
    hide_challenge_dialog()
    set_challenge_speed(resume)
    clear_challenge()
    pcall(function()
        multitode.net.broadcast("itd", "challenge_resolve", {
            birdIdx = tonumber(idx),
            accepted = accepted and true or false
        })
    end)
    pcall(function()
        multitode.slog("BIRD", string.format("challenge resolved idx=%s accepted=%s",
            tostring(idx), tostring(accepted)))
    end)
    pcall(function()
        if accepted then
            S.randomEncounter:birdAcceptAction(tonumber(idx))
        else
            S.randomEncounter:birdDeclineAction(tonumber(idx))
        end
    end)
end
itd.hostResolveChallenge = resolve_challenge

local function on_challenge_answer(accepted, isHost)
    local ch = itd.challenge
    if not ch.active or ch.resolved then
        return
    end
    if isHost then
        resolve_challenge(ch.birdIdx, accepted)
        return
    end
    if ch.decisionSent then
        return
    end
    ch.decisionSent = true
    pcall(function()
        multitode.net.sendToHost("itd", "challenge_decision", {
            birdIdx = tonumber(ch.birdIdx),
            accepted = accepted and true or false
        })
    end)
end

local function show_challenge_dialog(isHost)
    pcall(function()
        C.Dialog:i():showConfirmWithCallbacksAndId(
            challenge_text(),
            C.Runnable(function() on_challenge_answer(true, isHost) end),
            C.Runnable(function() on_challenge_answer(false, isHost) end),
            CHALLENGE_DIALOG_ID)
    end)
end

local function open_challenge(idx, slowSpeed, resumeSpeed, isHost)
    itd.challenge = {
        active = true,
        birdIdx = tonumber(idx),
        resumeSpeed = tonumber(resumeSpeed) or 1,
        resolved = false,
        decisionSent = false
    }
    set_challenge_speed(tonumber(slowSpeed) or 0.0667)
    show_challenge_dialog(isHost)
    pcall(function()
        multitode.slog("BIRD", string.format("challenge open idx=%s slow=%s resume=%s",
            tostring(idx), tostring(slowSpeed), tostring(resumeSpeed)))
    end)
end

local function host_receive_challenge_request(idx)
    if not challenge_session_ok() or itd.challenge.active then
        return
    end
    local bird = get_bird(idx)
    if bird == nil then
        return
    end
    local birdActive = false
    pcall(function() birdActive = bird:isActive() == true end)
    if not birdActive then
        return
    end
    local speed = 0
    pcall(function() speed = tonumber(S.gameState:getGameSpeed()) or 0 end)
    if speed == nil or speed < 0.95 then
        return
    end
    local needsConfirm = true
    pcall(function() needsConfirm = bird.requiresConfirmation ~= false end)
    if not needsConfirm then
        pcall(function()
            S.randomEncounter:birdAcceptAction(tonumber(idx))
        end)
        pcall(function()
            multitode.slog("BIRD", "no-confirm bird accepted idx=" .. tostring(idx))
        end)
        return
    end
    local slow = math.min(speed, 0.0667)
    open_challenge(idx, slow, speed, true)
    pcall(function()
        multitode.net.broadcast("itd", "challenge_open", {
            birdIdx = tonumber(idx),
            slowSpeed = slow,
            resumeSpeed = speed,
            tick = S.state.updateNumber
        })
    end)
end

local function apply_challenge_open(payload)
    if payload == nil then
        return
    end
    if not challenge_session_ok() or itd.challenge.active then
        return
    end
    local idx = tonumber(payload.birdIdx)
    local bird = get_bird(idx)
    if bird == nil then
        return
    end
    local birdActive = false
    pcall(function() birdActive = bird:isActive() == true end)
    if not birdActive then
        return
    end
    open_challenge(idx, tonumber(payload.slowSpeed) or 0.0667,
        tonumber(payload.resumeSpeed) or 1, false)
end

local function apply_challenge_resolve(payload)
    if payload == nil then
        return
    end
    local ch = itd.challenge
    if not ch.active or ch.resolved then
        return
    end
    if tonumber(payload.birdIdx) ~= tonumber(ch.birdIdx) then
        return
    end
    ch.resolved = true
    local resume = tonumber(ch.resumeSpeed) or 1
    hide_challenge_dialog()
    set_challenge_speed(resume)
    clear_challenge()
    pcall(function()
        multitode.slog("BIRD", string.format("challenge resolve applied idx=%s accepted=%s",
            tostring(payload.birdIdx), tostring(payload.accepted)))
    end)
end

local function apply_encounter_colors(payload)
    if payload == nil or payload.colors == nil then
        return
    end
    local birds = get_active_birds()
    if birds == nil or birds.size == nil then
        return
    end
    if birds.size ~= #payload.colors then
        return
    end
    for i = 1, #payload.colors do
        local spec = payload.colors[i]
        local bird = nil
        pcall(function() bird = birds:get(i - 1) end)
        if bird ~= nil and spec ~= nil then
            pcall(function()
                if bird.baseColor ~= nil and spec.base ~= nil then
                    bird.baseColor:set(tonumber(spec.base[1]) or 1,
                        tonumber(spec.base[2]) or 1,
                        tonumber(spec.base[3]) or 1,
                        tonumber(spec.base[4]) or 1)
                end
                if bird.overlayColor ~= nil and spec.overlay ~= nil then
                    bird.overlayColor:set(tonumber(spec.overlay[1]) or 1,
                        tonumber(spec.overlay[2]) or 1,
                        tonumber(spec.overlay[3]) or 1,
                        tonumber(spec.overlay[4]) or 1)
                end
            end)
        end
    end
end
itd.applyEncounterColors = apply_encounter_colors

local function sync_encounter_colors(currentTick)
    if not is_host_here() or not session_in_game() then
        return
    end
    if S.randomEncounter == nil then
        return
    end
    local birds = get_active_birds()
    if birds == nil or birds.size == nil or birds.size <= 0 then
        return
    end
    local hasNew = false
    pcall(function()
        for i = 0, birds.size - 1 do
            local bird = birds:get(i)
            if bird ~= nil and tonumber(bird.existsFrames) ~= nil
                and tonumber(bird.existsFrames) <= 2 then
                hasNew = true
                break
            end
        end
    end)
    if not hasNew or itd.lastEncounterColorTick == currentTick then
        return
    end
    itd.lastEncounterColorTick = currentTick
    local colors = {}
    pcall(function()
        for i = 0, birds.size - 1 do
            local bird = birds:get(i)
            if bird ~= nil and bird.baseColor ~= nil and bird.overlayColor ~= nil then
                colors[#colors + 1] = {
                    base = { bird.baseColor.r, bird.baseColor.g, bird.baseColor.b, bird.baseColor.a },
                    overlay = { bird.overlayColor.r, bird.overlayColor.g, bird.overlayColor.b, bird.overlayColor.a }
                }
            end
        end
    end)
    if #colors ~= birds.size then
        return
    end
    pcall(function()
        multitode.net.broadcast("itd", "encounter_colors", {
            tick = currentTick,
            colors = colors
        })
    end)
end

local function ensure_challenge_guard()
    -- Re-resolve the stage every call: after a level switch the old stage
    -- reference is stale and a guard bound to it never fires again.
    local stage = nil
    pcall(function()
        stage = C.Game.i.uiManager.stage
    end)
    if stage == nil then
        return
    end
    if itd.challengeGuard ~= nil and itd.challengeGuardStage == stage then
        return
    end
    -- Stage changed (or first install): drop the old guard if we can, then
    -- install on the live stage.
    if itd.challengeGuard ~= nil and itd.challengeGuardStage ~= nil then
        pcall(function()
            itd.challengeGuardStage:removeCaptureListener(itd.challengeGuard)
        end)
        itd.challengeGuard = nil
    end
    local ok, guard = pcall(function()
        return luajava.createProxy(C.InputListener, {
            touchDown = function(_, event, _x, _y, _pointer, _button)
                local button = 0
                pcall(function() button = tonumber(event:getButton()) or 0 end)
                if button ~= 0 then
                    return false
                end
                local target = nil
                pcall(function() target = event:getTarget() end)
                if target ~= nil then
                    local parent = nil
                    pcall(function() parent = target:getParent() end)
                    if parent ~= nil then
                        return false
                    end
                end
                if not challenge_session_ok() or itd.hostPaused then
                    return false
                end
                if multitode.bonusVote ~= nil and multitode.bonusVote.blocking then
                    return false
                end
                local pausedNow = false
                pcall(function()
                    pausedNow = S.gameState ~= nil and S.gameState:isPaused() == true
                end)
                if pausedNow then
                    return false
                end
                local speed = 0
                pcall(function()
                    speed = tonumber(S.gameState:getGameSpeed()) or 0
                end)
                if speed == nil or speed < 0.95 then
                    return false
                end
                local sx, sy = nil, nil
                pcall(function()
                    sx = tonumber(C.Gdx.input:getX())
                    sy = tonumber(C.Gdx.input:getY())
                end)
                if sx == nil or sy == nil then
                    return false
                end
                local map = nil
                pcall(function()
                    map = C.Vector2.new_2f(sx, sy)
                    S._input.cameraController.screenToMap(map)
                end)
                if map == nil then
                    return false
                end
                local birds = get_active_birds()
                if birds == nil or birds.size == nil then
                    return false
                end
                for i = 0, birds.size - 1 do
                    local bird = nil
                    pcall(function() bird = birds:get(i) end)
                    if bird ~= nil then
                        local hit = false
                        pcall(function()
                            hit = bird:isActive() == true
                                and bird:isMouseHit(map.x, map.y) == true
                        end)
                        if hit then
                            pcall(function() event:stop() end)
                            pcall(function() event:cancel() end)
                            if itd.challenge.active then
                                return true
                            end
                            pcall(function()
                                if is_host_here() then
                                    host_receive_challenge_request(i)
                                else
                                    multitode.net.sendToHost("itd", "challenge_request", {
                                        birdIdx = i,
                                        tick = S.state.updateNumber
                                    })
                                end
                            end)
                            return true
                        end
                    end
                end
                return false
            end,
        })
    end)
    if ok and guard ~= nil then
        pcall(function()
            stage:addCaptureListener(guard)
            itd.challengeGuard = guard
            itd.challengeGuardStage = stage
        end)
    end
end

local function broadcast_pause_state(paused, tick)
    local systems = get_live_systems()
    local speed = nil
    pcall(function()
        if systems ~= nil and systems.state ~= nil then
            speed = tonumber(systems.state:getGameSpeed())
        end
    end)
    itd.lastPauseBroadcast = paused and true or false
    itd.hostPaused = paused and true or false
    pcall(function()
        multitode.net.broadcast("itd", "pause_state", {
            paused = paused and true or false,
            speed = speed,
            tick = tick
        })
    end)
    pcall(function()
        multitode.slog("CTRL", string.format("host pause broadcast=%s tick=%s",
            paused and "ON" or "OFF", tostring(tick)))
        multitode.slog("HB", paused and "PAUSE ON" or "PAUSE OFF")
    end)
end

local function apply_pause_mirror(paused)
    local systems = get_live_systems()
    itd.hostPaused = paused and true or false
    itd.pauseMirrorActive = true
    -- While the host stays paused this runs every tick. Keep the cheap
    -- pause-state enforcement every tick, but only walk the pause-menu UI
    -- when the mirrored state or lockdown actually changes.
    if itd.pauseMirrorApplied == (paused and true or false)
        and itd.pauseLockdown == (paused and true or false)
        and (not paused or itd.pauseLockdownApplied == true) then
        pcall(function()
            if systems ~= nil and systems.gameState ~= nil then
                if paused then
                    if not systems.gameState:isPaused() then
                        systems.gameState:pauseGame()
                    end
                elseif systems.gameState:isPaused() then
                    systems.gameState:resumeGame()
                end
            end
        end)
        -- Re-apply lockdown while paused: the PauseMenu may have opened AFTER the
        -- first mirror change, so the original set_pause_lockdown ran against a
        -- missing layer and never locked the buttons. Cheap no-op when already locked.
        if paused then
            pcall(set_pause_lockdown, true)
        end
        itd.pauseMirrorActive = false
        pcall(function()
            if systems ~= nil and systems.state ~= nil then
                itd.lastSpeed = systems.state:getGameSpeed()
            end
        end)
        return
    end
    pcall(function()
        if paused then
            cancel_challenge("host-pause")
            if systems ~= nil and systems.gameState ~= nil
                and not systems.gameState:isPaused() then
                systems.gameState:pauseGame()
            end
            set_pause_lockdown(true)
        else
            if systems ~= nil and systems.gameState ~= nil
                and systems.gameState:isPaused() then
                systems.gameState:resumeGame()
            end
            set_pause_lockdown(false)
        end
    end)
    itd.pauseMirrorApplied = paused and true or false
    itd.pauseMirrorActive = false
    pcall(function()
        if systems ~= nil and systems.state ~= nil then
            itd.lastSpeed = systems.state:getGameSpeed()
        end
    end)
    pcall(function()
        multitode.slog("CTRL", string.format(
            "pause mirror applied=%s systems=%s tick=%s",
            tostring(paused), tostring(systems ~= nil),
            systems ~= nil and systems.state ~= nil and tostring(systems.state.updateNumber) or "?"))
    end)
end
itd.applyPauseMirror = apply_pause_mirror
itd.hostReceiveChallengeRequest = host_receive_challenge_request
itd.applyChallengeOpen = apply_challenge_open
itd.applyChallengeResolve = apply_challenge_resolve

local function install_pause_event_listeners()
    if itd.pauseEventsInstalled == S then
        return
    end
    pcall(function()
        S.events:getListeners(C.GamePaused):add(C.Listener(function(_)
            local systems = get_live_systems()
            -- Forced (unthrottled) sync: this fires synchronously inside the
            -- global env's pauseGame(), so the just-published hostPaused must be
            -- visible here even though ticks (and the probe's throttled ITD()
            -- sync) have stopped.
            pcall(sync_state_from_bridge, itd, true)
            if is_host_here() then
                if not itd.hostPaused then
                    broadcast_pause_state(true, systems ~= nil and systems.state ~= nil
                        and systems.state.updateNumber or 0)
                end
                itd.hostPaused = true
            elseif is_client_role() then
                if not itd.hostPaused then
                    -- A client pressing the native pause button is never authoritative.
                    -- Immediately undo it before the local menu can affect the sim.
                    pcall(function()
                        if systems ~= nil and systems.gameState ~= nil then
                            systems.gameState:resumeGame()
                        end
                    end)
                    -- Never unlock pause UI here: on a client the probe holds
                    -- menu + pause locked all match, and an unlock would open
                    -- a one-tick hole for the next press.
                else
                    -- Host-authoritative pause arrived via the other env: the
                    -- engine is already paused by the message handler, but the
                    -- lockdown/UI mirror must be applied here too.
                    pcall(apply_pause_mirror, true)
                end
            end
        end))
    end)
    pcall(function()
        S.events:getListeners(C.GameResumed):add(C.Listener(function(_)
            local systems = get_live_systems()
            pcall(sync_state_from_bridge, itd, true)
            if is_host_here() then
                if itd.hostPaused then
                    broadcast_pause_state(false, systems ~= nil and systems.state ~= nil
                        and systems.state.updateNumber or 0)
                end
                itd.hostPaused = false
            elseif is_client_role() then
                if itd.hostPaused then
                    -- Re-apply the mirrored host pause if a client button/ESC tried to
                    -- resume locally. The host's resume message will clear this flag.
                    pcall(function()
                        if systems ~= nil and systems.gameState ~= nil
                                and not systems.gameState:isPaused() then
                            systems.gameState:pauseGame()
                        end
                    end)
                    set_pause_lockdown(true)
                else
                    -- Host resumed via the other env: engine is already running;
                    -- release the lockdown this env applied when the pause mirrored.
                    pcall(apply_pause_mirror, false)
                end
            end
        end))
    end)
    itd.pauseEventsInstalled = S
    -- Force a pause-state re-evaluation on the next probe/tick so a pause that
    -- fired before these listeners attached still reaches clients via the
    -- heartbeat/pause_state path (lastPauseBroadcast is reset so the probe's
    -- "pausedNow ~= lastPauseBroadcast" check rebroadcasts).
    itd.lastPauseBroadcast = nil
end

local function install_game_speed_probe()
    -- One GameStateTick probe per systems instance. SystemsSetup +
    -- SystemsStateRestore + script re-execution used to stack listeners;
    -- a stale one kept coercing hostSpeed nil→1 and fighting speed_state.
    if itd.probeInstalled == S then
        return
    end
    itd.probeInstalled = S
    S.events:getListeners(C.GameStateTick):addStateAffectingWithPriority(C.Listener(function(_)
        itd = ITD()
        local current_speed = S.state:getGameSpeed()
        -- A past client session leaves pause menu + speed locked in this env's
        -- UI. If we've since become host (role flips between matches), drop
        -- the locks once - or the host gets a grey dead pause menu next match.
        if itd.clientMenuLocked == true and not is_client_role() then
            itd.clientMenuLocked = false
            pcall(set_pause_lockdown, false)
            if itd.clientSpeedLockdown == true then
                pcall(set_client_speed_lockdown, false)
            end
        end
        if session_in_game() then
            local pausedNow = false
            pcall(function()
                pausedNow = S.gameState ~= nil and S.gameState:isPaused() == true
            end)
            if is_host_here() then
                if pausedNow ~= (itd.lastPauseBroadcast == true) then
                    broadcast_pause_state(pausedNow, S.state.updateNumber)
                end
                if pausedNow then
                    cancel_challenge("host-pause")
                    itd.hostPaused = true
                    -- Still flush a pending host speed change before parking:
                    -- a pause entered right after a 1x->2x click must announce
                    -- 2x (pause_state carries 0; resume restores o=n).
                    if itd.suppressSpeedCapture then
                        itd.suppressSpeedCapture = false
                        itd.lastSpeed = current_speed
                    end
                    return
                end
                itd.hostPaused = false
            elseif is_client_role() then
                -- Client UI locks, re-checked every tick. Install can run
                -- before MainUi / PauseMenu exist, so one-shot locks could
                -- miss silently and leave speed (slow-mo path included) or
                -- the pause menu live - the first press on
                -- Continue/Restart/Main menu actually went through. Each check
                -- is a cheap no-op once locked; a rebuilt layer (new level)
                -- trips the menu check.
                if itd.clientSpeedLockdown == true and itd.speedLockdownApplied ~= true then
                    pcall(set_client_speed_lockdown, true)
                end
                local pauseMenuRoot = find_layer_table("PauseMenu main")
                -- Only re-walk when a lock is wrong or an OPEN menu's layer
                -- differs from the locked one. Closed menu = flag check only.
                if itd.pauseLockdown ~= true or itd.pauseLockdownApplied ~= true
                        or (pauseMenuRoot ~= nil and itd.pauseLockdownMenu ~= pauseMenuRoot) then
                    pcall(set_pause_lockdown, true)
                end
                itd.clientMenuLocked = true
                if itd.hostPaused then
                    apply_pause_mirror(true)
                    return
                end
            end
            sync_encounter_colors(S.state.updateNumber)
        end
        if itd.lastSpeed == nil then itd.lastSpeed = current_speed end
        -- Remember the last runnable speed so a boost-vote freeze (0) can restore
        -- the real pre-pause speed even if the overlay already zeroed it.
        if current_speed ~= nil and tonumber(current_speed) ~= nil and tonumber(current_speed) >= 0.05 then
            itd.lastGoodSpeed = tonumber(current_speed)
        end
        -- Tick-heartbeat drift correction (80_multitode_itd_net.lua) changes the
        -- speed directly; never capture or revert those, just adopt them.
        if itd.suppressSpeedCapture then
            itd.suppressSpeedCapture = false
            local announced = tonumber(itd.hostSpeed)
            local nowSpeed = tonumber(current_speed)
            -- Host must still announce a real rate change that a local
            -- correction (force_speed / challenge) applied without a broadcast.
            -- Returning here left clients stuck at 1x while the host ran 2x.
            local hostNeedsAnnounce = is_host_here()
                and session_in_game()
                and nowSpeed ~= nil
                and (announced == nil or math.abs(announced - nowSpeed) > 0.001)
            if not hostNeedsAnnounce then
                itd.lastSpeed = current_speed
                return
            end
            -- Fall through so the HOST capture path below broadcasts speed_state.
            -- Nudge lastSpeed so the equality gate does not swallow the announce.
            itd.lastSpeed = nowSpeed - 1
        end
        -- Boost-vote freeze: hold 0 locally. Never SPD-broadcast 0 (deserialize
        -- coerces <0.05 to 1) and never let the client's pause-block resume.
        -- Arm from the speed probe as well as 87_'s GameStateTick listener: the
        -- engine overlay can set speed 0 before the lazy 87_ install completes.
        if not itd.bonusPauseActive then
            local bv = multitode.bonusVote
            if bv ~= nil and bv.armPauseForStage ~= nil then
                pcall(bv.armPauseForStage)
            end
        end
        -- Also adopt the overlay's own setGameSpeed(0) as a freeze until 87_
        -- first-sight/open arms bonusPauseActive (those can land a tick later).
        -- Custom maps have basicLevelName == nil — only exclude the explicit
        -- 0.* tutorial family; requiring a non-nil name skipped arming on every
        -- custom multiplayer map (host froze, client kept running).
        if not itd.bonusPauseActive then
            local overlayVisible = false
            pcall(function()
                local info = multitode.getSessionInfo()
                local basicName = S.gameState ~= nil and S.gameState.basicLevelName
                local notTutorial = basicName == nil
                    or tostring(basicName):sub(1, 2) ~= "0."
                if info ~= nil and info.sessionActive == true
                    and S.gameState ~= nil
                    and notTutorial
                    and S._gameUi ~= nil and S._gameUi.gameplayBonusesOverlay ~= nil
                    and S._gameUi.gameplayBonusesOverlay:isVisible() == true then
                    overlayVisible = true
                end
            end)
            if overlayVisible and current_speed < 0.5 then
                itd.bonusPauseActive = true
            end
        end
        if itd.bonusPauseActive then
            if current_speed ~= 0 then
                itd.suppressSpeedCapture = true
                S.state:setGameSpeed(0)
                itd.lastSpeed = 0
            else
                itd.lastSpeed = 0
            end
            if not is_client_role() then
                itd.hostSpeed = 0
            end
            return
        end
        local lastAnnounced = tonumber(itd.lastSpeed)
        if lastAnnounced ~= nil and tonumber(current_speed) ~= nil
                and math.abs(lastAnnounced - tonumber(current_speed)) < 0.001 then
            return
        end

        -- ABSOLUTE rule, checked BEFORE anything else: if the client's speed was
        -- pushed into the engine's pause / slow-motion band by the ENGINE (not by
        -- our own correction), snap back to the host's speed immediately.
        -- This ran too late before: during a correction the enforcement below is
        -- skipped, so a pause-set ~0.1x survived indefinitely - the client crawled
        -- for 25 waves while the host finished the level, an unrecoverable gap.
        -- current_speed ~= itd.lastSpeed is the tell: our own corrections adopt the
        -- value they set, so a mismatch means the ENGINE overrode us.
        -- Skip entirely during an authoritative host pause (hostPaused) so we never
        -- resumeGame() against apply_pause_mirror.
        if is_client_role() and itd.hostPaused ~= true
                and itd.bonusPauseActive ~= true
                and not (itd.challenge ~= nil and itd.challenge.active)
                and current_speed < 0.5 and current_speed ~= itd.lastSpeed then
            local hostSpeed = tonumber(itd.hostSpeed) or 1
            if hostSpeed >= 1 then
                pcall(function()
                    if S.gameState ~= nil and S.gameState:isPaused() then
                        -- Close the pause MENU as well. Setting the speed alone lost
                        -- the fight: while the menu is open the engine re-applies its
                        -- slow-motion every frame, so repeated pausing silently
                        -- accumulated a permanent tick gap.
                        S.gameState:resumeGame()
                        local nowMs = 0
                        pcall(function() nowMs = multitode.now_ms() end)
                        if (nowMs - (itd.pauseNoticeAt or 0)) > 5000 then
                            itd.pauseNoticeAt = nowMs
                            pcall(function()
                                if multitode.show_toast ~= nil then
                                    multitode.show_toast("Pause is disabled in multiplayer")
                                end
                            end)
                        end
                    end
                end)
                itd.suppressSpeedCapture = true
                S.state:setGameSpeed(hostSpeed)
                itd.lastSpeed = hostSpeed
                pcall(function()
                    multitode.slog("HB", string.format("PAUSE BLOCKED (engine speed %sx -> host %sx)",
                        tostring(current_speed), tostring(hostSpeed)))
                end)
                return
            end
        end

        -- Speed is HOST-AUTHORITATIVE ("Host Speed Control"). A client must never
        -- change it: a local pause/slow-motion freezes only that client and
        -- desyncs the match instantly. Force the host's speed back AND clear the
        -- engine pause state, otherwise the engine re-applies its own value every
        -- tick and the two sides fight (thousands of SPD packets + a softlock).
        if is_client_role() then
            -- SINGLE WRITER RULE. The host rate is the only normal-gameplay rate;
            -- do not use tick drift to inject 0.5x/0.75x or 2x/4x. The speed
            -- guard above handles native input, while this per-tick check is
            -- only a final state reconciliation for other engine writers.
            -- Never fight an authoritative host pause: resumeGame/setGameSpeed
            -- here raced apply_pause_mirror and caused pause oscillation.
            if itd.hostPaused == true then
                return
            end
            local desired, fromSpeedState = authoritative_host_speed()
            if desired == nil then
                -- NEVER default a missing hostSpeed to 1x while speed_state is
                -- authoritative: that is exactly the "enforced 2x -> 1x" slam
                -- that re-locked the client after every host speed change.
                if itd.speedStateMode == true then
                    return
                end
                desired = 1
            end
            -- 0 is a legitimate host-authoritative freeze (bonus vote). Only
            -- treat a missing/invalid hostSpeed as 1x — do NOT coerce 0 to 1.
            if desired < 0 then
                desired = 1
            end
            if fromSpeedState and itd.speedStateSpeed ~= nil
                    and math.abs(desired - tonumber(itd.speedStateSpeed)) >= 0.001 then
                desired = tonumber(itd.speedStateSpeed)
            end

            if desired ~= nil and current_speed ~= nil
                    and math.abs(desired - current_speed) >= 0.001 then
                itd.suppressSpeedCapture = true
                S.state:setGameSpeed(desired)
                itd.lastSpeed = desired
                -- Only clear the engine pause menu when restoring a runnable
                -- speed. Resuming while the host froze us at 0 (bonus) would
                -- fight the freeze and desync again.
                if desired >= 0.5 then
                    pcall(function()
                        if S.gameState ~= nil and S.gameState:isPaused() then
                            -- Close the pause MENU as well. Setting the speed alone lost
                            -- the fight: while the menu is open the engine re-applies its
                            -- slow-motion every frame, so repeated pausing silently
                            -- accumulated a permanent tick gap.
                            S.gameState:resumeGame()
                            local nowMs = 0
                            pcall(function() nowMs = multitode.now_ms() end)
                            if (nowMs - (itd.pauseNoticeAt or 0)) > 5000 then
                                itd.pauseNoticeAt = nowMs
                                pcall(function()
                                    if multitode.show_toast ~= nil then
                                        multitode.show_toast("Pause is disabled in multiplayer")
                                    end
                                end)
                            end
                        end
                    end)
                end
                local nowMs = 0
                pcall(function() nowMs = multitode.now_ms() end)
                if (nowMs - (itd.speedEnforceNoticeAt or 0)) > 3000 then
                    itd.speedEnforceNoticeAt = nowMs
                    logger:i("Client speed enforced %sx -> %sx t=%s", tostring(current_speed), tostring(desired), tostring(ITD()))
                end
            else
                itd.lastSpeed = current_speed
            end
            return
        end

        -- HOST: the host owns the speed. Speed is a presentation/simulation-rate
        -- control, so do not enqueue it as a future action. A delayed SPD action
        -- can otherwise re-apply an old slow-motion value after the host has
        -- already returned to 1x.
        logger:i("Captured speed change speed=%s tick=%s", tostring(current_speed), tostring(S.state.updateNumber))
        itd.lastSpeed = current_speed
        itd.hostSpeed = current_speed
        itd.speedStateEpoch = (tonumber(itd.speedStateEpoch) or 0) + 1
        pcall(function()
            multitode.slog("CTRL", string.format("host speed captured=%s tick=%s epoch=%s",
                tostring(current_speed), tostring(S.state.updateNumber),
                tostring(itd.speedStateEpoch)))
            local payload = {
                speed = current_speed,
                epoch = itd.speedStateEpoch,
                tick = S.state.updateNumber
            }
            -- Explicit freeze flag so clients accept 0 instead of ignoring it.
            if current_speed ~= nil and tonumber(current_speed) ~= nil
                    and tonumber(current_speed) < 0.05 then
                payload.frozen = true
            end
            multitode.net.broadcast("itd", "speed_state", payload)
        end)
    end), C.EventListeners.PRIORITY_HIGHEST)
end

local function install_session_listeners()
    if S == nil or S.events == nil then
        logger:i("Skipping ITD interceptor install: no active game systems")
        return false
    end
    if itd.installedSession == S then
        logger:i("ITD interceptors already installed for current session")
        return false
    end

    -- Snapshot restore: converge itd to whatever the message-owning env has
    -- published before any listener callback fires on this fresh session.
    pcall(sync_state_from_bridge, itd, true)

    inspect_queued_actions()
    install_pause_event_listeners()
    install_game_speed_probe()
    install_client_speed_guard()
    set_client_speed_lockdown(is_client_role())
    ensure_challenge_guard()

    -- After a snapshot restore the engine forces 1x; re-announce the host's
    -- real rate immediately so clients do not stick at 1x under a 2x/4x host.
    if is_host_here() then
        local hostRate = nil
        pcall(function()
            if S.state.getNonAnimatedGameSpeed ~= nil then
                hostRate = tonumber(S.state:getNonAnimatedGameSpeed())
            else
                hostRate = tonumber(S.state:getGameSpeed())
            end
        end)
        if hostRate ~= nil and hostRate >= 0.05 then
            itd.hostSpeed = hostRate
            itd.lastSpeed = hostRate
            itd.speedStateEpoch = (tonumber(itd.speedStateEpoch) or 0) + 1
            pcall(function()
                multitode.net.broadcast("itd", "speed_state", {
                    speed = hostRate,
                    epoch = itd.speedStateEpoch,
                    tick = S.state.updateNumber
                })
                multitode.slog("CTRL", string.format(
                    "session-install re-announce speed=%s epoch=%s",
                    tostring(hostRate), tostring(itd.speedStateEpoch)))
            end)
        end
    end

    itd.installedSession = S
    logger:i("Installed ITD gameplay interceptors for current session")
    pcall(function()
        if multitode.net ~= nil and multitode.net.appendEnvMarker ~= nil then
            multitode.net.appendEnvMarker("70-session-installed")
        end
    end)
    return true
end

local function try_install_for_current_session()
    if S ~= nil then
        logger:i("Attempting ITD interceptor install for current session")
    end
    install_session_listeners(S)
    if S ~= nil and itd.installedSession == S then
        set_client_speed_lockdown(is_client_role())
    end
end

C.Game.EVENTS:getListeners(C.SystemsSetup):add(C.Listener(function(_)
    try_install_for_current_session()
end))

C.Game.EVENTS:getListeners(C.SystemsStateRestore):add(C.Listener(function(_)
    try_install_for_current_session()
end))

try_install_for_current_session()

logger:i("Multitode ITD skeleton loaded")
