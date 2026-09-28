local logger = C.TLog:forTag("multitode/bonus_votes.lua")

_G.multitode = _G.multitode or {}
multitode.bonusVote = multitode.bonusVote or {}

local bv = multitode.bonusVote

local CHANNEL = "bonus"
local PAUSE_SPEED = 0.0667
local VOTE_MS = 15000
local HOST_MODE_MS = 180000
local BADGE_LAYER_NAME = "multitode bonus votes"
local CARD_W = 350
local CARD_H = 250
local CARD_PAD = 20
local VOTE_COUNT_STYLE_SIZE = 30
local cast_local_vote
local install_input_blocker
local remove_input_blocker
local install_card_guards
local clear_card_badges

bv.PAUSE_SPEED = PAUSE_SPEED
bv.handlersRegistered = bv.handlersRegistered or false
bv.installedSession = nil

bv.active = false
bv.blocking = false
bv.pauseActive = false
bv.mode = "vote"
bv.stage = nil
bv.optionCount = 3
bv.votes = {}
bv.localVote = nil
bv.deadlineMs = 0
bv.resumeSpeed = 1
bv.resolvedIdx = nil
bv.forcedSelectionSaved = nil
bv.badgeLayer = nil
bv.badgeLabels = {}
bv.cardLabels = bv.cardLabels or {}
bv.cardYouLabels = bv.cardYouLabels or {}
bv.cardCountShown = bv.cardCountShown or {}
bv.cardYouShown = bv.cardYouShown or {}
bv.headerShown = nil
bv.cardGuards = bv.cardGuards or {}
bv.lastTallyAt = 0
-- Pause ticks, for the host/client comparison later:
bv.pauseTick = nil    -- our frozen updateNumber (stable at speed 0)
bv.hostTick = nil     -- the host's frozen tick, from the open message
bv.openAt = 0         -- when open arrived (dup guard + safety pause)
bv.tickCheckPending = false
bv.resyncAfterVote = false
bv.stageNilSince = 0  -- when the client last saw stage==nil while vote active
-- Don't reopen right after an apply: the bonus action needs live ticks to
-- run, so the stage looks pending for a moment.
bv.noReopenBeforeMs = 0
bv.lastReshowAt = 0

local function now_ms()
    local ok, v = pcall(multitode.now_ms)
    if ok and v then
        return tonumber(v) or 0
    end
    return 0
end

local function slog(msg)
    pcall(function()
        multitode.slog("BONUS", msg)
    end)
end

local function is_host_role()
    local ok, st = pcall(multitode.state)
    return ok and st ~= nil and (st.role == "HOST" or st.role == "HOST_AND_CLIENT")
end

-- Single-driver gate: this file runs in BOTH Lua envs (global ScriptManager
-- and game ScriptSystem - check the per-env envboot marker files). Without a
-- gate both sides register listeners and drive host logic on separate bv
-- tables: doubled opens/broadcasts and skipped cooldowns when the menu kept
-- asking twice. Whoever holds the live game systems drives. Fails open only
-- when there's no game screen to check against.
local function bonus_env_owns_drive()
    local owns, determined = true, false
    pcall(function()
        local scr = C.Game.i.screenManager:getCurrentScreen()
        if scr ~= nil and C.GameScreen:_isInstance(scr) and scr.S ~= nil then
            determined = true
            owns = (S ~= nil and (S == scr.S or tostring(S) == tostring(scr.S)))
        end
    end)
    if not determined then
        return true
    end
    return owns == true
end

local function get_self_id()
    local ok, id = pcall(function()
        return multitode.getApi():getLocalPlayerId()
    end)
    if not ok then
        return 0
    end
    return tonumber(id) or 0
end

local function session_active()
    local ok, info = pcall(multitode.getSessionInfo)
    return ok and info ~= nil and info.sessionActive == true
end

local function get_systems()
    -- 87_ is a top-level script and runs before the game-specific S global is
    -- available. Prefer the current GameScreen's S and only fall back to the
    -- global during the short window where the screen is being constructed.
    local ok, screen = pcall(function()
        return C.Game.i.screenManager:getCurrentScreen()
    end)
    if ok and screen ~= nil then
        local okGame, isGame = pcall(function()
            return C.GameScreen:_isInstance(screen)
        end)
        if okGame and isGame and screen.S ~= nil then
            return screen.S
        end
    end
    if S ~= nil and S.bonus ~= nil then
        return S
    end
    return nil
end

local function is_tutorial_level()
    local sys = get_systems()
    if sys == nil or sys.gameState == nil or sys.gameState.basicLevelName == nil then
        return false
    end
    local levelName = tostring(sys.gameState.basicLevelName)
    return levelName:sub(1, 2) == "0."
end

local function get_bonus_mode()
    -- Release runs host-authoritative. The "vote" path below is a dormant v2
    -- stub: leave it alone, just never pick it here.
    -- V2: read the setting again to bring voting back.
    return "host"
end

local function get_stage_info()
    local sys = get_systems()
    if sys == nil then
        return nil, 0, 0
    end
    local ok, stage = pcall(function()
        return sys.bonus:getStageToChooseBonusFor()
    end)
    if not ok or stage == nil then
        return nil, 0, 0
    end
    local optCount = 3
    pcall(function()
        local opts = stage:getBonusesToChooseFrom()
        if opts ~= nil and opts.size ~= nil then
            optCount = tonumber(opts.size) or 3
        end
    end)
    local stageNum = 0
    pcall(function()
        stageNum = tonumber(stage:getNumber()) or 0
    end)
    return stage, stageNum, optCount
end

local function capture_resume_speed()
    local sys = get_systems()
    if sys == nil then
        return 1
    end
    local speed = 1
    pcall(function()
        speed = tonumber(sys.state:getGameSpeed()) or 1
    end)
    if speed < 0.05 then
        speed = tonumber(multitode.itd and multitode.itd.hostSpeed) or 1
        if speed < 0.05 then
            speed = tonumber(multitode.itd and multitode.itd.lastGoodSpeed) or 1
        end
        if speed < 0.05 then
            speed = tonumber(multitode.itd and multitode.itd.lastSpeed) or 1
        end
        if speed < 0.05 then
            speed = 1
        end
    end
    return speed
end

