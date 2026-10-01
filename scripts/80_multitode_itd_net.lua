local logger = C.TLog:forTag("multitode/itd_net.lua")

_G.multitode = _G.multitode or {}
multitode.itdNet = multitode.itdNet or {}

local itdNet = multitode.itdNet

itdNet.handlersRegistered = itdNet.handlersRegistered or false
itdNet.nextActionSequence = itdNet.nextActionSequence or 1
itdNet.nextExpectedActionSequence = itdNet.nextExpectedActionSequence or 1
itdNet.pendingAuthoritativeActions = itdNet.pendingAuthoritativeActions or {}

local MIN_ACTION_LEAD_TICKS = 2

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
    RRB = C.ReRollBonusesAction
}

local function deserialize_action(payload, actionType, actionJson)
    local actionClass
    if actionType == "SPD" then
        if (payload.speed < 1) then payload.speed = 1 end 
        return C.ScriptAction.new_S("multitode.itd.lastSpeed = " .. payload.speed .. " S.state:setGameSpeed(" .. payload.speed .. ")")
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

local function enqueue_authoritative_action(envelope, sourceLabel, adjustStaleTarget)
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
    if adjustStaleTarget and currentTick >= 0 then
        local minimumTargetTick = currentTick + MIN_ACTION_LEAD_TICKS
        if effectiveTargetTick < minimumTargetTick then
            effectiveTargetTick = minimumTargetTick
        end
    end
    if adjustStaleTarget and currentTick >= 0 and effectiveTargetTick ~= targetTick then
        logger:w(
            "%s adjusted stale target tick for %s from %s to %s",
            tostring(sourceLabel),
            tostring(payload.queuedAction),
            tostring(targetTick),
            tostring(effectiveTargetTick)
        )
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

    return true
end

function itdNet.getNextActionSequence()
    return itdNet.nextActionSequence
end

function itdNet.resetClientActionSequence(nextSequence)
    local sequence = tonumber(nextSequence)
    if sequence == nil or sequence < 1 or sequence ~= math.floor(sequence) then
        error("invalid next action sequence")
    end

    itdNet.nextExpectedActionSequence = sequence
    itdNet.pendingAuthoritativeActions = {}
end

local function enqueue_pending_client_actions()
    while true do
        local sequence = itdNet.nextExpectedActionSequence
        local payload = itdNet.pendingAuthoritativeActions[sequence]
        if payload == nil then
            return
        end

        itdNet.pendingAuthoritativeActions[sequence] = nil
        itdNet.nextExpectedActionSequence = sequence + 1
        enqueue_authoritative_action(payload, "Client", false)
    end
end

local function should_handle_client_action_apply()
    local ok, state = pcall(multitode.state)
    if not ok or state == nil then
        return false
    end

    return state.role == "CLIENT"
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

        payload.sequence = itdNet.nextActionSequence
        itdNet.nextActionSequence = itdNet.nextActionSequence + 1
        enqueue_authoritative_action(payload, "Host", true)
        multitode.net.broadcast("itd", "action_apply", payload)
    end)

    multitode.net.onClient("itd", "action_apply", function(_, payload)
        if not should_handle_client_action_apply() then
            return
        end

        local sequence = tonumber(payload.sequence)
        if sequence == nil or sequence < 1 or sequence ~= math.floor(sequence) then
            logger:e("Received action_apply with invalid sequence %s", tostring(payload.sequence))
            return
        end
        if sequence < itdNet.nextExpectedActionSequence then
            return
        end
        if itdNet.pendingAuthoritativeActions[sequence] ~= nil then
            return
        end

        itdNet.pendingAuthoritativeActions[sequence] = payload
        enqueue_pending_client_actions()
    end)

    itdNet.handlersRegistered = true
    logger:i("Multitode ITD network handlers loaded")
end

ensure_handlers_registered()
