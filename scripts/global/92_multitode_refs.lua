local logger = C.TLog:forTag("multitode/refs.lua")

_G.multitode = _G.multitode or {}

-- ============================================================
-- Settings (session-local; UI lives in the multiplayer window)
-- ============================================================

multitode.settings = multitode.settings or {
    unavailableMode = "no", -- "no" = flat UNAVAILABLE, "context" = endless-tree focus
    allowPollsForEveryone = false, -- host-only rule, enforced by host
    bonusMode = "host", -- RELEASE: host-authoritative. "vote" is a dormant v2 stub (see 87_).
}

-- ============================================================
-- Tooltip overlay shell (in-game friendly: no screen switch)
-- ============================================================

multitode.tooltip = multitode.tooltip or {}
local tooltip = multitode.tooltip

tooltip.window = nil
tooltip.expiresAt = 0
tooltip.timerRegistered = tooltip.timerRegistered or false
tooltip.dismissListenerStage = nil

local TOOLTIP_TIMEOUT_SEC = 30

function tooltip.hide()
    if tooltip.window ~= nil then
        pcall(function()
            tooltip.window:remove()
        end)
        tooltip.window = nil
    end
    tooltip.expiresAt = 0
end

-- Tap-outside dismiss via a stage CAPTURE listener (fires before hit-testing,
-- so it can never steal taps from the card itself — unlike a fullscreen
-- catcher actor, which always wins hit-tests and eats card taps).
local function ensure_dismiss_listener(stage)
    if tooltip.dismissListenerStage == stage then
        return
    end
    local ok, err = pcall(function()
        stage:addCaptureListener(C.EventListener(function(event)
            if tooltip.window == nil then
                return false
            end
            if not C.InputEvent:_isInstance(event) then
                return false
            end
            if event:getType() ~= C.InputEvent.Type.touchDown then
                return false
            end
            local wx, wy, ww, wh = nil, nil, nil, nil
            local okR = pcall(function()
                wx = tooltip.window:getX()
                wy = tooltip.window:getY()
                ww = tooltip.window:getWidth()
                wh = tooltip.window:getHeight()
            end)
            if not okR or wx == nil then
                return false
            end
            local x, y = event:getStageX(), event:getStageY()
            if x < wx or x > wx + ww or y < wy or y > wy + wh then
                tooltip.hide()
            end
            return false -- never consume: taps pass through to the game
        end))
    end)
    if ok then
        tooltip.dismissListenerStage = stage
    else
        logger:w("Tap-outside dismiss unavailable: %s", tostring(err))
    end
end

