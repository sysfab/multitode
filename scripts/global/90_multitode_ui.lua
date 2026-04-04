local logger = C.TLog:forTag("multitode/ui.lua")

local patchedRoot = nil
local profileSummaryActor = nil
local profileNameLabel = nil
local multiplayerWindow = nil
local pendingWindowReopenFrames = -1
local lastPatchedUsername = nil
local lastDumpedUsername = nil
local patchLogged = false
local profileClickListeners = {}
local listenerOwnersDumped = false
local open_multiplayer_window = nil

local bridgeModes = {
    "CLIENT",
    "HOST_AND_CLIENT"
}

local function clear_profile_click_listener()
    profileClickListeners = {}
    profileSummaryActor = nil
end

local function clear_profile_state()
    clear_profile_click_listener()
    profileNameLabel = nil
    lastPatchedUsername = nil
    lastDumpedUsername = nil
end

local function toggle_flag(key)
    local config = multitode.getConfig()
    multitode.configure({ [key] = not not not config[key] })
end

local function create_action_button(text, onClick)
    local button = C.RectButton.new(text, C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_SMALL), C.Runnable(onClick))
    button:setSize(260, 56)
    return button
end

local function add_info_row(table, title, value)
    local labelStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL)
    local titleLabel = C.Label.new(title, labelStyle)
    titleLabel:setColor(1, 1, 1, 0.65)
    table:add(titleLabel):width(120):left():padRight(16):padBottom(8)

    local valueLabel = C.Label.new(tostring(value), labelStyle)
    valueLabel:setWrap(true)
    table:add(valueLabel):width(380):left():padBottom(8):row()
end

local function reopen_multiplayer_window()
    if multiplayerWindow ~= nil then
        multiplayerWindow:remove()
        multiplayerWindow = nil
    end

    open_multiplayer_window()
end

local function get_username()
    local config = multitode.getConfig()
    return config.name or "Player"
end

local function format_bridge_mode(role)
    if role == "HOST_AND_CLIENT" then
        return "Host and Client"
    end

    local normalized = tostring(role or "CLIENT"):lower():gsub("_", " ")
    return normalized:gsub("(%a)([%w']*)", function(first, rest)
        return string.upper(first) .. rest
    end)
end

local function next_bridge_mode(role)
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

    if multiplayerWindow ~= nil then
        multiplayerWindow:remove()
        multiplayerWindow = nil
    end

    local listener = luajava.createProxy(C.TextInputListener, {
        input = function(_, text)
            local value = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if value == "" then
                pendingWindowReopenFrames = 2
                return
            end

            multitode.configure({ name = value })
            pendingWindowReopenFrames = 2
        end,
        canceled = function()
            pendingWindowReopenFrames = 2
        end
    })

    C.Game.i.uiManager:getTextInput(listener, "Change Username", tostring(config.name or ""), "Player name")
end

local function open_config_text_input(title, initialValue, hint, onSubmit)
    if multiplayerWindow ~= nil then
        multiplayerWindow:remove()
        multiplayerWindow = nil
    end

    local listener = luajava.createProxy(C.TextInputListener, {
        input = function(_, text)
            local value = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if value ~= "" then
                onSubmit(value)
            end
            pendingWindowReopenFrames = 2
        end,
        canceled = function()
            pendingWindowReopenFrames = 2
        end
    })

    C.Game.i.uiManager:getTextInput(listener, title, tostring(initialValue or ""), hint)
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
            multitode.configure({ port = port, listenPort = port })
        end
    end)
end

local function text_of_label(label)
    local text = label:getText()
    if text == nil then
        return nil
    end

    return text:toString()
end

local function text_of_actor(actor)
    local ok, text = pcall(function()
        return actor:getText()
    end)
    if not ok or text == nil then
        return nil
    end

    return text:toString()
end

local function try_set_actor_text(actor, value)
    local ok = pcall(function()
        actor:setText(value)
    end)
    return ok
end

local function dump_profile_text_candidates(actor)
    if actor == nil then
        return
    end

    local text = text_of_actor(actor)

    local ok, children = pcall(function()
        return actor:getChildren()
    end)
    if not ok or children == nil then
        return
    end

    for i = 1, children.size do
        dump_profile_text_candidates(children.items[i])
    end
end

