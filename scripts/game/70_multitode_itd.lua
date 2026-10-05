local logger = C.TLog:forTag("multitode/itd.lua")

_G.multitode = _G.multitode or {}
multitode.itd = multitode.itd or {}

local itd = multitode.itd

itd.enforceInterception = true
itd.allowLocalActionDepth = 0
itd.installedSessionKey = nil
itd.seenQueuedActions = itd.seenQueuedActions or {}
itd.lastSpeed = 1
itd.lastAutoWaveEnabled = nil
itd.autoWavePendingThroughTick = nil

itd.actionDelayMs = 200

local function get_action_delay()
    local actionDelay = math.ceil((itd.actionDelayMs / (1000 / S.gameValue:getTickRate())) * itd.lastSpeed)
    if actionDelay < 1 then
        actionDelay = 1
        logger:w("Action delay is %s", tostring(actionDelay))
    end
    return actionDelay
end

local function send_action_to_host(actionName, payload)
    local currentTick = S.state.updateNumber
    local actionDelay = get_action_delay()

    local envelope = {
        action = actionName,
        tick = currentTick,
        target_tick = currentTick + actionDelay,
        payload = payload
    }
    if multitode.state().role == "CLIENT" then
        multitode.net.sendToHost("itd", "action_request", envelope)
        return envelope.target_tick
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
    return envelope.target_tick
end

local function capture_action(actionName, payload)
    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo == nil or not sessionInfo.sessionActive then
        return false
    end

    local ok, result = pcall(send_action_to_host, actionName, payload)
    if not ok then
        logger:e("Failed to capture action %s: %s", tostring(actionName), tostring(result))
        return false
    end

    return true, result
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

local function should_capture_queued_action(actionType)
    if actionType ~= "CW" then
        return true
    end

    if multitode.state().role == "CLIENT" and S.wave:isAutoForceWaveEnabled() then
        logger:i("Suppressing client auto-wave CallWave at tick=%s", tostring(S.state.updateNumber))
        return false
    end

    if S.wave:isAutoForceWaveEnabled()
        and itd.autoWavePendingThroughTick ~= nil
        and S.state.updateNumber <= itd.autoWavePendingThroughTick then
        return false
    end

    return true
end

function itd.applyAuthoritativeAutoWaveState(enabled)
    enabled = not not enabled
    itd.lastAutoWaveEnabled = enabled
    S.wave:setAutoForceWaveEnabled(enabled)
    if S._gameUi ~= nil and S._gameUi.mainUi ~= nil then
        S._gameUi.mainUi:updateForceWaveButton()
    end
end

local function install_auto_wave_probe()
    itd.lastAutoWaveEnabled = S.wave:isAutoForceWaveEnabled()
    itd.autoWavePendingThroughTick = nil
    S.events:getListeners(C.GameStateTick):addStateAffectingWithPriority(C.Listener(function(_)
        local enabled = S.wave:isAutoForceWaveEnabled()
        if itd.lastAutoWaveEnabled == enabled then
            return
        end

        itd.lastAutoWaveEnabled = enabled
        local sessionInfo = multitode.getSessionInfo()
        if sessionInfo == nil or not sessionInfo.sessionActive then
            return
        end

        if multitode.state().role == "CLIENT" then
            multitode.net.sendToHost("itd", "auto_wave_request", { enabled = enabled })
            logger:i("Requested host auto-wave state %s", tostring(enabled))
        else
            multitode.net.broadcast("itd", "auto_wave_state", { enabled = enabled })
            logger:i("Broadcast host auto-wave state %s", tostring(enabled))
        end
    end), C.EventListeners.PRIORITY_HIGHEST)
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
    S.events:getListeners(C.GameStateTick):addStateAffectingWithPriority(C.Listener(function(_)
        if not itd.shouldBlockLocalAction() then
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
                        logger:i(
                            "Allowed authoritative queued action tick=%s index=%s type=%s action=%s",
                            tostring(tick),
                            tostring(i - 1),
                            tostring(actionType),
                            actionString
                        )
                    else
                        if not should_capture_queued_action(actionType) then
                            neutralize_queued_action(actions, i, actionType, actionString)
                            goto continue
                        end

                        local actionKey = string.format("%s:%s:%s", tostring(tick), tostring(i - 1), actionString)
                        if not itd.seenQueuedActions[actionKey] then
                            local actionJson = serialize_action(action)
                            itd.seenQueuedActions[actionKey] = true
                            logger:i(
                                "Queued action tick=%s index=%s type=%s action=%s",
                                tostring(tick),
                                tostring(i - 1),
                                tostring(actionType),
                                actionString
                            )
                            local captured, targetTick = capture_action(actionName, {
                                queuedType = actionType,
                                queuedIndex = i - 1,
                                queuedAction = actionString,
                                actionJson = actionJson
                            })
                            if captured and actionType == "CW" and S.wave:isAutoForceWaveEnabled() then
                                itd.autoWavePendingThroughTick = tonumber(targetTick)
                            end
                        end

                        neutralize_queued_action(actions, i, actionType, actionString)
                    end
                end
            end

            ::continue::
        end
    end), C.EventListeners.PRIORITY_HIGHEST)
end

local function install_game_speed_probe()
    S.events:getListeners(C.GameStateTick):addStateAffectingWithPriority(C.Listener(function(_)
        if S.state:isPaused() then
            return
        end

        local current_speed = S.state:getGameSpeed()
        if itd.lastSpeed == nil then itd.lastSpeed = current_speed end
        if current_speed == 0
                and S._gameUi ~= nil
                and S._gameUi.gameplayBonusesOverlay ~= nil
                and S._gameUi.gameplayBonusesOverlay:isVisible() then
            return
        end
        if itd.lastSpeed == current_speed then return end
        
        logger:i("Captured speed change speed=%s tick=%s", tostring(current_speed), tostring(S.state.updateNumber))
        capture_action("SPD", {
            speed = current_speed,
            queuedType = "SPD",
            actionJson = "{}",
        })

        S.state:setGameSpeed(itd.lastSpeed)
    end), C.EventListeners.PRIORITY_HIGHEST)
end

local function install_session_listeners()
    if S == nil or S.events == nil then
        logger:i("Skipping ITD interceptor install: no active game systems")
        return false
    end
    local sessionKey = tostring(S.gameState.gameStartTimestamp)
    if itd.installedSessionKey == sessionKey then
        logger:i("ITD interceptors already installed for current session")
        return false
    end

    inspect_queued_actions()
    install_game_speed_probe()
    install_auto_wave_probe()

    itd.installedSessionKey = sessionKey
    logger:i("Installed ITD gameplay interceptors for current session")
    return true
end

local function try_install_for_current_session()
    if S ~= nil then
        logger:i("Attempting ITD interceptor install for current session")
    end
    install_session_listeners(S)
end

C.Game.EVENTS:getListeners(C.SystemsSetup):add(C.Listener(function(_)
    try_install_for_current_session()
end))

C.Game.EVENTS:getListeners(C.SystemsStateRestore):add(C.Listener(function(_)
    try_install_for_current_session()
end))

try_install_for_current_session()

logger:i("Multitode ITD skeleton loaded")
