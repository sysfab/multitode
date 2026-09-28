local logger = C.TLog:forTag("multitode/ui_menu.lua")

local multiplayerWindow = nil
local pendingWindowReopenFrames = -1
local open_multiplayer_window = nil
local chatWindow = nil
local toggle_chat_window = nil
-- Live label for the multiplayer "Chat window" button (setText, not rebuild).
local chatWindowToggleButton = nil
-- True while the native text-input dialog is open (Send Chat / config fields).
-- The global Enter poll must not toggle chat while Enter submits that dialog.
local textInputOpen = false
-- Sticky suppress: set when a text input finishes so a still-held Enter (the
-- submit keypress) cannot open chat on the same/next frame; cleared on release.
local suppressChatEnterUntilRelease = false
-- Deferred scroll-to-bottom: ScrollPane.maxY is stale on the same frame as
-- pack()/invalidate(); scrolling immediately left the newest line 1 row short.
local chatScrollPendingFrames = 0
local embedScrollPendingFrames = 0
-- Preserved across content rebuilds (ready, roster, send-chat dialog remove,
-- lobby state dirty). nil = no restore (fresh open or intentional close).
local savedMainScrollY = nil
local savedWinX = nil
local savedWinY = nil
local mainScrollRestoreFrames = 0
local mainScrollRestoreY = nil
local chatWindowPos = { x = nil, y = nil }
-- Live poll widgets: countdown ticks + vote tallies update these in place so
-- a 5 s heartbeat or a vote click never rebuilds the whole window.
local pollRun = {
    countdownLabel = nil,
    voteButtons = nil,
}
local levelSel = {
    window = nil,
    page = 0,
    attach = false,
}
local K = {
    LEVEL_SELECT_PER_PAGE = 8,
    CHAT_PREVIEW_COUNT = 6,
    FLOAT_BUTTON_W = 170,
    FLOAT_BUTTON_H = 54,
    FLOAT_CLICK_SLOP = 10,
    QUICK_MESSAGE_FRAMES = 300,
    QUICK_MESSAGE_FADE_FRAMES = 45,
    DARK_END = 0.68,
    RESEARCH_PAGE_SIZE = 12,
    GRADIENT_STEPS = 40,
}
local refPickerWindow = nil
local tilePickerCache = nil
local pollCreate = {
    draft = nil,
    window = nil,
    answerFields = nil,
    durationSec = 20,
    durationButtons = nil,
    customDurationField = nil,
}
local diagUI = {
    showSettings = false,
    leaveButton = nil,
    lobbySection = nil,
    -- Pure toggles keep a ref so onClick can setText instead of reopening
    -- the whole multiplayer window (settings flicker).
    toggleButtons = {},
}

-- Forward declarations: Lua locals resolve lexically, so any function defined
-- ABOVE the real definition that references these would otherwise see a nil
-- global. Declared here, assigned (without `local`) at their definitions.
local open_config_text_input, open_send_dialog, prefill_send
local reopen_multiplayer_window, open_ref_popup
local ensure_badge
-- add_chat_row_to is used from open_multiplayer_window (above its definition).
local add_chat_row_to
-- force_scroll_bottom is called from open_multiplayer_window (above its definition).
local force_scroll_bottom
-- Discord-like chat: fixed pane height so ~5-6 single-line messages are visible
-- (FONT_SIZE_X_SMALL=21 + padBottom(2) ≈ 26px/row + rowsTable pad(4)*2).
local CHAT_PANE_H = 164
-- Embedded chat inside the multiplayer window (separate from chatUI.rowsTable,
-- which belongs only to the detached chat window).
local embed = {
    rows = nil,
    scroll = nil,
    mainScroll = nil,
    rowW = 420,
}
-- Snapshot main-pane scroll + window position so rebuilds (ready, roster dirty,
-- text-input remove+reopen) do not jump the player back to the top.
local function save_multiplayer_scroll_pos()
    if embed.mainScroll ~= nil then
        pcall(function()
            savedMainScrollY = embed.mainScroll:getScrollY()
        end)
    end
    if multiplayerWindow ~= nil then
        pcall(function()
            savedWinX = multiplayerWindow:getX()
            savedWinY = multiplayerWindow:getY()
        end)
    end
end

local function clear_saved_multiplayer_scroll_pos()
    savedMainScrollY = nil
    savedWinX = nil
    savedWinY = nil
    mainScrollRestoreY = nil
    mainScrollRestoreFrames = 0
end

local function schedule_main_scroll_restore()
    if savedMainScrollY == nil then
        return
    end
    mainScrollRestoreY = savedMainScrollY
    -- maxY is stale until layout settles — same deferred pattern as force_scroll_bottom.
    mainScrollRestoreFrames = 2
end

-- Floating entry-point button (visible on every screen, draggable).
local floatBtn = {
    button = nil,
    pos = { x = nil, y = nil },
    armed = nil,
}

-- Layout metrics recomputed from the stage size on every window open, so the
-- window fills ~90% of the screen and long names/messages never get cut off.
local layout = {
    contentW = 540,
    titleW = 120,
    valueW = 380,
    listW = 500,
}

local function compute_layout()
    -- Bounded columns: the packed window always fits real viewports, so it can
    -- never be pushed half off-screen. Text wraps inside the value column.
    -- Derived from the real stage size when readable (small windows / scaled UI
    -- stay proportional); falls back to the previous fixed defaults.
    local stageW = nil
    pcall(function()
        local stage = C.Game.i.uiManager.stage
        if stage ~= nil then
            stageW = tonumber(stage:getWidth())
        end
    end)
    local contentW = 900
    if stageW ~= nil and stageW > 100 then
        -- ~55% of the stage on large screens, but never force a 640px floor
        -- that overflows half-width game windows (2–4 instances side by side).
        local target = math.min(stageW * 0.55, 1100)
        local floorW = math.min(480, math.max(320, stageW - 24))
        contentW = math.floor(math.max(floorW, target))
        if contentW > stageW - 16 then
            contentW = math.floor(stageW - 16)
        end
        if contentW < 320 then
            contentW = 320
        end
    end
    layout.contentW = contentW
    -- add_info_row lives inside sections that pad(12) or pad(16). Size the two
    -- columns to the NARROWEST inner width (contentW - 32) so a title+value row
    -- never overflows its section: title + gap + value + section pads <= contentW.
    -- (The old contentW-based row was 16-32px too wide and pushed the left edge
    -- out of the scroll viewport - the "Settings cut off" report.)
    local innerW = contentW - 32
    -- Slightly wider title column so short labels ("Show others' marks") fit
    -- without spilling into the tip/value column on narrow layouts.
    layout.titleW = math.max(100, math.floor(innerW * 0.28))
    layout.valueW = innerW - layout.titleW - 16
    if layout.valueW < 120 then
        layout.valueW = 120
        layout.titleW = math.max(80, innerW - layout.valueW - 16)
    end
    layout.listW = math.max(360, contentW - 40)
end

-- Live round-trip time in ms (measured from PING replies); "?" until known.
local function ping_ms()
    local ok, value = pcall(multitode.getLatency)
    if not ok or value == nil or tonumber(value) == nil or tonumber(value) < 0 then
        return "?"
    end
    return math.floor(tonumber(value))
end

-- Center a packed window in the windows layer, clamped to stay fully visible.
-- Must be called BEFORE show(): show() runs the engine's own clamp pass last.
local function place_window_centered(window)
    local pw, ph = nil, nil
    local ok, layer = pcall(function()
        return C.Game.i.uiManager:getWindowsLayer():getTable()
    end)
    if ok and layer ~= nil then
        local okW, w = pcall(function()
            return layer:getWidth()
        end)
        local okH, h = pcall(function()
            return layer:getHeight()
        end)
        if okW and okH and w ~= nil and h ~= nil and w > 100 and h > 100 then
            pw, ph = w, h
        end
    end
    if pw == nil then
        local stage = C.Game.i.uiManager.stage
        pw, ph = stage:getWidth(), stage:getHeight()
    end
    local w, h = window:getWidth(), window:getHeight()
    if w > pw * 0.95 then
        window:setSize(pw * 0.95, h)
        w = pw * 0.95
    end
    if h > ph * 0.95 then
        window:setSize(w, ph * 0.95)
        h = ph * 0.95
    end
    window:setPosition(math.max(0, (pw - w) * 0.5), math.max(0, (ph - h) * 0.5))
end

local function toggle_flag(key)
    local config = multitode.getConfig()
    multitode.configure({ [key] = not config[key] })
end

local function create_action_button(text, onClick)
    local button = C.RectButton.new(text, C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_SMALL), C.Runnable(onClick))
    button:setSize(260, 56)
    return button
end

-- In-place label update for settings/lobby toggles. Stores the live button so
-- later clicks never need open_multiplayer_window() just to flip ON/OFF text.
local function bind_toggle(key, button)
    if key == nil or button == nil then
        return button
    end
    diagUI.toggleButtons[key] = button
    return button
end

local function set_toggle_text(key, text)
    local button = diagUI.toggleButtons[key]
    if button == nil then
        return false
    end
    local ok = pcall(function()
        if button.getParent ~= nil and button:getParent() ~= nil then
            button:setText(tostring(text))
        end
    end)
    if not ok then
        diagUI.toggleButtons[key] = nil
        return false
    end
    return true
end

-- Rebuild ONLY when the click actually changes section structure
-- (show/hide Settings, enter/leave lobby, role, poll open/close).
local function clear_toggle_buttons()
    diagUI.toggleButtons = {}
end

local function is_chat_window_visible()
    return chatWindow ~= nil and chatWindow:getParent() ~= nil
end

local function refresh_chat_window_button()
    local on = is_chat_window_visible()
    local text = on and "Chat window: ON" or "Chat window: OFF"
    local button = chatWindowToggleButton
    chatWindowToggleButton = nil
    if button ~= nil and button:getParent() ~= nil then
        pcall(function() button:setText(text) end)
        chatWindowToggleButton = button
    end
end

local function create_list_button(text, onClick)
    local button = C.RectButton.new(text, C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL), C.Runnable(onClick))
    button:setSize(layout.listW, 44)
    return button
end

local function create_chip_button(text, onClick)
    local button = C.RectButton.new(text, C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL), C.Runnable(onClick))
    button:setSize(320, 40)
    return button
end

-- NOTE: open_send_dialog/prefill_send are defined after open_config_text_input
-- below (Lua locals must be declared before use).

local warn = {
    levelNames = false,
    rowColor = false,
    gradient = false,
    icon = false,
}

