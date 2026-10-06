local logger = C.TLog:forTag("multitode/itd_net.lua")

_G.multitode = _G.multitode or {}
multitode.itdNet = multitode.itdNet or {}

local itdNet = multitode.itdNet

itdNet.handlersRegistered = itdNet.handlersRegistered or false
itdNet.nextActionSequence = itdNet.nextActionSequence or 1
itdNet.nextExpectedActionSequence = itdNet.nextExpectedActionSequence or 1
itdNet.pendingAuthoritativeActions = itdNet.pendingAuthoritativeActions or {}
itdNet.pendingApprovals = itdNet.pendingApprovals or {}
itdNet.pauseInstalledSessionKey = nil
itdNet.authoritativePaused = false
itdNet.pendingPauseState = nil
itdNet.pauseRevision = 0
itdNet.pauseApplyDepth = 0
itdNet.exitMenuPatchedButtonKey = nil
itdNet.endGamePatchedButtonKey = nil
itdNet.restartLevelPatchedButtonKey = nil
itdNet.actionProbeSessionKey = nil
itdNet.bonusMenuSessionKey = nil
itdNet.bonusMenuObservedVisible = nil
itdNet.bonusMenuApplyDepth = 0
itdNet.bonusMenuRevision = 0
itdNet.bonusEventSessionKey = nil
itdNet.pendingBonusActionTick = nil
itdNet.pendingBonusMenuState = nil

local MIN_ACTION_LEAD_TICKS = 2
local PAUSE_LEAD_MILLIS = 500

