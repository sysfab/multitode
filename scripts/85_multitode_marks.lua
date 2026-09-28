-- ============================================================
-- Tile marks: point at a tile for the whole lobby.
--   blue  = "put it here"    (S.map:highlightTile, same as the tutorials)
--   red   = "NOT here"       (S.map:showTileWarningParticle)
-- Two access paths: a bound key (default M, Shift = NOT here) and an action in
-- the Attach menu (arm mode: the next click marks the tile under the cursor).
-- ============================================================

local logger = C.TLog:forTag("multitode/marks.lua")

_G.multitode = _G.multitode or {}
multitode.marks = multitode.marks or {}

local marks = multitode.marks

marks.keyName = marks.keyName or "M"
-- Enabled by default (marks are a core communication feature). Individual players
-- may switch them off for performance/annoyance; the host is told via the roster
-- flag once that is wired, so the badge can show "marks off".
if marks.enabled == nil then
    marks.enabled = true
end
if marks.showReceived == nil then
    marks.showReceived = true
end
marks.callSeq = marks.callSeq or 0
marks.durationSec = 10
marks.permanent = false            -- when true, new marks never expire (durationMs <= 0)
marks.armed = nil            -- "ok" | "no" | "erase" (attach-flow arm mode)
marks.eraseMode = false      -- Ctrl+E toggles erase; next click removes a mark
marks.active = marks.active or {}   -- { {x=, y=, mode=, expiresAt=ms, nextRedAt=ms, permanent=, ownerId=} = true }
marks.keyHeld = false
marks.clickHeld = false
marks.warnedKey = false
marks.mapKey = nil           -- cleared/rebuilt on level change (per-map lifecycle)

local RED_REFRESH_MS = 1200

-- ---------------------------------------------------------------- helpers
-- The bare global S is NOT available in this module's execution - that is exactly
-- why every mark silently failed to apply (the lookup returned nil, the pcall
-- swallowed it and nothing was drawn). Every working module resolves the systems
-- through the screen manager, so do the same here.
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

local function hovered_tile()
    local systems = current_systems()
    if systems == nil then
        return nil
    end
    local tile = nil
    pcall(function()
        if systems._gameMapSelection ~= nil then
            tile = systems._gameMapSelection:getHoveredTile()
        end
    end)
    if tile == nil then
        pcall(function()
            if systems.map ~= nil and systems.map.getHoveredTile ~= nil then
                tile = systems.map:getHoveredTile()
            end
        end)
    end
    return tile
end

local function tile_coords(tile)
    local x, y = nil, nil
    pcall(function()
        x = tile:getX()
        y = tile:getY()
    end)
    return x, y
end