local function get_basic_level_names()
    local ok, names = pcall(function()
        local result = {}
        local ordered = C.Game.i.basicLevelManager.levelsOrdered
        if ordered == nil or ordered.size == nil then
            return result
        end
        for i = 1, ordered.size do
            local level = ordered.items[i]
            if level ~= nil and level.name ~= nil then
                result[#result + 1] = tostring(level.name)
            end
        end
        return result
    end)
    if not ok or names == nil then
        if not warn.levelNames then
            warn.levelNames = true
            logger:w("Could not read basic level list")
        end
        return {}
    end
    if not warn.levelNames then
        warn.levelNames = true
        logger:i("Found %d basic levels", #names)
    end
    return names
end

local function open_level_select_window(page)
    if levelSel.window ~= nil then
        levelSel.window:remove()
        levelSel.window = nil
    end

    local names = get_basic_level_names()
    local totalPages = math.max(0, math.ceil(#names / K.LEVEL_SELECT_PER_PAGE) - 1)
    page = math.max(0, math.min(page or 0, totalPages))
    levelSel.page = page

    compute_layout()

    local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
    windowStyle.resizeable = false
    windowStyle.inheritWidgetMinSize = true

    local window = C.Window.new_WS(windowStyle)
    levelSel.window = window
    window:setTitle("")

    local content = C.Table.new()
    content:pad(8)

    local titleStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_SMALL)
    local title = C.Label.new("Choose Level (" .. #names .. ")", titleStyle)
    title:setColor(C.MaterialColor.LIGHT_BLUE.P500)
    content:add(title):left():padBottom(8):row()

    local startIndex = page * K.LEVEL_SELECT_PER_PAGE + 1
    local endIndex = math.min(startIndex + K.LEVEL_SELECT_PER_PAGE - 1, #names)
    for i = startIndex, endIndex do
        local levelName = names[i]
        local pickButton = create_list_button(levelName, function()
            if levelSel.attach then
                -- Attach flow: compose +map link into the send dialog.
                levelSel.attach = false
                if levelSel.window ~= nil then
                    levelSel.window:remove()
                    levelSel.window = nil
                end
                prefill_send(multitode.refs.composeMap(levelName))
                return
            end
            local ok, err = pcall(multitode.lobby.set_level, levelName)
            if not ok then
                logger:e("Failed to set level: %s", tostring(err))
            end
            if levelSel.window ~= nil then
                levelSel.window:remove()
                levelSel.window = nil
            end
            reopen_multiplayer_window()
        end)
        content:add(pickButton):width(layout.listW):left():padBottom(4):row()
    end

    if totalPages > 0 then
        local navRow = C.Table.new()
        local prevButton = create_action_button("< Prev", function()
            open_level_select_window(page - 1)
        end)
        local nextButton = create_action_button("Next >", function()
            open_level_select_window(page + 1)
        end)
        navRow:add(prevButton):width(245):left():padRight(10)
        navRow:add(nextButton):width(245):left()
        content:add(navRow):left():padTop(4):padBottom(4):row()
        local pageLabel = C.Label.new("Page " .. (page + 1) .. " / " .. (totalPages + 1),
            C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL))
        content:add(pageLabel):left():padBottom(4):row()
    end

    local closeButton = create_action_button("Close", function()
        if levelSel.window ~= nil then
            levelSel.window:remove()
            levelSel.window = nil
        end
    end)
    content:add(closeButton):width(260):left():padTop(4):row()

    window.main:add(content):pad(16):grow()
    C.Game.i.uiManager:addWindow(window)
    window:fitToContentSimple()
    place_window_centered(window)
    window:show()
end

-- Generic small popup used by attach flows (kind list, tile drill-down).
open_ref_popup = function(title, rows, onClose)
    if refPickerWindow ~= nil then
        refPickerWindow:remove()
        refPickerWindow = nil
    end

    compute_layout()

    local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
    windowStyle.resizeable = false
    windowStyle.inheritWidgetMinSize = true

    local window = C.Window.new_WS(windowStyle)
    refPickerWindow = window
    window:setTitle(tostring(title or ""))

    local content = C.Table.new()
    content:pad(8)

    local gradientRows = {}
    -- 25% wider list, and a left indent that reserves room for the icons which
    -- hang outside the row edges (they used to get clipped by the window frame).
    local listW = math.floor(layout.listW * 1.25)
    local iconOverhang = 48
    for _, row in ipairs(rows or {}) do
        if row.sep then
            local sep = C.Label.new(tostring(row.sep),
                C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL))
            if row.sepColor ~= nil then
                pcall(function() sep:setColor(row.sepColor) end)
            end
            content:add(sep):left():padLeft(iconOverhang):padTop(6):padBottom(2):row()
        elseif row.label ~= nil and row.onClick ~= nil then
            local onClick = row.onClick
            local labelStyle = C.Game.i.assetManager:getLabelStyle(
                row.big and C.Config.FONT_SIZE_SMALL or C.Config.FONT_SIZE_X_SMALL)
            local button = C.RectButton.new(tostring(row.label), labelStyle, C.Runnable(function()
                local ok, err = pcall(onClick)
                if not ok then
                    logger:e("Picker action failed: %s", tostring(err))
                end
            end))
            button:setSize(layout.listW, row.big and 46 or 40)

            -- NOTE: setBackgroundColors(normal, active, hover, disabled) sets one
            -- colour PER BUTTON STATE - that is why the rows came out flat. The real
            -- gradient is a 4-corner quad applied after layout (see below).
            if row.gradFrom ~= nil and row.gradTo ~= nil then
                local holder = build_gradient_holder(row.gradFrom, row.gradTo)
                if holder ~= nil then
                    pcall(function()
                        -- Hide the button's own flat background Image (public field)
                        -- and draw our gradient in its place at the BOTTOM of the
                        -- child list. RectButton keeps resetting that background on
                        -- resize, which is what kept showing blue; an invisible one
                        -- can be reset as often as it likes without being seen.
                        button.background:setVisible(false)
                        holder:setPosition(0, 0)
                        holder:setSize(button:getWidth(), button:getHeight())
                        button:addActorAt(0, holder)
                    end)
                end
                local iconImage = nil
                if row.iconKey ~= nil then
                    iconImage = build_tower_icon(row.iconKey)
                    if iconImage ~= nil then
                        pcall(function()
                            button:addActorAt(1, iconImage)
                        end)
                    end
                end
                gradientRows[#gradientRows + 1] = { button = button, image = holder, icon = iconImage }
            end

            -- Colours for ALL button states, otherwise the engine resets the label
            -- to white as soon as the pointer hovers it.
            if row.textColor ~= nil then
                pcall(function()
                    button:setLabelColors(row.textColor, row.textColor, row.textColor, row.textColor)
                end)
            elseif row.color ~= nil and apply_row_color ~= nil then
                apply_row_color(button, row.color)
            end

            -- Reserved for tower sprites (towers.<TYPE>.base quads); harmless while nil.
            if row.icon ~= nil then
                pcall(function()
                    button:setIcon(row.icon)
                end)
            end

            content:add(button):width(listW):left():padLeft(iconOverhang):padBottom(18):row()
        end
    end

    local closeButton = create_action_button("Close", function()
        if refPickerWindow ~= nil then
            refPickerWindow:remove()
            refPickerWindow = nil
        end
        if onClose ~= nil then
            local ok, err = pcall(onClose)
            if not ok then
                logger:e("Picker close failed: %s", tostring(err))
            end
        end
    end)
    content:add(closeButton):width(260):left():padTop(4):row()

    window.main:add(content):pad(16):grow()
    C.Game.i.uiManager:addWindow(window)
    window:fitToContentSimple()
    place_window_centered(window)
    window:show()

    -- Publish the rows: the window's own layout/animation can reset a RectButton's
    -- background right after we set it, so a frame hook keeps re-applying it for
    -- about a second (see the gradient hook at the end of this file).
    multitode._gradientRows = gradientRows
    multitode._gradientFrames = 90
    if apply_gradient_rows ~= nil then
        apply_gradient_rows()
    end
end

local function open_attach_kind_window()
    open_ref_popup("Attach +", {
        { label = "tile mark: HERE (blue)", onClick = function()
            if multitode.marks ~= nil then
                multitode.marks.arm("ok")
            end
            if multitode.close_multitode_window ~= nil then
                multitode.close_multitode_window()
            end
        end },
        { label = "tile mark: NOT HERE (red)", onClick = function()
            if multitode.marks ~= nil then
                multitode.marks.arm("no")
            end
            if multitode.close_multitode_window ~= nil then
                multitode.close_multitode_window()
            end
        end },
        { label = "research — ability / tower research", onClick = function()
            logger:i("Attach research row tapped")
            if open_research_browse_window ~= nil then
                open_research_browse_window()
                return
            end
            open_config_text_input("Attach research", "", "ENUM id, e.g. TOWER_SNIPER_A_LONG_RANGE", function(value)
                local id = tostring(value or ""):upper():gsub("%s+", "")
                local ok, rt = pcall(function()
                    return C.ResearchType[id]
                end)
                if not ok or rt == nil then
                    multitode.lobby.lastError = "Unknown research: " .. tostring(value)
                    reopen_multiplayer_window()
                    return
                end
                prefill_send(multitode.refs.composeResearch(id))
            end)
        end },
        { label = "map — basic level", onClick = function()
            levelSel.attach = true
            open_level_select_window(0)
        end },
        { label = "tile — map tile (in match only)", onClick = function()
            open_tile_picker()
        end },
    })
end

local function refresh_tile_cache()
    tilePickerCache = nil
    local ok, tiles = pcall(multitode.refs.getPlatformTiles)
    if ok and tiles ~= nil then
        tilePickerCache = tiles
        return true
    end
    return false
end

function open_tile_picker()
    if not refresh_tile_cache() then
        multitode.lobby.lastError = "Open a match first to attach tiles"
        reopen_multiplayer_window()
        return
    end
    local groups = multitode.refs.tileGroups(tilePickerCache)
    local rows = { { sep = "Folders (live counts)" } }
    local cats = {}
    for cat, _ in pairs(groups) do
        cats[#cats + 1] = cat
    end
    table.sort(cats, function(a, b)
        if a == "REGULAR" then return true end
        if b == "REGULAR" then return false end
        return a < b
    end)
    for _, cat in ipairs(cats) do
        local c = cat
        rows[#rows + 1] = {
            label = string.format("%s: %s", refs_pretty_cat(c), tostring(groups[c].total)),
            onClick = function()
                open_tile_level_window(c)
            end
        }
    end
    open_ref_popup("Attach tile", rows)
end

function refs_pretty_cat(cat)
    return tostring(cat or ""):lower()
end

function open_tile_level_window(cat)
    local groups = multitode.refs.tileGroups(tilePickerCache or {})
    local g = groups[cat]
    if g == nil then
        return
    end
    local rows = { { sep = refs_pretty_cat(cat) .. " by level" } }
    local levels = {}
    for lvl, _ in pairs(g.levels) do
        levels[#levels + 1] = lvl
    end
    table.sort(levels)
    for _, lvl in ipairs(levels) do
        local l = lvl
        local label
        if cat == "REGULAR" then
            label = string.format("regular tiles: %s", tostring(g.levels[l].total))
        else
            label = string.format("%s L%s: %s", refs_pretty_cat(cat), tostring(l), tostring(g.levels[l].total))
        end
        rows[#rows + 1] = {
            label = label,
            onClick = function()
                open_tile_list_window(cat, l)
            end
        }
    end
    open_ref_popup("Attach tile", rows)
end

function open_tile_list_window(cat, level)
    local groups = multitode.refs.tileGroups(tilePickerCache or {})
    local g = groups[cat]
    if g == nil or g.levels[level] == nil then
        return
    end
    local rows = { { sep = "tap a tile: snaps camera + composes link" } }
    local tiles = {}
    for _, t in ipairs(g.levels[level].tiles) do
        tiles[#tiles + 1] = t
    end
    table.sort(tiles, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    for _, t in ipairs(tiles) do
        local tile = t
        rows[#rows + 1] = {
            label = string.format("x:%s y:%s", tostring(tile.x), tostring(tile.y)),
            onClick = function()
                -- Snap first so you see exactly which tile you're linking.
                pcall(multitode.refs.snapTo, tile.x, tile.y)
                if refPickerWindow ~= nil then
                    refPickerWindow:remove()
                    refPickerWindow = nil
                end
                prefill_send(multitode.refs.composeTile(cat, level, tile.x, tile.y))
            end
        }
    end
    open_ref_popup("Attach tile", rows)
end

-- Host confirm dialog for map suggestions (level name + info, Apply/Cancel).
function confirm_map_suggestion(levelName)
    local ok, lvl = pcall(function()
        return C.Game.i.basicLevelManager:getLevel(levelName)
    end)
    if not ok or lvl == nil then
        multitode.lobby.lastError = "Unknown level: " .. tostring(levelName)
        reopen_multiplayer_window()
        return
    end

    compute_layout()
    local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
    windowStyle.resizeable = false
    windowStyle.inheritWidgetMinSize = true

    local window = C.Window.new_WS(windowStyle)
    refPickerWindow = window
    window:setTitle("Apply suggested level?")

    local content = C.Table.new()
    content:pad(8)
    local info = C.Table.new()
    info:pad(12)
    add_info_row(info, "Level", tostring(levelName))
    local okS, stageName = pcall(function()
        return lvl.stageName
    end)
    if okS and stageName ~= nil then
        add_info_row(info, "Stage", tostring(stageName))
    end
    content:add(info):width(layout.contentW):left():padBottom(8):row()

    local row = C.Table.new()
    local applyButton = create_action_button("Apply", function()
        if refPickerWindow ~= nil then
            refPickerWindow:remove()
            refPickerWindow = nil
        end
        local okA, errA = pcall(multitode.lobby.set_level, levelName)
        if not okA then
            multitode.lobby.lastError = tostring(errA)
        end
        reopen_multiplayer_window()
    end)
    row:add(applyButton):width(260):left():padRight(12)
    local cancelButton = create_action_button("Cancel", function()
        if refPickerWindow ~= nil then
            refPickerWindow:remove()
            refPickerWindow = nil
        end
        reopen_multiplayer_window()
    end)
    row:add(cancelButton):width(260):left()
    content:add(row):left():row()

    window.main:add(content):pad(16):grow()
    C.Game.i.uiManager:addWindow(window)
    window:fitToContentSimple()
    place_window_centered(window)
    window:show()
end

multitode.lobby.confirmMapSuggestion = confirm_map_suggestion

local function poll_countdown(poll)
    if poll == nil then
        return ""
    end
    -- Millisecond wall clock — integer os.time() phase made client tick a
    -- full second before host (host 15s → client 14s).
    local nowMs = 0
    if multitode and multitode.now_ms then
        nowMs = multitode.now_ms()
    else
        nowMs = (os.time and os.time() or 0) * 1000
    end
    local leftMs
    if poll.localDeadline ~= nil then
        -- Client: local deadline (ms) rebuilt from host remainingSec each heartbeat.
        leftMs = math.max(0, (tonumber(poll.localDeadline) or 0) - nowMs)
    else
        -- Host: absolute deadline (ms) on this machine's clock.
        leftMs = math.max(0, (tonumber(poll.expiresAt) or 0) - nowMs)
    end
    local dur = tonumber(poll.durationSec)
    if dur ~= nil and dur >= 1 and dur <= 3600 then
        leftMs = math.min(leftMs, dur * 1000)
    end
    -- Whole seconds only — floor of ms remaining (no float/ms digits).
    local left = math.floor(leftMs / 1000)
    if left >= 60 then
        return string.format("%d:%02d", math.floor(left / 60), left % 60)
    end
    return tostring(left) .. "s"
end

local function clear_poll_ui_refs()
    pollRun.countdownLabel = nil
    pollRun.voteButtons = nil
end

local function poll_compute_tallies(poll)
    local counts = {}
    for i = 1, #(poll.options or {}) do
        counts[i] = 0
    end
    for _, idx in pairs(poll.votes or {}) do
        local n = tonumber(idx) or 0
        if counts[n] ~= nil then
            counts[n] = counts[n] + 1
        end
    end
    local bestIdx, bestCount = 1, -1
    for i = 1, #(poll.options or {}) do
        local c = counts[i] or 0
        if c > bestCount then
            bestIdx, bestCount = i, c
        end
    end
    return counts, bestIdx, bestCount
end

local function poll_vote_button_text(poll, i, counts, bestIdx, bestCount, selfId)
    local mine = (poll.votes or {})[selfId] == i
    local leading = bestCount > 0 and i == bestIdx
    return string.format("%sVote: %s (%s)%s",
        leading and ">> " or "",
        tostring((poll.options or {})[i] or "?"),
        tostring(counts[i] or 0),
        mine and "  <you>" or "")
end

-- Patch countdown + vote buttons without open_multiplayer_window().
local function refresh_poll_ui_in_place()
    local poll = multitode.lobby and multitode.lobby.poll
    if poll == nil then
        return
    end
    if pollRun.countdownLabel ~= nil and pollRun.countdownLabel:getParent() ~= nil then
        pcall(function() pollRun.countdownLabel:setText(poll_countdown(poll)) end)
    end
    if pollRun.voteButtons == nil then
        return
    end
    local counts, bestIdx, bestCount = poll_compute_tallies(poll)
    local selfId = 0
    pcall(function()
        selfId = tonumber(multitode.getApi():getLocalPlayerId()) or 0
    end)
    for _, entry in ipairs(pollRun.voteButtons) do
        if entry.button ~= nil and entry.button:getParent() ~= nil then
            pcall(function()
                entry.button:setText(poll_vote_button_text(
                    poll, entry.optionIdx, counts, bestIdx, bestCount, selfId))
            end)
        end
    end
end

local function close_poll_create_window()
    if pollCreate.window ~= nil then
        pcall(function() pollCreate.window:remove() end)
        pollCreate.window = nil
    end
    pollCreate.answerFields = nil
    pollCreate.durationButtons = nil
    pollCreate.customDurationField = nil
end

local function poll_snapshot_answers()
    if pollCreate.answerFields == nil or pollCreate.draft == nil then
        return
    end
    local out = {}
    for i = 1, #pollCreate.answerFields do
        local text = ""
        pcall(function() text = tostring(pollCreate.answerFields[i]:getText() or "") end)
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        out[i] = text
    end
    pollCreate.draft.options = out
end

local function poll_duration_label(sec)
    sec = tonumber(sec) or 0
    if sec >= 60 then
        local m = math.floor(sec / 60)
        local s = sec % 60
        if s == 0 then
            return m .. " min"
        end
        return m .. "m " .. s .. "s"
    end
    return tostring(sec) .. "s"
end

local function poll_refresh_duration_buttons()
    if pollCreate.durationButtons == nil then
        return
    end
    for _, entry in ipairs(pollCreate.durationButtons) do
        local selected = entry.sec == pollCreate.durationSec
            or (entry.custom and pollCreate.durationSec ~= 20
                and pollCreate.durationSec ~= 45 and pollCreate.durationSec ~= 60)
        pcall(function()
            entry.button:setText(entry.custom and "Custom" or poll_duration_label(entry.sec))
        end)
        -- Selected = darker "pressed" plate so the choice is obvious at a glance.
        pcall(function()
            local blank = C.Game.i.assetManager:getDrawable("blank")
            if selected then
                pcall(function()
                    entry.button:setBackgroundColors(
                        C.Color.new_4f(0.04, 0.06, 0.10, 1),
                        C.Color.new_4f(0.04, 0.06, 0.10, 1),
                        C.Color.new_4f(0.06, 0.08, 0.12, 1),
                        C.Color.new_4f(0.04, 0.06, 0.10, 1))
                end)
                pcall(function()
                    entry.button:setLabelColors(
                        C.MaterialColor.LIGHT_BLUE.P200,
                        C.MaterialColor.LIGHT_BLUE.P200,
                        C.MaterialColor.LIGHT_BLUE.P200,
                        C.MaterialColor.LIGHT_BLUE.P200)
                end)
                if blank ~= nil then
                    pcall(function()
                        entry.button:setBackground(blank:tint(C.Color.new_4f(0.04, 0.06, 0.10, 1)))
                    end)
                end
            else
                pcall(function()
                    entry.button:setBackgroundColors(
                        C.Color.new_4f(0.18, 0.20, 0.26, 1),
                        C.Color.new_4f(0.14, 0.16, 0.22, 1),
                        C.Color.new_4f(0.22, 0.24, 0.30, 1),
                        C.Color.new_4f(0.18, 0.20, 0.26, 1))
                end)
                pcall(function()
                    entry.button:setLabelColors(
                        C.Color.new_4f(1, 1, 1, 0.85),
                        C.Color.new_4f(1, 1, 1, 0.85),
                        C.Color.new_4f(1, 1, 1, 0.85),
                        C.Color.new_4f(1, 1, 1, 0.85))
                end)
                if blank ~= nil then
                    pcall(function()
                        entry.button:setBackground(blank:tint(C.Color.new_4f(0.18, 0.20, 0.26, 1)))
                    end)
                end
            end
        end)
    end
    -- Show/hide custom seconds field: only when Custom is selected.
    if pollCreate.customDurationField ~= nil then
        local isCustom = pollCreate.durationSec ~= 20
            and pollCreate.durationSec ~= 45
            and pollCreate.durationSec ~= 60
        pcall(function()
            pollCreate.customDurationField:setVisible(isCustom)
            if pollCreate.customDurationField.getParent() ~= nil then
                pollCreate.customDurationField:getParent():invalidateHierarchy()
            end
        end)
    end
end

-- Dedicated editor window: question + one field per answer (Discord-style)
-- + duration + Create. Never chains native text inputs — those set
-- pendingWindowReopenFrames and yanked the main menu over the next step.
local function open_poll_create_window()
    close_poll_create_window()

    if refPickerWindow ~= nil then
        pcall(function() refPickerWindow:remove() end)
        refPickerWindow = nil
    end

    pollCreate.draft = pollCreate.draft or { question = "", options = { "", "" }, durationSec = 20 }
    -- Migrate the old comma-string draft (and guarantee 2 slots).
    if type(pollCreate.draft.options) == "string" then
        local migrated = {}
        for token in tostring(pollCreate.draft.options):gmatch("[^,]+") do
            local t = token:gsub("^%s+", ""):gsub("%s+$", "")
            if t ~= "" then
                migrated[#migrated + 1] = t
            end
        end
        pollCreate.draft.options = migrated
    end
    if type(pollCreate.draft.options) ~= "table" or #pollCreate.draft.options < 2 then
        local opts = {}
        if type(pollCreate.draft.options) == "table" then
            for i = 1, #pollCreate.draft.options do
                opts[i] = tostring(pollCreate.draft.options[i] or "")
            end
        end
        while #opts < 2 do
            opts[#opts + 1] = ""
        end
        pollCreate.draft.options = opts
    end
    while #pollCreate.draft.options > 6 do
        table.remove(pollCreate.draft.options)
    end
    pollCreate.durationSec = math.floor(tonumber(pollCreate.draft.durationSec) or 20)
    if pollCreate.durationSec < 1 then
        pollCreate.durationSec = 20
    elseif pollCreate.durationSec > 3600 then
        pollCreate.durationSec = 3600
    end

    local draft = pollCreate.draft
    compute_layout()

    local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
    windowStyle.resizeable = false
    windowStyle.inheritWidgetMinSize = true

    local window = C.Window.new_WS(windowStyle)
    pollCreate.window = window
    window:setTitle("New poll")

    local content = C.Table.new()
    content:left()
    local labelStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL)
    local fieldStyle = C.Game.i.assetManager:getTextFieldStyle(C.Config.FONT_SIZE_X_SMALL)
    local fieldW = 420
    local rowH = 40

    local function make_field(initial, message)
        local field = C.TextField.new(tostring(initial or ""), fieldStyle)
        pcall(function() field:setMessageText(tostring(message or "")) end)
        return field
    end

    -- Question
    content:add(C.Label.new("Question", labelStyle)):left():padBottom(4):row()
    local questionField = make_field(draft.question, "Ask the lobby...")
    content:add(questionField):width(fieldW):height(rowH):left():padBottom(10):row()

    -- Answers: one field each, add/remove buttons (max 6, min 2)
    local answersHeader = C.Table.new()
    answersHeader:add(C.Label.new("Answers", labelStyle)):left():padRight(10)
    content:add(answersHeader):left():padBottom(4):row()

    local answersHolder = C.Table.new()
    content:add(answersHolder):left():padBottom(6):row()

    pollCreate.answerFields = {}

    local function rebuild_answers()
        -- Persist typed text into the draft before wiping the holder.
        if pollCreate.answerFields ~= nil and #pollCreate.answerFields > 0 then
            local saved = {}
            for i = 1, #pollCreate.answerFields do
                local text = ""
                pcall(function() text = tostring(pollCreate.answerFields[i]:getText() or "") end)
                saved[i] = text
            end
            -- Preserve any draft slots the fields have not rendered yet.
            for i = #saved + 1, #(draft.options or {}) do
                saved[i] = draft.options[i]
            end
            draft.options = saved
        end

        answersHolder:clearChildren()
        pollCreate.answerFields = {}

        for i = 1, #draft.options do
            -- Capture the index: the bare loop variable is shared by every
            -- closure, so every Remove button used to delete the same slot.
            local idx = i
            local row = C.Table.new()
            row:add(C.Label.new(tostring(idx) .. ".", labelStyle)):width(28):left():padRight(6)

            local field = make_field(draft.options[idx], "Answer " .. tostring(idx))
            pollCreate.answerFields[idx] = field
            row:add(field):width(fieldW - 140):height(rowH):left():padRight(8)

            if #draft.options > 2 then
                local removeBtn = create_action_button("Remove", function()
                    poll_snapshot_answers()
                    if #draft.options > 2 then
                        table.remove(draft.options, idx)
                        rebuild_answers()
                    end
                end)
                row:add(removeBtn):width(100):height(36):left()
            end

            answersHolder:add(row):left():padBottom(6):row()
        end

        local addRow = C.Table.new()
        local addBtn = create_action_button("+ Add answer", function()
            poll_snapshot_answers()
            if #draft.options < 6 then
                draft.options[#draft.options + 1] = ""
                rebuild_answers()
            else
                multitode.lobby.lastError = "Poll supports at most 6 answers"
                pcall(function() window:setTitle("New poll (max 6 answers)") end)
            end
        end)
        addRow:add(addBtn):width(160):height(40):left()
        local countLabel = C.Label.new(
            string.format("%d / 6", #draft.options), labelStyle)
        addRow:add(countLabel):left():padLeft(10)
        answersHolder:add(addRow):left():padTop(4):row()

        -- Layout refresh: without this the new rows exist in the tree but are
        -- never measured — looks like "+ Add answer" does nothing.
        pcall(function() answersHolder:pack() end)
        pcall(function() content:pack() end)
        pcall(function() content:invalidateHierarchy() end)
        pcall(function()
            if window ~= nil then
                window:fitToContentSimple()
            end
        end)
    end

    rebuild_answers()

    -- Duration: 20s / 45s / 1 min / Custom (1–3600 s, host lobby.createPoll clamp).
    content:add(C.Label.new("Duration", labelStyle)):left():padTop(6):padBottom(4):row()
    local durationRow = C.Table.new()
    pollCreate.durationButtons = {}
    local durationChoices = {
        { sec = 20, custom = false },
        { sec = 45, custom = false },
        { sec = 60, custom = false },
        { sec = 0, custom = true },
    }
    for _, choice in ipairs(durationChoices) do
        local sec = choice.sec
        local isCustom = choice.custom
        local btn = create_action_button(
            isCustom and "Custom" or poll_duration_label(sec),
            function()
                if isCustom then
                    -- Keep a custom value if one is already selected; seed from presets.
                    if pollCreate.durationSec == 20
                        or pollCreate.durationSec == 45
                        or pollCreate.durationSec == 60 then
                        pollCreate.durationSec = 90
                    end
                    if pollCreate.customDurationField ~= nil then
                        pcall(function()
                            pollCreate.customDurationField:setText(tostring(pollCreate.durationSec))
                        end)
                    end
                else
                    pollCreate.durationSec = sec
                end
                draft.durationSec = pollCreate.durationSec
                poll_refresh_duration_buttons()
            end)
        durationRow:add(btn):width(120):height(40):left():padRight(8)
        pollCreate.durationButtons[#pollCreate.durationButtons + 1] =
            { sec = sec, custom = isCustom, button = btn }
    end
    content:add(durationRow):left():padBottom(4):row()

    -- Custom seconds field (hidden until Custom is chosen). Clamped 1–3600 on submit.
    pollCreate.customDurationField = C.TextField.new(
        tostring(pollCreate.durationSec), fieldStyle)
    pcall(function()
        pollCreate.customDurationField:setMessageText("Seconds (1-3600)")
    end)
    content:add(pollCreate.customDurationField)
        :width(200):height(rowH):left():padBottom(10):row()
    pcall(function()
        local isCustom = pollCreate.durationSec ~= 20
            and pollCreate.durationSec ~= 45
            and pollCreate.durationSec ~= 60
        pollCreate.customDurationField:setVisible(isCustom)
    end)
    poll_refresh_duration_buttons()

    local function submit_poll()
        poll_snapshot_answers()
        -- Read live custom seconds if Custom is the active selection.
        local isCustomDur = pollCreate.durationSec ~= 20
            and pollCreate.durationSec ~= 45
            and pollCreate.durationSec ~= 60
        if isCustomDur and pollCreate.customDurationField ~= nil then
            local customSec = tonumber(pollCreate.durationSec)
            pcall(function()
                customSec = tonumber(pollCreate.customDurationField:getText())
            end)
            if customSec ~= nil then
                customSec = math.floor(customSec)
                if customSec < 1 then
                    customSec = 1
                elseif customSec > 3600 then
                    customSec = 3600
                end
                pollCreate.durationSec = customSec
            end
        end
        draft.durationSec = pollCreate.durationSec

        -- Read LIVE from the field — draft.question is only the open-time
        -- seed, so using it blanked the user's typed question and failed
        -- validation (window stayed open, answers kept, question wiped).
        local question = ""
        pcall(function() question = tostring(questionField:getText() or "") end)
        question = question:gsub("^%s+", ""):gsub("%s+$", "")
        draft.question = question
        if question ~= "" then
            pcall(function() questionField:setText(question) end)
        end

        local opts = {}
        for i = 1, #(draft.options or {}) do
            local t = tostring(draft.options[i] or "")
            t = t:gsub("^%s+", ""):gsub("%s+$", "")
            if t ~= "" then
                opts[#opts + 1] = t
            end
        end

        if question == "" then
            multitode.lobby.lastError = "Poll question must not be blank"
            pcall(function() window:setTitle("New poll — question required") end)
            return
        end
        if #opts < 2 then
            multitode.lobby.lastError = "Poll needs at least 2 answers"
            pcall(function() window:setTitle("New poll — need 2 answers") end)
            return
        end

        local ok, err = pcall(multitode.lobby.createPoll, question, opts, pollCreate.durationSec)
        if not ok then
            multitode.lobby.lastError = tostring(err)
            pcall(function() window:setTitle("New poll — " .. tostring(err)) end)
            return
        end

        multitode.lobby.lastError = nil
        pollCreate.draft = nil
        close_poll_create_window()
        if reopen_multiplayer_window ~= nil then
            reopen_multiplayer_window()
        end
    end

    local createBtn = create_action_button("Create poll", function()
        local ok, err = pcall(submit_poll)
        if not ok then
            multitode.lobby.lastError = tostring(err)
            logger:e("Poll create failed: %s", tostring(err))
        end
    end)
    content:add(createBtn):width(200):height(48):left():padTop(6):row()

    local cancelBtn = create_action_button("Cancel", function()
        close_poll_create_window()
    end)
    content:add(cancelBtn):width(200):height(40):left():padTop(4):row()

    window.main:add(content):pad(12):grow()
    C.Game.i.uiManager:addWindow(window)
    window:fitToContentSimple()
    place_window_centered(window)
    window:show()

    -- Native submit must not yank the main menu over this form.
    pendingWindowReopenFrames = -1
    textInputOpen = false
end

local function add_info_row(table, title, value)
    local labelStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL)
    local titleLabel = C.Label.new(title, labelStyle)
    titleLabel:setColor(1, 1, 1, 0.65)
    -- Wrap titles too: without it, long labels ("Show others' marks") painted
    -- over the tip/value column on narrow windows.
    titleLabel:setWrap(true)
    table:add(titleLabel):width(layout.titleW):left():padRight(16):padBottom(8)

    local valueLabel = C.Label.new(tostring(value), labelStyle)
    valueLabel:setWrap(true)
    table:add(valueLabel):width(layout.valueW):left():padBottom(8):row()
    return valueLabel
end

reopen_multiplayer_window = function()
    -- Refresh the EXISTING window in place. It must not be dropped first: every
    -- chat message and lobby state update sets the dirty flag, so removing and
    -- re-creating the Window made it pop/re-centre constantly (and swallowed
    -- clicks while it was swapped out). open_multiplayer_window() detects an
    -- on-screen window and rebuilds only its content.
    local ok, err = pcall(open_multiplayer_window)
    if not ok then
        logger:e("Failed to refresh multiplayer window: %s", tostring(err))
    end
end

local function format_bridge_mode(role)
    if role == "HOST_AND_CLIENT" then
        return "Mode: Host"
    else
        return "Mode: Client"
    end
end

local function next_bridge_mode(role)
    local bridgeModes = {
        "CLIENT",
        "HOST_AND_CLIENT"
    }

    local current = tostring(role or "HOST_AND_CLIENT")

    for i = 1, #bridgeModes do
        if bridgeModes[i] == current then
            return bridgeModes[(i % #bridgeModes) + 1]
        end
    end

    return bridgeModes[1]
end

local function open_username_input()
    local config = multitode.getConfig()

    save_multiplayer_scroll_pos()
    if multiplayerWindow ~= nil then
        multiplayerWindow:remove()
        multiplayerWindow = nil
    end
    chatWindowToggleButton = nil
    textInputOpen = true

    local listener = luajava.createProxy(C.TextInputListener, {
        input = function(_, text)
            textInputOpen = false
            suppressChatEnterUntilRelease = true
            local value = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if value == "" then
                pendingWindowReopenFrames = 2
                return
            end

            multitode.configure({ name = value })
            pendingWindowReopenFrames = 2
        end,
        canceled = function()
            textInputOpen = false
            suppressChatEnterUntilRelease = true
            pendingWindowReopenFrames = 2
        end
    })

    C.Game.i.uiManager:getTextInput(listener, "Change Username", tostring(config.name or ""), "Player name")
end

open_config_text_input = function(title, initialValue, hint, onSubmit)
    -- The native dialog forces a full window remove; keep scroll + position so
    -- the reopen (pendingWindowReopenFrames) does not reset to the top.
    save_multiplayer_scroll_pos()
    if multiplayerWindow ~= nil then
        multiplayerWindow:remove()
        multiplayerWindow = nil
    end
    chatWindowToggleButton = nil
    textInputOpen = true

    local listener = luajava.createProxy(C.TextInputListener, {
        input = function(_, text)
            textInputOpen = false
            suppressChatEnterUntilRelease = true
            local value = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if value ~= "" then
                onSubmit(value)
            end
            pendingWindowReopenFrames = 2
        end,
        canceled = function()
            textInputOpen = false
            suppressChatEnterUntilRelease = true
            pendingWindowReopenFrames = 2
        end
    })

    C.Game.i.uiManager:getTextInput(listener, title, tostring(initialValue or ""), hint)
end

open_send_dialog = function(initialText)
    open_config_text_input("Send Chat", initialText or "", "Message (use +research/+map/+tile)", function(value)
        local ok, err = pcall(multitode.lobby.send_chat, value)
        if not ok then
            logger:e("Failed to send chat: %s", tostring(err))
        end
    end)
end

prefill_send = function(text)
    -- Close any picker window, then open the send dialog with canonical text.
    if refPickerWindow ~= nil then
        refPickerWindow:remove()
        refPickerWindow = nil
    end
    open_send_dialog(text)
end

local function open_host_input()
    local config = multitode.getConfig()
    open_config_text_input("Change IP", config.host, "Server IP", function(value)
        multitode.configure({ host = value })
    end)
end

local function open_port_input()
    local config = multitode.getConfig()
    open_config_text_input("Change Port", config.port, "Server port", function(value)
        local port = tonumber(value)
        if port ~= nil then
            port = math.floor(port)
            multitode.configure({ port = port })
        end
    end)
end

local function hide_multiplayer_window()
    -- Silent hide: keeps lobby + bridge untouched (unlike the title-bar X,
    -- which applies config and restarts the transport).
    -- Intentional close: forget scroll so the next open starts fresh.
    clear_saved_multiplayer_scroll_pos()
    if multiplayerWindow ~= nil then
        local ok, err = pcall(function()
            multiplayerWindow:remove()
        end)
        if not ok then
            logger:e("Failed to hide multiplayer window: %s", tostring(err))
        end
        multiplayerWindow = nil
    end
    chatWindowToggleButton = nil
    -- Drop embedded-chat refs so onChatLogged does not append into a removed tree.
    embed.rows = nil
    embed.scroll = nil
    embed.mainScroll = nil
    clear_poll_ui_refs()
    if levelSel.window ~= nil then
        local ok, err = pcall(function()
            levelSel.window:remove()
        end)
        if not ok then
            logger:e("Failed to hide level window: %s", tostring(err))
        end
        levelSel.window = nil
    end
end

-- Global wrapper: code defined EARLIER in this file (the Attach popup) must not
-- reference the local hide_multiplayer_window directly - that resolves to a nil
-- global and silently does nothing.
function multitode.close_multitode_window()
    if hide_multiplayer_window ~= nil then
        hide_multiplayer_window()
    end
end

-- Roster ready/marksOff value labels, rebuilt with the lobby section; mutated
-- in place by refresh_ready_ui_in_place so flag flips never rebuild.
local rosterReadyLabels = {}

open_multiplayer_window = function(keepX, keepY)
    -- Refresh IN PLACE when the window is already on screen. Creating a new
    -- Window made it pop and re-centre on every button press (and swallowed
    -- clicks while it was swapped out). Only the content is rebuilt now.
    clear_poll_ui_refs()
    clear_toggle_buttons()
    local window = multiplayerWindow
    local rebuilding = window ~= nil and window:getParent() ~= nil
    if not rebuilding then
        -- Text-input path removed the window but kept saved scroll/pos.
        if keepX == nil and savedWinX ~= nil and savedWinY ~= nil then
            keepX, keepY = savedWinX, savedWinY
        end
        window = nil
        multiplayerWindow = nil
    else
        -- Ready / roster / dirty rebuild: capture scroll before clearChildren.
        save_multiplayer_scroll_pos()
    end

    compute_layout()

    if not rebuilding then
        local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
        windowStyle.resizeable = false
        windowStyle.inheritWidgetMinSize = true
        -- CRITICAL: default style wraps window.main in a built-in ScrollPane
        -- (AssetManager.createDefaultWindowStyle sets scrollPaneStyle). Adding our
        -- own ScrollPane inside main then nests two panes: the outer one steals
        -- wheel focus, shows a horizontal bar (vertical scrollbar steals width and
        -- overflows main), and shifts/clips content - which is why the Settings
        -- button fell off-screen and chat text looked cut off. nil = main is a
        -- direct child of the window; only our inner pane scrolls.
        windowStyle.scrollPaneStyle = nil

        window = C.Window.new_WS(windowStyle)
        multiplayerWindow = window
        window:setTitle("")
        window:addListener(C.WindowListener({
            closed = function()
                -- "X" ONLY closes the window. It used to leave the lobby and bounce
                -- the transport, which was counter-intuitive (closing the panel
                -- kicked everyone out / dropped the session).
                local ok, err = pcall(function()
                    if hide_multiplayer_window ~= nil then
                        hide_multiplayer_window()
                    end
                end)
                if not ok then
                    logger:e("Failed to close multiplayer window: %s", tostring(err))
                end
            end
        }))
    end

    local config = multitode.getConfig()
    local content = C.Table.new()
    content:pad(8)
    -- Default Table align is center: when children are wider than the forced
    -- pane width the row starts at a NEGATIVE x and clips the LEFT edge
    -- (the "Settings buttons stuck left / offscreen" report). Force left so
    -- any residual overflow goes right (scroll-clipped) instead.
    pcall(function() content:left() end)

    local titleStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_SMALL)
    local sectionStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL)
    local info = C.Table.new()
    info:setBackground(C.Game.i.assetManager:getDrawable("blank"):tint(C.Color.new_4f(0.08, 0.1, 0.14, 0.9)))
    info:pad(16)
    pcall(function() info:left() end)
    local infoTitle = C.Label.new("Multitode", titleStyle)
    infoTitle:setColor(C.MaterialColor.LIGHT_BLUE.P500)
    info:add(infoTitle):colspan(2):left():padBottom(14):row()
    add_info_row(info, "Version", multitode.version)
    pcall(function()
        local mk = multitode.marks
        local live = 0
        pcall(function() live = tonumber(multitode.getApi():getTileMarkCount()) or 0 end)
        local sent = 0
        local recv = 0
        if mk ~= nil then
            sent = mk.sentCount or 0
            recv = mk.recvCount or 0
        end
        add_info_row(info, "Marks", string.format("live=%d sent=%d recv=%d", live, sent, recv))
    -- (Lab/analysis readouts used to sit here. They are test scaffolding, not player
    -- features, so they stay out of the user-facing window.)

    -- ---------------------------------------------------------------- lab (F9)
    -- Buttons for the stress harness. Each one runs the real paths a match uses, so
    -- whatever they break is something a player could hit too.
    -- (Lab buttons used to sit here. They are gone: the tests are development tooling and
    -- must not appear in a player-facing menu.)
        if mk ~= nil and mk.lastSend ~= nil then
            add_info_row(info, "  last send", tostring(mk.lastSend))
        end
        if mk ~= nil and mk.lastRecv ~= nil then
            add_info_row(info, "  last recv", tostring(mk.lastRecv))
        end
    end)
    add_info_row(info, "Main developer", "sysfab")
    add_info_row(info, "Co-author", "Chmoner34")

    content:add(info):width(layout.contentW):left():padBottom(12):row()

    -- Lobby state for the mode gate below and the lobby section: compute once.
    local lobbyState = multitode.lobby and multitode.lobby.state or "IDLE"
    local isInLobby = lobbyState ~= "IDLE"

    -- Flipping roles mid-lobby kicked the peer and half-killed the session,
    -- and a flip to "host" makes a second broadcast authority (80_'s client
    -- handlers - apply / pause / speed - never check senders). Gate the
    -- toggle on the lobby.
    local bridgeModeButton = create_action_button(
        format_bridge_mode(config.role) .. (isInLobby and " (in lobby)" or ""),
        function()
            -- Same guard live: a window from before the lobby must not flip
            -- roles either (greying only covers the fresh button).
            local liveState = multitode.lobby and multitode.lobby.state or "IDLE"
            if liveState ~= "IDLE" then
                if multitode.show_toast ~= nil then
                    multitode.show_toast("Leave the lobby before switching mode")
                end
                return
            end
            local nextRole = next_bridge_mode(multitode.getConfig().role)
            multitode.configure({ role = nextRole })
            -- Persist immediately: otherwise a hide-close (no restart) followed
            -- by a game kill loses the change, and the next boot shows a stale mode.
            pcall(multitode.saveConfig)
            reopen_multiplayer_window()
        end
    )
    if isInLobby then
        -- ComplexButton.setEnabled greys the button AND eats clicked()
        -- (it checks the flag before running anything).
        pcall(function() bridgeModeButton:setEnabled(false) end)
    end

    local usernameButton = create_action_button("Change Username", open_username_input)

    local controls = C.Table.new()
    controls:add(bridgeModeButton):width(260):left():padRight(12)
    controls:add(usernameButton):width(260):left()
    content:add(controls):left():padBottom(12):row()

    local hostButton = create_action_button("IP: " .. tostring(config.host), open_host_input)
    local portButton = create_action_button("Port: " .. tostring(config.port), open_port_input)

    local networkControls = C.Table.new()
    networkControls:add(hostButton):width(260):left():padRight(12)
    networkControls:add(portButton):width(260):left()
    content:add(networkControls):left():padBottom(12):row()

    -- Lobby section (uses the state computed above).
    local isHost = config.role == "HOST_AND_CLIENT" or config.role == "HOST"

    local lobbySection = C.Table.new()
    lobbySection:setBackground(C.Game.i.assetManager:getDrawable("blank"):tint(C.Color.new_4f(0.06, 0.08, 0.12, 0.85)))
    lobbySection:pad(12)
    pcall(function() lobbySection:left() end)

    local lobbyTitle = C.Label.new("Lobby", sectionStyle)
    lobbyTitle:setColor(C.MaterialColor.LIGHT_BLUE.P400)
    lobbySection:add(lobbyTitle):colspan(2):left():padBottom(8):row()

    if isInLobby then
        -- Show lobby info
        local lobbyName = multitode.lobby.lobbyName or "Unknown"
        add_info_row(lobbySection, "Name", lobbyName)
        -- State is in the title bar now

        if multitode.lobby.selectedLevel then
            -- Level is in the title bar now
        else
            -- Level is in the title bar now
        end

        if isHost then
            local chooseLevelButton = create_action_button("Choose Level", function()
                levelSel.attach = false
                open_level_select_window(levelSel.page)
            end)
            lobbySection:add(chooseLevelButton):width(260):colspan(2):left():padTop(4):row()
        end

        -- Player list
        rosterReadyLabels = {}
        local playerCount = 0
        for _ in pairs(multitode.lobby.players) do playerCount = playerCount + 1 end
        -- Players is in the title bar now

        for id, info in pairs(multitode.lobby.players) do
            local readyStr = info.ready and "[READY]" or "[ ]"
            if info.marksOff == true then
                readyStr = readyStr .. " [marks off]"
            end
            -- Keep the label: ready/marksOff flips tweak it in place
            -- (refresh_ready_ui_in_place), no window rebuild.
            rosterReadyLabels[id] = add_info_row(lobbySection, "  " .. tostring(info.name), readyStr)
        end

        -- Transport diagnostics (separate from the lobby roster)
        local inSessionOk, inSessionInfo = pcall(multitode.getSessionInfo)
        if inSessionOk and inSessionInfo ~= nil then
            add_info_row(lobbySection, "Link", tostring(inSessionInfo.connectionState or "?")
                .. " peers=" .. tostring(inSessionInfo.connectedPeerCount or 0)
                .. " ping=" .. tostring(ping_ms()) .. "ms")
        end

        if multitode.lobby.lastError then
            add_info_row(lobbySection, "Error", tostring(multitode.lobby.lastError))
        end

        -- Chat preview + send
        local chatTitle = C.Label.new("Chat", sectionStyle)
        chatTitle:setColor(C.MaterialColor.LIGHT_BLUE.P400)
        lobbySection:add(chatTitle):colspan(2):left():padTop(8):padBottom(4):row()

        local chatWindowButton = create_action_button(
            is_chat_window_visible() and "Chat window: ON" or "Chat window: OFF",
            function()
                if toggle_chat_window ~= nil then
                    toggle_chat_window()
                end
            end)
        chatWindowToggleButton = chatWindowButton
        -- Status line: one glance should answer "what state am I in". Role, head-count,
        -- the level about to be played and who you are as - none of that was visible
        -- anywhere, which is most of why the window felt confusing.
        pcall(function()
            local roleText = "Not in a session"
            pcall(function()
                local st = multitode.state()
                if st ~= nil and st.role ~= nil then
                    if tostring(st.role) == "CLIENT" then
                        roleText = "Client"
                    else
                        roleText = "Host"
                    end
                end
            end)
            local players = 0
            local maxPlayers = 8
            pcall(function()
                local list = multitode.lobby and multitode.lobby.players
                if list ~= nil then
                    for _ in pairs(list) do
                        players = players + 1
                    end
                end
                if multitode.lobby ~= nil and multitode.lobby.maxPlayers ~= nil then
                    maxPlayers = tonumber(multitode.lobby.maxPlayers) or maxPlayers
                end
            end)
            local level = "-"
            pcall(function()
                if multitode.lobby ~= nil and multitode.lobby.selectedLevel ~= nil then
                    level = tostring(multitode.lobby.selectedLevel)
                end
            end)
            local name = "?"
            pcall(function()
                name = tostring(multitode.getConfig().name or "?")
            end)
            -- Shown in the title bar (the blue strip) instead of as a body row: it is state
            -- about the whole window, not another field, and repeating it in the body just
            -- added another line to scroll past.
            local statusText = string.format("%s  |  %d/%d players  |  level %s  |  you: %s",
                roleText, players, maxPlayers, level, name)
            pcall(function() window:setTitle(statusText) end)
            multitode._windowStatusText = statusText
        end)

        lobbySection:add(chatWindowButton):width(260):colspan(2):left():padBottom(4):row()

        -- Embedded chat history: same rows/colours/line format as the detached
        -- chat window, sized to the section width. Fixed height so the main
        -- window does not grow with every message (that was the old preview bug).
        -- Separate table from chatUI.rowsTable so the detached window is untouched.
        pcall(function()
            embed.rows = nil
            embed.scroll = nil
            -- Section pad is 12 each side; rows table adds pad(4).
            local chatW = math.max(280, layout.contentW - 24)
            local chatH = CHAT_PANE_H
            embed.rowW = math.max(240, chatW - 8)
            embed.rows = C.Table.new()
            embed.rows:pad(4)
            pcall(function() embed.rows:left() end)
            local log = multitode.lobby.chatLog or {}
            local firstIndex = math.max(1, #log - 60)
            for i = firstIndex, #log do
                if log[i] ~= nil then
                    add_chat_row_to(embed.rows, log[i], embed.rowW)
                end
            end
            embed.rows:pack()

            local pane = C.ScrollPane.new_A_SPS(embed.rows,
                C.Game.i.assetManager:getScrollPaneStyle(16.0))
            embed.scroll = pane
            pcall(function() pane:setFadeScrollBars(false) end)
            pcall(function() pane:setScrollingDisabled(true, false) end)
            -- Nested under the main content scroll: steal wheel focus on enter,
            -- give it back on exit (otherwise the outer pane eats every wheel event).
            -- InputListener has no table-ctor overload (unlike WindowListener);
            -- use createProxy the same way TextInputListener is built.
            pcall(function()
                pane:addListener(luajava.createProxy(C.InputListener, {
                    enter = function(_, _event, _x, _y, _pointer, _from)
                        pcall(function()
                            local st = C.Game.i.uiManager and C.Game.i.uiManager.stage
                            if st ~= nil then
                                st:setScrollFocus(pane)
                            end
                        end)
                    end,
                    exit = function(_, _event, _x, _y, _pointer, _to)
                        pcall(function()
                            local st = C.Game.i.uiManager and C.Game.i.uiManager.stage
                            if st ~= nil and embed.mainScroll ~= nil then
                                st:setScrollFocus(embed.mainScroll)
                            end
                        end)
                    end,
                }))
            end)
            lobbySection:add(pane):width(chatW):height(chatH):colspan(2):left():padTop(4):padBottom(4):row()
            pcall(function() force_scroll_bottom(pane, embed.rows, "embed") end)
        end)

        local chatButtons = C.Table.new()
        local sendChatButton = create_action_button("Send Chat", function()
            open_send_dialog("")
        end)
        chatButtons:add(sendChatButton):width(260):left():padRight(12)
        local attachButton = create_action_button("Attach +", function()
            open_attach_kind_window()
        end)
        chatButtons:add(attachButton):width(260):left()
        lobbySection:add(chatButtons):colspan(2):left():padTop(4):row()

        -- Polls — directly under chat (was buried under Leave/Resync).
        clear_poll_ui_refs()
        local pollTitle = C.Label.new("Polls", sectionStyle)
        pollTitle:setColor(C.MaterialColor.LIGHT_BLUE.P400)
        lobbySection:add(pollTitle):colspan(2):left():padTop(8):padBottom(4):row()

        local poll = multitode.lobby.poll
        if poll ~= nil then
            add_info_row(lobbySection, "Q", tostring(poll.question or ""))
            -- Live countdown label: frame hook ticks this without a rebuild.
            local tinyStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL)
            local countdownTitle = C.Label.new("Closes in", tinyStyle)
            countdownTitle:setColor(1, 1, 1, 0.65)
            lobbySection:add(countdownTitle):width(layout.titleW):left():padRight(16):padBottom(8)
            local countdownValue = C.Label.new(poll_countdown(poll), tinyStyle)
            pollRun.countdownLabel = countdownValue
            lobbySection:add(countdownValue):width(layout.valueW):left():padBottom(8):row()

            local counts, bestIdx, bestCount = poll_compute_tallies(poll)
            local selfId = 0
            pcall(function()
                selfId = tonumber(multitode.getApi():getLocalPlayerId()) or 0
            end)
            pollRun.voteButtons = {}
            for i, opt in ipairs(poll.options or {}) do
                local voteButton = create_action_button(
                    poll_vote_button_text(poll, i, counts, bestIdx, bestCount, selfId),
                    function()
                        local o = i
                        local ok, err = pcall(multitode.lobby.votePoll, o)
                        if not ok then
                            logger:e("Failed to vote: %s", tostring(err))
                        end
                        -- Patch labels in place — do NOT reopen/rebuild.
                        refresh_poll_ui_in_place()
                    end)
                pollRun.voteButtons[#pollRun.voteButtons + 1] = { button = voteButton, optionIdx = i }
                lobbySection:add(voteButton):width(420):colspan(2):left():padTop(2):row()
            end
            if isHost then
                local closeNowButton = create_action_button("Close Now", function()
                    local ok, err = pcall(multitode.lobby.closePollNow)
                    if not ok then
                        logger:e("Failed to close poll: %s", tostring(err))
                    end
                end)
                lobbySection:add(closeNowButton):width(260):colspan(2):left():padTop(6):row()
            end
            add_info_row(lobbySection, "Tip", "Countdown/votes update live")
        else
            local canCreatePoll = isHost
                or (multitode.settings ~= nil and multitode.settings.allowPollsForEveryone == true)
            if canCreatePoll then
                local newPollButton = create_action_button("New Poll", function()
                    open_poll_create_window()
                end)
                lobbySection:add(newPollButton):width(260):colspan(2):left():padTop(4):row()
            end
            local history = multitode.lobby.pollHistory or {}
            local shown = 0
            for i = #history, 1, -1 do
                if shown >= 3 then
                    break
                end
                local h = history[i]
                if h ~= nil then
                    shown = shown + 1
                    local winner = tostring((h.options or {})[tonumber(h.winnerIdx) or 1] or "?")
                    add_info_row(lobbySection, "Was: " .. tostring(h.question or ""), "→ " .. winner)
                end
            end
        end

        -- Lobby actions
        if isHost then
            local startButton = create_action_button("Start Game", function()
                local ok, err = pcall(multitode.lobby.start_game)
                if not ok then
                    logger:e("Failed to start game: %s", tostring(err))
                    multitode.lobby.lastError = tostring(err)
                else
                    multitode.lobby.lastError = nil
                end
                reopen_multiplayer_window()
            end)
            lobbySection:add(startButton):width(260):colspan(2):left():padTop(8):row()
        end

        if not isHost then
            local selfId = 0
            local okId, myId = pcall(function()
                return multitode.getApi():getLocalPlayerId()
            end)
            if okId and myId ~= nil then
                selfId = tonumber(myId) or 0
            end
            local myEntry = multitode.lobby.players[selfId]
            local amReady = myEntry ~= nil and myEntry.ready == true
            local readyButton = create_action_button(
                amReady and "Ready: YES" or "Ready: NO",
                function()
                    local nextReady = not amReady
                    local ok, err = pcall(multitode.lobby.set_ready, nextReady)
                    if not ok then
                        logger:e("Failed to set ready: %s", tostring(err))
                    else
                        amReady = nextReady
                        if not set_toggle_text("ready",
                                amReady and "Ready: YES" or "Ready: NO") then
                            -- Roster line for this player still needs a rebuild;
                            -- only fall back when the button ref is gone.
                            reopen_multiplayer_window()
                        end
                    end
                end)
            bind_toggle("ready", readyButton)
            lobbySection:add(readyButton):width(260):colspan(2):left():padTop(4):row()
        end

        local leaveButton = create_action_button("Leave Lobby", function()
            local ok, err = pcall(multitode.lobby.leave)
            if not ok then
                logger:e("Failed to leave lobby: %s", tostring(err))
            end
            reopen_multiplayer_window()
        end)
        lobbySection:add(leaveButton):width(260):colspan(2):left():padTop(4):row()
        diagUI.leaveButton = leaveButton
        diagUI.lobbySection = lobbySection

        -- Task 7: on-demand mid-game resync (host broadcasts, client asks).
        local resyncButton = create_action_button(
            isHost and "Resync Match (broadcast)" or "Resync Match (request)",
            function()
                if isHost then
                    local ok, err = pcall(function()
                        multitode.levelSync.resyncNow()
                    end)
                    if not ok then
                        logger:e("Failed to broadcast resync: %s", tostring(err))
                        multitode.lobby.lastError = tostring(err)
                    end
                else
                    local ok, err = pcall(function()
                        multitode.net.sendToHost("itd", "resync_request", {})
                    end)
                    if not ok then
                        logger:e("Failed to request resync: %s", tostring(err))
                        multitode.lobby.lastError = tostring(err)
                    end
                end
                reopen_multiplayer_window()
            end)
        lobbySection:add(resyncButton):width(260):colspan(2):left():padTop(4):row()

        -- Polls already rendered directly under Chat (above).
    else
        -- Not in lobby -- show create/join options
        local outSessionOk, outSessionInfo = pcall(multitode.getSessionInfo)
        if outSessionOk and outSessionInfo ~= nil then
            add_info_row(lobbySection, "Link", tostring(outSessionInfo.connectionState or "?")
                .. " ping=" .. tostring(ping_ms()) .. "ms")
        end

        if multitode.lobby.lastError then
            add_info_row(lobbySection, "Error", tostring(multitode.lobby.lastError))
        end

        if isHost then
            local createLobbyButton = create_action_button("Create Lobby", function()
                local name = tostring(config.name or "Player") .. "'s Game"
                local ok, err = pcall(function()
                    multitode.lobby.create(name, "", 8)
                end)
                if not ok then
                    logger:e("Failed to create lobby: %s", tostring(err))
                end
                reopen_multiplayer_window()
            end)
            lobbySection:add(createLobbyButton):width(260):colspan(2):left():row()
        else
            local joinLobbyButton = create_action_button("Join Host", function()
                local ok, err = pcall(function()
                    multitode.lobby.join("")
                end)
                if not ok then
                    logger:e("Failed to join lobby: %s", tostring(err))
                end
                reopen_multiplayer_window()
            end)
            lobbySection:add(joinLobbyButton):width(260):colspan(2):left():row()
        end
    end

    -- +24 slop: the two-column rows (title+value) plus the table's 12px side
    -- pads need contentW+8 minimum; forcing exactly contentW clipped the right
    -- description column by ~8-16px (the "Settings cut off" report, twice).
    -- Sections are width(layout.contentW) with internal pad(12)/pad(16); the
    -- two-column rows are sized to fit that inner width in compute_layout().
    content:add(lobbySection):width(layout.contentW):left():padBottom(12):row()

    local settingsButton = create_action_button(
        diagUI.showSettings and "Hide Settings" or "Settings",
        function()
            diagUI.showSettings = not diagUI.showSettings
            reopen_multiplayer_window()
        end)
    content:add(settingsButton):width(260):left():padBottom(8):row()

    -- Hoisted so GEOM3 below can read its X after layout (was block-local).
    local settingsSection = nil

    if diagUI.showSettings then
        settingsSection = C.Table.new()
        settingsSection:setBackground(C.Game.i.assetManager:getDrawable("blank"):tint(C.Color.new_4f(0.06, 0.08, 0.12, 0.85)))
        settingsSection:pad(12)
        -- Same as content: center-align would shift the whole section left when
        -- its column widths (button col + info rows) exceed the forced cell width.
        pcall(function() settingsSection:left() end)

        local settingsTitle = C.Label.new("Settings", sectionStyle)
        settingsTitle:setColor(C.MaterialColor.LIGHT_BLUE.P400)
        settingsSection:add(settingsTitle):colspan(2):left():padBottom(8):row()

        local mode = multitode.settings ~= nil and multitode.settings.unavailableMode or "no"
        local modeButton = create_action_button(
            "Locked refs: " .. (mode == "context" and "CONTEXT" or "NO"),
            function()
                if multitode.settings.unavailableMode == "context" then
                    multitode.settings.unavailableMode = "no"
                else
                    multitode.settings.unavailableMode = "context"
                end
                local nextMode = multitode.settings.unavailableMode
                if not set_toggle_text("lockedRefs",
                        "Locked refs: " .. (nextMode == "context" and "CONTEXT" or "NO")) then
                    reopen_multiplayer_window()
                end
            end)
        bind_toggle("lockedRefs", modeButton)
        settingsSection:add(modeButton):width(320):colspan(2):left():padTop(4):row()

        local allowPolls = multitode.settings ~= nil
            and multitode.settings.allowPollsForEveryone == true
        if isHost then
            local pollsButton = create_action_button(
                "Polls for all: " .. (allowPolls and "ON" or "OFF"),
                function()
                    local nextVal = not (multitode.settings.allowPollsForEveryone == true)
                    multitode.settings.allowPollsForEveryone = nextVal
                    -- Push to clients immediately (state broadcasts are otherwise
                    -- roster-driven; without this the client never shows New Poll).
                    pcall(function()
                        if multitode.lobby ~= nil and multitode.lobby.broadcastState ~= nil then
                            multitode.lobby.broadcastState()
                        end
                    end)
                    if not set_toggle_text("pollsForAll",
                            "Polls for all: " .. (nextVal and "ON" or "OFF")) then
                        reopen_multiplayer_window()
                    end
                end)
            bind_toggle("pollsForAll", pollsButton)
            settingsSection:add(pollsButton):width(320):colspan(2):left():padTop(4):row()
        else
            add_info_row(settingsSection, "Polls for all", allowPolls and "ON (host)" or "OFF (host)")
        end

        -- Release: voting is a dormant v2 stub, so release is host-decides.
        -- Locked, unclickable row (V2: bring the toggle back here instead of
        -- rewriting it).
        local bonusModeButton = create_action_button("Boost select: Host only", function()
            -- no-op: voting unlocks in v2
        end)
        if isHost then
            settingsSection:add(bonusModeButton):width(320):colspan(2):left():padTop(4):row()
        else
            add_info_row(settingsSection, "Boost select", "Host only (host)")
        end

        -- Super-log moved to the development lab window (Shift+F9). It is a diagnostic
        -- switch for chasing multiplayer issues, not something a player needs to see.

        local quickMsgsOn = chat_quick_enabled()
        local quickMsgsButton = create_action_button(
            "Quick messages: " .. (quickMsgsOn and "ON" or "OFF"),
            function()
                pcall(function()
                    multitode.settings = multitode.settings or {}
                    multitode.settings.quickMessages = not chat_quick_enabled()
                end)
                local on = chat_quick_enabled()
                if not set_toggle_text("quickMsgs",
                        "Quick messages: " .. (on and "ON" or "OFF")) then
                    reopen_multiplayer_window()
                end
            end)
        bind_toggle("quickMsgs", quickMsgsButton)
        settingsSection:add(quickMsgsButton):width(320):colspan(2):left():padTop(4):row()
        add_info_row(settingsSection, "Quick messages", "top-screen chat popups in match")

        local markKey = (multitode.marks ~= nil and multitode.marks.keyName) or "M"
        local markKeyButton = create_action_button("Tile-mark key: " .. tostring(markKey), function()
            open_config_text_input("Tile-mark key", tostring(markKey), "single letter, e.g. M", function(value)
                if multitode.marks ~= nil then
                    multitode.marks.setKey(value)
                end
                local newKey = (multitode.marks ~= nil and multitode.marks.keyName) or value or "M"
                if not set_toggle_text("markKey", "Tile-mark key: " .. tostring(newKey)) then
                    reopen_multiplayer_window()
                end
            end)
        end)
        bind_toggle("markKey", markKeyButton)
        settingsSection:add(markKeyButton):width(320):colspan(2):left():padTop(4):row()
        add_info_row(settingsSection, "Shift + key", "marks NOT here")

        -- Sync precision: how often the host heartbeat (and therefore the tick
        -- correction) runs. On a good/local link a tighter period is nearly free.
        local precisionLevels = {
            { label = "Precise (0.25s)", value = 0.25 },
            { label = "High (0.5s)", value = 0.5 },
            { label = "Normal (1s)", value = 1.0 },
            { label = "Relaxed (2s)", value = 2.0 },
        }
        local currentPrecision = 0.5
        pcall(function()
            if multitode.itd ~= nil and tonumber(multitode.itd.heartbeatPeriodSec) ~= nil then
                currentPrecision = tonumber(multitode.itd.heartbeatPeriodSec)
            end
        end)
        local precisionLabel = "High (0.5s)"
        for i = 1, #precisionLevels do
            if math.abs(precisionLevels[i].value - currentPrecision) < 0.001 then
                precisionLabel = precisionLevels[i].label
            end
        end
        local precisionValue = currentPrecision
        local precisionButton = create_action_button("Sync: " .. precisionLabel, function()
            local nextValue = precisionLevels[1].value
            local nextLabel = precisionLevels[1].label
            for i = 1, #precisionLevels do
                if math.abs(precisionLevels[i].value - precisionValue) < 0.001 then
                    local nxt = precisionLevels[i + 1] or precisionLevels[1]
                    nextValue = nxt.value
                    nextLabel = nxt.label
                end
            end
            precisionValue = nextValue
            pcall(function()
                multitode.itd = multitode.itd or {}
                multitode.itd.heartbeatPeriodSec = nextValue
            end)
            if not set_toggle_text("syncPrecision", "Sync: " .. nextLabel) then
                reopen_multiplayer_window()
            end
        end)
        bind_toggle("syncPrecision", precisionButton)
        settingsSection:add(precisionButton):width(320):colspan(2):left():padTop(4):row()
        add_info_row(settingsSection, "Sync precision", "tighter = better on good links")

        local autoResyncOn = true
        pcall(function()
            if multitode.itd ~= nil and multitode.itd.autoResyncOnMismatch == false then
                autoResyncOn = false
            end
        end)
        local autoResyncButton = create_action_button("Auto-resync: " .. (autoResyncOn and "ON" or "OFF"), function()
            autoResyncOn = not autoResyncOn
            pcall(function()
                multitode.itd = multitode.itd or {}
                multitode.itd.autoResyncOnMismatch = autoResyncOn
            end)
            if not set_toggle_text("autoResync",
                    "Auto-resync: " .. (autoResyncOn and "ON" or "OFF")) then
                reopen_multiplayer_window()
            end
        end)
        bind_toggle("autoResync", autoResyncButton)
        settingsSection:add(autoResyncButton):width(320):colspan(2):left():padTop(4):row()
        add_info_row(settingsSection, "Auto-resync", "repair a diverged world automatically")

        -- Marks got their own window (Ctrl+M, chat style); the full controls
        -- live there so this menu stays small.
        local marksMenuButton = create_action_button("Marks menu (Ctrl+M)", function()
            pcall(function()
                if _G.multitode.toggle_marks_window ~= nil then
                    _G.multitode.toggle_marks_window()
                end
            end)
        end)
        settingsSection:add(marksMenuButton):width(320):colspan(2):left():padTop(4):row()
        add_info_row(settingsSection, "Tile marks", "separate menu (Ctrl+M)")

        -- Cross-map status panel (per-map channel dimension).
        pcall(function()
            local act = multitode.lobby and multitode.lobby.mapActivity
            local ourCh = (multitode.lobby and (multitode.lobby.mapChannel
                or multitode.lobby.selectedLevel)) or "*"
            if act ~= nil then
                local mapTitle = C.Label.new("Map channels", sectionStyle)
                mapTitle:setColor(C.MaterialColor.LIGHT_BLUE.P400)
                settingsSection:add(mapTitle):colspan(2):left():padTop(8):padBottom(4):row()
                add_info_row(settingsSection, "This map", tostring(ourCh))
                local shown = 0
                for ch, entry in pairs(act) do
                    if shown >= 6 then break end
                    shown = shown + 1
                    local age = "?"
                    pcall(function()
                        local now = 0
                        now = multitode.now_ms()
                        if entry.lastAt ~= nil and now > 0 then
                            age = tostring(math.floor((now - entry.lastAt) / 1000)) .. "s ago"
                        end
                    end)
                    add_info_row(settingsSection, "  " .. tostring(ch),
                        age .. " (" .. tostring(entry.lastSender or "?") .. ")")
                end
                if shown == 0 then
                    add_info_row(settingsSection, "Activity", "none yet this session")
                end
            end
        end)

        content:add(settingsSection):width(layout.contentW):left():padBottom(12):row()
    end

    local closeButton = create_action_button("Close", hide_multiplayer_window)
    content:add(closeButton):width(260):left():row()

    window.main:clearChildren()
    -- Bound the height and scroll the content. The column outgrew the screen, so its bottom -
    -- the whole Settings section and the last buttons - fell past the edge, became
    -- unreachable, and left vertical centering nothing to work with. Same scroll-pane
    -- pattern the chat window uses. The plain add stays as a fallback, so a failure here
    -- can never leave the window empty. Guarded against being applied twice.
    pcall(function() content:pack() end)
    local addedWithScroll = false
    pcall(function()
        local scrollContent = C.ScrollPane.new_A_SPS(content,
            C.Game.i.assetManager:getScrollPaneStyle(16.0))
        pcall(function() scrollContent:setFadeScrollBars(false) end)
        pcall(function() scrollContent:setScrollingDisabled(true, false) end)
        local screenH = 0
        pcall(function() screenH = C.Gdx.graphics:getHeight() end)
        local maxH = (screenH > 0) and (screenH - 90) or 600
        -- Measured, not guessed (the handoff forbids another guess): size the pane
        -- to the packed content's natural width, clamped to the screen, with a
        -- floor of layout.contentW. A row wider than the old fixed width (the
        -- two-column Settings rows) then gets room instead of being clipped.
        local naturalW = layout.contentW
        pcall(function()
            local w = content:getPrefWidth()
            if w == nil or (tonumber(w) ~= nil and tonumber(w) <= 0) then
                w = content:getWidth()
            end
            if w ~= nil and tonumber(w) ~= nil and tonumber(w) > 0 then
                naturalW = math.floor(tonumber(w))
            end
        end)
    -- Floor at layout.contentW, but never grow past it: rows are sized to fit
    -- that width inside their sections, so a larger pane only introduced a
    -- horizontal offset that clipped the LEFT title column.
    -- content:pad(8) adds 16px of horizontal padding on top of the row widths,
    -- so the real pref is layout.contentW+16; allow that (capped by the stage
    -- clamp below) instead of squeezing the table and center-clipping left.
    if naturalW < layout.contentW then
        naturalW = layout.contentW
    elseif naturalW > layout.contentW and naturalW <= layout.contentW + 16 then
        naturalW = math.floor(naturalW)
    elseif naturalW > layout.contentW + 16 then
        naturalW = layout.contentW + 16
    end
        pcall(function()
            local stage = C.Game.i.uiManager and C.Game.i.uiManager.stage
            if stage ~= nil then
                local sw = tonumber(stage:getWidth())
                if sw ~= nil and sw > 100 and naturalW > math.floor(sw - 64) then
                    naturalW = math.floor(sw - 64)
                end
            end
        end)
        pcall(function()
            scrollContent:setWidth(naturalW)
        end)
        pcall(function() scrollContent:setScrollX(0) end)
        pcall(function()
            if scrollContent.setScrollingDisabled ~= nil then
                scrollContent:setScrollingDisabled(true, false)
            end
        end)
        -- GEOM: settingsButton must sit inside the pane's scroll range after layout.
        pcall(function()
            if settingsButton ~= nil and settingsButton.getParent ~= nil then
                local sbY = settingsButton:getY()
                local sbH = settingsButton:getHeight()
                local spY = scrollContent:getY()
                local spH = scrollContent:getHeight()
                local contentX = 0
                local secX = -1
                local scrollXv = -1
                pcall(function() contentX = content:getX() end)
                pcall(function()
                    if diagUI.showSettings and settingsSection ~= nil then
                        secX = settingsSection:getX()
                    end
                end)
                pcall(function()
                    if scrollContent.getScrollX ~= nil then
                        scrollXv = scrollContent:getScrollX()
                    end
                end)
                logger:i("GEOM3 settingsBtn y=%s h=%s pane y=%s h=%s contentH=%s layoutW=%s contentX=%s settingsSecX=%s scrollX=%s naturalW=%s",
                    tostring(sbY), tostring(sbH), tostring(spY), tostring(spH),
                    tostring(content:getHeight()), tostring(layout.contentW),
                    tostring(contentX), tostring(secX), tostring(scrollXv),
                    tostring(naturalW))
            end
        end)
        -- The pane must hold SCROLL FOCUS or the mouse wheel is delivered to the stage
        -- instead of to it - which is why the content would not scroll with the wheel even
        -- though the drag bar worked.
        pcall(function()
            local stage = C.Game.i.uiManager and C.Game.i.uiManager.stage
            if stage ~= nil then
                stage:setScrollFocus(scrollContent)
            end
        end)
        -- Remember the outer pane so the embedded chat can restore wheel focus.
        embed.mainScroll = scrollContent
        window.main:add(scrollContent):pad(16):maxHeight(maxH):grow()
        addedWithScroll = true
        -- Put the player back where they were before the rebuild / dialog.
        schedule_main_scroll_restore()
    end)
    if not addedWithScroll then
        logger:w("Multitode: scrollable content unavailable, using a plain layout")
        window.main:add(content):pad(16):grow()
    end
    if not rebuilding then
        C.Game.i.uiManager:addWindow(window)
    end
    window:fitToContentSimple()
    if not rebuilding then
        if keepX ~= nil and keepY ~= nil then
            window:setPosition(keepX, keepY)
        else
            -- The scroll pane bounded the content, but fitToContentSimple() then grew the WINDOW
    -- back to full content height, so it still ran off the bottom of the screen. Clamp the
    -- window itself, right before it is centred, so centering has something to work with.
    pcall(function()
        local screenH = 0
        pcall(function() screenH = C.Gdx.graphics:getHeight() end)
        if screenH > 0 then
            local capped = screenH - 90
            if window:getHeight() > capped then
                window:setHeight(capped)
            end
        end
    end)
    -- Status in the title bar, set LAST on purpose: the assembly sets its own title later
    -- ("Multitode"), which silently overwrote the value we stored while building the body.
    -- Anything wanting the window title has to run after that.
    pcall(function()
        if multitode._windowStatusText ~= nil then
            window:setTitle(multitode._windowStatusText)
        end
    end)
    -- Let the player resize the window by dragging its edge, like any normal window. The
    -- style is created with resizeable = false, so both the style and the window are set.
    pcall(function()
        if windowStyle ~= nil then
            windowStyle.resizeable = true
            windowStyle.minWidth = 320
            windowStyle.minHeight = 240
        end
        window:setResizable(true)
    end)
    place_window_centered(window)
        end
        window:show()
    end
    -- A poll editor (or any modal child) must stay above a content rebuild.
    pcall(function()
        if pollCreate.window ~= nil and pollCreate.window:getParent() ~= nil then
            pollCreate.window:toFront()
        end
    end)
    pcall(function()
        local p = window:getParent()
        local lbx, lbw, lsx, lsw = "?","?","?","?"
        if diagUI.leaveButton ~= nil then
            lbx, lbw = diagUI.leaveButton:getX(), diagUI.leaveButton:getWidth()
        end
        if diagUI.lobbySection ~= nil then
            lsx, lsw = diagUI.lobbySection:getX(), diagUI.lobbySection:getWidth()
        end
        logger:i("GEOM2 win=%s,%s@%s,%s parent=%s,%s leavebtn=%s,%s lobbysec=%s,%s content=%s",
            tostring(window:getWidth()), tostring(window:getHeight()),
            tostring(window:getX()), tostring(window:getY()),
            tostring(p:getWidth()), tostring(p:getHeight()),
            tostring(lbx), tostring(lbw), tostring(lsx), tostring(lsw),
            tostring(content:getWidth()))
    end)
    diagUI.leaveButton = nil
    diagUI.lobbySection = nil
end

local function try_attach_button_handler(actor)
    local current = actor
    while current ~= nil do
        local ok, attached = pcall(function()
            if C.ComplexButton:_isInstance(current)
                    or C.TableButton:_isInstance(current)
                    or C.LabelButton:_isInstance(current)
                    or C.RightSideMenuButton:_isInstance(current)
                    or C.PaddedImageButton:_isInstance(current) then
                current:setClickHandler(C.Runnable(open_multiplayer_window))
                return true
            end
            return false
        end)
        if ok and attached then
            patchedButton = current
            return true
        end
        current = current:getParent()
    end

    return false
end

local function ensure_profile_click_listener(profileSummary)
    if profileSummary == nil then
        return
    end

    clear_profile_click_listener()
    profileSummaryActor = profileSummary

    local replacementListener = C.EventListener(function(event)
        if not C.InputEvent:_isInstance(event) then
            return false
        end
        if event:getType() ~= C.InputEvent.Type.touchDown then
            return false
        end

        event:stop()
        event:cancel()
        local ok, err = pcall(open_multiplayer_window)
        if not ok then
            logger:e("Failed to open multiplayer window: %s", tostring(err))
        end
        return true
    end)

    local function replace_profile_listeners(actor)
        if actor == nil then
            return false
        end

        local patchedAny = false
        local listeners = actor:getListeners()
        if listeners ~= nil and listeners.size > 0 then
            local removedAny = false
            for i = listeners.size, 1, -1 do
                local listener = listeners.items[i]
                local className = tostring(listener:getClass())
                if string.find(className, "com%.prineside%.tdi2%.ui%.shared%.ProfileSummary%$") ~= nil then
                    listeners:removeIndex(i - 1)
                    removedAny = true
                    patchedAny = true
                end
            end

            if removedAny then
                actor:addListener(replacementListener)
                profileClickListeners[#profileClickListeners + 1] = actor
            end
        end

        local ok, children = pcall(function()
            return actor:getChildren()
        end)
        if ok and children ~= nil then
            for i = 1, children.size do
                patchedAny = replace_profile_listeners(children.items[i]) or patchedAny
            end
        end

        return patchedAny
    end

    replace_profile_listeners(profileSummaryActor)
    listenerOwnersDumped = true
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

-- Profile patching permanently disabled: the floating Multitode button is the
-- entry point now, and the game profile stays 100% vanilla (its login must
-- keep working). Kept as a no-op so old call sites stay valid.
local function patch_actor_tree(actor)
    return false
end

local function patch_profile_summary(profileSummary)
    return false
end

local function toggle_multiplayer_window()
    if multiplayerWindow ~= nil and multiplayerWindow:getParent() ~= nil then
        hide_multiplayer_window()
        return
    end

    local ok, err = pcall(open_multiplayer_window)
    if not ok then
        logger:e("Failed to open multiplayer window: %s", tostring(err))
    end
end

-- Floating entry-point button: always on screen (menu AND in-game), draggable
-- anywhere, click toggles the multiplayer window. Re-created automatically
-- whenever a screen rebuild drops it.
local function ensure_floating_button()
    local uiManager = C.Game.i.uiManager
    if uiManager == nil then
        return
    end
    local stage = uiManager.stage
    if stage == nil then
        return
    end

    -- NOTE: never compare Java objects with == here (LuaJ userdata identity
    -- is unreliable across calls). Parent-nil is the only safe liveness check;
    -- the stage object itself never changes at runtime.
    if floatBtn.button ~= nil and floatBtn.button:getParent() ~= nil then
        -- Keep it above menu content (but never above the open multiplayer
        -- window, which must stay clickable).
        if multiplayerWindow == nil or multiplayerWindow:getParent() == nil then
            pcall(function()
                floatBtn.button:toFront()
            end)
        end
        return
    end

    local button = C.RectButton.new("MULTITODE",
        C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL),
        C.Runnable(function()
        end))
    button:setSize(K.FLOAT_BUTTON_W, K.FLOAT_BUTTON_H)
    button:setName("multitode floating button")

    local stageW = stage:getWidth()
    local stageH = stage:getHeight()
    local px = floatBtn.pos.x or (stageW - K.FLOAT_BUTTON_W - 20)
    local py = floatBtn.pos.y or (stageH - K.FLOAT_BUTTON_H - 140)
    px = math.min(math.max(0, px), math.max(0, stageW - K.FLOAT_BUTTON_W))
    py = math.min(math.max(0, py), math.max(0, stageH - K.FLOAT_BUTTON_H))
    button:setPosition(px, py)

    -- Event routing (from the decompiled scene2d):
    -- touchDown reaches this listener, but touch focus belongs to
    -- InputListeners only (handle -> addTouchFocus), and drag/up go
    -- exclusively to focused listeners. A plain EventListener never sees
    -- drag/up - the old workaround polled getDeltaX/getDeltaY, which carry
    -- stale screen-space deltas and left the button stuck or flung into a
    -- corner. We track focus ourselves: grab it on touchDown, and drag/up
    -- arrive as proper stage-coordinate events (accurate, no polling). Same
    -- small wrapper as 92_ and the other listeners here.
    local btnListener
    btnListener = C.EventListener(function(event)
        if not C.InputEvent:_isInstance(event) then
            return false
        end

        local et = event:getType()
        if et == C.InputEvent.Type.touchDown then
            local sx, sy = event:getStageX(), event:getStageY()
            logger:i("MULTITODE button touched at %s,%s", tostring(sx), tostring(sy))
            -- Grab point in stage coords, so the button doesn't jump when the
            -- first drag lands.
            floatBtn.armed = {
                sx = sx, sy = sy,
                grabX = sx - button:getX(),
                grabY = sy - button:getY(),
                moved = false,
            }
            local okF, errF = pcall(function()
                event:getStage():addTouchFocus(btnListener,
                    event:getListenerActor(), event:getTarget(),
                    event:getPointer(), event:getButton())
            end)
            if not okF then
                logger:e("Floating button addTouchFocus failed: %s", tostring(errF))
            end
            return true
        end

        if et == C.InputEvent.Type.touchDragged then
            local a = floatBtn.armed
            if a == nil then
                return true
            end
            local sx, sy = event:getStageX(), event:getStageY()
            if not a.moved then
                local dx, dy = sx - a.sx, sy - a.sy
                if (dx * dx + dy * dy) > (K.FLOAT_CLICK_SLOP * K.FLOAT_CLICK_SLOP) then
                    a.moved = true
                    logger:i("MULTITODE button drag started")
                end
            end
            if a.moved then
                local nx, ny = sx - a.grabX, sy - a.grabY
                -- Clamp to the STAGE, same bounds as creation. The button sits
                -- in the root Group, whose width/height read 0x0 in this
                -- engine - clamping to the parent glued dragged buttons to
                -- (0,0), bottom-left. event:getStage() is good at dispatch.
                local st = event:getStage()
                local maxW, maxH = 0, 0
                if st ~= nil then
                    maxW = st:getWidth() - button:getWidth()
                    maxH = st:getHeight() - button:getHeight()
                end
                nx = math.min(math.max(0, nx), math.max(0, maxW))
                ny = math.min(math.max(0, ny), math.max(0, maxH))
                button:setPosition(nx, ny)
                floatBtn.pos.x = button:getX()
                floatBtn.pos.y = button:getY()
            end
            return true
        end

        if et == C.InputEvent.Type.touchUp then
            local a = floatBtn.armed
            floatBtn.armed = nil
            if a ~= nil and not a.moved then
                toggle_multiplayer_window()
            end
            return true
        end

        return false
    end)
    pcall(function()
        button:addListener(btnListener)
    end)

    floatBtn.button = button
    stage:addActor(button)
    logger:i("Floating MULTITODE button created")
end

C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
    -- Keep the floating button alive across screen rebuilds.
    -- Drag + click run on events now (see ensure_floating_button); the old
    -- per-frame input poll went away with them.
    local ok, err = pcall(ensure_floating_button)
    if not ok then
        logger:e("Floating button error: %s", tostring(err))
    end
end))

C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.PostRender.class):add(C.Listener(function(_)
    -- Restore main-pane scroll after a rebuild/dialog reopen (layout settles in ~2 frames).
    if mainScrollRestoreFrames > 0 then
        mainScrollRestoreFrames = mainScrollRestoreFrames - 1
        if mainScrollRestoreFrames == 0 then
            local y = mainScrollRestoreY
            mainScrollRestoreY = nil
            if y ~= nil and embed ~= nil and embed.mainScroll ~= nil then
                pcall(function()
                    embed.mainScroll:setScrollY(y)
                end)
            end
        end
    end

    if pendingWindowReopenFrames > 0 then
        pendingWindowReopenFrames = pendingWindowReopenFrames - 1
    elseif pendingWindowReopenFrames == 0 then
        pendingWindowReopenFrames = -1
        -- Never yank the main menu over an open poll editor.
        local pollOpen = pollCreate.window ~= nil and pollCreate.window:getParent() ~= nil
        if not pollOpen then
            local ok, err = pcall(function()
                open_multiplayer_window(
                    (savedWinX ~= nil and savedWinY ~= nil) and savedWinX or nil,
                    (savedWinX ~= nil and savedWinY ~= nil) and savedWinY or nil)
            end)
            if not ok then
                logger:e("Failed to reopen multiplayer window: %s", tostring(err))
            end
        end
    end

    -- A fresh poll used to auto-open the lobby window. That obscured the screen;
    -- the poll now attaches as an arrow under quick messages instead.
    if _G.multitode and _G.multitode._openLobbyUi then
        _G.multitode._openLobbyUi = false
    end

    -- Ready/marksOff flips (91_ flag_ready_refresh): roster labels + own
    -- ready button change in place. Flag flips never rebuild.
    local function refresh_ready_ui_in_place()
        pcall(function()
            for id, info in pairs(multitode.lobby.players or {}) do
                local lbl = rosterReadyLabels[id]
                if lbl ~= nil and lbl:getParent() ~= nil then
                    local s = (info.ready and "[READY]" or "[ ]")
                    if info.marksOff == true then
                        s = s .. " [marks off]"
                    end
                    lbl:setText(s)
                end
            end
        end)
        pcall(function()
            local btn = diagUI.toggleButtons["ready"]
            if btn ~= nil and btn:getParent() ~= nil then
                local selfId = 0
                local okId, myId = pcall(function()
                    return multitode.getApi():getLocalPlayerId()
                end)
                if okId and myId ~= nil then
                    selfId = tonumber(myId) or 0
                end
                local myEntry = multitode.lobby.players[selfId]
                if myEntry ~= nil then
                    btn:setText(myEntry.ready and "Ready: YES" or "Ready: NO")
                end
            end
        end)
    end

    -- Lobby events (join/state/kick/close) refresh the open window so the
    -- roster never goes stale while it is on screen. Throttled to ~6/s: a burst
    -- of dirty flags (chat + state + poll at once) used to rebuild the whole
    -- window several times per second, which read as constant flickering.
    if _G.multitode then
        _G.multitode._uiFrame = (_G.multitode._uiFrame or 0) + 1
    end
    if _G.multitode and _G.multitode._lobbyUiDirty then
        if multiplayerWindow ~= nil and multiplayerWindow:getParent() ~= nil then
            -- Never rebuild while the pointer is down: replacing the buttons
            -- mid-click is what made buttons (e.g. "Chat window") feel broken.
            local pointerDown = false
            pcall(function()
                pointerDown = C.Gdx.input ~= nil and C.Gdx.input:isTouched()
            end)
            if (not pointerDown) and (_G.multitode._uiFrame or 0) - (_G.multitode._uiLastRebuildFrame or 0) >= 6 then
                _G.multitode._uiLastRebuildFrame = _G.multitode._uiFrame
                _G.multitode._lobbyUiDirty = false
                local ok, err = pcall(reopen_multiplayer_window)
                if not ok then
                    logger:e("Failed to refresh multiplayer window: %s", tostring(err))
                end
            end
        else
            _G.multitode._lobbyUiDirty = false
        end
    end

    -- Ready ticker: flips change labels in place, never rebuild.
    if _G.multitode and _G.multitode._readyUiRefresh then
        _G.multitode._readyUiRefresh = false
        pcall(refresh_ready_ui_in_place)
    end
    -- Poll live tick: countdown every frame + tally patches when flagged.
    -- Never sets _lobbyUiDirty — only mutates labels already on screen.
    if _G.multitode and _G.multitode._pollUiRefresh then
        _G.multitode._pollUiRefresh = false
        pcall(refresh_poll_ui_in_place)
    end
    pcall(function()
        local poll = multitode.lobby and multitode.lobby.poll
        if poll ~= nil and pollRun.countdownLabel ~= nil and pollRun.countdownLabel:getParent() ~= nil then
            pollRun.countdownLabel:setText(poll_countdown(poll))
        end
    end)
end))

logger:i("Multitode menu UI hook loaded")


-- ============================================================
-- Phase 3 UI: detached chat window, unread badge, quick messages
-- ============================================================

local chatUI = {
    rowsTable = nil,
    scrollPane = nil,
    inputField = nil,
    badgeStack = nil,
    badgeImage = nil,
    badgeLabel = nil,
    badgeKey = nil,
}
local quickUI = {
    msgs = {},
    -- Poll extension under the detached chat window (or toast strip when chat
    -- is closed): collapsed arrow by default so a new poll never obscures screen.
    arrow = nil,
    panel = nil,
    expanded = false,
    builtPollId = nil,
    countdownLabel = nil,
    voteButtons = nil,
    hostCloseButton = nil,
    panelAnimY = nil,
    dockX = nil,
    dockW = nil,
    dockY = nil,
    -- "chat" = under detached window, "strip" = under toasts. Changing mode
    -- snaps the panel so closing chat first cannot leave it stranded.
    dockMode = nil,
}

-- Called when the detached chat window goes away so an expanded poll panel
-- re-homes under the toast strip instead of freezing where chat was.
local function reset_quick_poll_dock()
    quickUI.dockX = nil
    quickUI.dockW = nil
    quickUI.dockY = nil
    quickUI.dockMode = nil
    quickUI.panelAnimY = nil
end

-- markChatRead lives on the lobby table so the badge logic works from anywhere.
pcall(function()
    multitode.lobby = multitode.lobby or {}
    multitode.lobby.markChatRead = function()
        local unread = tonumber(multitode.lobby.unread) or 0
        if unread ~= 0 or multitode.lobby.pinged then
            multitode.lobby.unread = 0
            multitode.lobby.pinged = false
            -- Badge-only: never dirty the multiplayer window for a read mark.
            pcall(function()
                if ensure_badge ~= nil then
                    ensure_badge()
                end
            end)
        end
    end
end)

function chat_quick_enabled()
    local on = true
    pcall(function()
        if multitode.settings ~= nil and multitode.settings.quickMessages ~= nil then
            on = multitode.settings.quickMessages == true
        end
    end)
    return on
end

-- "[HH:MM] Sender: text", coloured by who sent it.
local function chat_line_text(entry)
    local sender = tostring((entry or {}).sender or "?")
    local stamp = ""
    local timestamp = tonumber((entry or {}).timestamp)
    if timestamp ~= nil and timestamp > 0 then
        local ok, formatted = pcall(os.date, "%H:%M", timestamp)
        if ok and formatted ~= nil then
            stamp = "[" .. tostring(formatted) .. "] "
        end
    end
    return stamp .. sender .. ": " .. tostring((entry or {}).message or "")
end

add_chat_row_to = function(tableObject, entry, width)
    local line = C.Label.new(chat_line_text(entry),
        C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL))
    line:setWrap(true)
    pcall(function()
        local sender = tostring((entry or {}).sender or "")
        local myName = tostring((multitode.getConfig() or {}).name or "")
        local color = nil
        if sender == "System" then
            -- Yellow = poll results / lobby notices stand out from player chat.
            color = C.MaterialColor.YELLOW.P500
        elseif sender ~= "" and sender == myName then
            color = C.MaterialColor.LIGHT_GREEN.P300
        else
            color = C.MaterialColor.LIGHT_BLUE.P400
        end
        if color ~= nil then
            line:setColor(color)
        else
            line:setColor(C.MaterialColor.LIGHT_GREY.P300)
        end
    end)
    tableObject:add(line):width(width or 420):left():padBottom(2):row()
end

force_scroll_bottom = function(pane, rows, pendingKey)
    if pane == nil then
        return
    end
    pcall(function()
        if rows ~= nil then
            rows:invalidateHierarchy()
            rows:pack()
        end
        pane:invalidate()
        pane:setScrollPercentY(1)
    end)
    -- Layout often settles one frame later — retry so the newest row is visible.
    if pendingKey == "chat" then
        chatScrollPendingFrames = 2
    elseif pendingKey == "embed" then
        embedScrollPendingFrames = 2
    end
end

local function append_chat_row(sender, message, refs)
    if chatUI.rowsTable == nil then
        return
    end
    pcall(function()
        add_chat_row_to(chatUI.rowsTable, {
            sender = sender,
            message = message,
            refs = refs,
            timestamp = os.time and os.time() or 0
        })
        chatUI.rowsTable:pack()
    end)
    -- Force the scroll pane to re-layout, otherwise appended rows are stored but
    -- never drawn (the "chat window does not update live" symptom).
    pcall(function()
        if chatUI.rowsTable ~= nil then
            chatUI.rowsTable:invalidateHierarchy()
        end
    end)
    pcall(function()
        force_scroll_bottom(chatUI.scrollPane, chatUI.rowsTable, "chat")
    end)
end

local function build_chat_window()
    local stage = C.Game.i.uiManager and C.Game.i.uiManager.stage
    if stage == nil then
        return
    end

    local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
    windowStyle.resizeable = false
    windowStyle.inheritWidgetMinSize = true
    -- Same nested-ScrollPane trap as the multiplayer window: nil out the built-in
    -- outer pane so only our chat rows pane scrolls (otherwise wheel focus and
    -- horizontal offset make messages unreadable / unreachable).
    windowStyle.scrollPaneStyle = nil

    local window = C.Window.new_WS(windowStyle)
    chatWindow = window
    window:setTitle("Chat")

    local content = C.Table.new()
    content:pad(8)

    chatUI.rowsTable = C.Table.new()
    chatUI.rowsTable:pad(4)
    local log = multitode.lobby.chatLog or {}
    local firstIndex = math.max(1, #log - 60)
    for i = firstIndex, #log do
        if log[i] ~= nil then
            add_chat_row_to(chatUI.rowsTable, log[i])
        end
    end
    chatUI.rowsTable:pack()

    local scroll = C.ScrollPane.new_A_SPS(chatUI.rowsTable, C.Game.i.assetManager:getScrollPaneStyle(16.0))
    chatUI.scrollPane = scroll
    pcall(function() scroll:setFadeScrollBars(false) end)
    pcall(function() scroll:setScrollingDisabled(true, false) end)
    -- Wheel focus only while the pointer is over the chat (same pattern as the
    -- embedded pane). Permanent setScrollFocus on open made focus stick after
    -- the first scroll — wheel outside chat then did nothing until a click.
    pcall(function()
        scroll:addListener(luajava.createProxy(C.InputListener, {
            enter = function(_, _event, _x, _y, _pointer, _from)
                pcall(function()
                    local st = C.Game.i.uiManager and C.Game.i.uiManager.stage
                    if st ~= nil then
                        st:setScrollFocus(scroll)
                    end
                end)
            end,
            exit = function(_, _event, _x, _y, _pointer, _to)
                pcall(function()
                    local st = C.Game.i.uiManager and C.Game.i.uiManager.stage
                    if st == nil then
                        return
                    end
                    -- Hand wheel back to the multiplayer window's outer pane when
                    -- it is open; otherwise clear so the game/stage can scroll.
                    if embed.mainScroll ~= nil and embed.mainScroll:getParent() ~= nil then
                        st:setScrollFocus(embed.mainScroll)
                    else
                        st:setScrollFocus(nil)
                    end
                end)
            end,
        }))
    end)
    content:add(scroll):width(440):height(CHAT_PANE_H):left():row()

    local inputRow = C.Table.new()
    local field = C.TextField.new("", C.Game.i.assetManager:getTextFieldStyle(C.Config.FONT_SIZE_X_SMALL))
    chatUI.inputField = field
    pcall(function() field:setMessageText("Type a message...") end)
    inputRow:add(field):width(320):left():padRight(6)

    local sendButton = create_action_button("Send", function()
        local text = nil
        pcall(function()
            text = chatUI.inputField:getText()
        end)
        if text ~= nil and tostring(text) ~= "" then
            local ok, err = pcall(multitode.lobby.send_chat, tostring(text))
            if not ok then
                logger:e("Chat send failed: %s", tostring(err))
            end
            pcall(function() chatUI.inputField:setText("") end)
        end
    end)
    -- Enter sends (the global Enter handler deliberately stays quiet while the
    -- chat window is open - it used to do nothing at all here).
    pcall(function()
        field:setTextFieldListener(C.TextFieldListener(function(tf, c)
            -- 10 = LF, 13 = CR
            if c == 10 or c == 13 then
                local text = nil
                pcall(function() text = tf:getText() end)
                if text ~= nil and tostring(text) ~= "" then
                    local ok, err = pcall(multitode.lobby.send_chat, tostring(text))
                    if not ok then
                        logger:e("Chat send failed: %s", tostring(err))
                    end
                    pcall(function() tf:setText("") end)
                end
            end
        end))
    end)
    -- Keyboard focus so typing (and Enter) reach the field without an extra click.
    pcall(function()
        local st = C.Game.i.uiManager and C.Game.i.uiManager.stage
        if st ~= nil then
            st:setKeyboardFocus(field)
        end
    end)
    inputRow:add(sendButton):width(100):left()
    content:add(inputRow):width(440):left():padTop(6):row()

    local closeButton = create_action_button("Close", function()
        if chatWindow ~= nil then
            pcall(function()
                chatWindowPos.x = chatWindow:getX()
                chatWindowPos.y = chatWindow:getY()
                chatWindow:remove()
            end)
        end
        pcall(function()
            local stage = C.Game.i.uiManager and C.Game.i.uiManager.stage
            if stage ~= nil then
                stage:setScrollFocus(nil)
            end
        end)
        chatUI.rowsTable = nil
        chatUI.scrollPane = nil
        chatUI.inputField = nil
        pcall(function() multitode.lobby.chatOpen = false end)
        -- Expanded poll was docked under chat — re-home it to the toast strip.
        pcall(reset_quick_poll_dock)
        refresh_chat_window_button()
    end)
    content:add(closeButton):width(260):left():padTop(6):row()

    window.main:add(content):pad(12):grow()
    C.Game.i.uiManager:addWindow(window)
    window:fitToContentSimple()
    if chatWindowPos.x ~= nil and chatWindowPos.y ~= nil then
        window:setPosition(chatWindowPos.x, chatWindowPos.y)
    else
        place_window_centered(window)
    end
    window:show()

    pcall(function()
        multitode.lobby.chatOpen = true
        if multitode.lobby.markChatRead ~= nil then
            multitode.lobby.markChatRead()
        end
    end)
    pcall(function()
        force_scroll_bottom(chatUI.scrollPane, chatUI.rowsTable, "chat")
    end)
end

toggle_chat_window = function()
    pcall(function()
        multitode.slog("UI", "chat window toggle requested")
    end)
    if is_chat_window_visible() then
        pcall(function()
            chatWindowPos.x = chatWindow:getX()
            chatWindowPos.y = chatWindow:getY()
            chatWindow:remove()
        end)
        pcall(function()
            local stage = C.Game.i.uiManager and C.Game.i.uiManager.stage
            if stage ~= nil then
                stage:setScrollFocus(nil)
            end
        end)
        chatUI.rowsTable = nil
        chatUI.scrollPane = nil
        chatUI.inputField = nil
        pcall(function() multitode.lobby.chatOpen = false end)
        pcall(reset_quick_poll_dock)
        refresh_chat_window_button()
        return
    end
    local ok, err = pcall(build_chat_window)
    if not ok then
        logger:e("Chat window failed: %s", tostring(err))
    end
    refresh_chat_window_button()
end

ensure_badge = function()
    local button = floatBtn.button
    if button == nil or button:getParent() == nil then
        if chatUI.badgeStack ~= nil then
            pcall(function() chatUI.badgeStack:setVisible(false) end)
        end
        return
    end

    local unread = tonumber(multitode.lobby.unread) or 0
    local pinged = multitode.lobby.pinged == true

    if chatUI.badgeStack == nil then
        local drawable = nil
        local drawableName = "none"
        pcall(function() drawable = C.Game.i.assetManager:getDrawable("small-circle") end)
        if drawable ~= nil then drawableName = "small-circle" end
        if drawable == nil then
            pcall(function() drawable = C.Game.i.assetManager:getDrawable("circle") end)
            if drawable ~= nil then drawableName = "circle" end
        end
        if drawable == nil then
            pcall(function() drawable = C.Game.i.assetManager:getDrawable("blank") end)
            if drawable ~= nil then drawableName = "blank" end
        end
        if drawable == nil then
            return
        end
        pcall(function()
            multitode.slog("UI", "badge drawable=" .. drawableName)
        end)
        local stage = C.Game.i.uiManager and C.Game.i.uiManager.stage
        if stage == nil then
            return
        end
        -- Table with a tinted circular background (the proven pattern used a few
        -- lines above for the info box). A Stack did not size the Image, so the
        -- circle rendered at its native tiny size and was effectively invisible.
        local box = C.Table.new()
        local label = C.Label.new("", C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL))
        label:setColor(1, 1, 1, 1)
        pcall(function() label:setAlignment(1) end)
        box:add(label)
        box:setSize(28, 28)
        pcall(function()
            box:setBackground(drawable:tint(C.Color.new_4f(0.35, 0.35, 0.35, 1)))
        end)
        stage:addActor(box)
        chatUI.badgeStack = box
        chatUI.badgeImage = drawable
        chatUI.badgeLabel = label
    end

    pcall(function()
        chatUI.badgeStack:setPosition(button:getX() + K.FLOAT_BUTTON_W - 16, button:getY() + K.FLOAT_BUTTON_H - 12)
    end)
    -- Keep the badge ABOVE the button: the button re-fronts itself every frame,
    -- which is why the count used to end up behind it.
    pcall(function()
        chatUI.badgeStack:toFront()
    end)

    local show = unread > 0
    local key = tostring(unread) .. ":" .. tostring(pinged)
    if chatUI.badgeKey ~= key then
        chatUI.badgeKey = key
        pcall(function()
            chatUI.badgeLabel:setText(pinged and ("@" .. tostring(unread)) or tostring(unread))
            -- Grey normally, red when pinged; numeric fallback so a missing
            -- palette entry can never leave the badge untinted.
            local r, g, b = 0.35, 0.35, 0.35
            if pinged then
                r, g, b = 0.85, 0.15, 0.15
            end
            pcall(function()
                local color = pinged and C.MaterialColor.RED.P500 or C.MaterialColor.GREY.P600
                if color ~= nil then
                    r, g, b = color.r, color.g, color.b
                end
            end)
            pcall(function()
                chatUI.badgeStack:setBackground(chatUI.badgeImage:tint(C.Color.new_4f(r, g, b, 1)))
            end)
            chatUI.badgeStack:setVisible(show)
        end)
    elseif chatUI.badgeKey == nil then
        pcall(function() chatUI.badgeStack:setVisible(show) end)
    end
    -- Visibility still has to follow the count even when the key is unchanged.
    pcall(function() chatUI.badgeStack:setVisible(show) end)
end

local function show_quick_message(sender, message)
    if not chat_quick_enabled() then
        return
    end
    local stage = C.Game.i.uiManager and C.Game.i.uiManager.stage
    if stage == nil then
        return
    end
    pcall(function()
        local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
        local box = C.Table.new()
        if windowStyle.background ~= nil then
            box:setBackground(windowStyle.background)
        end
        box:pad(8)
        local label = C.Label.new(tostring(sender or "?") .. ": " .. tostring(message or ""),
            C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL))
        label:setWrap(true)
        label:setColor(C.MaterialColor.LIGHT_BLUE.P100)
        box:add(label):width(math.min(460, stage:getWidth() * 0.45)):left()
        box:pack()
        stage:addActor(box)
        -- Newest at the TOP of the stack (index 1 = newest). Layout walks the
        -- array backwards so a fresh line never sits "one message above".
        table.insert(quickUI.msgs, 1, { actor = box, framesLeft = K.QUICK_MESSAGE_FRAMES })
        while #quickUI.msgs > 3 do
            local oldest = table.remove(quickUI.msgs)
            pcall(function() oldest.actor:remove() end)
        end
    end)
end

-- Public toast: other modules (e.g. the sync watchdog) can raise a notice.
function multitode.show_toast(text)
    local ok, err = pcall(function()
        show_quick_message("Multitode", tostring(text))
    end)
    if not ok then
        logger:e("Toast failed: %s", tostring(err))
    end
end

local function destroy_quick_poll_ui()
    if quickUI.arrow ~= nil then
        pcall(function() quickUI.arrow:remove() end)
        quickUI.arrow = nil
    end
    if quickUI.panel ~= nil then
        pcall(function() quickUI.panel:remove() end)
        quickUI.panel = nil
    end
    quickUI.expanded = false
    quickUI.builtPollId = nil
    quickUI.countdownLabel = nil
    quickUI.voteButtons = nil
    quickUI.hostCloseButton = nil
    quickUI.panelAnimY = nil
    reset_quick_poll_dock()
end

-- Build/rebuild the slide-out poll body for the current lobby.poll.
local function ensure_quick_poll_panel(stage, poll, width)
    local pollId = tonumber((poll or {}).id) or -1
    if quickUI.panel ~= nil and quickUI.builtPollId == pollId then
        return
    end
    if quickUI.panel ~= nil then
        pcall(function() quickUI.panel:remove() end)
        quickUI.panel = nil
    end
    quickUI.countdownLabel = nil
    quickUI.voteButtons = nil
    quickUI.hostCloseButton = nil
    if poll == nil then
        quickUI.builtPollId = nil
        return
    end

    local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
    local panel = C.Table.new()
    if windowStyle.background ~= nil then
        panel:setBackground(windowStyle.background)
    end
    panel:pad(8)
    local labelStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL)

    local q = C.Label.new(tostring(poll.question or ""), labelStyle)
    q:setWrap(true)
    q:setColor(C.MaterialColor.LIGHT_BLUE.P200)
    panel:add(q):width(width):left():row()

    local cdRow = C.Table.new()
    local cdTitle = C.Label.new("Closes in", labelStyle)
    cdTitle:setColor(1, 1, 1, 0.65)
    cdRow:add(cdTitle):left():padRight(10)
    local cd = C.Label.new(poll_countdown(poll), labelStyle)
    quickUI.countdownLabel = cd
    cdRow:add(cd):left()
    panel:add(cdRow):width(width):left():padBottom(4):row()

    local counts, bestIdx, bestCount = poll_compute_tallies(poll)
    local selfId = 0
    pcall(function()
        selfId = tonumber(multitode.getApi():getLocalPlayerId()) or 0
    end)
    quickUI.voteButtons = {}
    local quickUI_vote_refresh -- forward for button handlers
    quickUI_vote_refresh = function()
        local p = multitode.lobby and multitode.lobby.poll
        if p == nil then
            return
        end
        if quickUI.countdownLabel ~= nil and quickUI.countdownLabel:getParent() ~= nil then
            pcall(function() quickUI.countdownLabel:setText(poll_countdown(p)) end)
        end
        if quickUI.voteButtons == nil then
            return
        end
        local counts, bestIdx, bestCount = poll_compute_tallies(p)
        local sid = 0
        pcall(function()
            sid = tonumber(multitode.getApi():getLocalPlayerId()) or 0
        end)
        for _, entry in ipairs(quickUI.voteButtons) do
            if entry.button ~= nil and entry.button:getParent() ~= nil then
                pcall(function()
                    entry.button:setText(poll_vote_button_text(
                        p, entry.optionIdx, counts, bestIdx, bestCount, sid))
                end)
            end
        end
    end

    for i = 1, #(poll.options or {}) do
        local idx = i
        local voteButton = create_action_button(
            poll_vote_button_text(poll, i, counts, bestIdx, bestCount, selfId),
            function()
                local ok, err = pcall(multitode.lobby.votePoll, idx)
                if not ok then
                    logger:e("Failed to vote: %s", tostring(err))
                end
                pcall(refresh_poll_ui_in_place)
                pcall(quickUI_vote_refresh)
            end)
        quickUI.voteButtons[#quickUI.voteButtons + 1] = { button = voteButton, optionIdx = i }
        panel:add(voteButton):width(math.min(420, width)):left():padTop(2):row()
    end

    local isHost = false
    pcall(function()
        local role = multitode.state().role
        isHost = role == "HOST" or role == "HOST_AND_CLIENT"
    end)
    if isHost then
        local closeBtn = create_action_button("Close Now", function()
            pcall(multitode.lobby.closePollNow)
            pcall(function() destroy_quick_poll_ui() end)
        end)
        quickUI.hostCloseButton = closeBtn
        panel:add(closeBtn):width(200):left():padTop(4):row()
    end

    panel:pack()
    stage:addActor(panel)
    quickUI.panel = panel
    quickUI.builtPollId = pollId
    quickUI.voteRefresh = quickUI_vote_refresh
end

local function ensure_quick_poll_arrow(stage, poll, width)
    if poll == nil then
        if quickUI.arrow ~= nil then
            pcall(function() quickUI.arrow:remove() end)
            quickUI.arrow = nil
        end
        return
    end
    if quickUI.arrow ~= nil and quickUI.arrow:getParent() ~= nil then
        return
    end
    local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
    local arrow = C.RectButton.new(
        quickUI.expanded and "Poll  ^" or "Poll  v",
        C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL),
        C.Runnable(function()
            quickUI.expanded = not quickUI.expanded
            pcall(function()
                if quickUI.arrow ~= nil then
                    quickUI.arrow:setText(quickUI.expanded and "Poll  ^" or "Poll  v")
                end
            end)
            if not quickUI.expanded and quickUI.panel ~= nil then
                -- Slide-back: hide body immediately; position is re-driven next frame.
                pcall(function() quickUI.panel:setVisible(false) end)
            end
        end))
    arrow:setSize(math.min(160, width), 36)
    stage:addActor(arrow)
    quickUI.arrow = arrow
end

local function update_quick_messages()
    local stage = C.Game.i.uiManager and C.Game.i.uiManager.stage
    if stage == nil then
        return
    end

    local poll = nil
    pcall(function()
        poll = multitode.lobby and multitode.lobby.poll
    end)
    local showPoll = chat_quick_enabled() and poll ~= nil
    if not showPoll then
        if quickUI.arrow ~= nil or quickUI.panel ~= nil then
            destroy_quick_poll_ui()
        end
    end

    -- Fixed top slot for the NEWEST toast (array index 1).
    local topY = stage:getHeight() - 70
    local xCenter = stage:getWidth() * 0.5
    -- cursor = top edge of the next (older) toast; stack grows downward.
    local cursorY = topY

    local i = 1
    while i <= #quickUI.msgs do
        local entry = quickUI.msgs[i]
        entry.framesLeft = entry.framesLeft - 1
        if entry.framesLeft <= 0 then
            pcall(function() entry.actor:remove() end)
            table.remove(quickUI.msgs, i)
        else
            local h = 48
            pcall(function() h = math.max(24, entry.actor:getHeight()) end)
            local y = cursorY
            cursorY = y - h - 4
            pcall(function()
                entry.actor:setPosition((stage:getWidth() - entry.actor:getWidth()) * 0.5, y)
            end)
            if entry.framesLeft < K.QUICK_MESSAGE_FADE_FRAMES then
                pcall(function()
                    entry.actor:setColor(1, 1, 1, entry.framesLeft / K.QUICK_MESSAGE_FADE_FRAMES)
                end)
            end
            i = i + 1
        end
    end

    -- cursorY now sits just below the lowest toast (or == topY when empty).
    local bottomY = cursorY + 4

    local stripW = math.min(460, stage:getWidth() * 0.45)
    if showPoll then
        ensure_quick_poll_arrow(stage, poll, stripW)
        if quickUI.expanded then
            ensure_quick_poll_panel(stage, poll, stripW)
            if _G.multitode ~= nil and _G.multitode._quickPollDirty then
                _G.multitode._quickPollDirty = false
                if quickUI.voteRefresh ~= nil then
                    pcall(quickUI.voteRefresh)
                end
            elseif _G.multitode ~= nil and _G.multitode._pollUiRefresh then
                if quickUI.voteRefresh ~= nil then
                    pcall(quickUI.voteRefresh)
                end
            end
        elseif quickUI.panel ~= nil then
            pcall(function() quickUI.panel:setVisible(false) end)
            if _G.multitode ~= nil then
                _G.multitode._quickPollDirty = false
            end
        end

        local gap = 6
        -- Prefer docking under the DETACHED chat window (poll = chat extension).
        -- Falls back to the toast strip when chat is closed.
        local chatVisible = chatWindow ~= nil and chatWindow:getParent() ~= nil
        local dockMode = chatVisible and "chat" or "strip"
        -- Chat closed while the poll was open under it → snap panel to strip.
        if quickUI.dockMode ~= nil and quickUI.dockMode ~= dockMode then
            reset_quick_poll_dock()
        end
        quickUI.dockMode = dockMode

        -- Shared horizontal center so arrow and panel are center-aligned
        -- (panel left used to equal arrow left → panel looked shifted left).
        local centerCX = xCenter
        local arrowY = nil
        if chatVisible then
            pcall(function()
                local cw = chatWindow:getWidth()
                local cx = chatWindow:getX()
                local cy = chatWindow:getY()
                centerCX = cx + cw * 0.5
                -- libGDX Y grows upward: "beneath" = below the window's bottom edge.
                arrowY = cy - 42 - gap
                quickUI.dockX = cx
                quickUI.dockW = cw
                quickUI.dockY = arrowY
            end)
        end
        if arrowY == nil then
            arrowY = bottomY - 40 - gap
            if #quickUI.msgs == 0 then
                arrowY = topY - 40
            end
            centerCX = xCenter
            quickUI.dockX = nil
            quickUI.dockW = nil
            quickUI.dockY = nil
        end

        local arrowW = 160
        if quickUI.arrow ~= nil then
            pcall(function() arrowW = quickUI.arrow:getWidth() end)
        end
        local arrowX = centerCX - arrowW * 0.5
        if quickUI.arrow ~= nil and quickUI.arrow:getParent() ~= nil then
            pcall(function()
                quickUI.arrow:setPosition(centerCX - quickUI.arrow:getWidth() * 0.5, arrowY)
            end)
        end

        if quickUI.expanded and quickUI.panel ~= nil and quickUI.panel:getParent() ~= nil then
            local panelH = 0
            local panelW = 0
            pcall(function()
                panelH = quickUI.panel:getHeight()
                panelW = quickUI.panel:getWidth()
            end)
            local targetY = arrowY - panelH - 4
            local panelX = centerCX - panelW * 0.5
            -- Simple slide: ease panelY toward target each frame.
            -- Dock mode changes snap (panelAnimY was cleared by reset_quick_poll_dock).
            if quickUI.panelAnimY == nil then
                quickUI.panelAnimY = arrowY
            end
            local cur = quickUI.panelAnimY
            local step = math.min(24, math.abs(targetY - cur))
            if targetY < cur then
                cur = cur - step
            elseif targetY > cur then
                cur = cur + step
            else
                cur = targetY
            end
            quickUI.panelAnimY = cur
            pcall(function()
                quickUI.panel:setVisible(true)
                quickUI.panel:setPosition(panelX, cur)
            end)
            if quickUI.countdownLabel ~= nil and quickUI.countdownLabel:getParent() ~= nil then
                pcall(function()
                    quickUI.countdownLabel:setText(poll_countdown(poll))
                end)
            end
        else
            quickUI.panelAnimY = nil
        end
    end
end

-- Called for EVERY logged chat line (own and remote) so the detached chat
-- window AND the embedded multiplayer-window chat stay live. Quick-message
-- toasts remain incoming-only (onIncomingChat).
multitode.onChatLogged = function(sender, message, refs)
    if chatUI.rowsTable ~= nil then
        pcall(function() append_chat_row(sender, message, refs) end)
    end
    if embed.rows ~= nil then
        pcall(function()
            add_chat_row_to(embed.rows, {
                sender = sender,
                message = message,
                refs = refs,
                timestamp = os.time and os.time() or 0
            }, embed.rowW)
            embed.rows:pack()
            embed.rows:invalidateHierarchy()
            if embed.scroll ~= nil then
                force_scroll_bottom(embed.scroll, embed.rows, "embed")
            end
        end)
    end
end

-- Called from the lobby module for every incoming (non-own) player chat message.
multitode.onIncomingChat = function(sender, message, isPing)
    pcall(function() show_quick_message(sender, message) end)
    pcall(function()
        multitode.slog("CHAT", string.format("ui incoming from=%s ping=%s", tostring(sender), tostring(isPing)))
    end)
end

pcall(function()
    C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
        pcall(function()
            ensure_badge()
            -- Retry scroll-to-bottom after layout so the newest chat line is visible.
            if chatScrollPendingFrames > 0 then
                chatScrollPendingFrames = chatScrollPendingFrames - 1
                if chatUI.scrollPane ~= nil and chatUI.rowsTable ~= nil then
                    pcall(function()
                        chatUI.rowsTable:invalidateHierarchy()
                        chatUI.rowsTable:pack()
                        chatUI.scrollPane:invalidate()
                        chatUI.scrollPane:setScrollPercentY(1)
                    end)
                else
                    chatScrollPendingFrames = 0
                end
            end
            if embedScrollPendingFrames > 0 then
                embedScrollPendingFrames = embedScrollPendingFrames - 1
                if embed.scroll ~= nil and embed.rows ~= nil then
                    pcall(function()
                        embed.rows:invalidateHierarchy()
                        embed.rows:pack()
                        embed.scroll:invalidate()
                        embed.scroll:setScrollPercentY(1)
                    end)
                else
                    embedScrollPendingFrames = 0
                end
            end
            update_quick_messages()
            local chatVisible = chatWindow ~= nil and chatWindow:getParent() ~= nil
            local menuVisible = multiplayerWindow ~= nil and multiplayerWindow:getParent() ~= nil
            multitode.lobby.chatOpen = chatVisible
            multitode.lobby.menuOpen = menuVisible
            if chatVisible or menuVisible then
                if multitode.lobby.markChatRead ~= nil then
                    multitode.lobby.markChatRead()
                end
            end
        end)
    end))
end)

-- ============================================================
-- Research browse picker: Towers -> per-tower researches, then other groups.
-- Every entry blends the tower's own colour with the research-tree colour
-- (blue = normal tree, orange = endless / prestige research). Colour lookups are
-- fully defensive: a missing palette entry used to throw inside the click
-- handler, which made the research button look dead.
-- ============================================================

researchIndexCache = nil

local function hsv_to_rgb(h, s, v)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p = v * (1 - s)
    local q = v * (1 - f * s)
    local t = v * (1 - (1 - f) * s)
    i = i % 6
    if i == 0 then return v, t, p end
    if i == 1 then return q, v, p end
    if i == 2 then return p, v, t end
    if i == 3 then return p, q, v end
    if i == 4 then return t, p, v end
    return v, p, q
end

local function safe_color(fallbackR, fallbackG, fallbackB, ...)
    local names = { ... }
    for i = 1, #names do
        local resolvedR, resolvedG, resolvedB = nil, nil, nil
        pcall(function()
            local palette = C.MaterialColor[names[i]]
            if palette ~= nil and palette.P400 ~= nil then
                resolvedR = palette.P400.r
                resolvedG = palette.P400.g
                resolvedB = palette.P400.b
            end
        end)
        if resolvedR ~= nil and resolvedG ~= nil and resolvedB ~= nil then
            return resolvedR, resolvedG, resolvedB
        end
    end
    return fallbackR, fallbackG, fallbackB
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Real display names from the game locale (key families: tower_name_<TYPE> for
-- towers, gv_title_<RESEARCH_ID> for researches). Markup tags like [#ff0000] or
-- [@tower_name_SNIPER] are stripped so they do not show up literally.
local function locale_text(key)
    if key == nil or key == "" then
        return nil
    end

    local text = nil
    pcall(function()
        text = C.Game.i.localeManager:get(key)
    end)
    if text == nil then
        pcall(function()
            local locale = C.Game.i.localeManager:getLocale()
            if locale ~= nil then
                text = locale:get(key)
            end
        end)
    end
    if text == nil then
        return nil
    end

    local value = tostring(text)
    if value == "" or value == key then
        return nil
    end
    value = value:gsub("%[[^%]]*%]", "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return nil
    end
    return value
end

local function tower_display_name(towerKey)
    local key = string.upper(tostring(towerKey or ""))
    local text = locale_text("tower_name_" .. key)
    if text ~= nil then
        return text
    end
    return refs_pretty_cat(towerKey)
end

local function research_display_name_localized(id)
    local upper = string.upper(tostring(id))
    local text = locale_text("gv_title_" .. upper)
    if text == nil then
        text = locale_text(upper)
    end
    if text ~= nil then
        return text
    end
    -- Fallback: the internal id, prettified. NOTE: research_display_name is
    -- declared LATER in this file, so referencing it here would resolve to a nil
    -- global (that nil call was what broke every research row / click).
    local ok, pretty = pcall(function()
        return multitode.refs.prettify(id)
    end)
    if ok and pretty ~= nil and tostring(pretty) ~= "" then
        return tostring(pretty)
    end
    return tostring(id)
end

local function research_display_name(id)
    local ok, pretty = pcall(function()
        return multitode.refs.prettify(id)
    end)
    if ok and pretty ~= nil and tostring(pretty) ~= "" then
        return tostring(pretty)
    end
    return tostring(id)
end

local function research_is_endless(id)
    local upper = string.upper(tostring(id))
    if string.find(upper, "PRESTIGE", 1, true) ~= nil
        or string.find(upper, "ENDLESS", 1, true) ~= nil
        or string.find(upper, "_AUTO_", 1, true) ~= nil
        or string.sub(upper, 1, 2) == "S_" then
        return true
    end
    return false
end

-- Research-tree colour: blue for the normal tree, orange for endless research.
local function tree_rgb(id)
    if research_is_endless(id) then
        return safe_color(1.00, 0.66, 0.16, "AMBER", "ORANGE", "DEEP_ORANGE", "YELLOW")
    end
    return safe_color(0.28, 0.56, 0.95, "LIGHT_BLUE", "BLUE", "CYAN", "INDIGO")
end

-- Tower main colours, matching the in-game palette.
local TOWER_RGB = {
    BASIC = { 0.00, 0.72, 0.82 },
    SNIPER = { 0.25, 0.72, 0.30 },
    CANNON = { 0.85, 0.22, 0.22 },
    FREEZING = { 0.20, 0.45, 0.92 },
    AIR = { 0.55, 0.90, 0.95 },
    SPLASH = { 0.95, 0.55, 0.15 },
    BLAST = { 0.32, 0.32, 0.36 },
    MULTISHOT = { 0.95, 0.85, 0.25 },
    MINIGUN = { 0.58, 0.35, 0.80 },
    VENOM = { 0.62, 0.85, 0.35 },
    TESLA = { 0.15, 0.32, 0.78 },
    MISSILE = { 0.68, 0.16, 0.24 },
    FLAMETHROWER = { 0.98, 0.70, 0.35 },
    LASER = { 0.35, 0.82, 0.88 },
    GAUSS = { 0.95, 0.60, 0.20 },
    CRUSHER = { 0.62, 0.42, 0.25 },
}

local function tower_rgb(towerKey)
    local key = string.upper(tostring(towerKey or ""))
    local palette = TOWER_RGB[key]
    if palette ~= nil then
        return palette[1], palette[2], palette[3]
    end

    -- Unknown tower: try the engine, then a stable fallback hue.
    local r, g, b = nil, nil, nil
    pcall(function()
        local towerType = C.TowerType[key]
        if towerType ~= nil and C.Game.i.towerManager ~= nil then
            local tower = C.Game.i.towerManager:getTower(towerType)
            if tower ~= nil then
                local colour = nil
                pcall(function() colour = tower.color end)
                if colour ~= nil then
                    r, g, b = colour.r, colour.g, colour.b
                end
            end
        end
    end)
    if r == nil then
        r, g, b = hsv_to_rgb(((#key * 47) % 360) / 360, 0.60, 0.95)
    end
    return r, g, b
end

local function color_from(r, g, b)
    return C.Color.new_4f(r, g, b, 1)
end

-- Row gradient: the tower's own bright hue fading to a near-black version of the
-- SAME hue (matches the reference sprite). No tree tint any more - normal vs
-- endless is already obvious from the "[endless]" prefix and from the game itself.
-- Group rows (no tower) fall back to a neutral grey, or orange for endless groups.

local function darken(r, g, b)
    return color_from(r * K.DARK_END, g * K.DARK_END, b * K.DARK_END)
end

local function row_gradient(towerKey, isEndless, towerStyle)
    local br, bg, bb = 0.45, 0.50, 0.58
    if towerKey ~= nil then
        br, bg, bb = tower_rgb(towerKey)
    elseif isEndless then
        br, bg, bb = safe_color(1.00, 0.66, 0.16, "AMBER", "ORANGE", "DEEP_ORANGE", "YELLOW")
    end
    return color_from(br, bg, bb), darken(br, bg, bb)
end


-- RectButton/ComplexButton expose the label as a field ("button.label"); the game
-- itself colours buttons with this.label.setColor(...). getLabel() does NOT
-- exist here, which is why the first attempt silently coloured nothing.
function apply_row_color(button, color)
    if button == nil or color == nil then
        return false
    end

    local applied = false
    pcall(function()
        if button.label ~= nil then
            button.label:setColor(color)
            applied = true
        end
    end)

    if not applied and not warn.rowColor then
        warn.rowColor = true
        pcall(function()
            multitode.slog("UI", "row colour failed: no button.label accessor")
        end)
    end
    return applied
end

-- One flat colour per tower so the category you are browsing is obvious
-- (all Sniper researches green, all Tesla researches dark blue, ...).
-- Gauss is the exception: its in-game colour is an orange -> black gradient, so
-- its list fades darker row by row.
local function research_entry_color(id, towerKey, rowIndex)
    local tr, tg, tb = tree_rgb(id)
    if towerKey == nil then
        return color_from(tr, tg, tb)
    end

    local wr, wg, wb = tower_rgb(towerKey)
    if string.upper(tostring(towerKey)) == "GAUSS" and rowIndex ~= nil then
        local factor = math.max(0.45, 1 - 0.035 * (rowIndex - 1))
        wr, wg, wb = wr * factor, wg * factor, wb * factor
    end

    -- Tower colour dominates; the tree colour is the tint
    -- (blue = normal tree, orange = endless research).
    local treeWeight = research_is_endless(id) and 0.50 or 0.25
    return color_from(
        lerp(wr, tr, treeWeight),
        lerp(wg, tg, treeWeight),
        lerp(wb, tb, treeWeight))
end

local function build_research_index()
    if researchIndexCache ~= nil then
        return researchIndexCache
    end

    local towers, towerOrder, others = {}, {}, {}
    pcall(function()
        local values = C.ResearchType.values
        for i = 1, #values do
            local name = tostring(values[i]:name())
            local towerKey = nil
            if string.sub(name, 1, 6) == "TOWER_" then
                local rest = string.sub(name, 7)
                if string.sub(rest, 1, 5) == "TYPE_" then
                    rest = string.sub(rest, 6)
                end
                towerKey = string.match(rest, "^[A-Z]+")
            end

            if towerKey ~= nil and towerKey ~= "" then
                if towers[towerKey] == nil then
                    towers[towerKey] = { key = towerKey, ids = {} }
                    towerOrder[#towerOrder + 1] = towerKey
                end
                local ids = towers[towerKey].ids
                ids[#ids + 1] = name
            else
                local group = string.match(name, "^[A-Z]+") or "OTHER"
                if others[group] == nil then
                    others[group] = {}
                end
                local ids = others[group]
                ids[#ids + 1] = name
            end
        end
    end)

    researchIndexCache = { towers = towers, towerOrder = towerOrder, others = others }
    logger:i("Research index built: %s tower groups", tostring(#towerOrder))
    return researchIndexCache
end


local function attach_research(researchId)
    if refPickerWindow ~= nil then
        refPickerWindow:remove()
        refPickerWindow = nil
    end
    prefill_send(multitode.refs.composeResearch(researchId))
end

local open_research_list_window

local function open_research_list_window(title, ids, page, towerKey)
    local totalPages = math.max(1, math.ceil(#ids / K.RESEARCH_PAGE_SIZE))
    page = math.max(1, math.min(page or 1, totalPages))

    local headerSepColor = nil
    pcall(function()
        headerSepColor = color_from(tree_rgb(ids[1]))
    end)

    local rows = { {
        sep = string.format("%s - %s entries (page %s/%s)",
            tostring(title), tostring(#ids), tostring(page), tostring(totalPages)),
        sepColor = headerSepColor
    } }

    local firstIndex = (page - 1) * K.RESEARCH_PAGE_SIZE + 1
    local lastIndex = math.min(firstIndex + K.RESEARCH_PAGE_SIZE - 1, #ids)
    for i = firstIndex, lastIndex do
        local researchId = ids[i]
        local gradFrom, gradTo = row_gradient(towerKey, research_is_endless(researchId))
        rows[#rows + 1] = {
            label = (research_is_endless(researchId) and "[endless] " or "") .. research_display_name_localized(researchId),
            gradFrom = gradFrom,
            gradTo = gradTo,
            iconKey = towerKey,
            textColor = color_from(0.86, 0.95, 0.86),
            onClick = function()
                attach_research(researchId)
            end
        }
    end

    if totalPages > 1 then
        rows[#rows + 1] = { sep = "Page navigation" }
        local currentPage = page
        if currentPage > 1 then
            rows[#rows + 1] = { label = "< Prev page", onClick = function()
                open_research_list_window(title, ids, currentPage - 1, towerKey)
            end }
        end
        if currentPage < totalPages then
            rows[#rows + 1] = { label = "Next page >", onClick = function()
                open_research_list_window(title, ids, currentPage + 1, towerKey)
            end }
        end
    end

    rows[#rows + 1] = { label = "< Back to categories", onClick = function()
        open_research_browse_window()
    end }

    open_ref_popup("Attach research", rows)
end

local function open_research_group_window(groupKey)
    local index = build_research_index()
    local ids = index.others[groupKey]
    if ids == nil then
        return
    end
    open_research_list_window(refs_pretty_cat(groupKey), ids, 1, nil)
end

local function build_and_open_browse()
    local index = build_research_index()
    local rows = {}

    local towerHeaderColor = nil
    pcall(function()
        towerHeaderColor = color_from(tree_rgb(""))
    end)
    local otherHeaderColor = nil
    pcall(function()
        otherHeaderColor = color_from(tree_rgb("ENDLESS_MODE"))
    end)

    rows[#rows + 1] = { sep = "Towers (" .. tostring(#index.towerOrder) .. ")",
        sepColor = towerHeaderColor }
    for _, towerKey in ipairs(index.towerOrder) do
        local tower = index.towers[towerKey]
        if tower ~= nil then
            local key = towerKey
            local gradFrom, gradTo = nil, nil
            pcall(function()
                gradFrom, gradTo = row_gradient(key, false, true)
            end)
            rows[#rows + 1] = {
                label = string.format("%s (%s)", tower_display_name(key), tostring(#tower.ids)),
                big = true,
                iconKey = key,
                gradFrom = gradFrom,
                gradTo = gradTo,
                textColor = color_from(0.86, 0.95, 0.86),
                onClick = function()
                    open_research_list_window(tower_display_name(key), tower.ids, 1, key)
                end
            }
        end
    end

    local groupKeys = {}
    for groupKey, _ in pairs(index.others) do
        groupKeys[#groupKeys + 1] = groupKey
    end
    table.sort(groupKeys)

    rows[#rows + 1] = { sep = "Other (" .. tostring(#groupKeys) .. ")",
        sepColor = otherHeaderColor }
    for _, groupKey in ipairs(groupKeys) do
        local key = groupKey
        local ids = index.others[key]
        local gradFrom, gradTo = nil, nil
        pcall(function()
            gradFrom, gradTo = row_gradient(nil, research_is_endless(ids[1]))
        end)
        rows[#rows + 1] = {
            label = string.format("%s (%s)", refs_pretty_cat(key), tostring(#ids)),
            gradFrom = gradFrom,
            gradTo = gradTo,
            iconKey = towerKey,
            textColor = color_from(0.86, 0.95, 0.86),
            onClick = function()
                open_research_group_window(key)
            end
        }
    end

    rows[#rows + 1] = { sep = "Search" }
    rows[#rows + 1] = { label = "Type an exact id...", onClick = function()
        open_config_text_input("Attach research", "", "ENUM id, e.g. TOWER_SNIPER_A_LONG_RANGE", function(value)
            local id = tostring(value or ""):upper():gsub("%s+", "")
            local ok, rt = pcall(function()
                return C.ResearchType[id]
            end)
            if not ok or rt == nil then
                multitode.lobby.lastError = "Unknown research: " .. tostring(value)
                reopen_multiplayer_window()
                return
            end
            attach_research(id)
        end)
    end }

    open_ref_popup("Attach research", rows)
end

function open_research_browse_window()
    -- Wrapped so a failure is LOUD in the log instead of silently doing nothing.
    local ok, err = pcall(build_and_open_browse)
    if not ok then
        logger:e("Research picker failed: %s", tostring(err))
    end
end

-- ============================================================
-- Gradient helpers (real horizontal ramp via explicit quad corners)
-- ============================================================


-- Tower sprite for the row's left edge. The game stores towers as quads named
-- "towers.<TYPE>.base" (no .icon region), so try a few resolution paths and fall
-- back to no icon rather than breaking the row.
function build_tower_icon(towerKey)
    local key = string.upper(tostring(towerKey or ""))
    if key == "" then
        return nil
    end

    -- Aliases verified against resourcepacks/default/quads.json5:
    --   "tower-sniper"       -> whole tower: base + turret  (what we want)
    --   "tower-basic-base"   -> base only, no turret
    --   "tower-sniper-base-new" -> per-tower variant of the base
    -- Every tower has a whole-tower sprite, so try that first; the base-only
    -- fallbacks are why earlier attempts showed a bare base (and only for the
    -- two towers whose base regions happen to exist by that exact name).
    local id = string.lower(key)
    local aliases = {
        "tower-" .. id,
        "tower-" .. id .. "-base",
        "tower-" .. id .. "-base-new",
    }

    local image = nil
    local usedAlias = nil
    for i = 1, #aliases do
        local alias = aliases[i]
        if image == nil then
            pcall(function()
                local drawable = C.Game.i.assetManager:getDrawable(alias)
                if drawable ~= nil then
                    image = C.Image.new_D(drawable)
                    usedAlias = alias
                end
            end)
        end
        if image == nil then
            pcall(function()
                local region = C.Game.i.assetManager:getTextureRegion(alias)
                if region ~= nil then
                    image = C.Image.new_TR(region)
                    usedAlias = alias
                end
            end)
        end
    end

    if image == nil then
        if not warn.icon then
            warn.icon = true
            pcall(function()
                multitode.slog("UI", "tower icon not resolvable for " .. id)
            end)
        end
        return nil
    end

    if multitode._iconLogged == nil then
        multitode._iconLogged = {}
    end
    if not multitode._iconLogged[id] then
        multitode._iconLogged[id] = true
        pcall(function()
            multitode.slog("UI", "tower icon " .. id .. " -> " .. tostring(usedAlias))
        end)
    end
    return image
end

-- Horizontal gradient built from a strip of tinted cells. This uses the plain
-- 'blank' drawable the mod already uses elsewhere - a QuadDrawable is a UNIT quad
-- (0..1) and renders about one pixel, which is why the quad attempts were invisible.

function build_gradient_holder(fromColor, toColor)
    if fromColor == nil or toColor == nil then
        return nil
    end

    local holder = nil
    pcall(function()
        holder = C.Table.new()
        local fr, fg, fb = fromColor.r, fromColor.g, fromColor.b
        local tr, tg, tb = toColor.r, toColor.g, toColor.b

        for i = 0, K.GRADIENT_STEPS - 1 do
            -- Very gentle ease (exponent 0.92): smooths the ends without being
            -- perceptible as "easing" - at 56 steps the banding is invisible.
            local t = (i / (K.GRADIENT_STEPS - 1)) ^ 0.92
            local cell = C.Table.new()
            local blank = C.Game.i.assetManager:getDrawable("blank")
            if blank ~= nil then
                local cellR = lerp(fr, tr, t)
                local cellG = lerp(fg, tg, t)
                local cellB = lerp(fb, tb, t)

                cell:setBackground(blank:tint(C.Color.new_4f(cellR, cellG, cellB, 1)))
            end
            holder:add(cell):expand():fill()
        end
    end)

    if holder == nil and not warn.gradient then
        warn.gradient = true
        pcall(function()
            multitode.slog("UI", "gradient holder could not be built")
        end)
    end
    return holder
end

function apply_gradient_rows()
    local rows = multitode._gradientRows
    if rows == nil then
        return
    end
    for i = 1, #rows do
        local entry = rows[i]
        pcall(function()
            if entry.button == nil or entry.image == nil then
                return
            end
            pcall(function()
                entry.button.background:setVisible(false)
            end)
            if entry.image:getParent() == nil then
                entry.button:addActorAt(0, entry.image)
            end
            local w = entry.button:getWidth()
            local h = entry.button:getHeight()
            entry.image:setPosition(0, 0)
            entry.image:setSize(w, h)

            if entry.icon ~= nil then
                local size = h * 1.9
                if entry.icon:getParent() == nil then
                    entry.button:addActorAt(1, entry.icon)
                end
                entry.icon:setSize(size, size)
                entry.icon:setPosition(-size * 0.5, (h - size) * 0.5)
            end
        end)
    end
end

pcall(function()
    C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
        pcall(function()
            local frames = multitode._gradientFrames or 0
            if frames > 0 then
                multitode._gradientFrames = frames - 1
                if frames % 3 == 1 then
                    apply_gradient_rows()
                end
            end
        end)
    end))
end)
-- Expose the window opener for consumers outside this module (the stress harness binds F9
-- to the lab). Done here at file scope so it exists before the window is ever opened -
-- installing it inside the builder meant it only appeared after the first manual open.
pcall(function()
    if reopen_multiplayer_window ~= nil then
        _G.multitode.open_multitode_window = reopen_multiplayer_window
    end
end)
-- ========================================================================== Enter = chat
-- Enter opens the chat window. The toggle is wrapped lazily because the real implementation
-- is assigned during UI setup, which may run after this file is loaded. While the chat is
-- OPEN we deliberately do nothing: the input field owns Enter there (send / close), and
-- stealing it would close the window as the player hits send.
pcall(function()
    _G.multitode.toggle_chat_window = function()
        if toggle_chat_window ~= nil then
            return toggle_chat_window()
        end
        return false
    end
end)

-- ===================================================================== marks window
-- Separate marks menu (Ctrl+M), chat style. Small on purpose (narrow rows,
-- tight pads). Rebuilt fresh every open. Opening starts paint mode (any map
-- press paints); closing stops it.
-- Env note: scripts run twice per process (global + game env). The window
-- lives ONLY in the S-less env (same one that owns marks in 85_), and open
-- dedups by title scan - otherwise twins stack and look permanent.
local marksWindow = nil

-- Shares the file-local typing flag with 85_'s Ctrl+M poll, so the menu
-- can't pop while you're typing in chat.
_G.multitode.ui_text_input_open = function()
    return textInputOpen == true
end

local function marks_role_is_host()
    local role = nil
    pcall(function()
        if multitode.state ~= nil then role = multitode.state().role end
    end)
    return role == "HOST" or role == "HOST_AND_CLIENT"
end

-- One env owns the window (same rule as 85_'s Ctrl+M poll). Useless in menus
-- anyway - it needs a live game screen.
local function marks_window_env()
    if S ~= nil then
        return false
    end
    local okLive, live = pcall(function()
        local scr = C.Game.i.screenManager:getCurrentScreen()
        return scr ~= nil and C.GameScreen:_isInstance(scr)
    end)
    return okLive and live == true
end

-- Kill any existing marks window by title: a stale twin from the other env
-- (or a re-run script) would otherwise survive every close.
local function close_any_marks_window()
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
                -- getTitle() returns a StringBuilder: compare its string form,
                -- never the userdata itself (a direct == never matches, which
                -- once made twin windows unkillable).
                if okT and tostring(title) == "Marks (Ctrl+M)" then
                    pcall(function() w:remove() end)
                end
            end
        end
    end)
    marksWindow = nil
end

-- Button retitle with a tripwire: setText is real on ComplexButton, so a
-- silent failure means the click hit a stale/twin window, not a rendering
-- quirk. Still never rebuilds the window for a text change.
local function marks_set_text(btn, text)
    local ok = pcall(function()
        if btn ~= nil then btn:setText(tostring(text)) end
    end)
    if not ok then
        pcall(function()
            multitode.slog("UI", "marks button text update FAILED: " .. tostring(text))
        end)
    end
    return ok
end

local function open_marks_window()
    if not marks_window_env() then
        return
    end
    close_any_marks_window()
    local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
    windowStyle.resizeable = false
    windowStyle.inheritWidgetMinSize = true
    local window = C.Window.new_WS(windowStyle)
    marksWindow = window
    window:setTitle("Marks (Ctrl+M)")
    local content = C.Table.new()
    content:pad(6)

    -- Paint-mode button: flips the paint type HERE -> NOT HERE. While open,
    -- any map press/drag paints with it.
    local markMode = "ok"
    pcall(function()
        if multitode.marks ~= nil and multitode.marks.windowMarkMode == "no" then
            markMode = "no"
        end
    end)
    local modeBtn = create_action_button("Mark: HERE", function()
        markMode = (markMode == "ok") and "no" or "ok"
        pcall(function()
            if multitode.marks ~= nil and multitode.marks.set_window_mark_mode ~= nil then
                multitode.marks.set_window_mark_mode(markMode)
            end
        end)
        marks_set_text(modeBtn, markMode == "ok" and "Mark: HERE" or "Mark: NOT HERE")
        pcall(function()
            multitode.slog("UI", "marks window paint mode " .. tostring(markMode))
        end)
    end)
    pcall(function()
        if markMode == "no" then modeBtn:setText("Mark: NOT HERE") end
    end)
    content:add(modeBtn):width(210):left():padTop(2):row()

    local marksOn = true
    pcall(function()
        marksOn = not (multitode.marks ~= nil and multitode.marks.enabled == false)
    end)
    local marksBtn = create_action_button("Tile marks: " .. (marksOn and "ON" or "OFF"), function()
        marksOn = not marksOn
        pcall(function()
            multitode.marks = multitode.marks or {}
            multitode.marks.enabled = marksOn
            if multitode.marks.broadcast_enabled_flag ~= nil then
                multitode.marks.broadcast_enabled_flag()
            end
        end)
        marks_set_text(marksBtn, "Tile marks: " .. (marksOn and "ON" or "OFF"))
    end)
    content:add(marksBtn):width(210):left():padTop(2):row()

    local permOn = false
    pcall(function()
        permOn = (multitode.marks ~= nil and multitode.marks.permanent == true)
    end)
    local permBtn = create_action_button("Permanent: " .. (permOn and "ON" or "OFF"), function()
        permOn = not permOn
        pcall(function()
            multitode.marks = multitode.marks or {}
            if multitode.marks.set_permanent ~= nil then
                multitode.marks.set_permanent(permOn)
            else
                multitode.marks.permanent = permOn
            end
        end)
        marks_set_text(permBtn, "Permanent: " .. (permOn and "ON" or "OFF"))
    end)
    content:add(permBtn):width(210):left():padTop(2):row()

    content:add(create_action_button("Erase mode", function()
        pcall(function()
            if multitode.marks ~= nil and multitode.marks.arm ~= nil then
                multitode.marks.arm("erase")
            end
        end)
        pcall(function()
            multitode.show_toast("Erase armed: click a tile to remove its mark")
        end)
    end)):width(210):left():padTop(2):row()

    content:add(create_action_button("Clear my marks", function()
        pcall(function()
            if multitode.marks ~= nil and multitode.marks.clear_mine ~= nil then
                multitode.marks.clear_mine()
            end
        end)
    end)):width(210):left():padTop(2):row()

    -- Clear ALL stays host-only: clients only ever clear their own (and the
    -- API says no on client role as backup).
    if marks_role_is_host() then
        content:add(create_action_button("Clear ALL marks", function()
            pcall(function()
                if multitode.marks ~= nil and multitode.marks.clear_all ~= nil then
                    multitode.marks.clear_all()
                end
            end)
        end)):width(210):left():padTop(2):row()
    else
        add_info_row(content, "Clear ALL", "host only")
    end

    local showReceived = true
    pcall(function()
        showReceived = not (multitode.marks ~= nil and multitode.marks.showReceived == false)
    end)
    local showBtn = create_action_button("Others': " .. (showReceived and "ON" or "OFF"), function()
        showReceived = not showReceived
        pcall(function()
            multitode.marks = multitode.marks or {}
            multitode.marks.showReceived = showReceived
        end)
        marks_set_text(showBtn, "Others': " .. (showReceived and "ON" or "OFF"))
    end)
    content:add(showBtn):width(210):left():padTop(2):row()

    content:add(create_action_button("Close", function()
        close_marks_window()
    end)):width(210):left():padTop(2):row()

    window.main:add(content):pad(10):grow()
    C.Game.i.uiManager:addWindow(window)
    window:fitToContentSimple()
    place_window_centered(window)
    window:show()
    -- Opening arms painting (default HERE) and makes sure marks are on.
    pcall(function()
        multitode.marks = multitode.marks or {}
        multitode.marks.enabled = true
        if multitode.marks.set_window_mark_mode ~= nil then
            multitode.marks.set_window_mark_mode(markMode)
        end
        -- Clear any picked tile first, so its tower menu isn't covering the
        -- map when you start painting (the guard below keeps it clear).
        if multitode.marks.clear_selection ~= nil then
            multitode.marks.clear_selection()
        end
    end)
    pcall(function()
        multitode.slog("UI", "marks window opened")
    end)
end

local function close_marks_window()
    pcall(function()
        if multitode.marks ~= nil and multitode.marks.set_window_mark_mode ~= nil then
            multitode.marks.set_window_mark_mode(nil)
        end
    end)
    close_any_marks_window()
    pcall(function()
        multitode.slog("UI", "marks window closed")
    end)
end

local function toggle_marks_window()
    if not marks_window_env() then
        return
    end
    if marksWindow ~= nil then
        close_marks_window()
        return
    end
    local ok, err = pcall(open_marks_window)
    if not ok then
        logger:e("Marks window failed: %s", tostring(err))
    end
end
_G.multitode.toggle_marks_window = toggle_marks_window

pcall(function()
    local enterHeld = false
    C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
        pcall(function()
            local input = C.Gdx.input
            if input == nil then
                return
            end
            local code = nil
            pcall(function() code = C.Input_Keys.ENTER end)
            if code == nil then pcall(function() code = C.Input.Keys.ENTER end) end
            if code == nil then code = 66 end

            local down = input:isKeyPressed(code)
            if not down then
                enterHeld = false
                suppressChatEnterUntilRelease = false
                return
            end
            -- Enter still held: after a text-input submit, keep the edge consumed
            -- until release so the dialog's confirm key cannot open chat.
            if suppressChatEnterUntilRelease or textInputOpen then
                enterHeld = true
                return
            end
            if not enterHeld then
                enterHeld = true
                local open = false
                pcall(function()
                    open = _G.multitode.lobby ~= nil and _G.multitode.lobby.chatOpen == true
                end)
                if not open then
                    pcall(function() _G.multitode.toggle_chat_window() end)
                end
            end
        end)
    end))
end)
-- ===================================================================== lab window (dev)
-- Only reachable in development mode: Shift+F9 enables the lab, which opens this window.
-- Nothing here is needed to play, and none of it appears unless the lab is switched on.
pcall(function()
    local labWindow = nil
    local overlayWindow = nil
    local overlayHeld = false

    local function lab_set(key, value)
        pcall(function()
            multitode.getApi():setSetting(key, value and "1" or "0")
        end)
    end

    local function lab_get(key)
        local v = "0"
        pcall(function() v = tostring(multitode.getApi():getSetting(key, "0")) end)
        return v == "1"
    end

    local function toast(text)
        pcall(function()
            if multitode.show_toast ~= nil then multitode.show_toast(text) end
        end)
        pcall(function() logger:i("Lab: %s", tostring(text)) end)
    end

    -- ------------------------------- debug overlay: human-readable numbers, no log digging
    local function overlay_text()
        local tick, wave, speed = "?", "?", "?"
        pcall(function()
            local scr = C.Game.i.screenManager:getCurrentScreen()
            local S = scr ~= nil and scr.S or nil
            if S ~= nil and S.state ~= nil then
                tick = tostring(S.state.updateNumber)
                wave = tostring(S.wave ~= nil and S.wave.currentWave or "?")
                speed = tostring(S.state:getGameSpeed())
            end
        end)
        local pending = "?"
        pcall(function() pending = tostring(multitode.net.getPendingCount()) end)
        local rtt = "-"
        pcall(function()
            local v = tonumber(multitode.getApi():getLatencyMillis())
            if v ~= nil and v > 0 then rtt = string.format("%.0f", v) end
        end)
        local marks = "?"
        pcall(function() marks = tostring(multitode.getApi():getTileMarkCount()) end)
        local acts = "?"
        pcall(function()
            local a = multitode.actStats
            if a ~= nil then
                acts = string.format("%s/%s/%s", tostring(a.allowed or 0),
                    tostring(a.captured or 0), tostring(a.hostSent or 0))
            end
        end)
        return string.format("tick=%s wave=%s speed=%sx | pending=%s rtt=%sms marks=%s | act ok/cap/host=%s",
            tick, wave, speed, pending, rtt, marks, acts)
    end

    local function build_overlay()
        if overlayWindow ~= nil then
            return
        end
        local stage = C.Game.i.uiManager and C.Game.i.uiManager.stage
        if stage == nil then
            return
        end
        local style = C.Game.i.assetManager:createDefaultWindowStyle()
        style.resizeable = false
        style.inheritWidgetMinSize = true
        local window = C.Window.new_WS(style)
        window:setTitle(overlay_text())
        local content = C.Table.new()
        content:pad(6)
        pcall(function()
            window.main:add(content):pad(6):grow()
        end)
        pcall(function() C.Game.i.uiManager:addWindow(window) end)
        pcall(function() window:fitToContentSimple() end)
        pcall(function() window:setPosition(8, 8) end)
        pcall(function() window:show() end)
        overlayWindow = window
    end

    local function destroy_overlay()
        if overlayWindow ~= nil then
            pcall(function() overlayWindow:remove() end)
            overlayWindow = nil
        end
    end

    -- refresh the overlay once per frame (title only: no label API needed)
    pcall(function()
        C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
            pcall(function()
                if overlayWindow ~= nil then
                    local ok = pcall(function() overlayWindow:setTitle(overlay_text()) end)
                    if not ok then
                        destroy_overlay()
                    end
                end
            end)
        end))
    end)

    local function toggle_overlay()
        overlayHeld = not overlayHeld
        lab_set("lab.overlay", overlayHeld)
        if overlayHeld then
            build_overlay()
            toast("Debug overlay ON")
        else
            destroy_overlay()
            toast("Debug overlay OFF")
        end
    end

    -- ------------------------------------------------------------- the lab window itself
    local function build_lab()
        if labWindow ~= nil then
            return labWindow
        end
        local stage = C.Game.i.uiManager and C.Game.i.uiManager.stage
        if stage == nil or create_action_button == nil then
            return nil
        end

        local style = C.Game.i.assetManager:createDefaultWindowStyle()
        style.resizeable = false
        style.inheritWidgetMinSize = true
        local window = C.Window.new_WS(style)
        labWindow = window
        window:setTitle("Multitode Lab (development)")

    local content = C.Table.new()
    content:pad(8)
    pcall(function() content:left() end)

        local function addButton(label, fn, width)
            local b = create_action_button(label, fn)
            content:add(b):width(width or 300):left():padBottom(4):row()
        end

        addButton((lab_get("lab.anyMap") and "Any map: ON" or "Any map: OFF"), function()
            local now = not lab_get("lab.anyMap")
            lab_set("lab.anyMap", now)
            toast(now and "Any map ON - progress check ignored on this host" or "Any map OFF")
            pcall(function() labWindow:remove() end)
            labWindow = nil
            build_lab()
        end)

        addButton((lab_get("lab.overlay") and "Debug overlay: ON" or "Debug overlay: OFF"), function()
            toggle_overlay()
            pcall(function() labWindow:remove() end)
            labWindow = nil
            build_lab()
        end)

        addButton("Marks burst 10s @120/s", function()
            pcall(function() multitode.stress.start(10, 120) end)
        end)

        addButton("HARD 15s @1500/s + 8x", function()
            pcall(function() multitode.stress.startHard() end)
        end)

        addButton("Speed test 1x/2x/4x/8x", function()
            pcall(function() multitode.stress.startSpeed() end)
        end)

        addButton("Watch actions 30s", function()
            pcall(function() multitode.stress.watchStart() end)
        end)

        -- Superlog control, moved here: it is a development/diagnostic switch, not something
        -- a normal player needs in the settings.
        local superlogNow = true
        pcall(function()
            if multitode.superlogOn ~= nil then
                superlogNow = multitode.superlogOn()
            end
        end)
        addButton("Superlog: " .. (superlogNow and "ON" or "OFF"), function()
            pcall(function()
                if multitode.setSuperlog ~= nil then
                    multitode.setSuperlog(not superlogNow)
                end
            end)
            toast(not superlogNow and "Superlog ON" or "Superlog OFF")
            pcall(function() labWindow:remove() end)
            labWindow = nil
            build_lab()
        end)

        local note = nil
        pcall(function()
            note = C.Label.new("Development only. Shift+F9 toggles the lab.", C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL))
        end)
        if note ~= nil then
            pcall(function() content:add(note):left():padTop(4):row() end)
        end

        pcall(function() window.main:add(content):pad(12):grow() end)
        pcall(function() C.Game.i.uiManager:addWindow(window) end)
        pcall(function() window:fitToContentSimple() end)
        pcall(function() window:setPosition(16, 120) end)
        pcall(function() window:show() end)
        return window
    end

    -- Toggle, and rebuild whenever the window is no longer attached. Closing with the
    -- window's own X left the cached reference alive, so build_lab() returned a dead
    -- window and nothing appeared - that was the "cannot reopen" bug.
    multitode.open_lab_window = function()
        if labWindow ~= nil then
            local attached = false
            pcall(function() attached = labWindow:getParent() ~= nil end)
            if attached then
                pcall(function() labWindow:remove() end)
                labWindow = nil
                toast("Lab window closed (Shift+F9 to reopen)")
                return
            end
            labWindow = nil
        end
        if build_lab() == nil then
            toast("Lab window unavailable in this build")
        end
    end

    multitode.lab_overlay_setting = function()
        overlayHeld = lab_get("lab.overlay")
        if overlayHeld then
            build_overlay()
        end
    end

    -- honour a previously saved overlay setting at load
    pcall(function() multitode.lab_overlay_setting() end)
end)