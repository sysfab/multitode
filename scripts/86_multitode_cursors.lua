-- ============================================================
-- Player cursors: broadcast the local cursor tile at ~6 Hz and
-- show remote cursors as lightweight indicators on the map.
-- Uses BridgeApi.setRemoteCursor / clearRemoteCursor (TileMarks).
-- ============================================================

local logger = C.TLog:forTag("multitode/cursors.lua")

_G.multitode = _G.multitode or {}
multitode.cursors = multitode.cursors or {}

local cursors = multitode.cursors

cursors.enabled = true
cursors.sendIntervalMs = 160   -- ~6 Hz (within the 4-8 Hz handoff target)
cursors.lastSentAt = 0
cursors.lastSentX = nil
cursors.lastSentY = nil
cursors.remote = {}            -- playerId -> { x=, y=, name=, at=ms }
cursors.handlersRegistered = false

local function now_ms()
    local ok, v = pcall(multitode.now_ms)
    if ok and v then return v end
    return 0
end

local function get_self_id()
    local ok, info = pcall(multitode.getSessionInfo)
    if ok and info ~= nil then return tonumber(info.localPlayerId) or 0 end
    return 0
end

local function current_systems()
    local systems = nil
    pcall(function()
        local screen = C.Game.i.screenManager:getCurrentScreen()
        if screen ~= nil and C.GameScreen:_isInstance(screen) then
            systems = screen.S
        end
    end)
    return systems
end

local function local_cursor_tile()
    -- Prefer the engine's camera unprojection (works for clients too).
    local x, y = nil, nil
    pcall(function()
        local api = multitode.getApi()
        local cx = tonumber(api:getCursorTileX())
        local cy = tonumber(api:getCursorTileY())
        if cx ~= nil and cy ~= nil and cx > -1000 and cy > -1000 then
            x, y = cx, cy
        end
    end)
    if x == nil then
        pcall(function()
            local systems = current_systems()
            if systems ~= nil and systems._gameMapSelection ~= nil then
                local tile = systems._gameMapSelection:getHoveredTile()
                if tile ~= nil then
                    x = tile:getX()
                    y = tile:getY()
                end
            end
        end)
    end
    return x, y
end

local function send_cursor()
    if cursors.enabled ~= true then return end
    local systems = current_systems()
    if systems == nil or systems.map == nil then return end

    local x, y = local_cursor_tile()
    if x == nil or y == nil then return end

    local now = now_ms()
    if now - cursors.lastSentAt < cursors.sendIntervalMs then return end
    -- Only send when the tile actually changed (or heartbeat every ~500ms).
    local changed = (x ~= cursors.lastSentX or y ~= cursors.lastSentY)
    if not changed and (now - cursors.lastSentAt) < 500 then return end

    cursors.lastSentAt = now
    cursors.lastSentX = x
    cursors.lastSentY = y

    local selfId = get_self_id()
    local name = "?"
    pcall(function() name = tostring((multitode.getConfig() or {}).name or "?") end)

    local payload = { x = tonumber(x), y = tonumber(y), from = selfId, name = name,
        mapCh = (multitode.lobby and (multitode.lobby.mapChannel or multitode.lobby.selectedLevel)) or "*" }
    pcall(function()
        local role = nil
        pcall(function() role = multitode.state().role end)
        if tostring(role) == "CLIENT" then
            -- A client can only send to the host. The host handler applies the
            -- cursor and relays it; attempting a client-side broadcast is a no-op
            -- and used to make cursor recovery depend on two unrelated paths.
            pcall(function()
                multitode.getApi():sendLuaMessageToHost(
                    "itd", "cursor_pos", multitode.net.encodePayload(payload))
            end)
        else
            pcall(function()
                multitode.net.broadcast("itd", "cursor_pos", payload)
            end)
        end
    end)
end

local function apply_remote_cursor(payload)
    if payload == nil then return end
    local fromId = tonumber(payload.from)
    local rx, ry = tonumber(payload.x), tonumber(payload.y)
    if fromId == nil or rx == nil or ry == nil then return end
    if fromId == get_self_id() then return end

    cursors.remote[fromId] = {
        x = rx,
        y = ry,
        name = tostring(payload.name or "?"),
        at = now_ms()
    }
    pcall(function()
        multitode.getApi():setRemoteCursor(fromId, rx, ry)
    end)
end

local function ensure_handlers()
    if cursors.handlersRegistered then return end

    -- Single handler for both roles (multitode.net keeps ONE per channel+name).
    multitode.net.on("itd", "cursor_pos", function(ctx, payload)
        if payload == nil then return end

        -- Cross-map filter.
        local ourCh = multitode.lobby and (multitode.lobby.mapChannel or multitode.lobby.selectedLevel)
        local msgCh = payload.mapCh
        if ourCh ~= nil and msgCh ~= nil and tostring(msgCh) ~= "*" and tostring(ourCh) ~= "*"
                and tostring(msgCh) ~= tostring(ourCh) then
            return
        end

        if ctx ~= nil and ctx.receiverContext == "HOST" then
            -- Host applies + relays (keeping "from" so the origin can skip its echo).
            apply_remote_cursor(payload)
            pcall(function()
                multitode.net.broadcast("itd", "cursor_pos", {
                    x = tonumber(payload.x),
                    y = tonumber(payload.y),
                    from = tonumber(payload.from) or 0,
                    name = tostring(payload.name or "?"),
                    mapCh = tostring(payload.mapCh or "*")
                })
            end)
            return
        end
        apply_remote_cursor(payload)
    end)

    cursors.handlersRegistered = true
    logger:i("Cursor handlers registered")
end

local function prune_stale()
    local now = now_ms()
    for id, entry in pairs(cursors.remote) do
        if now - (entry.at or 0) > 3000 then
            cursors.remote[id] = nil
            pcall(function() multitode.getApi():clearRemoteCursor(id) end)
        end
    end
end

ensure_handlers()

pcall(function()
    C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
        pcall(function()
            if cursors.enabled ~= true then return end
            send_cursor()
            prune_stale()
        end)
    end))
end)

logger:i("Multitode player cursors loaded (interval=%dms)", cursors.sendIntervalMs)
multitode.cursors = cursors