-- spec: { title="..", rows={{k,v},...}, actions={{label=.., onClick=function}...} }
function tooltip.show(spec)
    if spec == nil then
        return
    end
    tooltip.hide()

    local uiManager = C.Game.i.uiManager
    if uiManager == nil then
        return
    end
    local stage = uiManager.stage
    if stage == nil then
        return
    end

    ensure_dismiss_listener(stage)

    local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
    windowStyle.resizeable = false
    windowStyle.inheritWidgetMinSize = true

    local window = C.Window.new_WS(windowStyle)
    tooltip.window = window
    window:setTitle(tostring(spec.title or "Info"))

    local labelStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL)
    local content = C.Table.new()
    content:pad(12)

    for _, row in ipairs(spec.rows or {}) do
        local titleLabel = C.Label.new(tostring(row[1] or ""), labelStyle)
        titleLabel:setColor(1, 1, 1, 0.65)
        content:add(titleLabel):width(150):left():padRight(12):padBottom(6)

        local valueLabel = C.Label.new(tostring(row[2] or ""), labelStyle)
        valueLabel:setWrap(true)
        content:add(valueLabel):width(330):left():padBottom(6):row()
    end

    for _, action in ipairs(spec.actions or {}) do
        if action ~= nil and action.label ~= nil and action.onClick ~= nil then
            local onClick = action.onClick
            local button = C.RectButton.new(tostring(action.label),
                C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL),
                C.Runnable(function()
                    local ok, err = pcall(onClick)
                    if not ok then
                        logger:e("Tooltip action failed: %s", tostring(err))
                    end
                end))
            button:setSize(480, 48)
            content:add(button):width(480):left():padTop(4):row()
        end
    end

    local closeButton = C.RectButton.new("Close",
        C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL),
        C.Runnable(tooltip.hide))
    closeButton:setSize(200, 48)
    content:add(closeButton):width(200):left():padTop(8):row()

    window.main:add(content):pad(12):grow()
    uiManager:addWindow(window)
    window:fitToContentSimple()
    -- Center clamped inside the visible area BEFORE show(): show() runs the
    -- engine clamp pass last, and anything positioned off-screen stays cut.
    pcall(function()
        local layer = C.Game.i.uiManager:getWindowsLayer():getTable()
        local pw, ph = layer:getWidth(), layer:getHeight()
        if pw ~= nil and ph ~= nil and pw > 100 and ph > 100 then
            local w, h = window:getWidth(), window:getHeight()
            if w > pw * 0.95 then
                window:setSize(pw * 0.95, h)
                w = pw * 0.95
            end
            window:setPosition(math.max(0, (pw - w) * 0.5), math.max(0, (ph - h) * 0.5))
        else
            window:setPosition(
                math.max(0, (stage:getWidth() - window:getWidth()) * 0.5),
                math.max(0, (stage:getHeight() - window:getHeight()) * 0.5))
        end
    end)
    window:show()

    tooltip.expiresAt = os.clock and (os.clock() + TOOLTIP_TIMEOUT_SEC) or 0
end

local function ensure_tooltip_timer()
    if tooltip.timerRegistered then
        return
    end
    C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
        local ok, err = pcall(function()
            if tooltip.window ~= nil and tooltip.expiresAt > 0 and os.clock
                    and os.clock() > tooltip.expiresAt then
                tooltip.hide()
            end
        end)
        if not ok then
            logger:e("Tooltip timer error: %s", tostring(err))
        end
    end))
    tooltip.timerRegistered = true
end

ensure_tooltip_timer()

-- ============================================================
-- Screen helpers
-- ============================================================

local function is_in_game()
    local ok, scr = pcall(function()
        return C.Game.i.screenManager:getCurrentScreen()
    end)
    if not ok or scr == nil then
        return false
    end
    local ok2, result = pcall(C.GameScreen._isInstance, C.GameScreen, scr)
    return ok2 and result == true
end

local function get_game_systems()
    local ok, scr = pcall(function()
        return C.Game.i.screenManager:getCurrentScreen()
    end)
    if not ok or scr == nil then
        return nil
    end
    local ok2, isGame = pcall(C.GameScreen._isInstance, C.GameScreen, scr)
    if not ok2 or not isGame then
        return nil
    end
    return scr.S
end

-- ============================================================
-- Reference parsing (+kind args...), canonical compose
-- kinds: research <ENUM_ID> | map <name> | tile <CAT> [L<1-5>] <x> <y>
-- ============================================================

multitode.refs = multitode.refs or {}
local refs = multitode.refs

local VALID_KINDS = { research = true, map = true, tile = true }

function refs.prettify(id)
    return tostring(id or ""):gsub("_", " "):lower()
end