open_multiplayer_window = function()
    if multiplayerWindow ~= nil and multiplayerWindow:getParent() ~= nil then
        multiplayerWindow:toFront()
        multiplayerWindow:show()
        return
    end

    local windowStyle = C.Game.i.assetManager:createDefaultWindowStyle()
    windowStyle.resizeable = false
    windowStyle.inheritWidgetMinSize = true

    local window = C.Window.new_WS(windowStyle)
    multiplayerWindow = window
    window:setTitle("Multiplayer")
    window:addListener(C.WindowListener({
        closed = function()
            local ok, err = pcall(function()
                multitode.saveConfig()
                multitode.stop()
                multitode.start()
            end)
            if not ok then
                logger:e("Failed to apply config on window close: %s", tostring(err))
            end
        end
    }))

    local config = multitode.getConfig()
    local content = C.Table.new()
    content:pad(8)

    local titleStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_SMALL)
    local sectionStyle = C.Game.i.assetManager:getLabelStyle(C.Config.FONT_SIZE_X_SMALL)
    local info = C.Table.new()
    info:setBackground(C.Game.i.assetManager:getDrawable("blank"):tint(C.Color.new_4f(0.08, 0.1, 0.14, 0.9)))
    info:pad(16)
    local infoTitle = C.Label.new("Session Config", titleStyle)
    infoTitle:setColor(C.MaterialColor.LIGHT_BLUE.P500)
    info:add(infoTitle):colspan(2):left():padBottom(14):row()
    add_info_row(info, "Profile", config.name)
    add_info_row(info, "Role", config.role)
    add_info_row(info, "Host", config.host)
    add_info_row(info, "Port", config.port)
    add_info_row(info, "Listen", config.listenPort)
    add_info_row(info, "Auto start", config.autoStart)
    add_info_row(info, "Auto connect", config.autoConnect)
    add_info_row(info, "Session", multitode.describeSession())
    add_info_row(info, "Peers", multitode.describePeers())

    content:add(info):width(540):left():padBottom(12):row()

    local bridgeModeButton = create_action_button(
        format_bridge_mode(config.role),
        function()
            local nextRole = next_bridge_mode(multitode.getConfig().role)
            multitode.configure({ role = nextRole })
            reopen_multiplayer_window()
        end
    )

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

    window.main:add(content):pad(16):grow()
    C.Game.i.uiManager:addWindow(window)
    window:fitToContentSimple()
    window:showAtCursor()

    local stage = C.Game.i.uiManager.stage
    window:setPosition(
        (stage:getWidth() - window:getWidth()) * 0.5,
        (stage:getHeight() - window:getHeight()) * 0.5
    )
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

local function patch_actor_tree(actor)
    if actor == nil then
        return false
    end

    local patched = false
    local text = text_of_actor(actor)
    if text == "Tap here to sign in for cloud saves and leaderboards" and C.Label:_isInstance(actor) then
        if try_set_actor_text(actor, "Tap to open multitode settings") then
            patched = true
        end
    end

    if text ~= nil and (C.Label:_isInstance(actor) or tostring(actor:getClass()) == "class com.prineside.tdi2.ui.actors.LimitedWidthLabel")
            and (text == "Guest" or text == lastPatchedUsername or actor == profileNameLabel) then
        local username = get_username()
        if try_set_actor_text(actor, username) then
            profileNameLabel = actor
            lastPatchedUsername = username
            patched = true
            if patchedButton == nil then
                try_attach_button_handler(actor)
            end
        end
    end

    if C.Group:_isInstance(actor) then
        local children = actor:getChildren()
        for i = 1, children.size do
            patched = patch_actor_tree(children.items[i]) or patched
        end
    end

    return patched
end

local function patch_profile_summary(profileSummary)
    if profileSummary == nil then
        return false
    end

    local patched = patch_actor_tree(profileSummary)
    ensure_profile_click_listener(profileSummary)
    if patched and not patchLogged then
        patchLogged = true
        logger:i("Patched main menu multiplayer entry for %s", get_username())
    end
    return patched
end

local function sync_main_menu_username()
    local username = get_username()

    if profileNameLabel ~= nil and profileNameLabel:getParent() ~= nil then
        if text_of_actor(profileNameLabel) ~= username then
            try_set_actor_text(profileNameLabel, username)
        end
        lastPatchedUsername = username
    end
end

local function patch_main_menu_ui()
    if not C.MainMenuScreen:_isInstance(C.Game.i.screenManager:getCurrentScreen()) then
        clear_profile_state()
        patchedRoot = nil
        return
    end

    local root = C.Game.i.uiManager.stage:getRoot()
    if root == nil then
        return
    end

    if root ~= patchedRoot then
        clear_profile_state()
        patchedRoot = root
        patchLogged = false
        listenerOwnersDumped = false
        patch_profile_summary(find_actor_by_name(root, "ProfileSummary"))
        return
    end

    local currentUsername = get_username()
    if lastDumpedUsername ~= currentUsername then
        lastDumpedUsername = currentUsername
        dump_profile_text_candidates(find_actor_by_name(root, "ProfileSummary"))
    end

    sync_main_menu_username()

    patch_profile_summary(find_actor_by_name(root, "ProfileSummary"))
end

local Render = com.prineside.tdi2.events.global.Render.class
local PostRender = com.prineside.tdi2.events.global.PostRender.class

C.Game.EVENTS:getListeners(Render):add(C.Listener(function(_)
    patch_main_menu_ui()
end))

C.Game.EVENTS:getListeners(PostRender):add(C.Listener(function(_)
    if pendingWindowReopenFrames > 0 then
        pendingWindowReopenFrames = pendingWindowReopenFrames - 1
    elseif pendingWindowReopenFrames == 0 then
        pendingWindowReopenFrames = -1
        local ok, err = pcall(open_multiplayer_window)
        if not ok then
            logger:e("Failed to reopen multiplayer window: %s", tostring(err))
        end
    end

    if not C.MainMenuScreen:_isInstance(C.Game.i.screenManager:getCurrentScreen()) then
        return
    end

    sync_main_menu_username()
    patch_profile_summary(find_actor_by_name(C.Game.i.uiManager.stage:getRoot(), "ProfileSummary"))
end))

logger:i("Multitode UI hook loaded")
