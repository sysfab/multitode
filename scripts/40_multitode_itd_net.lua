local logger = C.TLog:forTag("multitode/itd_net.lua")

_G.multitode = _G.multitode or {}
multitode.itdNet = multitode.itdNet or {}

local itdNet = multitode.itdNet

itdNet.handlersRegistered = itdNet.handlersRegistered or false

local MIN_ACTION_LEAD_TICKS = 2

local actionClassByType = {
    S = C.GameSpeedChange,
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
    if currentTick >= 0 then
        local minimumTargetTick = currentTick + MIN_ACTION_LEAD_TICKS
        if effectiveTargetTick < minimumTargetTick then
            effectiveTargetTick = minimumTargetTick
        end
    end
    if currentTick >= 0 and effectiveTargetTick ~= targetTick then
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

local function enqueue_auto_wave_change(envelope, sourceLabel)
    local targetTick = tonumber(envelope.target_tick)
    if targetTick == nil then
        error("missing target_tick")
    end

    local payload = envelope.payload or {}
    local enabled = not not payload.enabled

    local systems = get_current_systems()
    if systems == nil or systems.state == nil or systems.wave == nil then
        logger:w("Dropping auto wave change before game systems are ready")
        return false
    end

    local currentTick = get_current_tick()
    local effectiveTargetTick = targetTick
    if currentTick >= 0 then
        effectiveTargetTick = math.max(effectiveTargetTick, currentTick + MIN_ACTION_LEAD_TICKS)
    end

    local action = C.ScriptAction.new_S(string.format(
        "multitode.itd.allowLocalActions(function() S.wave:setAutoForceWaveEnabled(%s) end)",
        tostring(enabled)
    ))
    systems.state:pushAction(action, effectiveTargetTick)
    logger:i(
        "%s queued auto wave change enabled=%s for tick %s",
        tostring(sourceLabel),
        tostring(enabled),
        tostring(effectiveTargetTick)
    )
    return true
end

local function apply_authoritative_message(envelope, sourceLabel)
    if envelope.action == "AWC" then
        return enqueue_auto_wave_change(envelope, sourceLabel)
    end

    return enqueue_authoritative_action(envelope, sourceLabel)
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

        multitode.net.broadcast("itd", "action_apply", payload)
        apply_authoritative_message(payload, "Host")
    end)

    multitode.net.onClient("itd", "action_apply", function(_, payload)
        if not should_handle_client_action_apply() then
            return
        end

        apply_authoritative_message(payload, "Client")
    end)

    itdNet.handlersRegistered = true
    logger:i("Multitode ITD network handlers loaded")
end

ensure_handlers_registered()