local function force_speed(speed)
    local sys = get_systems()
    if sys == nil then
        return
    end
    -- Peek at the engine speed BEFORE writing: the host bit below needs to
    -- know if the bonus overlay already froze the game on its own.
    local engineBefore = nil
    pcall(function()
        engineBefore = tonumber(sys.state:getGameSpeed())
    end)
    pcall(function()
        if multitode.itd ~= nil then
            multitode.itd.suppressSpeedCapture = true
        end
        sys.state:setGameSpeed(speed)
        if multitode.itd ~= nil then
            multitode.itd.lastSpeed = speed
        end
    end)
    -- Host-authoritative rate: always push speed_state (epoch-ordered) so
    -- clients learn freezes (0) AND resume rates (2x/4x). Relying on SPD
    -- for resume left clients at 1x when the SPD was deduped or lost.
    if is_host_role() then
        pcall(function()
            local itd = multitode.itd
            if itd == nil then
                itd = {}
                multitode.itd = itd
            end
            local frozen = speed < 0.05
            if frozen and engineBefore ~= nil and engineBefore < 0.05 then
                -- Engine was already at 0 - the overlay froze it. Broadcasting
                -- that would slam every client to 0 wherever they happen to
                -- be (they trail the host), freezing them at the wrong tick
                -- and splitting kill counts at the pause. They freeze on
                -- their own when they see the stage; the vote comes by open.
                itd.hostSpeed = 0
                slog("FROZEN engine already at 0 - skipping speed_state broadcast")
                return
            end
            itd.speedStateEpoch = (tonumber(itd.speedStateEpoch) or 0) + 1
            itd.hostSpeed = frozen and 0 or speed
            local tick = 0
            pcall(function()
                if sys ~= nil and sys.state ~= nil then
                    tick = sys.state.updateNumber or 0
                end
            end)
            local payload = {
                speed = frozen and 0 or speed,
                epoch = itd.speedStateEpoch,
                tick = tick
            }
            if frozen then
                payload.frozen = true
            end
            multitode.net.broadcast("itd", "speed_state", payload)
            slog(string.format("%s broadcast epoch=%s speed=%.4f",
                frozen and "FROZEN" or "SPEED",
                tostring(itd.speedStateEpoch), frozen and 0 or speed))
        end)
    end
end

-- Called by the authoritative speed probe before it captures/broadcasts a
-- speed change. This is intentionally independent of the GameStateTick
-- listener installation: 70_ can run a few frames before 87_'s lazy screen
-- retry, and the overlay's own setGameSpeed(0) must not be broadcast as 1x.
bv.armPauseForStage = function()
    if not session_active() or is_tutorial_level() or bv.pauseActive then
        return false
    end
    local stage = get_stage_info()
    if stage == nil then
        return false
    end
    bv.resumeSpeed = capture_resume_speed()
    bv.pauseActive = true
    if multitode.itd ~= nil then
        multitode.itd.bonusPauseActive = true
    end
    force_speed(0)
    -- Frozen (or was already), so updateNumber can't move: this is the exact
    -- pause tick, safe to compare against the host's later.
    pcall(function()
        local sys = get_systems()
        if sys ~= nil and sys.state ~= nil then
            bv.pauseTick = tonumber(sys.state.updateNumber)
        end
    end)
    return true
end

local function broadcast_spd(speed)
    if not is_host_role() then
        return
    end
    pcall(function()
        local sys = get_systems()
        local channelHandlers = multitode.net.handlers and multitode.net.handlers["itd"] or nil
        local requestHandler = channelHandlers and channelHandlers["action_request"] or nil
        if requestHandler == nil or sys == nil or sys.state == nil then
            return
        end
        local sessionInfo = multitode.getSessionInfo()
        requestHandler({
            receiverContext = "HOST",
            messageChannel = "itd",
            messageName = "action_request",
            senderPlayerId = sessionInfo ~= nil and sessionInfo.localPlayerId or 0
        }, {
            action = "SPD",
            tick = sys.state.updateNumber,
            target_tick = sys.state.updateNumber,
            sent_wall = (os.clock and os.clock()) or 0,
            lead_ms = 0,
            payload = {
                speed = speed,
                queuedType = "SPD",
                actionJson = "{}"
            }
        })
    end)
end

local function disable_force_immediate()
    local sys = get_systems()
    if sys == nil then
        return
    end
    pcall(function()
        local cfg = sys.bonus:getStagesConfig()
        if cfg == nil then
            return
        end
        if bv.forcedSelectionSaved == nil then
            bv.forcedSelectionSaved = (cfg.forceImmediateSelection == true)
        end
        cfg.forceImmediateSelection = false
    end)
end

local function restore_force_immediate()
    local sys = get_systems()
    if bv.forcedSelectionSaved == nil then
        return
    end
    local saved = bv.forcedSelectionSaved
    bv.forcedSelectionSaved = nil
    if sys == nil then
        return
    end
    pcall(function()
        local cfg = sys.bonus:getStagesConfig()
        if cfg ~= nil then
            cfg.forceImmediateSelection = saved
        end
    end)
end

local function hide_overlay()
    pcall(function()
        local sys = get_systems()
        if sys ~= nil and sys._gameUi ~= nil and sys._gameUi.gameplayBonusesOverlay ~= nil then
            sys._gameUi.gameplayBonusesOverlay:hide()
        end
    end)
end

local function remaining_sec()
    if not bv.active then
        return 0
    end
    local left = (tonumber(bv.deadlineMs) or 0) - now_ms()
    if left < 0 then
        return 0
    end
    return left / 1000
end

local function stringify_votes(votes)
    local out = {}
    for k, v in pairs(votes or {}) do
        out[tostring(k)] = tonumber(v) or 0
    end
    return out
end