local actionClassByType = {
    S = C.ScriptAction,
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

    return currentScreen.S
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

local function reset_game_session_state()
    itdNet.pendingPauseState = nil
    itdNet.authoritativePaused = false
    itdNet.pauseRevision = 0
    itdNet.pauseApplyDepth = 0
    itdNet.pauseInstalledSessionKey = nil
    itdNet.exitMenuPatchedButtonKey = nil
    itdNet.endGamePatchedButtonKey = nil
    itdNet.restartLevelPatchedButtonKey = nil
    itdNet.actionProbeSessionKey = nil
    itdNet.bonusMenuSessionKey = nil
    itdNet.bonusMenuObservedVisible = nil
    itdNet.bonusMenuApplyDepth = 0
    itdNet.bonusMenuRevision = 0
    itdNet.bonusEventSessionKey = nil
    itdNet.pendingBonusActionTick = nil
    itdNet.pendingBonusMenuState = nil
    itdNet.pendingApprovals = {}

    local api = multitode.getApi()
    api:clearLevelSyncAnnouncement()
    api:setSynchronizedPauseActive(false)
    multitode.resetApprovedQueuedActions()
end

local function go_to_main_menu()
    reset_game_session_state()
    if not C.GameScreen:_isInstance(C.Game.i.screenManager:getCurrentScreen()) then
        return
    end

    C.Game.i.screenManager:goToMainMenu()
end

local function broadcast_exit_to_menu()
    local ok, err = pcall(multitode.net.broadcast, "itd", "exit_to_menu", {})
    if not ok then
        logger:e("Failed to broadcast exit to menu: %s", tostring(err))
        return false
    end

    logger:i("Broadcasted exit to menu")
    return true
end

local function perform_local_exit_to_menu()
    local systems = get_current_systems()
    if systems == nil then
        return
    end

    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo ~= nil and sessionInfo.sessionActive then
        local role = multitode.state().role
        if role == "CLIENT" then
            logger:i("Ignored client exit to menu; only the host can end the session")
            return
        end
        if (role == "HOST" or role == "HOST_AND_CLIENT") and not broadcast_exit_to_menu() then
            return
        end
    end

    go_to_main_menu()
end

local function request_local_exit_to_menu()
    local systems = get_current_systems()
    if systems == nil then
        return
    end

    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo ~= nil and sessionInfo.sessionActive and multitode.state().role == "CLIENT" then
        logger:i("Ignored client exit to menu; only the host can end the session")
        return
    end

    if not systems.gameValue:getBooleanValue(C.GameValueType.GAME_SAVES) then
        C.Dialog:i():showConfirm(
            C.Game.i.localeManager.i18n:get("game_cant_be_continued_confirm"),
            C.Runnable(perform_local_exit_to_menu)
        )
        return
    end

    perform_local_exit_to_menu()
end

local function trigger_manual_game_over()
    local systems = get_current_systems()
    if systems == nil or systems.gameState == nil or systems.gameState:isGameOver() then
        return
    end

    if systems._gameUi ~= nil and systems._gameUi.pauseMenu ~= nil then
        systems._gameUi.pauseMenu:setVisible(false)
    end
    systems.gameState:triggerGameOver(C.GameOverReason.MANUAL)
end

local function perform_local_end_game()
    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo ~= nil and sessionInfo.sessionActive then
        local role = multitode.state().role
        if role == "CLIENT" then
            logger:i("Ignored client end game; only the host can end the game")
            return
        end
        if role == "HOST" or role == "HOST_AND_CLIENT" then
            local ok, err = pcall(multitode.net.broadcast, "itd", "end_game", {})
            if not ok then
                logger:e("Failed to broadcast end game: %s", tostring(err))
                return
            end
            logger:i("Broadcasted end game")
        end
    end

    trigger_manual_game_over()
end

local function request_local_end_game()
    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo ~= nil and sessionInfo.sessionActive and multitode.state().role == "CLIENT" then
        logger:i("Ignored client end game; only the host can end the game")
        return
    end

    C.Dialog:i():showConfirm(
        C.Game.i.localeManager.i18n:get("end_game_button_confirm"),
        C.Runnable(perform_local_end_game)
    )
end

local function restart_current_game()
    local systems = get_current_systems()
    if systems == nil or systems.gameState == nil then
        return false
    end

    reset_game_session_state()
    if systems.gameState.replayMode then
        C.GameStateSystem:startReplay(systems.gameState.replayRecord)
    else
        systems.gameState:restartGame(true)
    end
    return true
end

local function perform_local_restart_level()
    local systems = get_current_systems()
    if systems == nil or systems.gameState == nil then
        return
    end

    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo ~= nil and sessionInfo.sessionActive and multitode.state().role == "CLIENT" then
        logger:i("Ignored client restart level; only the host can restart the level")
        return
    end

    local levelName = systems.gameState.basicLevelName
    if levelName ~= nil and C.Game.i.basicLevelManager:getLevel(levelName).canNotBeRestarted then
        C.Notifications:i():addFailure(C.Game.i.localeManager.i18n:get("level_can_not_be_restarted"))
        return
    end

    if sessionInfo ~= nil and sessionInfo.sessionActive then
        local role = multitode.state().role
        if role == "HOST" or role == "HOST_AND_CLIENT" then
            local ok, err = pcall(multitode.net.broadcast, "itd", "restart_level", {})
            if not ok then
                logger:e("Failed to broadcast restart level: %s", tostring(err))
                return
            end
            logger:i("Broadcasted restart level")
        end
    end

    restart_current_game()
end

local function request_local_restart_level()
    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo ~= nil and sessionInfo.sessionActive and multitode.state().role == "CLIENT" then
        logger:i("Ignored client restart level; only the host can restart the level")
        return
    end

    C.Dialog:i():showConfirm(
        C.Game.i.localeManager.i18n:get("restart_confirm"),
        C.Runnable(perform_local_restart_level)
    )
end

local function find_actor_by_name(actor, targetName)
    if actor == nil then
        return nil
    end
    if actor:getName() == targetName then
        return actor
    end

    local ok, children = pcall(function()
        return actor:getChildren()
    end)
    if not ok or children == nil then
        return nil
    end

    for i = 1, children.size do
        local found = find_actor_by_name(children.items[i], targetName)
        if found ~= nil then
            return found
        end
    end
    return nil
end

local function find_right_menu_button_by_text(actor, targetText)
    if actor == nil then
        return nil
    end
    if C.RightSideMenuButton:_isInstance(actor) then
        local children = actor:getChildren()
        for i = 1, children.size do
            local ok, text = pcall(function()
                return children.items[i]:getText()
            end)
            if ok and text ~= nil and tostring(text) == targetText then
                return actor
            end
        end
    end

    local ok, children = pcall(function()
        return actor:getChildren()
    end)
    if not ok or children == nil then
        return nil
    end
    for i = 1, children.size do
        local found = find_right_menu_button_by_text(children.items[i], targetText)
        if found ~= nil then
            return found
        end
    end
    return nil
end

local function install_pause_menu_action_probes()
    local systems = get_current_systems()
    if systems == nil then
        itdNet.exitMenuPatchedButtonKey = nil
        itdNet.endGamePatchedButtonKey = nil
        itdNet.restartLevelPatchedButtonKey = nil
        itdNet.actionProbeSessionKey = nil
        return false
    end

    local sessionKey = get_session_key(systems)
    if sessionKey ~= itdNet.actionProbeSessionKey then
        itdNet.exitMenuPatchedButtonKey = nil
        itdNet.endGamePatchedButtonKey = nil
        itdNet.restartLevelPatchedButtonKey = nil
        itdNet.actionProbeSessionKey = sessionKey
    end
    if itdNet.exitMenuPatchedButtonKey ~= nil
            and itdNet.endGamePatchedButtonKey ~= nil
            and itdNet.restartLevelPatchedButtonKey ~= nil then
        return false
    end

    local installed = false
    local root = C.Game.i.uiManager.stage:getRoot()
    local exitButton = find_actor_by_name(root, "pause_menu_main_menu_button")
    if itdNet.exitMenuPatchedButtonKey == nil then
        if exitButton ~= nil then
            exitButton:setClickHandler(C.Runnable(request_local_exit_to_menu))
            itdNet.exitMenuPatchedButtonKey = tostring(exitButton)
            installed = true
            logger:i("Installed host-authoritative exit-to-menu handler")
        end
    end

    local pauseMenuContainer = exitButton ~= nil and exitButton:getParent() or nil
    if itdNet.endGamePatchedButtonKey == nil then
        local endGameButton = find_right_menu_button_by_text(
            pauseMenuContainer,
            tostring(C.Game.i.localeManager.i18n:get("end_game_button_text"))
        )
        if endGameButton ~= nil then
            endGameButton:setClickHandler(C.Runnable(request_local_end_game))
            itdNet.endGamePatchedButtonKey = tostring(endGameButton)
            installed = true
            logger:i("Installed host-authoritative end-game handler")
        end
    end

    if itdNet.restartLevelPatchedButtonKey == nil then
        local restartLevelButton = find_right_menu_button_by_text(
            pauseMenuContainer,
            tostring(C.Game.i.localeManager.i18n:get("restart"))
        )
        if restartLevelButton ~= nil then
            restartLevelButton:setClickHandler(C.Runnable(request_local_restart_level))
            itdNet.restartLevelPatchedButtonKey = tostring(restartLevelButton)
            installed = true
            logger:i("Installed host-authoritative restart-level handler")
        end
    end
    return installed
end

local function get_bonus_overlay(systems)
    if systems == nil or systems._gameUi == nil then
        return nil
    end
    return systems._gameUi.gameplayBonusesOverlay
end

local function apply_bonus_menu_visibility(visible, revision, selectionRequired)
    visible = not not visible
    selectionRequired = not not selectionRequired
    revision = tonumber(revision) or itdNet.bonusMenuRevision
    if revision < itdNet.bonusMenuRevision then
        return false
    end

    local systems = get_current_systems()
    local overlay = get_bonus_overlay(systems)
    if overlay == nil then
        return false
    end

    itdNet.bonusMenuRevision = revision
    if visible and selectionRequired then
        local stage = systems.bonus ~= nil and systems.bonus:getStageToChooseBonusFor() or nil
        local currentTick = get_current_tick()
        if stage == nil or (itdNet.pendingBonusActionTick ~= nil and currentTick <= itdNet.pendingBonusActionTick) then
            itdNet.pendingBonusMenuState = {
                visible = true,
                revision = revision,
                selection_required = true
            }
            return false
        end
    else
        itdNet.pendingBonusMenuState = nil
    end

    itdNet.bonusMenuObservedVisible = visible
    if overlay:isVisible() == visible then
        return true
    end

    itdNet.bonusMenuApplyDepth = itdNet.bonusMenuApplyDepth + 1
    local ok, err = pcall(function()
        if visible then
            overlay:show()
        else
            overlay:hide()
        end
    end)
    itdNet.bonusMenuApplyDepth = math.max(0, itdNet.bonusMenuApplyDepth - 1)
    if not ok then
        logger:e("Failed to apply bonus menu visibility %s: %s", tostring(visible), tostring(err))
        return false
    end

    logger:i("Applied authoritative bonus menu visibility=%s revision=%s", tostring(visible), tostring(revision))
    return true
end

local function apply_pending_bonus_menu_state()
    local pending = itdNet.pendingBonusMenuState
    if pending == nil then
        return false
    end

    if apply_bonus_menu_visibility(pending.visible, pending.revision, pending.selection_required) then
        itdNet.pendingBonusMenuState = nil
        return true
    end
    return false
end

local function publish_bonus_menu_visibility(visible, sourcePlayerId, selectionRequired)
    selectionRequired = visible and not not selectionRequired
    itdNet.bonusMenuRevision = itdNet.bonusMenuRevision + 1
    local revision = itdNet.bonusMenuRevision
    if not apply_bonus_menu_visibility(visible, revision, selectionRequired) then
        return false
    end

    multitode.net.broadcast("itd", "bonus_menu_state", {
        visible = not not visible,
        revision = revision,
        selection_required = selectionRequired
    })
    logger:i(
        "Published bonus menu visibility=%s revision=%s from player=%s",
        tostring(visible),
        tostring(revision),
        tostring(sourcePlayerId)
    )
    return true
end

local function probe_bonus_menu_visibility()
    local systems = get_current_systems()
    local overlay = get_bonus_overlay(systems)
    if overlay == nil then
        itdNet.bonusMenuSessionKey = nil
        itdNet.bonusMenuObservedVisible = nil
        return false
    end

    local sessionKey = get_session_key(systems)
    local visible = overlay:isVisible()
    if sessionKey ~= itdNet.bonusMenuSessionKey then
        itdNet.bonusMenuSessionKey = sessionKey
        itdNet.bonusMenuObservedVisible = false
        if not visible then
            return true
        end
    end
    if itdNet.bonusMenuApplyDepth > 0 or visible == itdNet.bonusMenuObservedVisible then
        return false
    end

    itdNet.bonusMenuObservedVisible = visible
    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo == nil or not sessionInfo.sessionActive then
        return true
    end

    -- Selecting a bonus hides the local overlay before its queued action is
    -- captured. Let the authoritative action close remote overlays instead of
    -- resuming them early and triggering forced random selection.
    if not visible and systems.bonus ~= nil and systems.bonus:getStageToChooseBonusFor() ~= nil then
        return true
    end

    local role = multitode.state().role
    local selectionRequired = visible
        and systems.bonus ~= nil
        and systems.bonus:getStageToChooseBonusFor() ~= nil
    if role == "CLIENT" then
        multitode.net.sendToHost("itd", "bonus_menu_request", {
            visible = visible,
            selection_required = selectionRequired
        })
    elseif role == "HOST" or role == "HOST_AND_CLIENT" then
        publish_bonus_menu_visibility(visible, sessionInfo.localPlayerId, selectionRequired)
    end
    return true
end

local function install_bonus_event_listeners()
    local systems = get_current_systems()
    local sessionKey = get_session_key(systems)
    if systems == nil or systems.events == nil or sessionKey == itdNet.bonusEventSessionKey then
        return false
    end

    systems.events:getListeners(C.BonusSelect):addWithPriority(C.Listener(function(_)
        local role = multitode.state().role
        if role == "HOST" or role == "HOST_AND_CLIENT" then
            local sessionInfo = multitode.getSessionInfo()
            publish_bonus_menu_visibility(false, sessionInfo and sessionInfo.localPlayerId or 0, false)
        else
            apply_bonus_menu_visibility(false, itdNet.bonusMenuRevision, false)
        end
        itdNet.pendingBonusActionTick = nil
    end), C.EventListeners.PRIORITY_LOWEST)

    systems.events:getListeners(C.BonusesReRoll):addWithPriority(C.Listener(function(_)
        itdNet.pendingBonusActionTick = nil
    end), C.EventListeners.PRIORITY_LOWEST)

    itdNet.bonusEventSessionKey = sessionKey
    logger:i("Installed bonus synchronization listeners for current session")
    return true
end

local function apply_auto_wave_state(enabled)
    if type(enabled) ~= "boolean" then
        error("auto-wave enabled state must be a boolean")
    end

    local systems = get_current_systems()
    if systems == nil or systems.wave == nil then
        logger:w("Ignoring auto-wave state before game systems are ready")
        return false
    end

    if multitode.itd ~= nil and multitode.itd.applyAuthoritativeAutoWaveState ~= nil then
        multitode.itd.applyAuthoritativeAutoWaveState(enabled)
    else
        systems.wave:setAutoForceWaveEnabled(enabled)
        if systems._gameUi ~= nil and systems._gameUi.mainUi ~= nil then
            systems._gameUi.mainUi:updateForceWaveButton()
        end
    end
    return true
end

function itdNet.getDesiredPauseState()
    return multitode.getApi():isSynchronizedPauseActive()
end

local function is_pause_apply_active()
    return itdNet.pauseApplyDepth > 0 or multitode.getApi():isPauseApplyActive()
end

local function run_pause_apply(fn)
    local api = multitode.getApi()
    itdNet.pauseApplyDepth = itdNet.pauseApplyDepth + 1
    api:beginPauseApply()
    local ok, err = pcall(fn)
    api:endPauseApply()
    itdNet.pauseApplyDepth = math.max(0, itdNet.pauseApplyDepth - 1)
    return ok, err
end

function itdNet.applyAuthoritativePause(paused, revision)
    paused = not not paused
    revision = tonumber(revision) or 0
    if revision < itdNet.pauseRevision then
        logger:i("Ignoring stale pause state revision=%s current=%s", tostring(revision), tostring(itdNet.pauseRevision))
        return false
    end

    itdNet.pauseRevision = revision
    itdNet.pendingPauseState = nil
    itdNet.authoritativePaused = paused
    multitode.getApi():setSynchronizedPauseActive(paused)
    local systems = get_current_systems()
    if systems == nil or systems.state == nil or systems.state:isPaused() == paused then
        return true
    end

    local ok, err = run_pause_apply(function()
        if paused then
            systems.state:pauseGame()
        else
            systems.state:resumeGame()
        end
    end)
    if not ok then
        logger:e("Failed to apply authoritative pause state %s: %s", tostring(paused), tostring(err))
        return false
    end

    logger:i("Applied authoritative pause state=%s revision=%s", tostring(paused), tostring(revision))
    return true
end

function itdNet.applyStartupPauseState(paused)
    if type(paused) ~= "boolean" then
        logger:w("Startup snapshot is missing authoritative pause state")
        return false
    end

    return itdNet.applyAuthoritativePause(paused, itdNet.pauseRevision)
end

function itdNet.scheduleAuthoritativePause(revision)
    C.Threads:i():postRunnable(C.Runnable(function()
        itdNet.applyAuthoritativePause(true, revision)
    end))
end

function itdNet.queueAuthoritativePause(targetTick, revision)
    revision = tonumber(revision) or 0
    if revision < itdNet.pauseRevision then
        return false
    end

    local systems = get_current_systems()
    if systems == nil or systems.state == nil then
        return false
    end

    itdNet.pauseRevision = revision
    itdNet.pendingPauseState = true
    multitode.getApi():setSynchronizedPauseActive(true)
    local action = C.ScriptAction.new_S(string.format(
        "multitode.itdNet.scheduleAuthoritativePause(%d)",
        revision
    ))
    local actionString = tostring(action)
    multitode.approveQueuedAction(targetTick, actionString)
    systems.state:pushAction(action, targetTick)
    return actionString
end

function itdNet.requestPauseState(paused)
    local sessionInfo = multitode.getSessionInfo()
    if sessionInfo == nil or not sessionInfo.sessionActive then
        return false
    end

    local payload = { paused = not not paused }
    if multitode.state().role == "CLIENT" then
        multitode.net.sendToHost("itd", "pause_request", payload)
        return true
    end

    local channelHandlers = multitode.net.handlers and multitode.net.handlers["itd"] or nil
    local handler = channelHandlers and channelHandlers["pause_request"] or nil
    if handler == nil then
        error("missing itd/pause_request host handler")
    end
    handler({
        receiverContext = "HOST",
        messageChannel = "itd",
        messageName = "pause_request",
        senderPlayerId = sessionInfo.localPlayerId
    }, payload)
    return true
end

local function install_pause_menu_probe()
    local systems = get_current_systems()
    local sessionKey = get_session_key(systems)
    if systems == nil or systems.events == nil or sessionKey == itdNet.pauseInstalledSessionKey then
        return false
    end

    systems.events:getListeners(C.GamePaused):addWithPriority(C.Listener(function(_)
        local currentSystems = get_current_systems()
        if currentSystems == nil or is_pause_apply_active() or not currentSystems.state:isPaused() then
            return
        end

        local sessionInfo = multitode.getSessionInfo()
        if sessionInfo == nil or not sessionInfo.sessionActive then
            return
        end

        local ok, err = pcall(itdNet.requestPauseState, true)
        if not ok then
            logger:e("Failed to request pause menu: %s", tostring(err))
        end

        local resumed, resumeError = run_pause_apply(function()
            currentSystems.state:resumeGame()
        end)
        if not resumed then
            logger:e("Failed to cancel local pause menu: %s", tostring(resumeError))
        end
    end), C.EventListeners.PRIORITY_LOWEST)

    systems.events:getListeners(C.GameResumed):addWithPriority(C.Listener(function(_)
        local currentSystems = get_current_systems()
        if currentSystems == nil or is_pause_apply_active() or currentSystems.state:isPaused() or not multitode.getApi():isSynchronizedPauseActive() then
            return
        end

        local sessionInfo = multitode.getSessionInfo()
        if sessionInfo == nil or not sessionInfo.sessionActive then
            return
        end

        local ok, err = pcall(itdNet.requestPauseState, false)
        if not ok then
            logger:e("Failed to request pause menu resume: %s", tostring(err))
        end

        if multitode.state().role == "CLIENT" then
            local paused, pauseError = run_pause_apply(function()
                currentSystems.state:pauseGame()
            end)
            if not paused then
                logger:e("Failed to keep pause menu open pending host approval: %s", tostring(pauseError))
            end
        end
    end), C.EventListeners.PRIORITY_LOWEST)

    itdNet.pauseInstalledSessionKey = sessionKey
    local role = multitode.state().role
    if role == "HOST" or role == "HOST_AND_CLIENT" then
        itdNet.authoritativePaused = systems.state:isPaused()
        multitode.getApi():setSynchronizedPauseActive(itdNet.authoritativePaused)
    elseif multitode.getApi():isSynchronizedPauseActive() and not systems.state:isPaused() then
        itdNet.applyAuthoritativePause(true, itdNet.pauseRevision)
    elseif itdNet.pauseRevision == 0 then
        itdNet.authoritativePaused = systems.state:isPaused()
        multitode.getApi():setSynchronizedPauseActive(itdNet.authoritativePaused)
    end
    logger:i("Installed pause menu synchronization for current session")
    return true
end

function itdNet.reinstallSessionListeners()
    itdNet.pauseInstalledSessionKey = nil
    itdNet.exitMenuPatchedButtonKey = nil
    itdNet.endGamePatchedButtonKey = nil
    itdNet.restartLevelPatchedButtonKey = nil
    itdNet.actionProbeSessionKey = nil
    itdNet.bonusMenuSessionKey = nil
    itdNet.bonusMenuObservedVisible = nil
    itdNet.bonusEventSessionKey = nil
    itdNet.pendingBonusMenuState = nil
    install_pause_menu_probe()
    install_pause_menu_action_probes()
    install_bonus_event_listeners()
end

local function queue_authoritative_pause(targetTick, revision, sourceLabel)
    local systems = get_current_systems()
    if systems == nil or systems.state == nil then
        logger:w("Dropping authoritative pause before game systems are ready")
        return false
    end

    local actionString = itdNet.queueAuthoritativePause(targetTick, revision)
    if actionString == false then
        return false
    end
    table.insert(itdNet.pendingApprovals, {
        target_tick = targetTick,
        action_string = actionString,
        session_key = get_session_key(systems)
    })
    logger:i(
        "%s queued authoritative pause for tick=%s revision=%s",
        tostring(sourceLabel),
        tostring(targetTick),
        tostring(revision)
    )
    return true
end

local function get_pause_target_tick()
    local systems = get_current_systems()
    if systems == nil or systems.state == nil then
        return nil
    end

    local tickRate = tonumber(systems.gameValue:getTickRate()) or 60
    local speed = 1
    if multitode.itd ~= nil and tonumber(multitode.itd.lastSpeed) ~= nil then
        speed = math.max(1, tonumber(multitode.itd.lastSpeed))
    end
    local leadTicks = math.max(MIN_ACTION_LEAD_TICKS, math.ceil(PAUSE_LEAD_MILLIS / 1000 * tickRate * speed))
    return get_current_tick() + leadTicks
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
    local isBonusAction = actionType == "SGB" or actionType == "RRB"
    if isBonusAction and adjustStaleTarget and currentTick >= 0 then
        -- The overlay pauses gameplay. Resume all peers only long enough to
        -- reach this action before the game's three-frame forced fallback.
        effectiveTargetTick = math.max(
            currentTick + MIN_ACTION_LEAD_TICKS,
            (tonumber(envelope.tick) or currentTick) + 1
        )
    elseif adjustStaleTarget and currentTick >= 0 then
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

    -- The host may replace a stale or bonus target. Broadcast the actual tick,
    -- not the requester's original tick.
    envelope.target_tick = effectiveTargetTick

    if isBonusAction then
        local role = multitode.state().role
        if role == "HOST" or role == "HOST_AND_CLIENT" then
            publish_bonus_menu_visibility(false, 0, false)
        else
            apply_bonus_menu_visibility(false, itdNet.bonusMenuRevision, false)
        end
    end

    local action = deserialize_action(payload, actionType, actionJson)
    if action == nil then
        return false
    end

    local actionString = tostring(action)
    multitode.approveQueuedAction(effectiveTargetTick, actionString)
    table.insert(itdNet.pendingApprovals, {
        target_tick = effectiveTargetTick,
        action_string = actionString,
        session_key = get_session_key(systems)
    })
    systems.state:pushAction(action, effectiveTargetTick)

    logger:i(
        "%s queued authoritative action %s for tick %s",
        tostring(sourceLabel),
        tostring(actionString),
        tostring(effectiveTargetTick)
    )

    return effectiveTargetTick
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

function itdNet.getPendingApprovals(currentTick)
    local tick = tonumber(currentTick) or -1
    local systems = get_current_systems()
    local sessionKey = get_session_key(systems)
    local pending = {}
    for _, approval in ipairs(itdNet.pendingApprovals) do
        if approval.session_key == sessionKey and tonumber(approval.target_tick) > tick then
            table.insert(pending, {
                target_tick = approval.target_tick,
                action_string = approval.action_string
            })
        end
    end
    return pending
end

function itdNet.restorePendingApprovals(approvals)
    multitode.resetApprovedQueuedActions()
    itdNet.pendingApprovals = {}
    local systems = get_current_systems()
    if type(approvals) ~= "table" then
        return
    end

    for _, approval in ipairs(approvals) do
        local targetTick = tonumber(approval.target_tick)
        local actionString = approval.action_string
        if targetTick ~= nil and actionString ~= nil then
            actionString = tostring(actionString)
            multitode.approveQueuedAction(targetTick, actionString)
            table.insert(itdNet.pendingApprovals, {
                target_tick = targetTick,
                action_string = actionString,
                session_key = get_session_key(systems)
            })
        end
    end
end

local function should_handle_client_action_apply()
    local ok, state = pcall(multitode.state)
    if not ok or state == nil then
        return false
    end

    return state.role == "CLIENT"
end

local function validate_bonus_action_request(payload, actionType)
    if actionType ~= "SGB" and actionType ~= "RRB" then
        return true
    end

    local currentTick = get_current_tick()
    if itdNet.pendingBonusActionTick ~= nil and currentTick >= itdNet.pendingBonusActionTick then
        itdNet.pendingBonusActionTick = nil
    end
    if itdNet.pendingBonusActionTick ~= nil then
        logger:w("Dropping duplicate bonus action while one is pending for tick %s", tostring(itdNet.pendingBonusActionTick))
        return false
    end

    local systems = get_current_systems()
    local stage = systems ~= nil and systems.bonus ~= nil and systems.bonus:getStageToChooseBonusFor() or nil
    if stage == nil then
        logger:w("Dropping bonus action with no selectable bonus stage")
        return false
    end

    if actionType == "SGB" then
        local actionPayload = payload.payload or {}
        local action = deserialize_action(actionPayload, actionType, actionPayload.actionJson)
        if action == nil or tonumber(action.stage) ~= tonumber(stage:getNumber()) then
            logger:w(
                "Dropping stale bonus selection for stage %s; current stage is %s",
                tostring(action and action.stage or nil),
                tostring(stage:getNumber())
            )
            return false
        end
    end
    return true
end

local function ensure_handlers_registered()
    if itdNet.handlersRegistered then
        return
    end

    multitode.net.onHost("itd", "action_request", function(ctx, payload)
        if multitode.desyncDetection ~= nil and multitode.desyncDetection.isResyncInProgress() then
            logger:w("Dropping action %s from player %s during resync", tostring(payload and payload.action), tostring(ctx.senderPlayerId))
            return
        end

        local actionPayload = payload and payload.payload or nil
        local actionType = actionPayload and actionPayload.queuedType or nil
        if not validate_bonus_action_request(payload, actionType) then
            return
        end

        logger:i(
            "Host received action %s from player %s at tick %s target_tick=%s",
            tostring(payload.action),
            tostring(ctx.senderPlayerId),
            tostring(payload.tick),
            tostring(payload.target_tick)
        )

        payload.sequence = itdNet.nextActionSequence
        itdNet.nextActionSequence = itdNet.nextActionSequence + 1
        local targetTick = enqueue_authoritative_action(payload, "Host", true)
        if not targetTick then
            return
        end
        if actionType == "SGB" or actionType == "RRB" then
            itdNet.pendingBonusActionTick = targetTick
        end
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
        -- All action_apply packets use the same TCP stream, so they are already
        -- ordered. Buffering by sequence can incorrectly discard a valid packet
        -- when the expected sequence was reset by a startup snapshot.
        itdNet.nextExpectedActionSequence = math.max(itdNet.nextExpectedActionSequence, sequence + 1)
        local targetTick = enqueue_authoritative_action(payload, "Client", false)
        local actionPayload = payload.payload or {}
        local actionType = actionPayload.queuedType
        if targetTick and (actionType == "SGB" or actionType == "RRB") then
            itdNet.pendingBonusActionTick = targetTick
        end
    end)

    multitode.net.onHost("itd", "auto_wave_request", function(ctx, payload)
        local enabled = nil
        if payload ~= nil then
            enabled = payload.enabled
        end
        local ok, applied = pcall(apply_auto_wave_state, enabled)
        if not ok then
            logger:e("Rejected auto-wave request from player %s: %s", tostring(ctx.senderPlayerId), tostring(applied))
            return
        end
        if not applied then
            return
        end

        multitode.net.broadcast("itd", "auto_wave_state", { enabled = enabled })
        logger:i("Applied auto-wave state %s from player %s", tostring(enabled), tostring(ctx.senderPlayerId))
    end)

    multitode.net.onClient("itd", "auto_wave_state", function(_, payload)
        if not should_handle_client_action_apply() then
            return
        end

        local enabled = nil
        if payload ~= nil then
            enabled = payload.enabled
        end
        local ok, err = pcall(apply_auto_wave_state, enabled)
        if not ok then
            logger:e("Failed to apply host auto-wave state: %s", tostring(err))
        end
    end)

    multitode.net.onHost("itd", "bonus_menu_request", function(ctx, payload)
        if type(payload) ~= "table"
                or type(payload.visible) ~= "boolean"
                or type(payload.selection_required) ~= "boolean" then
            logger:w("Rejected invalid bonus menu request from player %s", tostring(ctx.senderPlayerId))
            return
        end
        if multitode.desyncDetection ~= nil and multitode.desyncDetection.isResyncInProgress() then
            logger:w("Dropping bonus menu request from player %s during resync", tostring(ctx.senderPlayerId))
            return
        end

        publish_bonus_menu_visibility(payload.visible, ctx.senderPlayerId, payload.selection_required)
    end)

    multitode.net.onClient("itd", "bonus_menu_state", function(_, payload)
        if not should_handle_client_action_apply() or type(payload) ~= "table" then
            return
        end
        if type(payload.visible) ~= "boolean"
                or type(payload.selection_required) ~= "boolean"
                or tonumber(payload.revision) == nil then
            logger:w("Rejected invalid authoritative bonus menu state")
            return
        end

        apply_bonus_menu_visibility(payload.visible, payload.revision, payload.selection_required)
    end)

    multitode.net.onHost("itd", "pause_request", function(ctx, payload)
        if type(payload) ~= "table" or type(payload.paused) ~= "boolean" then
            logger:w("Rejected invalid pause request from player %s", tostring(ctx.senderPlayerId))
            return
        end
        if multitode.desyncDetection ~= nil and multitode.desyncDetection.isResyncInProgress() then
            logger:w("Dropping pause request from player %s during resync", tostring(ctx.senderPlayerId))
            return
        end
        if itdNet.getDesiredPauseState() == payload.paused then
            return
        end

        local revision = multitode.getApi():nextPauseRevision()
        local statePayload = {
            paused = payload.paused,
            revision = revision
        }

        if payload.paused then
            local targetTick = get_pause_target_tick()
            if targetTick == nil then
                logger:w("Dropping pause request before game systems are ready")
                return
            end
            statePayload.target_tick = targetTick
            if not queue_authoritative_pause(targetTick, revision, "Host") then
                return
            end
        else
            itdNet.applyAuthoritativePause(false, revision)
        end

        multitode.net.broadcast("itd", "pause_state", statePayload)
        logger:i(
            "Applied pause request state=%s revision=%s from player=%s",
            tostring(payload.paused),
            tostring(revision),
            tostring(ctx.senderPlayerId)
        )
    end)

    multitode.net.onClient("itd", "pause_state", function(_, payload)
        if not should_handle_client_action_apply() or type(payload) ~= "table" then
            return
        end

        local revision = tonumber(payload.revision)
        if revision == nil or type(payload.paused) ~= "boolean" then
            logger:w("Rejected invalid authoritative pause state")
            return
        end

        if payload.paused then
            local targetTick = tonumber(payload.target_tick)
            if targetTick == nil or targetTick <= get_current_tick() then
                logger:e(
                    "Authoritative pause arrived too late target=%s current=%s; applying immediately",
                    tostring(targetTick),
                    tostring(get_current_tick())
                )
                itdNet.applyAuthoritativePause(true, revision)
                return
            end
            queue_authoritative_pause(targetTick, revision, "Client")
        else
            itdNet.applyAuthoritativePause(false, revision)
        end
    end)

    multitode.net.onClient("itd", "exit_to_menu", function(_)
        if not should_handle_client_action_apply() then
            return
        end

        logger:i("Applying host exit to menu")
        go_to_main_menu()
    end)

    multitode.net.onClient("itd", "end_game", function(_)
        if not should_handle_client_action_apply() then
            return
        end

        logger:i("Applying host end game")
        trigger_manual_game_over()
    end)

    multitode.net.onClient("itd", "restart_level", function(_)
        if not should_handle_client_action_apply() then
            return
        end

        logger:i("Applying host restart level")
        restart_current_game()
    end)

    itdNet.handlersRegistered = true
    logger:i("Multitode ITD network handlers loaded")
end

ensure_handlers_registered()

if not itdNet.pauseLifecycleListenersRegistered then
    C.Game.EVENTS:getListeners(C.SystemsSetup):add(C.Listener(function(_)
        install_pause_menu_probe()
    end))
    C.Game.EVENTS:getListeners(C.SystemsStateRestore):add(C.Listener(function(_)
        itdNet.reinstallSessionListeners()
    end))
    itdNet.pauseLifecycleListenersRegistered = true
end

if not itdNet.pauseRenderProbeRegistered then
    local Render = com.prineside.tdi2.events.global.Render.class
    C.Game.EVENTS:getListeners(Render):add(C.Listener(function(_)
        install_pause_menu_probe()
        install_pause_menu_action_probes()
    end))
    itdNet.pauseRenderProbeRegistered = true
end

if multitode.getApi():claimGlobalHook("bonus-menu-sync-render-probe") then
    local Render = com.prineside.tdi2.events.global.Render.class
    C.Game.EVENTS:getListeners(Render):add(C.Listener(function(_)
        install_bonus_event_listeners()
        apply_pending_bonus_menu_state()
        probe_bonus_menu_visibility()
    end))
    install_bonus_event_listeners()
    probe_bonus_menu_visibility()
end

install_pause_menu_probe()
install_pause_menu_action_probes()