-- ---------------------------------------------------------------- rendering
local function apply_local_mark(x, y, mode, isOwn)
    if marks.enabled ~= true then
        return false
    end
    if x == nil or y == nil then
        return false
    end

        -- One highlight per tile, ever. A repeat mark for a tile we already marked only
        -- refreshes its entry - it must NOT call into the game again.
        for i = 1, #marks.active do
            local existing = marks.active[i]
            if existing.x == x and existing.y == y then
                local nowMs = 0
                pcall(function() nowMs = multitode.now_ms() end)
                existing.mode = mode
                existing.permanent = marks.permanent == true
                if existing.permanent then
                    existing.expiresAt = nowMs + 365 * 24 * 3600 * 1000 -- effectively forever
                else
                    existing.expiresAt = nowMs + marks.durationSec * 1000
                end
                if mode == "ok" then
                    marks.blueExpiryAt = existing.expiresAt
                end
                pcall(function()
                    multitode.slog("MARK", string.format("refreshed %s x=%s y=%s (no re-highlight)",
                        tostring(mode), tostring(x), tostring(y)))
                end)
                return true
            end
        end

    local okay = false
    pcall(function()
        local systems = current_systems()
        if systems == nil or systems.map == nil then
            return
        end

        -- Everything is Java-managed: the bridge obtains the particles, positions
        -- them at the tile centre and owns each mark's lifetime. No engine highlight
        -- list, so MapSystem.drawBatch can never meet a null particle, and a mark no
        -- longer depends on its tile happening to be drawn.
        marks.callSeq = (marks.callSeq or 0) + 1
        local added = false
        pcall(function()
            local durMs = 0
            if marks.permanent ~= true then
                durMs = (marks.durationSec or 10) * 1000
            end
            -- ownerId: our local player id so Clear mine can filter
            local ownerId = 0
            pcall(function()
                local info = multitode.getSessionInfo()
                if info ~= nil then ownerId = tonumber(info.localPlayerId) or 0 end
            end)
            added = multitode.getApi():addTileMark(tonumber(x), tonumber(y), mode ~= "ok", durMs) == true
            -- ownerId is Lua-side only (active entry); Java tracks via mark itself when needed
            _ = ownerId
        end)
        okay = added
        pcall(function()
            multitode.slog("MARKCALL", string.format("seq=%s mark x=%s y=%s mode=%s ok=%s",
                tostring(marks.callSeq), tostring(x), tostring(y), tostring(mode), tostring(added)))
        end)
    end)

    if okay then
        local nowMs = 0
        pcall(function() nowMs = multitode.now_ms() end)

        -- One mark per tile: refresh/replace instead of stacking.
        local existingIndex = nil
        for i = 1, #marks.active do
            if marks.active[i].x == x and marks.active[i].y == y then
                existingIndex = i
            end
        end
        local isPerm = marks.permanent == true
        local deadline = nowMs + marks.durationSec * 1000
        if isPerm then
            deadline = nowMs + 365 * 24 * 3600 * 1000
        end
        local selfId = 0
        pcall(function()
            local info = multitode.getSessionInfo()
            if info ~= nil then selfId = tonumber(info.localPlayerId) or 0 end
        end)
        local entry = {
            x = x,
            y = y,
            mode = mode,
            expiresAt = deadline,
            nextRedAt = nowMs + RED_REFRESH_MS,
            permanent = isPerm,
            ownerId = selfId
        }
        if mode == "ok" and not isPerm then
            -- every live blue mark is extended to the same deadline, so a
            -- removeHighlights only happens when the last one is finished
            marks.blueExpiryAt = deadline
            for i = 1, #marks.active do
                if not marks.active[i].permanent then
                    marks.active[i].expiresAt = deadline
                end
            end
        end
        if existingIndex ~= nil then
            marks.active[existingIndex] = entry
        else
            -- keep the live set small: each red mark re-triggers a particle, so an
            -- unbounded list multiplies effects (and the pooled particles are finite)
            -- Permanent marks are never evicted by the size cap.
            local nonPerm = 0
            for i = 1, #marks.active do
                if not marks.active[i].permanent then nonPerm = nonPerm + 1 end
            end
            while nonPerm >= 12 do
                for i = 1, #marks.active do
                    if not marks.active[i].permanent then
                        table.remove(marks.active, i)
                        nonPerm = nonPerm - 1
                        break
                    end
                end
            end
            marks.active[#marks.active + 1] = entry
        end
        pcall(function()
            multitode.slog("MARK", string.format("applied %s x=%s y=%s own=%s perm=%s",
                tostring(mode), tostring(x), tostring(y), tostring(isOwn), tostring(isPerm)))
        end)
    else
        pcall(function()
            multitode.slog("MARK", string.format("FAILED to apply %s x=%s y=%s own=%s",
                tostring(mode), tostring(x), tostring(y), tostring(isOwn)))
        end)
    end
    return okay
end

function marks.clear()
    marks.active = {}
    pcall(function()
        multitode.getApi():clearTileMarks()
    end)
end

-- Remove one mark at (x, y) locally + on peers (erase mode).
function marks.erase_at(x, y)
    if x == nil or y == nil then return false end
    local removed = false
    for i = #marks.active, 1, -1 do
        local m = marks.active[i]
        if m.x == x and m.y == y then
            table.remove(marks.active, i)
            removed = true
        end
    end
    pcall(function()
        multitode.getApi():removeTileMarkAt(tonumber(x), tonumber(y))
    end)
    local selfId = 0
    pcall(function()
        local info = multitode.getSessionInfo()
        if info ~= nil then selfId = tonumber(info.localPlayerId) or 0 end
    end)
    pcall(function()
        multitode.net.broadcast("itd", "tile_erase",
            { x = tonumber(x), y = tonumber(y), from = selfId })
    end)
    pcall(function()
        multitode.slog("MARK", string.format("erased x=%s y=%s hadEntry=%s",
            tostring(x), tostring(y), tostring(removed)))
    end)
    return removed
end

-- Clear only this player's marks (Clear mine).
function marks.clear_mine()
    local selfId = 0
    pcall(function()
        local info = multitode.getSessionInfo()
        if info ~= nil then selfId = tonumber(info.localPlayerId) or 0 end
    end)
    local keep = {}
    for _, m in ipairs(marks.active) do
        if m.ownerId ~= selfId then
            keep[#keep + 1] = m
        end
    end
    marks.active = keep
    -- Rebuild Java-side: clear all, re-add survivors (clearTileMarks is the only bulk op).
    pcall(function() multitode.getApi():clearTileMarks() end)
    for _, m in ipairs(marks.active) do
        pcall(function()
            local durMs = m.permanent and 0 or (marks.durationSec or 10) * 1000
            multitode.getApi():addTileMark(m.x, m.y, m.mode ~= "ok", durMs)
        end)
    end
    pcall(function()
        multitode.net.broadcast("itd", "marks_clear", { scope = "mine", from = selfId })
    end)
    pcall(function()
        multitode.slog("MARK", "cleared own marks, kept " .. tostring(#marks.active))
    end)
end

-- Clear everything for everyone. Host only - clients get Clear mine instead.
-- The window hides this button from clients; this guard catches stray calls.
function marks.clear_all()
    local role = nil
    pcall(function() role = multitode.state().role end)
    if tostring(role) == "CLIENT" then
        pcall(function() multitode.slog("MARK", "clear_all refused: host-only") end)
        return false
    end
    marks.active = {}
    pcall(function() multitode.getApi():clearTileMarks() end)
    pcall(function()
        multitode.net.broadcast("itd", "marks_clear", { scope = "all", from = 0 })
    end)
    pcall(function() multitode.slog("MARK", "cleared ALL marks") end)
    return true
end

-- Per-map lifecycle: drop everything when the level/map key changes.
function marks.on_level_change(newMapKey)
    local key = tostring(newMapKey or "")
    if marks.mapKey == key then return end
    marks.mapKey = key
    marks.active = {}
    marks.sentAt = {}
    pcall(function() multitode.getApi():clearTileMarks() end)
    pcall(function()
        multitode.slog("MARK", "level/map change -> marks cleared (key=" .. key .. ")")
    end)
end

-- Broadcast our marks-enabled flag so the roster can show a "marks off" badge.
function marks.broadcast_enabled_flag()
    local selfId = 0
    pcall(function()
        local info = multitode.getSessionInfo()
        if info ~= nil then selfId = tonumber(info.localPlayerId) or 0 end
    end)
    pcall(function()
        multitode.net.broadcast("lobby", "marks_flag", {
            playerId = selfId,
            enabled = marks.enabled == true
        })
    end)
end

-- ---------------------------------------------------------------- sending
function marks.mark_hovered(mode)
    if marks.enabled ~= true then
        return false
    end
    pcall(function()
        local roleNow = "?"
        pcall(function() roleNow = tostring(multitode.state().role) end)
        multitode.slog("MARK", string.format("mark requested mode=%s role=%s (key or armed click)",
            tostring(mode), roleNow))
    end)

    local tile = hovered_tile()
    local x, y = nil, nil
    if tile ~= nil then
        x, y = tile_coords(tile)
    end

    if x == nil or y == nil then
        -- Clients report no hovered tile, so ask the engine for the cursor tile
        -- (Java-side camera unprojection). This is what lets a client send marks.
        pcall(function()
            local api = multitode.getApi()
            local cx = tonumber(api:getCursorTileX())
            local cy = tonumber(api:getCursorTileY())
            multitode.slog("MARK", string.format("cursor tile from engine: x=%s y=%s", tostring(cx), tostring(cy)))
            if cx ~= nil and cy ~= nil and cx > -1000 and cy > -1000 then
                x, y = cx, cy
            end
        end)
    end

    if x == nil or y == nil then
        pcall(function()
            multitode.slog("MARK", "no tile under the cursor (lookup returned nil)")
        end)
        return false
    end

    -- Spam guard: timestamp per tile+mode, kept even when the LOCAL apply fails.
    -- (The earlier guard lived in a script that failed to parse, so it was never
    -- active - hence the mark spam coming back.)
    local nowMs = 0
    pcall(function() nowMs = multitode.now_ms() end)
    local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(mode)
    if marks.sentAt == nil then
        marks.sentAt = {}
    end
    if marks.sentAt[key] ~= nil and nowMs > 0 and (nowMs - marks.sentAt[key]) < marks.durationSec * 1000 then
        return true
    end
    marks.sentAt[key] = nowMs

    pcall(function()
        local roleNow = "?"
        pcall(function() roleNow = tostring(multitode.state().role) end)
        multitode.slog("MARK", string.format("local x=%s y=%s mode=%s role=%s viaHover=%s",
            tostring(x), tostring(y), tostring(mode), roleNow, tostring(tile ~= nil)))
    end)

    apply_local_mark(x, y, mode, true)

    local selfId = 0
    pcall(function()
        local info = multitode.getSessionInfo()
        if info ~= nil then
            selfId = tonumber(info.localPlayerId) or 0
        end
    end)
    local payload = { x = tonumber(x), y = tonumber(y), mode = tostring(mode), from = selfId,
        perm = (marks.permanent == true),
        mapCh = (multitode.lobby and (multitode.lobby.mapChannel or multitode.lobby.selectedLevel)) or "*" }
    pcall(function()
        local role = nil
        pcall(function() role = multitode.state().role end)
        -- Send BOTH ways on purpose.
        --  - A client sends to the host so the host can relay it to the other players.
        --  - A broadcast from a client still reaches the host (the host is a client's only
        --    peer), and from the host it reaches every client.
        -- Earlier versions picked one path by role and by a return value that did not mean
        -- what it looked like: on the host, "send to host" came back as success and the
        -- broadcast was skipped, so the host stopped sending its own marks at all. Marking
        -- twice is harmless now because TileMarks dedupes a repeat within 600ms, so the
        -- cost of this redundancy is nil and a mark can no longer be lost to routing.
        marks.sentCount = (marks.sentCount or 0) + 1
        local sentToHost = false
        if tostring(role) == "CLIENT" then
            pcall(function()
                sentToHost = multitode.getApi():sendLuaMessageToHost(
                    "itd", "tile_mark", multitode.net.encodePayload(payload)) ~= false
            end)
        end
        local broadcastOk = false
        pcall(function()
            broadcastOk = multitode.net.broadcast("itd", "tile_mark", payload) ~= false
        end)
        marks.lastSend = string.format("toHost=%s broadcast=%s", tostring(sentToHost), tostring(broadcastOk))
        pcall(function()
            multitode.slog("MARK", string.format("sent x=%s y=%s mode=%s role=%s toHost=%s broadcast=%s from=%s",
                tostring(x), tostring(y), tostring(mode), tostring(role),
                tostring(sentToHost), tostring(broadcastOk), tostring(selfId)))
        end)
    end)
    return true
end

-- Paint one mark at exact tile coords (the drag painter batches through
-- here). Same spam guard, same local apply, same send-both-ways as
-- mark_hovered. True when painted (or painted very recently).
function marks.place_tile(x, y, mode)
    if marks.enabled ~= true then
        return false
    end
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then
        return false
    end
    mode = tostring(mode or "ok")
    local nowMs = 0
    pcall(function() nowMs = multitode.now_ms() end)
    local key = tostring(x) .. ":" .. tostring(y) .. ":" .. mode
    if marks.sentAt == nil then
        marks.sentAt = {}
    end
    if marks.sentAt[key] ~= nil and nowMs > 0
        and (nowMs - marks.sentAt[key]) < (marks.durationSec or 10) * 1000 then
        return true
    end
    marks.sentAt[key] = nowMs
    apply_local_mark(x, y, mode, true)
    local selfId = 0
    pcall(function()
        local info = multitode.getSessionInfo()
        if info ~= nil then selfId = tonumber(info.localPlayerId) or 0 end
    end)
    local payload = { x = x, y = y, mode = mode, from = selfId,
        perm = (marks.permanent == true),
        mapCh = (multitode.lobby and (multitode.lobby.mapChannel or multitode.lobby.selectedLevel)) or "*" }
    pcall(function()
        local role = nil
        pcall(function() role = multitode.state().role end)
        if tostring(role) == "CLIENT" then
            pcall(function()
                multitode.getApi():sendLuaMessageToHost(
                    "itd", "tile_mark", multitode.net.encodePayload(payload))
            end)
        end
        pcall(function()
            multitode.net.broadcast("itd", "tile_mark", payload)
        end)
    end)
    return true
end

-- Drag-paint flourish: pop warning particles around the selection's border
-- instead of one burst per tile. Looks only - marks still go out per tile so
-- the other side stays in sync through the normal relay.
function marks.ring_effect(set)
    if set == nil or #set == 0 then
        return
    end
    local minX, maxX, minY, maxY = nil, nil, nil, nil
    for _, t in ipairs(set) do
        if t.x == nil or t.y == nil then
            -- skip malformed entries
        else
            if minX == nil or t.x < minX then minX = t.x end
            if maxX == nil or t.x > maxX then maxX = t.x end
            if minY == nil or t.y < minY then minY = t.y end
            if maxY == nil or t.y > maxY then maxY = t.y end
        end
    end
    if minX == nil then
        return
    end
    local per = {}
    for x = minX, maxX do
        per[#per + 1] = { x = x, y = minY }
        if maxY ~= minY then
            per[#per + 1] = { x = x, y = maxY }
        end
    end
    for y = minY + 1, maxY - 1 do
        per[#per + 1] = { x = minX, y = y }
        if maxX ~= minX then
            per[#per + 1] = { x = maxX, y = y }
        end
    end
    local stride = math.max(1, math.floor(#per / 48))
    local systems = current_systems()
    if systems == nil or systems.map == nil then
        return
    end
    for i = 1, #per, stride do
        local p = per[i]
        pcall(function()
            systems.map:showTileWarningParticle(p.x, p.y)
        end)
    end
end

-- ---------------------------------------------------------------- handlers
local function ensure_handlers()
    if marks.handlersRegistered then
        return
    end

    -- (There is deliberately no separate onHost registration here. multitode.net keeps
    -- ONE handler per channel+name, so it would be silently replaced by the onClient
    -- registration below - which is exactly why client marks never reached the host:
    -- the host's handler had been overwritten by one that returns unless it is a client.
    -- The single registration below handles both roles.)

    -- Single handler for both roles: the host applies and relays, a client applies.
    multitode.net.on("itd", "tile_mark", function(ctx, payload)
        if payload == nil then return end

        -- Cross-map filter: ignore marks tagged for a different map channel.
        local ourCh = multitode.lobby and (multitode.lobby.mapChannel or multitode.lobby.selectedLevel)
        local msgCh = payload.mapCh
        if ourCh ~= nil and msgCh ~= nil and tostring(msgCh) ~= "*" and tostring(ourCh) ~= "*"
                and tostring(msgCh) ~= tostring(ourCh) then
            return
        end

        if ctx ~= nil and ctx.receiverContext == "HOST" then
            -- we are the host: apply it, then relay to everyone else, keeping "from" so
            -- the original sender can recognise its own echo
            local hx = tonumber(payload.x)
            local hy = tonumber(payload.y)
            local hmode = tostring(payload.mode or "ok")
            multitode.slog("MARK", string.format("host relay from=%s x=%s y=%s mode=%s",
                tostring(payload.from), tostring(hx), tostring(hy), tostring(hmode)))
            local wasPerm = marks.permanent
            marks.permanent = (payload.perm == true)
            apply_local_mark(hx, hy, hmode, false)
            marks.permanent = wasPerm
            pcall(function()
                multitode.net.broadcast("itd", "tile_mark",
                    { x = hx, y = hy, mode = hmode, from = tonumber(payload.from) or 0,
                      perm = (payload.perm == true),
                      mapCh = tostring(payload.mapCh or "*") })
            end)
            return
        end
        -- ignore our own mark echoed back by the host (it was already applied)
        local selfId = 0
        pcall(function()
            local info = multitode.getSessionInfo()
            if info ~= nil then
                selfId = tonumber(info.localPlayerId) or 0
            end
        end)
        if selfId ~= 0 and tonumber(payload.from) ~= nil and tonumber(payload.from) == selfId then
            -- says the host echoed our own mark back. If a client starts logging this for marks it
            -- never sent, the two sides are using colliding player ids and this check is eating
            -- other players' marks.
            pcall(function()
                multitode.slog("MARK", string.format("skipped as own echo from=%s x=%s y=%s",
                    tostring(payload.from), tostring(payload.x), tostring(payload.y)))
            end)
            return
        end
        if marks.showReceived == false then
            return
        end
        marks.recvCount = (marks.recvCount or 0) + 1
        marks.lastRecv = string.format("from=%s x=%s y=%s mode=%s", tostring(payload.from), tostring(payload.x), tostring(payload.y), tostring(payload.mode))
        multitode.slog("MARK", string.format("received from=%s x=%s y=%s mode=%s",
            tostring(payload.from), tostring(payload.x), tostring(payload.y), tostring(payload.mode)))
        -- Apply with the sender's permanent flag so lifetime matches the origin.
        local wasPerm = marks.permanent
        marks.permanent = (payload.perm == true)
        apply_local_mark(tonumber(payload.x), tonumber(payload.y), tostring(payload.mode or "ok"), false)
        marks.permanent = wasPerm
    end)

    -- Erase relay: host applies + rebroadcasts; clients apply.
    multitode.net.on("itd", "tile_erase", function(ctx, payload)
        if payload == nil then return end
        local ex, ey = tonumber(payload.x), tonumber(payload.y)
        if ex == nil or ey == nil then return end
        if ctx ~= nil and ctx.receiverContext == "HOST" then
            -- Remove locally without re-broadcasting an infinite loop: only relay once.
            for i = #marks.active, 1, -1 do
                local m = marks.active[i]
                if m.x == ex and m.y == ey then table.remove(marks.active, i) end
            end
            pcall(function() multitode.getApi():removeTileMarkAt(ex, ey) end)
            pcall(function()
                multitode.net.broadcast("itd", "tile_erase",
                    { x = ex, y = ey, from = tonumber(payload.from) or 0 })
            end)
            return
        end
        local selfId = 0
        pcall(function()
            local info = multitode.getSessionInfo()
            if info ~= nil then selfId = tonumber(info.localPlayerId) or 0 end
        end)
        if selfId ~= 0 and tonumber(payload.from) == selfId then return end
        for i = #marks.active, 1, -1 do
            local m = marks.active[i]
            if m.x == ex and m.y == ey then table.remove(marks.active, i) end
        end
        pcall(function() multitode.getApi():removeTileMarkAt(ex, ey) end)
    end)

    -- Clear relay (mine/all): host applies + rebroadcasts; clients apply.
    multitode.net.on("itd", "marks_clear", function(ctx, payload)
        if payload == nil then return end
        local scope = tostring(payload.scope or "all")
        local fromId = tonumber(payload.from) or 0
        local function applyClear()
            if scope == "mine" then
                local keep = {}
                for _, m in ipairs(marks.active) do
                    if m.ownerId ~= fromId then keep[#keep + 1] = m end
                end
                marks.active = keep
                pcall(function() multitode.getApi():clearTileMarks() end)
                for _, m in ipairs(marks.active) do
                    pcall(function()
                        local durMs = m.permanent and 0 or (marks.durationSec or 10) * 1000
                        multitode.getApi():addTileMark(m.x, m.y, m.mode ~= "ok", durMs)
                    end)
                end
            else
                marks.active = {}
                pcall(function() multitode.getApi():clearTileMarks() end)
            end
        end
        if ctx ~= nil and ctx.receiverContext == "HOST" then
            applyClear()
            pcall(function()
                multitode.net.broadcast("itd", "marks_clear",
                    { scope = scope, from = fromId })
            end)
            return
        end
        applyClear()
    end)

    marks.handlersRegistered = true
    logger:i("Tile mark handlers registered")
end

ensure_handlers()

-- ---------------------------------------------------------------- key bind
-- Standard libGDX Input.Keys values: a deterministic fallback so the bind works
-- even if none of the enum paths is reachable from Lua (loadstring-based lookup
-- was the original mistake - it silently returned nothing).
local KEY_CODES = {
    A = 29, B = 30, C = 31, D = 32, E = 33, F = 34, G = 35, H = 36, I = 37,
    J = 38, K = 39, L = 40, M = 41, N = 42, O = 43, P = 44, Q = 45, R = 46,
    S = 47, T = 48, U = 49, V = 50, W = 51, X = 52, Y = 53, Z = 54,
    NUM_0 = 7, NUM_1 = 8, NUM_2 = 9, NUM_3 = 10, NUM_4 = 11,
    NUM_5 = 12, NUM_6 = 13, NUM_7 = 14, NUM_8 = 15, NUM_9 = 16,
    SPACE = 62, TAB = 61, ENTER = 66, ESCAPE = 111, BACKSPACE = 67,
    SHIFT_LEFT = 59, SHIFT_RIGHT = 60, CTRL_LEFT = 129, CTRL_RIGHT = 130,
    ALT_LEFT = 57, ALT_RIGHT = 58,
}

marks.keyRoute = marks.keyRoute or nil

local function key_code(name)
    local code = nil
    pcall(function() code = C.Input_Keys[name] end)
    if code == nil then pcall(function() code = C.Input.Keys[name] end) end
    if code == nil then pcall(function() code = C.Keys[name] end) end
    if code == nil then pcall(function() code = C.InputKeys[name] end) end

    local route = "enum"
    if code == nil then
        code = KEY_CODES[name]
        route = "table"
    end

    if code ~= nil and marks.keyRoute == nil then
        marks.keyRoute = route
        pcall(function()
            multitode.slog("MARK", "key " .. tostring(name) .. " -> code " .. tostring(code) .. " via " .. route)
        end)
    end
    return code
end

local function input_pressed()
    local pressed = false
    pcall(function()
        local input = C.Gdx.input
        if input == nil then
            return
        end
        local key = key_code(marks.keyName)
        if key == nil then
            if not marks.warnedKey then
                marks.warnedKey = true
                logsKeyMissing()
            end
            return
        end
        pressed = input:isKeyPressed(key)
    end)
    return pressed
end

function logsKeyMissing()
    pcall(function()
        logger:w("Could not resolve key '%s' - the tile-mark bind is inactive (attach menu still works)",
            tostring(marks.keyName))
    end)
end

local function shift_down()
    local down = false
    pcall(function()
        local input = C.Gdx.input
        if input == nil then
            return
        end
        local left = key_code("SHIFT_LEFT") or key_code("SHIFT")
        if left ~= nil then
            down = input:isKeyPressed(left)
        end
    end)
    return down
end

local function pointer_down()
    local down = false
    pcall(function()
        local input = C.Gdx.input
        if input ~= nil then
            down = input:isTouched() or input:isButtonPressed(0)
        end
    end)
    return down
end

local function ctrl_down()
    local down = false
    pcall(function()
        local input = C.Gdx.input
        if input == nil then return end
        local left = key_code("CTRL_LEFT") or key_code("CTRL")
        if left ~= nil then
            down = input:isKeyPressed(left)
        end
    end)
    return down
end

-- True while ANY marks window is open in either Lua env. Painting and the
-- click guard key off this, so every close path stops marking everywhere,
-- even if one env's armed flag went stale.
local function marks_window_open()
    local open = false
    pcall(function()
        local layer = C.Game.i.uiManager:getWindowsLayer():getTable()
        if layer == nil then return end
        local kids = layer:getChildren()
        if kids == nil then return end
        for i = 0, (tonumber(kids.size) or 0) do
            local w = nil
            pcall(function() w = kids.items[i] end)
            if w ~= nil then
                -- getTitle() is a StringBuilder: compare its string form.
                local okT, title = pcall(function() return w:getTitle() end)
                if okT and tostring(title) == "Marks (Ctrl+M)" then
                    open = true
                    break
                end
            end
        end
    end)
    return open
end

marks.mapBlocker = marks.mapBlocker or nil
marks.mapBlockerStage = marks.mapBlockerStage or nil

local function tick_keys()
    local systems = current_systems()
    if systems == nil or systems.map == nil then
        marks.keyHeld = false
        return
    end
    -- Mark-mode selection guard (one per session): with a marks window open,
    -- cancel tile/gate selections so painting never pops tower menus. The
    -- select event reverts cleanly on cancel and hover keeps working for the
    -- painter. One listener covers clicks, hotkeys, everything.
    if marks.selectGuardSys ~= systems then
        marks.selectGuardSys = systems
        if C.MapElementSelect == nil then
            if not marks.warnedSelectGuard then
                marks.warnedSelectGuard = true
                logger:w("MapElementSelect not exposed - mark-mode selection guard inactive")
            end
        else
            pcall(function()
                systems.events:getListeners(C.MapElementSelect):add(C.Listener(function(ev)
                    if marks_window_open() then
                        pcall(function() ev:cancel() end)
                    end
                    return false
                end))
            end)
        end
    end

    if not marks.availLogged then
        marks.availLogged = true
        pcall(function()
            local hasSelection = systems._gameMapSelection ~= nil
            local hovered = hovered_tile()
            multitode.slog("MARK", string.format("systems: selection=%s hoveredTile=%s",
                tostring(hasSelection), tostring(hovered ~= nil)))
        end)
    end

    -- Ctrl+E toggles erase mode (next click / drag removes marks).
    local eKey = key_code("E")
    if eKey ~= nil then
        local eDown = false
        pcall(function()
            local input = C.Gdx.input
            if input ~= nil then eDown = input:isKeyPressed(eKey) end
        end)
        if eDown and ctrl_down() and not marks.ctrlEHeld then
            marks.eraseMode = not marks.eraseMode
            marks.armed = marks.eraseMode and "erase" or nil
            pcall(function()
                multitode.slog("MARK", "erase mode " .. (marks.eraseMode and "ON" or "OFF"))
            end)
        end
        marks.ctrlEHeld = eDown and ctrl_down()
    end

    -- Ctrl+M opens the marks menu (built in 90_). Edge-triggered like Ctrl+E,
    -- and dead while typing in chat. Only the S-less env polls, or two envs
    -- would open twin windows that look unclosable.
    local mKey = key_code("M")
    if mKey ~= nil and S == nil then
        local mDown = false
        pcall(function()
            local input = C.Gdx.input
            if input ~= nil then mDown = input:isKeyPressed(mKey) end
        end)
        local combo = mDown and ctrl_down()
        if combo and not marks.ctrlMHeld then
            local textOpen = false
            pcall(function()
                if multitode.ui_text_input_open ~= nil then
                    textOpen = multitode.ui_text_input_open() == true
                end
            end)
            if not textOpen then
                pcall(function()
                    if multitode.toggle_marks_window ~= nil then
                        multitode.toggle_marks_window()
                    end
                end)
            end
        end
        marks.ctrlMHeld = combo
    end

    -- bound key: press = mark here, Shift+press = NOT here.
    -- While held (drag-marking), mark each NEW tile the cursor enters.
    local pressed = input_pressed()
    if pressed then
        local mode = shift_down() and "no" or "ok"
        local tile = hovered_tile()
        local x, y = nil, nil
        if tile ~= nil then x, y = tile_coords(tile) end
        if x == nil or y == nil then
            pcall(function()
                local api = multitode.getApi()
                local cx, cy = tonumber(api:getCursorTileX()), tonumber(api:getCursorTileY())
                if cx ~= nil and cy ~= nil and cx > -1000 and cy > -1000 then x, y = cx, cy end
            end)
        end
        local isNewTile = (x ~= nil) and (marks.dragLastX ~= x or marks.dragLastY ~= y)
        if (not marks.keyHeld) or isNewTile then
            if marks.eraseMode then
                if x ~= nil then marks.erase_at(x, y) end
            else
                marks.mark_hovered(mode)
            end
            marks.dragLastX, marks.dragLastY = x, y
        end
    else
        marks.dragLastX, marks.dragLastY = nil, nil
    end
    marks.keyHeld = pressed

    -- armed (from the Attach menu): next click marks/erases the hovered tile
    if marks.armed ~= nil then
        local click = pointer_down()
        if click and not marks.clickHeld then
            local mode = marks.armed
            marks.armed = nil
            marks.eraseMode = false
            pcall(function()
                multitode.slog("MARK", "armed click detected, mode " .. tostring(mode))
            end)
            if mode == "erase" then
                local tile = hovered_tile()
                local x, y = nil, nil
                if tile ~= nil then x, y = tile_coords(tile) end
                if x == nil or y == nil then
                    pcall(function()
                        local api = multitode.getApi()
                        local cx, cy = tonumber(api:getCursorTileX()), tonumber(api:getCursorTileY())
                        if cx ~= nil and cy ~= nil and cx > -1000 and cy > -1000 then x, y = cx, cy end
                    end)
                end
                if x ~= nil then marks.erase_at(x, y) end
            else
                marks.mark_hovered(mode)
            end
        end
        marks.clickHeld = click
    end

    -- Window mark mode: left press paints the window type, right press paints
    -- the opposite for the whole stroke. Drags collect tiles and paint on
    -- release with the border flourish. Hovered tile only (no cursor
    -- fallback), so pressing window buttons never paints. Needs a live marks
    -- window on top of the armed flag - that way every close path stops all
    -- envs, stale flags included. S-less env only, like the Ctrl+M poll.
    if S == nil and marks.windowMarkMode ~= nil and marks_window_open() then
        local lDown = pointer_down()
        local rDown = false
        pcall(function()
            local input = C.Gdx.input
            if input ~= nil then rDown = input:isButtonPressed(1) end
        end)
        local click = lDown or rDown
        if click and not marks.windowClickHeld then
            -- Stroke start: right button inverts the window type.
            local base = marks.windowMarkMode
            if rDown then
                base = (base == "ok") and "no" or "ok"
            end
            marks.windowStrokeMode = base
        end
        if click then
            local wtile = hovered_tile()
            if wtile ~= nil then
                local wx, wy = tile_coords(wtile)
                if wx ~= nil then
                    marks.windowDrag = marks.windowDrag or {}
                    marks.windowDragSeen = marks.windowDragSeen or {}
                    local wkey = wx .. ":" .. wy
                    if not marks.windowDragSeen[wkey] then
                        marks.windowDragSeen[wkey] = true
                        marks.windowDrag[#marks.windowDrag + 1] = { x = wx, y = wy }
                    end
                end
            end
        end
        if not click and marks.windowClickHeld then
            local set = marks.windowDrag or {}
            local smode = marks.windowStrokeMode or marks.windowMarkMode
            if #set == 1 then
                marks.place_tile(set[1].x, set[1].y, smode)
            elseif #set > 1 then
                for _, t in ipairs(set) do
                    marks.place_tile(t.x, t.y, smode)
                end
                marks.ring_effect(set)
            end
            marks.windowDrag = {}
            marks.windowDragSeen = {}
            marks.windowStrokeMode = nil
        end
        marks.windowClickHeld = click
    elseif marks.windowMarkMode == nil then
        marks.windowDrag = {}
        marks.windowDragSeen = {}
        marks.windowClickHeld = false
        marks.windowStrokeMode = nil
    end
end

-- ---------------------------------------------------------------- public API
function marks.arm(mode)
    if mode == "erase" then
        marks.armed = "erase"
        marks.eraseMode = true
    else
        marks.armed = (mode == "no") and "no" or "ok"
        marks.eraseMode = false
    end
    pcall(function()
        logger:i("Armed tile mark (%s): the next click acts on the tile under the cursor", tostring(marks.armed))
    end)
    return marks.armed
end

function marks.set_permanent(on)
    marks.permanent = (on == true)
    pcall(function()
        multitode.slog("MARK", "permanent marks " .. (marks.permanent and "ON" or "OFF"))
    end)
    return marks.permanent
end

-- Window paint mode, set by the marks menu: "ok"/"no" while open, nil shut.
-- Anything pressed or dragged on the map paints with this.
function marks.set_window_mark_mode(mode)
    if mode ~= "ok" and mode ~= "no" then
        mode = nil
    end
    marks.windowMarkMode = mode
    marks.windowDrag = {}
    marks.windowDragSeen = {}
    marks.windowClickHeld = false
    pcall(function()
        multitode.slog("MARK", "window mark mode " .. tostring(mode))
    end)
    return marks.windowMarkMode
end

-- Drop any current tile/gate selection. The menu calls this on open so an
-- old tower window isn't covering the map when you start painting.
function marks.clear_selection()
    pcall(function()
        local systems = current_systems()
        if systems ~= nil and systems._gameMapSelection ~= nil then
            systems._gameMapSelection:disableSelection()
        end
    end)
end

function marks.setKey(name)
    local text = tostring(name or "")
    if text == "" then
        return marks.keyName
    end
    marks.keyName = string.upper(string.sub(text, 1, 1))
    marks.warnedKey = false
    logger:i("Tile mark bind set to %s", marks.keyName)
    return marks.keyName
end

-- ---------------------------------------------------------------- driver
pcall(function()
    C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
        pcall(function()
            local nowMs = 0
            pcall(function() nowMs = multitode.now_ms() end)

            if marks.enabled ~= true then
                return
            end

            -- let the bridge honour each mark's lifetime (and respawn red flashes)
            pcall(function()
                multitode.getApi():tickTileMarks()
            end)

            -- Client pause guard: a purely LOCAL pause freezes only this client and
            -- creates a huge tick gap — so clear it every frame. NEVER clear a pause
            -- that is authoritative (host mirror, bonus vote freeze, challenge).
            -- Racing apply_pause_mirror with an unconditional resumeGame() was the
            -- primary pause-desync: the mirror paused, this resumed, forever.
            pcall(function()
                local role = nil
                pcall(function() role = multitode.state().role end)
                if role ~= "CLIENT" then return end
                local itd = multitode.itd
                if itd ~= nil and (itd.hostPaused == true
                    or itd.bonusPauseActive == true
                    or (itd.challenge ~= nil and itd.challenge.active == true)) then
                    return
                end
                local systems = current_systems()
                if systems ~= nil and systems.gameState ~= nil then
                    if systems.gameState:isPaused() then
                        systems.gameState:resumeGame()
                    end
                end
            end)

            -- Per-map lifecycle: detect level change and drop all marks.
            pcall(function()
                local systems = current_systems()
                if systems ~= nil and systems.gameState ~= nil
                        and systems.gameState.basicLevelName ~= nil then
                    local name = tostring(systems.gameState.basicLevelName)
                    if marks.mapKey ~= name then
                        marks.on_level_change(name)
                    end
                end
            end)

            -- expire finished marks (permanent marks never expire)
            if #marks.active > 0 and nowMs > 0 then
                local keep, expiredBlue = {}, false
                for i = 1, #marks.active do
                    local mark = marks.active[i]
                    if mark.permanent or mark.expiresAt > nowMs then
                        if mark.mode ~= "ok" and nowMs >= (mark.nextRedAt or 0) then
                            -- particles are owned and respawned by the bridge
                            mark.nextRedAt = nowMs + RED_REFRESH_MS
                        end
                        keep[#keep + 1] = mark
                    elseif mark.mode == "ok" then
                        expiredBlue = true
                    end
                end
                marks.active = keep
                if expiredBlue then
                    -- removeHighlights() clears ALL tile highlights, so surviving
                    -- blue marks are redrawn right after. Before this, one expiry
                    -- wiped every player's marks at once.
                    -- nothing to do: the bridge expires each mark on its own timer
                    -- (no redraw: see the shared-deadline note above)
                end
            end

            tick_keys()
        end)
    end))
end)

logger:i("Multitode tile marks loaded (bind=%s, duration=%ss)", tostring(marks.keyName), tostring(marks.durationSec))

-- expose the module so the MOD window can show mark counters
multitode.marks = marks