local function get_member_ids()
    local ids = {}
    pcall(function()
        if multitode.lobby ~= nil and multitode.lobby.players ~= nil then
            for id, info in pairs(multitode.lobby.players) do
                local numericId = tonumber(id)
                if numericId ~= nil and (info == nil or info.connected ~= false) then
                    ids[#ids + 1] = numericId
                end
            end
        end
    end)
    if #ids == 0 then
        local selfId = get_self_id()
        if selfId ~= 0 then
            ids[1] = selfId
        end
    end
    return ids
end

local function all_voted()
    local members = get_member_ids()
    if #members == 0 then
        return false
    end
    for i = 1, #members do
        if bv.votes[members[i]] == nil then
            return false
        end
    end
    return true
end

local function clear_badges()
    remove_input_blocker()
    clear_card_badges()
    pcall(function()
        for i = 1, #bv.badgeLabels do
            local label = bv.badgeLabels[i]
            if label ~= nil then
                label:remove()
            end
        end
    end)
    bv.badgeLabels = {}
    bv.headerShown = nil
    pcall(function()
        if bv.badgeLayer ~= nil then
            bv.badgeLayer:remove()
            bv.badgeLayer = nil
        end
    end)
end

local function get_overlay_root()
    local root = nil
    pcall(function()
        local mainLayers = C.MainUiLayer.values
        local layerGroups = C.Game.i.uiManager.layers
        for i = 1, #mainLayers do
            local group = layerGroups[i]
            if group ~= nil and group.size ~= nil then
                for j = 1, group.size do
                    local layer = group:get(j - 1)
                    if layer ~= nil and tostring(layer.name) == "AbilitySelectionOverlay main" then
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

local function ensure_badge_layer()
    if bv.badgeLayer ~= nil then
        return bv.badgeLayer
    end
    local ok, layer = pcall(function()
        return C.Game.i.uiManager:addLayer(C.MainUiLayer.SCREEN, 209, BADGE_LAYER_NAME)
    end)
    if not ok or layer == nil then
        return nil
    end
    bv.badgeLayer = layer
    bv.badgeLabels = {}
    pcall(function()
        local root = layer:getTable()
        if root ~= nil then
            root:setTouchable(C.Touchable.disabled)
            -- Badges live at the top: centered put the countdown on the cards.
            root:top()
        end
    end)
    return layer
end

local function get_overlay_card_tables()
    local cards = {}
    local sys = get_systems()
    if sys == nil or sys._gameUi == nil then
        return cards
    end
    local root = get_overlay_root()
    if root == nil then
        return cards
    end
    local function visit(actor)
        if actor == nil then
            return
        end
        local okW, width = pcall(function() return tonumber(actor:getWidth()) end)
        local okH, height = pcall(function() return tonumber(actor:getHeight()) end)
        if okW and okH and width ~= nil and height ~= nil
            and width >= 340 and width <= 360 and height >= 240 and height <= 260 then
            cards[#cards + 1] = actor
            return
        end
        local okChildren, children = pcall(function() return actor:getChildren() end)
        if okChildren and children ~= nil then
            for i = 1, children.size do
                visit(children.items[i])
            end
        end
    end
    visit(root)
    return cards
end

local function actor_is_descendant_of(actor, ancestor)
    if actor == nil or ancestor == nil then
        return false
    end
    local ok, result = pcall(function()
        return actor:isDescendantOf(ancestor)
    end)
    return ok and result == true
end

local function clear_descendant_listeners(actor, depth)
    -- Only strip listeners on the card root (and shallow button wrappers).
    -- clearListeners() on the ENTIRE subtree wiped hover/press handlers on
    -- labels and nested widgets, breaking the overlay after a vote opened.
    -- Our capture listener is installed on the card root, so it still sees
    -- (and can cancel) touches that target any descendant.
    if actor == nil or (depth or 0) > 2 then
        return
    end
    pcall(function() actor:clearListeners() end)
    local ok, children = pcall(function() return actor:getChildren() end)
    if ok and children ~= nil then
        for i = 1, children.size do
            local child = children.items[i]
            -- Clear only interactive button-like children, not labels/images.
            local clearChild = false
            pcall(function()
                if C.ComplexButton ~= nil and C.ComplexButton:_isInstance(child) then
                    clearChild = true
                elseif C.LabelToggleButton ~= nil and C.LabelToggleButton:_isInstance(child) then
                    clearChild = true
                elseif C.PaddedImageButton ~= nil and C.PaddedImageButton:_isInstance(child) then
                    clearChild = true
                end
            end)
            if clearChild then
                clear_descendant_listeners(child, (depth or 0) + 1)
            end
        end
    end
end

local function actor_is_multitode_floating_button(actor)
    local current = actor
    for _ = 1, 8 do
        if current == nil then
            return false
        end
        local name = nil
        pcall(function() name = tostring(current:getName()) end)
        if name == "multitode floating button" then
            return true
        end
        local okParent, parent = pcall(function() return current:getParent() end)
        if not okParent then
            return false
        end
        current = parent
    end
    return false
end

local function is_vote_ui_actor(actor)
    if actor == nil then
        return false
    end
    if bv.badgeLayer ~= nil then
        local layerTable = nil
        pcall(function() layerTable = bv.badgeLayer:getTable() end)
        if actor_is_descendant_of(actor, layerTable) then
            return true
        end
    end
    local overlayRoot = get_overlay_root()
    if overlayRoot ~= nil and actor_is_descendant_of(actor, overlayRoot) then
        return true
    end
    -- The marks menu (found by title - it can belong to the other env, so no
    -- file-local ref can see it): never block its buttons, even mid-vote.
    -- People mark while waiting on a host pick, and a dead Close button
    -- looks like a permanently stuck window.
    local inMarks = false
    pcall(function()
        local layer = C.Game.i.uiManager:getWindowsLayer():getTable()
        if layer == nil then return end
        local kids = layer:getChildren()
        if kids == nil then return end
        for i = 0, (tonumber(kids.size) or 0) do
            local w = nil
            pcall(function() w = kids.items[i] end)
            if w ~= nil then
                local okT, title = pcall(function() return w:getTitle() end)
                -- StringBuilder: compare tostring(title), never the userdata.
                if okT and tostring(title) == "Marks (Ctrl+M)" then
                    if actor_is_descendant_of(actor, w) then
                        inMarks = true
                    end
                    break
                end
            end
        end
    end)
    if inMarks then
        return true
    end
    return false
end

-- Block game input while the vote overlay is open, but never block the
-- floating MULTITODE button. This is installed as a capture listener on the
-- gameplay stage, so it runs before card/game actors can consume the click.
bv.inputBlocker = nil
install_input_blocker = function()
    if bv.inputBlocker ~= nil then
        return
    end
    local sys = get_systems()
    if sys == nil or sys._gameUi == nil or sys._gameUi.mainUi == nil then
        return
    end
    local stage = nil
    pcall(function()
        stage = C.Game.i.uiManager.stage
    end)
    if stage == nil then
        return
    end
    local ok, blocker = pcall(function()
        -- createProxy(C.InputEvent-listener) always threw here (InputListener
        -- is a class, not an interface, and proxies are whitelist-gated). The
        -- pcall swallowed it so no guard ever installed and vote clicks fell
        -- through. C.EventListener(fn) is what actually works (see 90_/92_).
        -- A capture listener sees every event type, so filter to touchDown;
        -- root capture runs first with the target already set (Actor.fire).
        return C.EventListener(function(event)
            if not bv.blocking or not bv.active then
                return false
            end
            if not C.InputEvent:_isInstance(event) then
                return false
            end
            if event:getType() ~= C.InputEvent.Type.touchDown then
                return false
            end
            -- The floating button is a stage actor, not part of any card.
            -- Leave it clickable while everything else is blocked.
            local target = nil
            pcall(function() target = event:getTarget() end)
            if target ~= nil and is_vote_ui_actor(target) then
                return false
            end
            if actor_is_multitode_floating_button(target) then
                return false
            end
            pcall(function() event:stop() end)
            pcall(function() event:cancel() end)
            return true
        end)
    end)
    if not ok or blocker == nil then
        return
    end
    pcall(function()
        stage:addCaptureListener(blocker)
        bv.inputBlocker = blocker
        bv.inputBlockerStage = stage
    end)
end

remove_input_blocker = function()
    if bv.inputBlocker == nil then
        return
    end
    pcall(function()
        if bv.inputBlockerStage ~= nil then
            bv.inputBlockerStage:removeCaptureListener(bv.inputBlocker)
        end
    end)
    bv.inputBlocker = nil
    bv.inputBlockerStage = nil
end

clear_card_badges = function()
    pcall(function()
        for i = 1, #(bv.cardGuards or {}) do
            local entry = bv.cardGuards[i]
            if entry ~= nil and entry.actor ~= nil and entry.listener ~= nil then
                pcall(function() entry.actor:removeCaptureListener(entry.listener) end)
            end
        end
        for i = 1, #(bv.cardLabels or {}) do
            local label = bv.cardLabels[i]
            if label ~= nil then
                pcall(function() label:remove() end)
            end
        end
        for i = 1, #(bv.cardYouLabels or {}) do
            local label = bv.cardYouLabels[i]
            if label ~= nil then
                pcall(function() label:remove() end)
            end
        end
    end)
    bv.cardGuards = {}
    bv.cardLabels = {}
    bv.cardYouLabels = {}
    bv.cardCountShown = {}
    bv.cardYouShown = {}
end

install_card_guards = function()
    if not bv.active or not bv.blocking then
        return
    end
    install_input_blocker()
    local cards = get_overlay_card_tables()
    if #cards ~= bv.optionCount then
        return
    end
    -- Host clicks go through our guard too: click -> local vote ->
    -- resolve("host-picked") -> apply, which broadcasts to the client. Letting
    -- the native handler run skipped all of that - no apply ever reached the
    -- client and it sat on "Waiting for host" forever. The real SGB still goes
    -- out through apply_choice's selectBonusAction.
    -- Reinstall when the overlay got rebuilt (show()/reroll make fresh card
    -- actors): guards pointing at dead actors never fire, while the count
    -- check alone would still look fine.
    local guardsFresh = (#bv.cardGuards == #cards and #bv.cardLabels == #cards and #bv.cardYouLabels == #cards)
    if guardsFresh then
        for i = 1, #cards do
            if bv.cardGuards[i] == nil or bv.cardGuards[i].actor ~= cards[i] then
                guardsFresh = false
                break
            end
        end
    end
    if guardsFresh then
        return
    end
    clear_card_badges()
    for i = 1, #cards do
        local card = cards[i]
        local ok, listener = pcall(function()
            -- Same createProxy story as the stage blocker above: it always
            -- threw, no guard installed, and the strip below still killed the
            -- native handlers - dead cards, no votes at all. Capture runs root-down so we see the touch before the
            -- native button does; stop()+cancel() kills it there.
            -- Capture runs root->down, so this fires BEFORE the native card
            -- button handlers; stop()+cancel() aborts them entirely.
            return C.EventListener(function(event)
                if not bv.active or not bv.blocking then
                    return false
                end
                if not C.InputEvent:_isInstance(event) then
                    return false
                end
                if event:getType() ~= C.InputEvent.Type.touchDown then
                    return false
                end
                -- Every click (host's included) becomes a local vote here: in
                -- host mode that resolves and applies straight away with an
                -- "apply" broadcast, so the client always hears it. Native
                -- handlers never run, so nothing selects+hides early.
                pcall(function() event:stop() end)
                pcall(function() event:cancel() end)
                cast_local_vote(i - 1)
                return true
            end)
        end)
        if ok and listener ~= nil then
            -- Strip native handlers FIRST, then install our capture guard:
            -- clearListeners() wipes capture listeners too, so guard-then-
            -- strip deleted our own guard on every install and native clicks
            -- walked straight into real bonus picks. (SGB fallback in
            -- onQueuedBonusAction stays as backup either way.)
            clear_descendant_listeners(card, 0)
            pcall(function()
                card:addCaptureListener(listener)
                bv.cardGuards[#bv.cardGuards + 1] = { actor = card, listener = listener }
            end)
        end
    end
end

local function tally_counts()
    local counts = {}
    for i = 1, bv.optionCount do
        counts[i] = 0
    end
    for _, idx in pairs(bv.votes or {}) do
        local n = (tonumber(idx) or -1) + 1
        if counts[n] ~= nil then
            counts[n] = counts[n] + 1
        end
    end
    return counts
end

local function update_badges()
    if not bv.active then
        return
    end
    local layer = ensure_badge_layer()
    if layer == nil then
        return
    end
    local tableRoot = nil
    pcall(function()
        tableRoot = layer:getTable()
    end)
    if tableRoot == nil then
        return
    end

    local counts = tally_counts()
    local remainSec = math.ceil(remaining_sec())
    local header
    if bv.mode == "host" then
        if is_host_role() then
            header = string.format("Host picks  %ds  - click a boost!", remainSec)
        else
            header = string.format("Waiting for host  %ds", remainSec)
        end
    else
        header = string.format("Boost vote  %ds  - click a boost!", remainSec)
    end

    if #bv.badgeLabels == 0 then
        local okHeader, headerLabel = pcall(function()
            local label = C.Label.new(header, C.Game.i.assetManager:getLabelStyle(21))
            label:setColor(C.MaterialColor.AMBER.P400)
            label:setAlignment(1)
            tableRoot:add(label):width(640):padTop(4):row()
            return label
        end)
        if okHeader and headerLabel ~= nil then
            bv.badgeLabels[1] = headerLabel
            bv.headerShown = header
        end
    end

    -- Countdown first: the card section below is best-effort and must never
    -- take the timer down with it (a wedged card section once froze it).
    if bv.headerShown ~= header and bv.badgeLabels[1] ~= nil then
        bv.headerShown = header
        pcall(function()
            bv.badgeLabels[1]:setText(header)
        end)
    end

    pcall(install_card_guards)
    local cards = get_overlay_card_tables()
    if #cards == bv.optionCount then
        for i = 1, #cards do
            local countText = tostring(math.floor(tonumber(counts[i] or 0)))
            if bv.cardLabels[i] == nil then
                local okLabel, label = pcall(function()
                    local l = C.Label.new(countText,
                        C.Game.i.assetManager:getLabelStyle(VOTE_COUNT_STYLE_SIZE))
                    l:setColor(C.MaterialColor.LIGHT_GREEN.P400)
                    l:setAlignment(1)
                    l:setTouchable(C.Touchable.disabled)
                    cards[i]:addActor(l)
                    l:setSize(CARD_W, 42)
                    l:setPosition(0, CARD_H + 4)
                    return l
                end)
                if okLabel and label ~= nil then
                    bv.cardLabels[i] = label
                    bv.cardCountShown[i] = countText
                end
            elseif bv.cardCountShown[i] ~= countText then
                bv.cardCountShown[i] = countText
                local label = bv.cardLabels[i]
                if label ~= nil then
                    pcall(function()
                        label:setTextFromInt(math.floor(tonumber(counts[i] or 0)))
                    end)
                end
            end
            -- Stacked above each card, bottom to top: the count ("0" .. N)
            -- sits on the card edge, ">>YOU<<" gets its own row above it so
            -- you always see your own pick. The marker always exists (empty =
            -- invisible) so nothing jumps around.
            if bv.cardYouLabels[i] == nil then
                local okYou, youLabel = pcall(function()
                    local l = C.Label.new("", C.Game.i.assetManager:getLabelStyle(VOTE_COUNT_STYLE_SIZE))
                    l:setColor(C.MaterialColor.AMBER.P400)
                    l:setAlignment(1)
                    l:setTouchable(C.Touchable.disabled)
                    cards[i]:addActor(l)
                    l:setSize(CARD_W, 34)
                    l:setPosition(0, CARD_H + 4 + 44)
                    return l
                end)
                if okYou and youLabel ~= nil then
                    bv.cardYouLabels[i] = youLabel
                    bv.cardYouShown[i] = ""
                end
            end
            local youText = (bv.localVote == i - 1) and ">>YOU<<" or ""
            if bv.cardYouLabels[i] ~= nil and bv.cardYouShown[i] ~= youText then
                bv.cardYouShown[i] = youText
                local youLabel = bv.cardYouLabels[i]
                pcall(function()
                    youLabel:setText(youText)
                end)
            end
        end
    end
    -- The labels are children of the card actors, so they are positioned
    -- directly above the cards rather than in a separate, drifting HUD.
end

-- Overlay helpers. Order matters: they must stay BELOW get_overlay_root,
-- ensure_badge_layer and update_badges - Lua reads locals top-down, and
-- putting these first made every drive crash on nil.
local function overlay_is_visible()
    local root = get_overlay_root()
    if root == nil then
        return false
    end
    local ok, vis = pcall(function() return root:isVisible() end)
    return ok and vis == true
end

local function reshow_overlay_for_vote()
    -- Keep-open watchdog: the native overlay hides on any native card click
    -- (select + hide) and on dim-background clicks (DarkOverlay caller).
    -- While a vote is live the screen stays up, so re-show it if something
    -- hid it. show() rebuilds the cards, so drop old guards/labels first -
    -- update_badges puts them back on the fresh actors next pump.
    local shown = false
    pcall(function()
        local sys = get_systems()
        if sys ~= nil and sys._gameUi ~= nil and sys._gameUi.gameplayBonusesOverlay ~= nil then
            sys._gameUi.gameplayBonusesOverlay:show()
            shown = true
        end
    end)
    if shown then
        clear_card_badges()
        ensure_badge_layer()
        pcall(update_badges)
        slog("overlay re-shown (kept open for vote)")
    end
end

local function enter_pause()
    local first = not bv.pauseActive
    if first then
        if bv.resumeSpeed == nil or bv.resumeSpeed < 0.05 then
            bv.resumeSpeed = capture_resume_speed()
        end
        bv.pauseActive = true
        slog(string.format("PAUSE mode=%s resume=%.4f stage=%s", bv.mode, bv.resumeSpeed, tostring(bv.stage)))
    end
    if multitode.itd ~= nil then
        multitode.itd.bonusPauseActive = true
    end
    -- Freeze at 0. Never SPD-broadcast 0/PAUSE_SPEED (deserialize coerces
    -- <0.05 to 1); clients learn the pause via the open message.
    force_speed(0)
    -- Frozen: updateNumber is stable now, record the exact pause tick.
    pcall(function()
        local sys = get_systems()
        if sys ~= nil and sys.state ~= nil then
            bv.pauseTick = tonumber(sys.state.updateNumber)
        end
    end)
end

local function exit_pause()
    bv.pauseActive = false
    if multitode.itd ~= nil then
        multitode.itd.bonusPauseActive = false
    end
    local resume = tonumber(bv.resumeSpeed) or 1
    if resume < 0.05 then
        resume = 1
    end
    force_speed(resume)
    if is_host_role() then
        if multitode.itd ~= nil then
            multitode.itd.hostSpeed = resume
        end
        broadcast_spd(resume)
    end
    slog(string.format("RESUME speed=%.4f", resume))
end

local function close_vote_internal(reason)
    local itdState = multitode.itd
    local hadAny = bv.active or bv.pauseActive or bv.blocking
        or (itdState ~= nil and itdState.bonusPauseActive == true)
    if not hadAny then
        return
    end
    local wasActive = bv.active
    bv.active = false
    bv.blocking = false
    -- forceImmediateSelection stays disabled for the whole session (restored
    -- only on session end) so the 3-frame auto-random cannot race the next vote.
    clear_badges()
    hide_overlay()
    exit_pause()
    bv.votes = {}
    bv.localVote = nil
    bv.resolvedIdx = nil
    bv.stage = nil
    bv.deadlineMs = 0
    bv.openAt = 0
    bv.stageNilSince = 0
    bv.tickCheckPending = false
    bv.hostTick = nil
    bv.reopenBlockLogged = false
    if wasActive then
        slog("CLOSE reason=" .. tostring(reason))
    end
    -- Fix the divergence AFTER the vote, never during: a mid-vote restore
    -- would rewind the bonus pick and the pause. The request goes out after
    -- resume, so the host snapshots post-vote life and both sides converge
    -- while running.
    if bv.resyncAfterVote and not is_host_role() then
        bv.resyncAfterVote = false
        local ourTick = bv.pauseTick
        pcall(function()
            multitode.net.sendToHost("itd", "resync_request", {
                reason = "bonus_pause_tick",
                tick = ourTick
            })
        end)
        slog("TICK mismatch resync requested after vote close (our pause tick=" ..
            tostring(ourTick) .. ")")
    end
end

bv.close = close_vote_internal
bv.isBlocking = function()
    return bv.blocking == true
end

local function broadcast_tally()
    if not is_host_role() or not bv.active then
        return
    end
    local now = now_ms()
    if now - (bv.lastTallyAt or 0) < 150 and not all_voted() then
        return
    end
    bv.lastTallyAt = now
    pcall(function()
        multitode.net.broadcast(CHANNEL, "tally", {
            stage = bv.stage,
            mode = bv.mode,
            optionCount = bv.optionCount,
            votes = stringify_votes(bv.votes),
            remainingSec = remaining_sec(),
            resumeSpeed = bv.resumeSpeed
        })
    end)
end

local function pick_winner_idx()
    local counts = tally_counts()
    local totalVotes = 0
    for i = 1, bv.optionCount do
        totalVotes = totalVotes + (counts[i] or 0)
    end

    if totalVotes == 0 then
        return math.random(0, bv.optionCount - 1)
    end

    local maxCount = 0
    for i = 1, bv.optionCount do
        if (counts[i] or 0) > maxCount then
            maxCount = counts[i]
        end
    end

    local candidates = {}
    for i = 1, bv.optionCount do
        if (counts[i] or 0) == maxCount then
            candidates[#candidates + 1] = i
        end
    end

    local hostId = nil
    pcall(function()
        if is_host_role() then
            hostId = get_self_id()
        end
    end)
    if hostId ~= nil and hostId ~= 0 and bv.votes[hostId] ~= nil then
        local hostPick = (tonumber(bv.votes[hostId]) or -1) + 1
        for i = 1, #candidates do
            if candidates[i] == hostPick then
                return hostPick - 1
            end
        end
    end

    local chosen = candidates[math.random(#candidates)]
    return chosen - 1
end

local function apply_choice(idx)
    if idx == nil then
        return
    end
    idx = math.max(0, math.min(bv.optionCount - 1, math.floor(tonumber(idx) or 0)))
    bv.resolvedIdx = idx
    bv.blocking = false

    local sys = get_systems()
    if sys ~= nil then
        pcall(function()
            if multitode.itd ~= nil and multitode.itd.allowLocalActions ~= nil then
                multitode.itd.allowLocalActions(function()
                    sys.bonus:selectBonusAction(idx)
                end)
            else
                sys.bonus:selectBonusAction(idx)
            end
        end)
    end

    pcall(function()
        multitode.net.broadcast(CHANNEL, "apply", {
            stage = bv.stage,
            idx = idx,
            mode = bv.mode
        })
    end)
    slog(string.format("APPLY idx=%s mode=%s votes=%s", tostring(idx), bv.mode, tostring((function()
        local n = 0
        for _ in pairs(bv.votes or {}) do n = n + 1 end
        return n
    end)())))

    close_vote_internal("applied")
    -- The bonus action only runs on live ticks, so right after apply (still
    -- ~frozen) the stage looks pending and the render drive would instantly
    -- open a duplicate vote (we watched a second open land 4ms after an
    -- apply). Hold re-opens briefly so the action lands and clears the stage.
    bv.noReopenBeforeMs = now_ms() + 5000
end

local function resolve_now(reason)
    if not bv.active then
        return
    end
    local idx
    if bv.mode == "host" then
        idx = math.random(0, bv.optionCount - 1)
    else
        idx = pick_winner_idx()
    end
    slog(string.format("RESOLVE reason=%s idx=%s", tostring(reason), tostring(idx)))
    apply_choice(idx)
end

local function host_start_vote(stageNum, optCount)
    if bv.active then
        return
    end
    bv.active = true
    bv.blocking = true
    bv.mode = get_bonus_mode()
    bv.stage = stageNum
    bv.optionCount = optCount or 3
    bv.votes = {}
    bv.localVote = nil
    bv.resolvedIdx = nil
    bv.deadlineMs = now_ms() + (bv.mode == "vote" and VOTE_MS or HOST_MODE_MS)
    bv.lastTallyAt = 0
    disable_force_immediate()
    enter_pause()
    ensure_badge_layer()

    local selfId = get_self_id()
    if bv.mode == "vote" then
        -- host has not voted yet; wait for click or timer
    end

    -- Grab the frozen tick for the client's comparison. Paused already (or
    -- armPause just did it), so updateNumber is the exact tick both sides
    -- should be sitting on.
    local hostTick = nil
    pcall(function()
        local sys = get_systems()
        if sys ~= nil and sys.state ~= nil then
            hostTick = tonumber(sys.state.updateNumber)
        end
    end)

    pcall(function()
        multitode.net.broadcast(CHANNEL, "open", {
            stage = bv.stage,
            mode = bv.mode,
            optionCount = bv.optionCount,
            remainingSec = remaining_sec(),
            resumeSpeed = bv.resumeSpeed,
            tick = hostTick
        })
    end)
    slog(string.format("OPEN mode=%s stage=%s opts=%s remain=%.1fs tick=%s", bv.mode, tostring(bv.stage),
        tostring(bv.optionCount), remaining_sec(), tostring(hostTick)))
    broadcast_tally()
end

cast_local_vote = function(idx)
    if not bv.active then
        return false
    end
    idx = math.floor(tonumber(idx) or -1)
    if idx < 0 or idx >= bv.optionCount then
        return false
    end
    local selfId = get_self_id()
    bv.localVote = idx
    bv.votes[selfId] = idx

    if is_host_role() then
        broadcast_tally()
        pcall(update_badges)
        -- Never cut a vote-mode ballot short: clicks are votes, and the boost
        -- screen stays up the whole window (resolving on all-voted hid it
        -- seconds after the first clicks). Host mode still resolves on the
        -- host click: waiting out 3 minutes after they picked would strand
        -- everyone.
        if bv.mode == "host" then
            resolve_now("host-picked")
        end
        return true
    end

    pcall(function()
        multitode.net.sendToHost(CHANNEL, "vote", {
            stage = bv.stage,
            idx = idx
        })
    end)
    pcall(update_badges)
    slog("VOTE send idx=" .. tostring(idx))
    return true
end

-- Called from 70_multitode_itd inspect loop when SGB/RRB is queued.
-- Returns true when the action was consumed (must be neutralized, both roles).
bv.onQueuedBonusAction = function(action, actionType)
    if action == nil then
        return false
    end
    if actionType ~= "SGB" and actionType ~= "RRB" then
        return false
    end
    -- A client must NEVER pick, even with no vote running locally - lagging
    -- clients see their overlay late, guards might not be up yet, the vote
    -- may already be closed. Swallow it all; the host's action_apply lands on
    -- both sides through the pipeline, clients only APPLY.
    if not is_host_role() then
        pcall(function()
            slog(string.format("BLOCK client %s (host-authoritative release)",
                tostring(actionType)))
        end)
        return true
    end
    if not bv.blocking then
        return false
    end

    if actionType == "RRB" then
        if bv.mode == "host" then
            if is_host_role() then
                return false
            end
            slog("BLOCK client RRB during host mode")
            return true
        end
        if is_host_role() then
            return false
        end
        pcall(function()
            multitode.net.sendToHost(CHANNEL, "reroll", { stage = bv.stage })
        end)
        slog("REROLL request sent")
        return true
    end

    -- SGB
    local idx = nil
    pcall(function()
        idx = tonumber(action.bonusIdx)
    end)
    if idx == nil then
        return false
    end

    if bv.mode == "host" then
        if is_host_role() then
            return false
        end
        slog("BLOCK client SGB during host mode idx=" .. tostring(idx))
        return true
    end

    cast_local_vote(idx)
    return true
end

-- One-shot tick check (client only). Once we're frozen and know the host's
-- frozen tick from open, compare: any gap means the two worlds weren't on
-- the same tick when the vote opened (split kill counts at the pause).
-- Remember it and resync AFTER the vote closes (close_vote_internal) - a
-- restore mid-vote would rewind the pick and the pause.
local function maybe_check_pause_tick()
    if not bv.active or not bv.tickCheckPending then
        return
    end
    if not bv.pauseActive or bv.hostTick == nil then
        return
    end
    local localTick = nil
    pcall(function()
        local sys = get_systems()
        if sys ~= nil and sys.state ~= nil then
            localTick = tonumber(sys.state.updateNumber)
        end
    end)
    bv.tickCheckPending = false
    if localTick == nil then
        return
    end
    local diff = localTick - bv.hostTick
    slog(string.format("TICK CMP host=%s local=%s diff=%s",
        tostring(bv.hostTick), tostring(localTick), tostring(diff)))
    if not is_host_role() and diff ~= 0 then
        bv.resyncAfterVote = true
        slog(string.format("TICK MISMATCH - resync scheduled after vote (diff=%s)",
            tostring(diff)))
    end
end

-- One driver for stage watch / freeze / vote life. Runs off BOTH GameStateTick
-- and Render: at speed 0 the engine only services rare one-shot ticks, so the
-- tick path goes quiet mid-pause (the host once sat 16s frozen with no vote
-- at all). Render fires every frame at any speed. Every branch is idempotent
-- (pauseActive / bv.active guards), so doubling up is safe.
local function drive_stage_logic()
    -- Ghost check: one env drives, or votes reopen and messages double
    -- (separate bv tables).
    if not bonus_env_owns_drive() then
        return
    end
    if not session_active() or is_tutorial_level() then
        if bv.active or bv.pauseActive or bv.blocking
            or (multitode.itd ~= nil and multitode.itd.bonusPauseActive == true) then
            close_vote_internal("session-ended")
        end
        restore_force_immediate()
        return
    end

    -- forceImmediateSelection stays off all session; the 3-frame auto-pick
    -- would race any host vote open.
    local sys = get_systems()
    if sys ~= nil and sys.bonus ~= nil then
        disable_force_immediate()
    end

    local stage, stageNum, optCount = get_stage_info()

    -- First glimpse of a bonus stage: freeze on BOTH sides right away (ahead
    -- of host open) so overlay show/hide can't unpause us.
    if stage ~= nil and not bv.pauseActive then
        bv.armPauseForStage()
    end

    if bv.active then
        if stage == nil then
            -- Open can beat our own stage sight (the host runs ahead), so a
            -- missing stage right after open is normal while we catch up.
            -- Only a long absence means it's really gone: close after 5s.
            local t = now_ms()
            if bv.stageNilSince == 0 then
                bv.stageNilSince = t
            elseif (t - bv.stageNilSince) > 5000 and bv.mode ~= "host" then
                -- Host mode waits on the host's apply (no local sight needed);
                -- only vote mode gives up on a stage that never shows.
                close_vote_internal("stage-gone")
                return
            end
        else
            bv.stageNilSince = 0
            -- Keep-open: re-show the overlay if something hid it mid-vote
            -- (native click-through, dim click). Throttled - show() rebuilds
            -- everything, so at most once a second.
            if not overlay_is_visible() then
                local now = now_ms()
                if now - (bv.lastReshowAt or 0) > 1000 then
                    bv.lastReshowAt = now
                    reshow_overlay_for_vote()
                end
            end
        end
        -- Backup: if the stage never shows locally (overlay quirk), freeze
        -- anyway after 3s instead of running free while the host sits paused.
        -- Normally we freeze the moment we see the stage.
        if not bv.pauseActive and bv.openAt ~= 0 and (now_ms() - bv.openAt) > 3000 then
            slog("CLIENT pause safety - stage never seen locally, freezing now")
            enter_pause()
        end
        maybe_check_pause_tick()
        if is_host_role() and now_ms() >= (bv.deadlineMs or 0) then
            resolve_now("timeout")
            return
        end
        update_badges()
        return
    end

    if stage == nil then
        if bv.active or bv.pauseActive or bv.blocking
            or (multitode.itd ~= nil and multitode.itd.bonusPauseActive == true) then
            close_vote_internal("stage-gone")
        end
        return
    end

    if is_host_role() then
        -- Cooldown (see apply_choice): the applied action needs live ticks to
        -- clear the stage; without the hold the vote pops right back open.
        if now_ms() < (bv.noReopenBeforeMs or 0) then
            -- Tripwire: if an OPEN ever sneaks in right after an apply, this
            -- line (or its absence) says whether the gate held.
            if not bv.reopenBlockLogged then
                bv.reopenBlockLogged = true
                slog(string.format("REOPEN BLOCKED stage=%s now=%s holdUntil=%s",
                    tostring(stageNum), tostring(now_ms()),
                    tostring(bv.noReopenBeforeMs)))
            end
            return
        end
        host_start_vote(stageNum, optCount)
    elseif not bv.blocking then
        bv.blocking = true
    end
end

local function register_handlers()
    if bv.handlersRegistered then
        return
    end

    multitode.net.onHost(CHANNEL, "vote", function(ctx, payload)
        -- Ghost check: a second env tallying doubles every message.
        if not bonus_env_owns_drive() then
            return
        end
        if not bv.active or bv.mode ~= "vote" then
            return
        end
        local pid = tonumber(ctx and ctx.senderPlayerId) or 0
        local idx = tonumber(payload and payload.idx)
        if idx == nil or idx < 0 or idx >= bv.optionCount then
            return
        end
        bv.votes[pid] = idx
        slog(string.format("HOST got vote from=%s idx=%s", tostring(pid), tostring(idx)))
        broadcast_tally()
        -- No early resolve here either: vote mode runs the clock out even
        -- when everyone's voted.
    end)

    multitode.net.onHost(CHANNEL, "reroll", function(ctx, payload)
        if not bonus_env_owns_drive() then
            return
        end
        if not bv.active or bv.mode ~= "vote" then
            return
        end
        local sys = get_systems()
        if sys == nil then
            return
        end
        local ok = pcall(function()
            sys.bonus:reRollBonusesAction()
        end)
        slog("HOST reroll ok=" .. tostring(ok))
    end)

    multitode.net.onClient(CHANNEL, "open", function(_, payload)
        -- Ghost check: the loopback env must not run vote state (pause /
        -- resume / guards) on the same live game twice.
        if not bonus_env_owns_drive() then
            return
        end
        if payload == nil then
            return
        end
        -- Seen broadcasts arrive twice for the client (~1ms apart); the rerun
        -- must not wipe the live vote's picks and deadline.
        if bv.active and bv.openAt ~= 0 and (now_ms() - bv.openAt) < 300 then
            slog("CLIENT open duplicate ignored")
            return
        end
        bv.active = true
        bv.blocking = true
        bv.mode = tostring(payload.mode or "vote")
        bv.stage = tonumber(payload.stage) or 0
        bv.optionCount = tonumber(payload.optionCount) or 3
        bv.votes = {}
        bv.localVote = nil
        bv.resolvedIdx = nil
        bv.resumeSpeed = tonumber(payload.resumeSpeed) or 1
        if bv.resumeSpeed < 0.05 then
            bv.resumeSpeed = 1
        end
        local remain = tonumber(payload.remainingSec) or (bv.mode == "vote" and 15 or 180)
        bv.deadlineMs = now_ms() + remain * 1000
        bv.openAt = now_ms()
        bv.hostTick = tonumber(payload.tick)
        bv.tickCheckPending = true
        bv.resyncAfterVote = false
        bv.stageNilSince = 0
        disable_force_immediate()
        -- Freeze where WE see the stage, not where open lands: it can arrive
        -- while we're still catching up (host runs ahead), and pausing on
        -- arrival froze clients at the wrong tick - kills split at the pause.
        -- drive_stage_logic pauses us the moment our stage shows; only pause
        -- here if it's already showing.
        if get_stage_info() ~= nil then
            enter_pause()
        end
        ensure_badge_layer()
        slog(string.format("CLIENT open mode=%s stage=%s remain=%.1fs hostTick=%s stageVisible=%s",
            bv.mode, tostring(bv.stage), remain, tostring(bv.hostTick),
            tostring(get_stage_info() ~= nil)))
        maybe_check_pause_tick()
    end)

    multitode.net.onClient(CHANNEL, "tally", function(_, payload)
        if not bonus_env_owns_drive() then
            return
        end
        if not bv.active or payload == nil then
            return
        end
        if payload.votes ~= nil then
            local votes = {}
            for k, v in pairs(payload.votes) do
                votes[tonumber(k) or k] = tonumber(v) or 0
            end
            bv.votes = votes
        end
        if payload.optionCount ~= nil then
            bv.optionCount = tonumber(payload.optionCount) or bv.optionCount
        end
        if payload.remainingSec ~= nil then
            bv.deadlineMs = now_ms() + (tonumber(payload.remainingSec) or 0) * 1000
        end
        if payload.resumeSpeed ~= nil then
            bv.resumeSpeed = tonumber(payload.resumeSpeed) or bv.resumeSpeed
        end
        update_badges()
    end)

    multitode.net.onClient(CHANNEL, "apply", function(_, payload)
        if not bonus_env_owns_drive() then
            return
        end
        if payload == nil then
            return
        end
        bv.resolvedIdx = tonumber(payload.idx)
        bv.blocking = false
        close_vote_internal("client-apply")
    end)

    multitode.net.onClient(CHANNEL, "close", function(_, payload)
        if not bonus_env_owns_drive() then
            return
        end
        close_vote_internal("net-close")
    end)

    bv.handlersRegistered = true
    logger:i("Multitode bonus vote handlers loaded")
end

local function install_session_listeners()
    -- Ghost check: listeners must exist exactly once, in the driving env.
    -- A second set drives everything twice.
    if not bonus_env_owns_drive() then
        return false
    end
    local sys = get_systems()
    if sys == nil or sys.events == nil then
        return false
    end
    if bv.installedSession == sys then
        return false
    end

    pcall(function()
        sys.events:getListeners(C.GameStateTick):addStateAffectingWithPriority(C.Listener(function(_)
            local ok, err = pcall(drive_stage_logic)
            if not ok then
                logger:w("bonus vote tick failed: %s", tostring(err))
            end
        end), C.EventListeners.PRIORITY_HIGHEST)
    end)

    pcall(function()
        sys.events:getListeners(C.BonusSelect):add(C.Listener(function(_)
            if not bonus_env_owns_drive() then
                return
            end
            local itdState = multitode.itd
            if bv.active or bv.pauseActive or bv.blocking
                or (itdState ~= nil and itdState.bonusPauseActive == true) then
                close_vote_internal("bonus-selected")
            end
        end))
    end)

    pcall(function()
        sys.events:getListeners(C.BonusesReRoll):add(C.Listener(function(_)
            if not bonus_env_owns_drive() then
                return
            end
            if not bv.active then
                return
            end
            bv.votes = {}
            bv.localVote = nil
            bv.deadlineMs = now_ms() + (bv.mode == "vote" and VOTE_MS or HOST_MODE_MS)
            bv.lastTallyAt = 0
            local _, _, optCount = get_stage_info()
            if optCount ~= nil and optCount > 0 then
                bv.optionCount = optCount
            end
            -- The native overlay rebuilds all card actors on reroll. Drop the
            -- old capture listeners and labels before rebuilding our guards.
            clear_card_badges()
            clear_badges()
            ensure_badge_layer()
            if is_host_role() then
                broadcast_tally()
            end
            slog("REROLL applied; vote restarted")
        end))
    end)

    bv.installedSession = sys
    logger:i("Installed bonus vote listeners for current session")
    return true
end

local function try_install()
    install_session_listeners()
end

-- SystemsSetup/StateRestore can run before GameScreen.S is visible. Retry
-- from Render until the current session is actually installed; otherwise the
-- bonus module silently remains inert while the engine overlay still runs.
local function retry_install()
    local sys = get_systems()
    if sys ~= nil and bv.installedSession ~= sys then
        pcall(try_install)
    end
end

register_handlers()

C.Game.EVENTS:getListeners(C.SystemsSetup):add(C.Listener(function(_)
    try_install()
end))
C.Game.EVENTS:getListeners(C.SystemsStateRestore):add(C.Listener(function(_)
    try_install()
    -- A restore swaps the systems and hardcodes speed 1.0. If one lands
    -- mid-vote, pin our freeze back (storm-era restores blipped the speed)
    -- and rebuild badges/guards on the NEW overlay actors - the old ones died
    -- with the restored UI and stale actors eat clicks.
    if bv.active or bv.pauseActive then
        pcall(function()
            force_speed(0)
        end)
        if bv.active then
            pcall(function()
                clear_card_badges()
                clear_badges()
                ensure_badge_layer()
                update_badges()
                slog("StateRestore re-asserted pause + rebuilt vote badges")
            end)
        end
    end
end))
-- Install retries AND the full vote drive, from Render. At speed 0 the engine
-- only runs updateSystems() on rare one-shot ticks, so GameStateTick dies
-- inside our own pause: the host once sat 16s frozen with NO vote open (stage
-- watch + arm + host_start all tick-driven). Render runs every frame at any
-- speed, so the whole lifecycle lives here too. Throttled: 100ms idle (stage
-- watch), 200ms mid-vote (timer/badges keep their own pace).
local lastPumpAt = 0
C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
    retry_install()
    local t = now_ms()
    local interval = bv.active and 200 or 100
    if t - (lastPumpAt or 0) < interval then
        return
    end
    lastPumpAt = t
    local ok, err = pcall(drive_stage_logic)
    if not ok then
        logger:w("bonus vote render pump failed: %s", tostring(err))
    end
end))
try_install()

logger:i("Multitode bonus votes loaded")