function refs.parse(text)
    if text == nil or text == "" then
        return text, {}
    end

    local found = {}
    local clean = tostring(text):gsub("%+(%a+)%s+([^%+%s][^%+]*)", function(kind, rest)
        kind = tostring(kind):lower()
        if not VALID_KINDS[kind] then
            return nil -- leave unknown +kinds as plain text
        end

        local args = {}
        for token in tostring(rest):gmatch("%S+") do
            args[#args + 1] = token
        end

        local ref = nil
        if kind == "research" and #args >= 1 then
            local id = tostring(args[1]):upper()
            local ok, rt = pcall(function()
                return C.ResearchType[id]
            end)
            if ok and rt ~= nil then
                ref = { kind = "research", id = id }
            end
        elseif kind == "map" and #args >= 1 then
            local name = tostring(args[1])
            local ok, lvl = pcall(function()
                return C.Game.i.basicLevelManager:getLevel(name)
            end)
            if ok and lvl ~= nil then
                ref = { kind = "map", id = name }
            end
        elseif kind == "tile" and #args >= 2 then
            local cat = tostring(args[1]):upper()
            local nums = {}
            for i = 2, #args do
                local n = tonumber(args[i] and tostring(args[i]):match("L?(%d+)"))
                nums[#nums + 1] = n
            end
            if cat == "REGULAR" and #nums >= 2 and nums[1] ~= nil and nums[2] ~= nil then
                ref = { kind = "tile", cat = "REGULAR", level = 0, x = nums[1], y = nums[2] }
            elseif #nums >= 3 and nums[1] ~= nil and nums[2] ~= nil and nums[3] ~= nil then
                ref = { kind = "tile", cat = cat, level = nums[1], x = nums[2], y = nums[3] }
            end
        end

        if ref ~= nil then
            found[#found + 1] = ref
            return "" -- strip the consumed token from visible text
        end
        return nil -- invalid ref: keep original text
    end)

    clean = clean:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if clean == "" then
        clean = tostring(text)
    end
    return clean, found
end

function refs.composeResearch(id)
    return "+research " .. tostring(id or "")
end

function refs.composeMap(name)
    return "+map " .. tostring(name or "")
end

function refs.composeTile(cat, level, x, y)
    if tostring(cat or ""):upper() == "REGULAR" then
        return string.format("+tile REGULAR %s %s", tostring(x), tostring(y))
    end
    return string.format("+tile %s L%s %s %s",
        tostring(cat), tostring(level), tostring(x), tostring(y))
end

function refs.chipLabel(ref)
    if ref.kind == "research" then
        return "research: " .. refs.prettify(ref.id)
    elseif ref.kind == "map" then
        return "map: " .. tostring(ref.id)
    elseif ref.kind == "tile" then
        if tostring(ref.cat or ""):upper() == "REGULAR" then
            return string.format("tile %s,%s", tostring(ref.x), tostring(ref.y))
        end
        return string.format("tile %s L%s %s,%s",
            tostring(ref.cat), tostring(ref.level), tostring(ref.x), tostring(ref.y))
    end
    return tostring(ref.kind or "?")
end

-- ============================================================
-- Tile enumeration (current map only) + camera snap
-- ============================================================

function refs.getPlatformTiles()
    local systems = get_game_systems()
    if systems == nil or systems.map == nil then
        return nil, "no map loaded"
    end

    local okMap, map = pcall(function()
        return systems.map:getMap()
    end)
    if not okMap or map == nil then
        return nil, "no map loaded"
    end

    local platformClass = C.PlatformTile
    if platformClass == nil then
        local okBind, bound = pcall(luajava.bindClass, "com.prineside.tdi2.tiles.PlatformTile")
        if not okBind then
            return nil, "tile class unavailable"
        end
        platformClass = bound
    end

    local okTiles, arr = pcall(function()
        return map:getTilesByType(platformClass)
    end)
    if not okTiles or arr == nil or arr.size == nil then
        return nil, "tile query failed"
    end

    local result = {}
    for i = 1, arr.size do
        local okT, tile = pcall(function()
            return arr.items[i]
        end)
        if okT and tile ~= nil then
            local okF, entry = pcall(function()
                local bonus = tile.bonusType
                local cat = bonus == nil and "REGULAR" or tostring(bonus)
                local cx, cy = tile:getX(), tile:getY()
                return {
                    x = tonumber(cx) or 0,
                    y = tonumber(cy) or 0,
                    cat = cat,
                    level = tonumber(tile.bonusLevel) or 0,
                }
            end)
            if okF and entry ~= nil then
                result[#result + 1] = entry
            end
        end
    end
    return result, nil
end

function refs.tileGroups(tiles)
    -- { [cat] = { total=n, levels={ [lvl]={total=n, tiles={...}} } } }
    local groups = {}
    for _, t in ipairs(tiles or {}) do
        local cat = tostring(t.cat or "REGULAR"):upper()
        local g = groups[cat]
        if g == nil then
            g = { total = 0, levels = {} }
            groups[cat] = g
        end
        g.total = g.total + 1
        local lvl = tonumber(t.level) or 0
        local l = g.levels[lvl]
        if l == nil then
            l = { total = 0, tiles = {} }
            g.levels[lvl] = l
        end
        l.total = l.total + 1
        l.tiles[#l.tiles + 1] = t
    end
    return groups
end

function refs.findTile(x, y)
    local tiles, err = refs.getPlatformTiles()
    if tiles == nil then
        return nil
    end
    for _, t in ipairs(tiles) do
        if t.x == x and t.y == y then
            return t
        end
    end
    return nil
end

function refs.snapTo(x, y)
    local systems = get_game_systems()
    if systems == nil or systems._input == nil
            or systems._input.cameraController == nil then
        return false, "no game camera"
    end
    local ok, err = pcall(function()
        systems._input.cameraController:lookAt(tonumber(x) or 0, tonumber(y) or 0)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

-- ============================================================
-- Describe a ref -> tooltip spec; deep-link actions when in menu
-- ============================================================

local function menu_actions_for_research(rt)
    if is_in_game() then
        return {}
    end
    return {
        {
            label = "Open in research tree",
            onClick = function()
                tooltip.hide()
                C.Game.i.screenManager:goToResearchesScreenFocusOnResearch(rt)
                -- Pre-select the node too (focus only centers the camera).
                pcall(function()
                    local scr = C.Game.i.screenManager:getCurrentScreen()
                    if scr ~= nil and C.ResearchesScreen:_isInstance(scr) then
                        local inst = C.Game.i.researchManager:getInstance(rt)
                        if inst ~= nil then
                            scr.selectedResearch = inst
                        end
                    end
                end)
            end,
        },
    }
end

local function menu_actions_for_map(levelName)
    if is_in_game() then
        return {}
    end
    local actions = {}
    local ok, lvl = pcall(function()
        return C.Game.i.basicLevelManager:getLevel(levelName)
    end)
    if ok and lvl ~= nil then
        actions[#actions + 1] = {
            label = "Open in level select",
            onClick = function()
                tooltip.hide()
                C.Game.i.screenManager:goToLevelSelectScreenShowLevel(lvl)
            end,
        }
    end
    -- Host in an open lobby gets an apply action (confirm dialog in menu code).
    local stateOk, state = pcall(multitode.state)
    if stateOk and state ~= nil and (state.role == "HOST" or state.role == "HOST_AND_CLIENT")
            and multitode.lobby ~= nil and multitode.lobby.state == "WAITING"
            and multitode.lobby.confirmMapSuggestion ~= nil then
        actions[#actions + 1] = {
            label = "Apply as lobby level...",
            onClick = function()
                tooltip.hide()
                multitode.lobby.confirmMapSuggestion(levelName)
            end,
        }
    end
    return actions
end

function refs.describe(ref)
    if ref == nil or ref.kind == nil then
        return { title = "Link", rows = { { "Error", "bad reference" } }, actions = {} }
    end

    if ref.kind == "research" then
        local okRt, rt = pcall(function()
            return C.ResearchType[ref.id]
        end)
        if not okRt or rt == nil then
            return { title = "Research", rows = { { "Error", "unknown: " .. tostring(ref.id) } }, actions = {} }
        end

        local rm = C.Game.i.researchManager
        local okI, inst = pcall(function()
            return rm:getInstance(rt)
        end)
        local title = tostring(ref.id)
        if okI and inst ~= nil then
            local okT, t = pcall(function()
                return inst:getTitle()
            end)
            if okT and t ~= nil then
                title = tostring(t)
            end
        end

        local installed = 0
        local okL, lvl = pcall(function()
            return rm:getInstalledLevel(rt)
        end)
        if okL and lvl ~= nil then
            installed = tonumber(lvl) or 0
        end

        local visible = false
        if okI and inst ~= nil then
            local okV, v = pcall(function()
                return rm:isVisible(inst)
            end)
            visible = okV and v == true
        end

        -- Mode 1 (default): flat UNAVAILABLE for anything out of reach.
        if not visible then
            local reason = "locked or out of reach"
            if okI and inst ~= nil then
                local okE, endOnly = pcall(function()
                    return inst.endlessOnly
                end)
                if okE and endOnly == true then
                    reason = "endless mode only"
                end
            end
            if multitode.settings.unavailableMode ~= "context" then
                return {
                    title = title,
                    rows = {
                        { "Status", "UNAVAILABLE" },
                        { "Reason", reason },
                    },
                    actions = {},
                }
            end
            -- Context mode: endless tree render would go here (Phase 4);
            -- for now explain + still offer the deep link.
        end

        local rows = { { "Installed level", tostring(installed) } }
        if okI and inst ~= nil then
            local okP, price = pcall(function()
                return inst.priceInStars
            end)
            if okP and price ~= nil then
                rows[#rows + 1] = { "Price (stars)", tostring(price) }
            end
            local okD, dur = pcall(function()
                return inst.researchDuration
            end)
            if okD and dur ~= nil then
                rows[#rows + 1] = { "Research time", tostring(dur) .. "s" }
            end
            if not visible then
                rows[#rows + 1] = { "Status", "UNAVAILABLE (" .. reason .. ")" }
            end
        end
        return { title = title, rows = rows, actions = menu_actions_for_research(rt) }
    end

    if ref.kind == "map" then
        local okL, lvl = pcall(function()
            return C.Game.i.basicLevelManager:getLevel(ref.id)
        end)
        if not okL or lvl == nil then
            return { title = "Map", rows = { { "Error", "unknown: " .. tostring(ref.id) } }, actions = {} }
        end
        local rows = { { "Name", tostring(ref.id) } }
        local okS, stage = pcall(function()
            return lvl.stageName
        end)
        if okS and stage ~= nil then
            rows[#rows + 1] = { "Stage", tostring(stage) }
        end
        return { title = "Map: " .. tostring(ref.id), rows = rows, actions = menu_actions_for_map(ref.id) }
    end

    if ref.kind == "tile" then
        local cat = tostring(ref.cat or ""):upper()
        local x = tonumber(ref.x) or 0
        local y = tonumber(ref.y) or 0
        local rows
        if cat == "REGULAR" then
            rows = { { "Tile", "regular" }, { "At", x .. "," .. y } }
        else
            rows = { { "Tile", cat }, { "Level", tostring(ref.level) }, { "At", x .. "," .. y } }
        end
        local live = refs.findTile(x, y)
        local actions = {}
        if live == nil then
            rows[#rows + 1] = { "Status", "no tile found (stale or other map)" }
        elseif not is_in_game() then
            rows[#rows + 1] = { "Status", "open a match to snap camera" }
        else
            actions[#actions + 1] = {
                label = "Snap camera to tile",
                onClick = function()
                    tooltip.hide()
                    local ok, err = refs.snapTo(x, y)
                    if not ok then
                        logger:w("Camera snap failed: %s", tostring(err))
                    end
                end,
            }
        end
        return { title = "Tile " .. x .. "," .. y, rows = rows, actions = actions }
    end

    return { title = "Link", rows = { { "Error", "unsupported kind" } }, actions = {} }
end

function refs.openRef(ref)
    local ok, spec = pcall(refs.describe, ref)
    if not ok or spec == nil then
        logger:e("Ref resolve failed: %s", tostring(spec))
        return
    end
    tooltip.show(spec)
end

logger:i("Multitode refs + tooltip module loaded")
