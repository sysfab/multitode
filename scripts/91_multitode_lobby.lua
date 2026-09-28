local logger = C.TLog:forTag("multitode/lobby.lua")

_G.multitode = _G.multitode or {}
multitode.lobby = multitode.lobby or {}

local lobby = multitode.lobby

-- Lobby state
lobby.state = lobby.state or "IDLE" -- IDLE, WAITING, LOADING, IN_GAME
lobby.lobbyName = lobby.lobbyName or ""
lobby.password = lobby.password or "" -- empty = no password
lobby.maxPlayers = lobby.maxPlayers or 8
lobby.players = lobby.players or {} -- { [playerId] = { name, ready, connected } }
lobby.chatLog = lobby.chatLog or {}
lobby.selectedLevel = lobby.selectedLevel or nil
lobby.hostReady = lobby.hostReady or false
lobby.handlersRegistered = lobby.handlersRegistered or false
lobby.lastError = lobby.lastError or nil
lobby.joinPending = lobby.joinPending or false
lobby.lastSessionActiveAt = lobby.lastSessionActiveAt or 0
lobby.lastReconcileAt = lobby.lastReconcileAt or 0
lobby.watchdogRegistered = lobby.watchdogRegistered or false
lobby.poll = nil
lobby.pollHistory = lobby.pollHistory or {}
lobby.nextPollId = lobby.nextPollId or 1
lobby.lastPollUpdateAt = lobby.lastPollUpdateAt or 0

local CHANNEL = "lobby"

-- Chat notification state (read by the floating-button badge and the quick
-- message popups in 90_multitode_ui_menu.lua). Kept here, not in the UI, so a
-- window rebuild can never lose the unread counter.
lobby.unread = lobby.unread or 0
lobby.pinged = lobby.pinged or false
lobby.chatOpen = false
lobby.menuOpen = false
local CLIENT_LOBBY_TIMEOUT_SEC = 10
local HOST_RECONCILE_INTERVAL_SEC = 2

local function now_sec()
    if os.time then
        return os.time()
    end
    return 0
end

-- Wall-clock ms for poll deadlines. Integer os.time() ticks on each machine's
-- own second boundary (client clock phase → client showed 14 while host 15).
local function now_ms()
    if multitode and multitode.now_ms then
        return multitode.now_ms()
    end
    return now_sec() * 1000
end

local function mark_ui_dirty()
    _G.multitode._lobbyUiDirty = true
end

-- Ready/marksOff flips must NOT rebuild the window (Ready used to reflash
-- host+client and jump the scroll). They set a refresh flag; 90_ tweaks the
-- roster labels + ready button directly. Join/leave still rebuild.
local function flag_ready_refresh()
    _G.multitode._readyUiRefresh = true
end

local function is_host_role()
    local role = multitode.state().role
    return role == "HOST" or role == "HOST_AND_CLIENT"
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

local function is_session_active()
    local ok, info = pcall(multitode.getSessionInfo)
    if not ok or info == nil then
        return false
    end
    return info.sessionActive == true
end

local function get_link_peer_ids()
    local ok, ids = pcall(function()
        return multitode.getApi():getConnectedPeerIds()
    end)
    if not ok or ids == nil then
        return nil
    end
    return ids
end

-- ============================================================
-- Lobby State Management
-- ============================================================

local function reset_lobby()
    lobby.state = "IDLE"
    lobby.lobbyName = ""
    lobby.password = ""
    lobby.maxPlayers = 8
    lobby.players = {}
    lobby.chatLog = {}
    lobby.selectedLevel = nil
    lobby.hostReady = false
    lobby.joinPending = false
    lobby.lastSessionActiveAt = 0
    lobby.poll = nil
    lobby.pollHistory = {}
    mark_ui_dirty()
end

local function get_local_player_info()
    local config = multitode.getConfig()
    return {
        id = get_self_id(),
        name = config.name or "Player",
        ready = false,
        connected = true
    }
end

local function broadcast_lobby_state()
    if not is_host_role() then
        return
    end

    -- Build player list for broadcast (normalize ids: JSON round-trips must stay numeric)
    local playerList = {}
    for id, info in pairs(lobby.players) do
        playerList[#playerList + 1] = {
            id = tonumber(id) or 0,
            name = info.name,
            ready = info.ready,
            connected = info.connected,
            marksOff = (info.marksOff == true)
        }
    end

    multitode.net.broadcast(CHANNEL, "state", {
        lobbyName = lobby.lobbyName,
        maxPlayers = lobby.maxPlayers,
        state = lobby.state,
        players = playerList,
        selectedLevel = lobby.selectedLevel,
        passwordProtected = lobby.password ~= "",
        -- Per-map channel tag: which map this lobby instance is bound to.
        mapCh = lobby.mapChannel or lobby.selectedLevel or "*",
        -- Host rule; clients must see it or "New Poll" never appears for them.
        allowPollsForEveryone = (multitode.settings ~= nil
            and multitode.settings.allowPollsForEveryone == true),
        -- Host boost mode. Release: always "host" (vote is a dormant v2 stub).
        bonusMode = "host"
    })
end

-- Exposed so the UI can push a setting change (e.g. Polls for all) immediately.
lobby.broadcastState = broadcast_lobby_state

local function add_chat_message(senderName, message, refs, senderId)
    lobby.chatLog[#lobby.chatLog + 1] = {
        sender = senderName,
        message = message,
        refs = refs,
        timestamp = os.time and os.time() or 0
    }
    -- Keep last 100 messages
    if #lobby.chatLog > 100 then
        table.remove(lobby.chatLog, 1)
    end

    -- Live-append to the detached chat window for EVERY line, including our own
    -- (send_chat used to skip this path for isOwn, so you never saw what you sent).
    pcall(function()
        if multitode.onChatLogged ~= nil then
            multitode.onChatLogged(tostring(senderName or "?"), tostring(message or ""), refs)
        end
    end)

    -- Unread badge + "@name" ping detection. Everything here is best-effort:
    -- a failure must never affect the chat itself. Own lines skip toasts/unread.
    pcall(function()
        local name = tostring((multitode.getConfig() or {}).name or "")
        local senderText = tostring(senderName or "")
        if senderText == "System" then
            return
        end
        local selfId = get_self_id()
        local isOwn = (senderId ~= nil and selfId ~= 0 and tonumber(senderId) == selfId)
            or (name ~= "" and senderText == name)
        if isOwn then
            return
        end

        local lowerMessage = string.lower(tostring(message or ""))
        local isPing = false
        if name ~= "" then
            isPing = string.find(lowerMessage, "@" .. string.lower(name), 1, true) ~= nil
        end
        -- "@all" pings every player.
        if not isPing then
            isPing = string.find(lowerMessage, "@all", 1, true) ~= nil
        end
        if not lobby.chatOpen then
            lobby.unread = (tonumber(lobby.unread) or 0) + 1
        end
        if isPing then
            lobby.pinged = true
        end
        if multitode.onIncomingChat ~= nil then
            multitode.onIncomingChat(senderText ~= "" and senderText or "?", tostring(message or ""), isPing)
        end
        multitode.slog("CHAT", string.format("incoming from=%s ping=%s unread=%s",
            senderText, tostring(isPing), tostring(lobby.unread)))
    end)
end

-- ============================================================
-- Host Actions
-- ============================================================

function lobby.create(name, password, maxPlayers)
    if not is_host_role() then
        error("Only host can create a lobby")
    end

    -- Duplicate-CLICK guard only: the Create button can fire twice within a few
    -- ms, and the second call would run reset_lobby() right after a client
    -- joined (the phantom "1/8" roster). Debounce on real wall-clock time so a
    -- deliberate click always goes through, even while a lobby is still open.
    local nowMs = 0
    pcall(function() nowMs = multitode.now_ms() end)
    if nowMs > 0 and lobby.lastCreateAtMs ~= nil and (nowMs - lobby.lastCreateAtMs) < 1000 then
        logger:i("Ignored duplicate create_lobby (%sms since last)", tostring(nowMs - lobby.lastCreateAtMs))
        return
    end
    if nowMs > 0 then
        lobby.lastCreateAtMs = nowMs
    end

    reset_lobby()
    lobby.state = "WAITING"
    lobby.lobbyName = name or "Game"
    lobby.password = password or ""
    lobby.maxPlayers = maxPlayers or 8
    lobby.hostReady = false
    lobby.lastError = nil

    -- Add self to player list
    local localInfo = get_local_player_info()
    localInfo.ready = true
    lobby.players[localInfo.id] = localInfo

    add_chat_message("System", "Lobby created: " .. lobby.lobbyName)
    broadcast_lobby_state()
    mark_ui_dirty()
    logger:i("Lobby created: %s (password=%s)", lobby.lobbyName, lobby.password ~= "" and "yes" or "no")
end

function lobby.join(password)
    if is_host_role() then
        error("Host cannot join a lobby, create one instead")
    end

    -- Debounce a duplicated join click (real wall-clock time).
    local nowMs = 0
    pcall(function() nowMs = multitode.now_ms() end)
    if nowMs > 0 and lobby.lastJoinAtMs ~= nil and (nowMs - lobby.lastJoinAtMs) < 1500 then
        logger:i("Ignored duplicate join request (%sms since last)", tostring(nowMs - lobby.lastJoinAtMs))
        return
    end
    if nowMs > 0 then
        lobby.lastJoinAtMs = nowMs
    end

    -- Make sure the transport is up before sending the join request.
    local state = multitode.state()
    if state.lifecycleState ~= "RUNNING" then
        multitode.start()
    end
    if not is_session_active() then
        lobby.lastError = "Not connected to host yet, try again in a moment"
        mark_ui_dirty()
        error(lobby.lastError)
    end

    lobby.lastError = nil
    lobby.joinPending = true
    lobby.joinPendingAt = os.clock and os.clock() or 0
    local config = multitode.getConfig()
    multitode.net.sendToHost(CHANNEL, "join", {
        playerName = config.name or "Player",
        password = password or ""
    })
    logger:i("Join request sent to host as %s", tostring(config.name or "Player"))
end

-- Host-side level guard. Multiplayer must not become a way to skip to the last level: if
-- this host has not unlocked a level, it cannot be selected here either. The progress API
-- differs between builds, so the check is best-effort - if nothing queryable is found we
-- allow the level rather than blocking play, and say so in the log once.
function lobby.level_is_unlocked(levelName)
    -- Lab escape hatch. Only reachable in development mode (Shift+F9 -> Lab window ->
    -- "Any map"), and never enabled for a normal player, so progression stays intact by
    -- default. When on, the host may pick any level regardless of progress.
    local anyMap = false
    pcall(function()
        anyMap = tostring(multitode.getApi():getSetting("lab.anyMap", "0")) == "1"
    end)
    if anyMap then
        return true
    end

    local result = nil
    pcall(function()
        local pm = C.Game.i.progressManager
        if pm == nil then
            return
        end
        for _, candidate in ipairs({ "isLevelUnlocked", "isUnlocked", "getLevelProgress" }) do
            local fn = pm[candidate]
            if type(fn) == "function" then
                local ok, value = pcall(fn, pm, levelName)
                if ok then
                    if type(value) == "boolean" then
                        result = value
                        return
                    end
                    if type(value) == "number" then
                        result = value > 0
                        return
                    end
                    if value ~= nil then
                        result = true
                        return
                    end
                end
            end
        end
    end)
    if result == nil and not lobby.levelGuardWarned then
        lobby.levelGuardWarned = true
        pcall(function()
            logger:w("Level unlock check found no usable progress API - allowing levels as-is")
        end)
    end
    return result
end

function lobby.set_level(levelName)
    pcall(function()
        local unlocked = lobby.level_is_unlocked(levelName)
        if unlocked == false then
            logger:w("Refusing level %s: this host has not unlocked it", tostring(levelName))
            if multitode.show_toast ~= nil then
                multitode.show_toast("That level is not unlocked on this host")
            end
            return
        end
    end)
    local role = multitode.state().role
    if role ~= "HOST" and role ~= "HOST_AND_CLIENT" then
        error("Only host can set the level")
    end

    if lobby.state == "IDLE" then
        error("Create a lobby first")
    end

    lobby.selectedLevel = levelName
    broadcast_lobby_state()
    mark_ui_dirty()
    logger:i("Level set to: %s", tostring(levelName))
end

function lobby.set_ready(ready)
    local localInfo = get_local_player_info()
    if is_host_role() then
        lobby.hostReady = ready
        if lobby.players[localInfo.id] then
            lobby.players[localInfo.id].ready = ready
        end
        broadcast_lobby_state()
        flag_ready_refresh()
    else
        -- Pure clients have no host server: route through the host, which
        -- updates the roster and rebroadcasts to everyone.
        if lobby.players[localInfo.id] then
            lobby.players[localInfo.id].ready = ready
        end
        multitode.net.sendToHost(CHANNEL, "player_ready", {
            playerId = localInfo.id,
            ready = ready
        })
    end
end

function lobby.start_game()
    if not is_host_role() then
        error("Only host can start the game")
    end

    if lobby.selectedLevel == nil then
        error("No level selected")
    end

    -- Check all connected players are ready
    for id, info in pairs(lobby.players) do
        if info.connected and not info.ready then
            error("Not all players are ready")
        end
    end

    lobby.state = "LOADING"
    broadcast_lobby_state()
    multitode.net.broadcast(CHANNEL, "start_level", {
        levelName = lobby.selectedLevel
    })

    -- The actual level loading is handled by 70_multitode_level_sync.lua
    -- which detects screen changes. We trigger it by starting the level.
    local basicLevel = C.Game.i.basicLevelManager:getLevel(lobby.selectedLevel)
    if basicLevel ~= nil then
        C.Game.i.screenManager:startNewBasicLevel(basicLevel, nil)
        lobby.state = "IN_GAME"
        logger:i("Game started: %s", lobby.selectedLevel)
    else
        lobby.state = "WAITING"
        error("Level not found: " .. tostring(lobby.selectedLevel))
    end
end

function lobby.kick_player(playerId)
    if not is_host_role() then
        error("Only host can kick players")
    end

    playerId = tonumber(playerId)
    multitode.net.broadcast(CHANNEL, "kicked", {
        playerId = playerId
    })
    lobby.players[playerId] = nil
    broadcast_lobby_state()
    mark_ui_dirty()
end

function lobby.leave()
    -- Never throw out of leave(): transports may already be down when this
    -- runs (window close, game exit). Best effort notify, always reset.
    if is_host_role() then
        -- Host leaving destroys the lobby
        pcall(multitode.net.broadcast, CHANNEL, "lobby_closed", {
            reason = "Host left"
        })
    else
        -- Client leaving
        local localInfo = get_local_player_info()
        pcall(multitode.net.sendToHost, CHANNEL, "leave", {
            playerId = localInfo.id
        })
    end
    reset_lobby()
end

-- ============================================================
-- Polls (host-created; optional all-players via settings)
-- ============================================================

local POLL_UPDATE_INTERVAL_SEC = 5

local function poll_tallies(poll)
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
    return counts
end

local function poll_winner(poll)
    local counts = poll_tallies(poll)
    local bestIdx, bestCount = 1, -1
    for i = 1, #counts do
        if counts[i] > bestCount then
            bestIdx, bestCount = i, counts[i]
        end
    end
    return bestIdx, counts
end

local function poll_remaining_sec(poll)
    if poll == nil then
        return 0
    end
    -- expiresAt is milliseconds on the host clock.
    local left = (tonumber(poll.expiresAt) or 0) - now_ms()
    if left < 0 then
        return 0
    end
    -- Seconds with fraction: client deadline = now_ms() + remainingSec*1000.
    return left / 1000
end

local function broadcast_poll_open(poll)
    multitode.net.broadcast(CHANNEL, "poll_open", {
        pollId = poll.id,
        question = poll.question,
        options = poll.options,
        -- Host-authoritative remaining time. Clients must NOT use absolute
        -- expiresAt across machines (clock skew made 20s show 0s / 45s stick).
        remainingSec = poll_remaining_sec(poll),
        durationSec = poll.durationSec
    })
end

local function broadcast_poll_update(poll)
    -- Votes use numeric player-id keys; stringify so JSON always sees strings
    -- even if a future encoder path still rejects bare numbers.
    local votes = {}
    for k, v in pairs(poll.votes or {}) do
        votes[tostring(k)] = v
    end
    multitode.net.broadcast(CHANNEL, "poll_update", {
        pollId = poll.id,
        votes = votes,
        -- Heartbeat resync: client rebuilds its local deadline from this.
        remainingSec = poll_remaining_sec(poll)
    })
    lobby.lastPollUpdateAt = now_ms()
end

local function poll_votes_fingerprint(poll)
    local parts = {}
    local keys = {}
    for k, _ in pairs(poll.votes or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(poll.votes[k])
    end
    return table.concat(parts, ",")
end

function lobby.createPoll(question, options, durationSec)
    question = tostring(question or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if question == "" then
        error("Poll question must not be blank")
    end
    if type(options) ~= "table" or #options < 2 or #options > 6 then
        error("Poll needs 2-6 options")
    end
    durationSec = math.floor(tonumber(durationSec) or 20)
    if durationSec < 1 then
        durationSec = 1
    elseif durationSec > 3600 then
        durationSec = 3600
    end

    if is_host_role() then
        local openedAt = now_ms()
        local poll = {
            id = lobby.nextPollId,
            question = question,
            options = options,
            votes = {},
            openedAt = openedAt,
            expiresAt = openedAt + durationSec * 1000,
            durationSec = durationSec
        }
        lobby.nextPollId = lobby.nextPollId + 1
        lobby.poll = poll
        broadcast_poll_open(poll)
        -- Host never receives poll_open (broadcast is clients-only) — same System line.
        add_chat_message("System", "Poll: " .. poll.question)
        -- Host: show the quick-strip arrow too (no full-window auto-open).
        pcall(function()
            if _G.multitode ~= nil then
                _G.multitode._quickPollDirty = true
            end
        end)
        -- Only refreshes an ALREADY-OPEN multiplayer window (New Poll → live).
        mark_ui_dirty()
        logger:i("Poll created: %s (%ss) id=%s expiresAt=%s",
            tostring(question), tostring(durationSec),
            tostring(poll.id), tostring(poll.expiresAt))
    else
        multitode.net.sendToHost(CHANNEL, "poll_create_request", {
            question = question,
            options = options,
            durationSec = durationSec
        })
    end
end

local function apply_vote(poll, playerId, optionIdx)
    playerId = tonumber(playerId) or 0
    optionIdx = tonumber(optionIdx) or 0
    if playerId == 0 or optionIdx < 1 or optionIdx > #(poll.options or {}) then
        return false
    end
    poll.votes[playerId] = optionIdx
    return true
end

function lobby.votePoll(optionIdx)
    if lobby.poll == nil then
        error("No active poll")
    end
    if is_host_role() then
        if apply_vote(lobby.poll, get_self_id(), optionIdx) then
            broadcast_poll_update(lobby.poll)
            -- Tally-only change: UI patches vote buttons in place (no rebuild).
            if _G.multitode ~= nil then
                _G.multitode._pollUiRefresh = true
            end
        end
    else
        multitode.net.sendToHost(CHANNEL, "poll_vote", {
            pollId = lobby.poll.id,
            optionIdx = tonumber(optionIdx) or 0
        })
    end
end

function lobby.closePollNow()
    if not is_host_role() or lobby.poll == nil then
        return
    end
    local poll = lobby.poll
    -- Drop the active poll BEFORE any broadcast so a loopback poll_close
    -- cannot run against a half-cleared or replaced poll object.
    lobby.poll = nil
    local winnerIdx, counts = poll_winner(poll)
    local winnerText = tostring(poll.options[winnerIdx] or "?")
    local total = 0
    local parts = {}
    for i, c in ipairs(counts or {}) do
        total = total + (c or 0)
        parts[#parts + 1] = string.format("%s: %d", tostring(poll.options[i] or "?"), c or 0)
    end
    -- Yellow System line in chat: full result so nobody has to dig history.
    local announce = string.format(
        "Poll closed: \"%s\" -> %s (%d/%d votes) | %s",
        tostring(poll.question or ""),
        winnerText,
        counts[winnerIdx] or 0,
        total,
        table.concat(parts, ", ")
    )
    multitode.net.broadcast(CHANNEL, "poll_close", {
        pollId = poll.id,
        winnerIdx = winnerIdx,
        counts = counts,
        announce = announce
    })
    lobby.pollHistory[#lobby.pollHistory + 1] = {
        question = poll.question,
        options = poll.options,
        winnerIdx = winnerIdx,
        counts = counts
    }
    while #lobby.pollHistory > 5 do
        table.remove(lobby.pollHistory, 1)
    end
    -- lobby.poll already cleared above (before broadcast).
    add_chat_message("System", announce)
    -- Toast only when the full window is closed (System line already covers open UIs).
    pcall(function()
        if multitode.lobby.chatOpen ~= true
            and multitode.lobby.menuOpen ~= true
            and multitode.show_toast ~= nil then
            multitode.show_toast(announce)
        end
    end)
    mark_ui_dirty()
    logger:i("Poll closed, winner option %s (pollId=%s)",
        tostring(winnerIdx), tostring(poll.id))
end

function lobby.send_chat(message)
    if message == nil or message == "" then
        return
    end

    local config = multitode.getConfig()
    local senderName = config.name or "Player"
    local senderId = get_self_id()

    -- Extract +kind references (pcall: refs module loads after this file).
    local cleanText, refs = message, nil
    local okParse, c, r = pcall(function()
        return multitode.refs.parse(message)
    end)
    if okParse then
        cleanText, refs = c, r
    end

    add_chat_message(senderName, cleanText, refs)
    -- Live-append via onChatLogged only — mark_ui_dirty rebuilt the whole
    -- multiplayer window every time someone sent a chat line.
    pcall(function()
        multitode.slog("CHAT", string.format("SEND %s: %s", tostring(senderName), tostring(cleanText)))
    end)

    if is_host_role() then
        -- Host broadcasts to all (receivers skip their own echo via senderId)
        multitode.net.broadcast(CHANNEL, "chat", {
            sender = senderName,
            senderId = senderId,
            message = cleanText,
            refs = refs,
            mapCh = lobby.mapChannel or lobby.selectedLevel or "*"
        })
    else
        -- Client sends to host for broadcast
        multitode.net.sendToHost(CHANNEL, "chat", {
            sender = senderName,
            senderId = senderId,
            message = cleanText,
            refs = refs,
            mapCh = lobby.mapChannel or lobby.selectedLevel or "*"
        })
    end
end

-- ============================================================
-- Message Handlers
-- ============================================================

local function ensure_handlers_registered()
    if lobby.handlersRegistered then
        return
    end

    -- Host receives join request
    multitode.net.onHost(CHANNEL, "join", function(ctx, payload)
        local senderId = tonumber(ctx.senderPlayerId) or 0
        local playerName = payload and payload.playerName or "Unknown"
        local password = payload and payload.password or ""

        -- No open lobby: reject instead of building a phantom roster
        if lobby.state ~= "WAITING" then
            multitode.net.sendToPeer(senderId, CHANNEL, "join_rejected", {
                reason = "No lobby open on host"
            })
            return
        end

        -- Validate password
        if lobby.password ~= "" and password ~= lobby.password then
            multitode.net.sendToPeer(senderId, CHANNEL, "join_rejected", {
                reason = "Wrong password"
            })
            return
        end

        -- Check player limit
        local playerCount = 0
        for _ in pairs(lobby.players) do
            playerCount = playerCount + 1
        end
        if playerCount >= lobby.maxPlayers then
            multitode.net.sendToPeer(senderId, CHANNEL, "join_rejected", {
                reason = "Lobby is full"
            })
            return
        end

        -- Add player
        lobby.players[senderId] = {
            name = playerName,
            ready = false,
            connected = true,
            marksOff = false
        }

        add_chat_message("System", playerName .. " joined the lobby")
        multitode.net.sendToPeer(senderId, CHANNEL, "join_accepted", {
            lobbyName = lobby.lobbyName,
            selectedLevel = lobby.selectedLevel,
            state = lobby.state
        })
        broadcast_lobby_state()
        mark_ui_dirty()
        logger:i("Player joined: %s (id=%s)", playerName, senderId)
    end)

    -- Host receives leave request
    multitode.net.onHost(CHANNEL, "leave", function(ctx, payload)
        local playerId = tonumber(payload and payload.playerId) or tonumber(ctx.senderPlayerId) or 0
        local playerInfo = lobby.players[playerId]
        if playerInfo then
            add_chat_message("System", playerInfo.name .. " left the lobby")
            lobby.players[playerId] = nil
            broadcast_lobby_state()
            mark_ui_dirty()
        end
    end)

    -- Host receives poll creation request (only when polls-for-all is on).
    multitode.net.onHost(CHANNEL, "poll_create_request", function(ctx, payload)
        if payload == nil then return end
        local allowed = multitode.settings ~= nil
            and multitode.settings.allowPollsForEveryone == true
        if not allowed then
            multitode.net.sendToPeer(tonumber(ctx.senderPlayerId) or 0, CHANNEL, "poll_notice", {
                text = "Only the host can create polls"
            })
            return
        end
        local ok, err = pcall(lobby.createPoll, payload.question, payload.options, payload.durationSec)
        if not ok then
            multitode.net.sendToPeer(tonumber(ctx.senderPlayerId) or 0, CHANNEL, "poll_notice", {
                text = "Poll rejected: " .. tostring(err)
            })
        end
    end)

    -- Host receives a vote.
    multitode.net.onHost(CHANNEL, "poll_vote", function(ctx, payload)
        if payload == nil or lobby.poll == nil then return end
        if tonumber(payload.pollId) ~= lobby.poll.id then return end
        if apply_vote(lobby.poll, ctx.senderPlayerId, payload.optionIdx) then
            broadcast_poll_update(lobby.poll)
            -- Patch tally labels in place — no full window rebuild.
            if _G.multitode ~= nil then
                _G.multitode._pollUiRefresh = true
            end
        end
    end)

    -- Clients: poll opened.
    -- On HOST_AND_CLIENT this also sees the host's own broadcast via loopback.
    -- Never let that clobber the authoritative host poll (a lost/zero expiresAt
    -- here made the watchdog close every subsequent poll instantly).
    multitode.net.onClient(CHANNEL, "poll_open", function(_, payload)
        if payload == nil then return end
        if is_host_role() then return end
        local durationSec = tonumber(payload.durationSec) or 20
        if durationSec < 1 then durationSec = 1 elseif durationSec > 3600 then durationSec = 3600 end
        local remainingSec = tonumber(payload.remainingSec)
        if remainingSec == nil or remainingSec < 0 then
            remainingSec = durationSec
        end
        -- Keep the fraction from the host — do not floor (off-by-1s / phase).
        -- localDeadline is milliseconds on THIS machine's clock.
        local nowLocal = now_ms()
        lobby.poll = {
            id = tonumber(payload.pollId) or 0,
            question = tostring(payload.question or ""),
            options = payload.options or {},
            votes = {},
            remainingSec = remainingSec,
            localDeadline = nowLocal + remainingSec * 1000,
            durationSec = durationSec
        }
        add_chat_message("System", "Poll: " .. lobby.poll.question)
        -- Do NOT auto-open the lobby window — poll is an extension of the
        -- quick-message strip (arrow under chat). Opening the full window
        -- here obscured the screen every time someone started a poll.
        pcall(function()
            if _G.multitode ~= nil then
                _G.multitode._quickPollDirty = true
            end
        end)
        -- Refresh only if the multiplayer window is already open (frame hook
        -- ignores dirty when closed). Never force-opens the window.
        mark_ui_dirty()
    end)

    -- Clients: poll tally update.
    multitode.net.onClient(CHANNEL, "poll_update", function(_, payload)
        if payload == nil or lobby.poll == nil then return end
        -- Host owns the live poll; ignore loopback echoes of its own updates.
        if is_host_role() then return end
        if tonumber(payload.pollId) ~= lobby.poll.id then return end
        local votesChanged = false
        if payload.votes ~= nil then
            local votes = {}
            for k, v in pairs(payload.votes) do
                votes[tonumber(k) or 0] = tonumber(v) or 0
            end
            local before = poll_votes_fingerprint(lobby.poll)
            lobby.poll.votes = votes
            votesChanged = poll_votes_fingerprint(lobby.poll) ~= before
        end
        -- Resync local deadline from host remaining (5s heartbeat).
        if payload.remainingSec ~= nil then
            local rem = tonumber(payload.remainingSec)
            if rem ~= nil and rem >= 0 then
                lobby.poll.remainingSec = rem
                lobby.poll.localDeadline = now_ms() + rem * 1000
            end
        end
        -- Only rebuild the whole window when tallies actually changed; the
        -- 5 s heartbeat is handled by the live countdown label.
        if votesChanged then
            if _G.multitode ~= nil then
                _G.multitode._pollUiRefresh = true
                _G.multitode._quickPollDirty = true
            end
        end
    end)

    -- Clients: poll closed with locked-in result.
    multitode.net.onClient(CHANNEL, "poll_close", function(_, payload)
        if payload == nil or lobby.poll == nil then return end
        -- Host already ran closePollNow; loopback must not double-fire.
        if is_host_role() then return end
        local closeId = tonumber(payload.pollId)
        local activeId = tonumber(lobby.poll.id)
        if closeId == nil or activeId == nil or closeId ~= activeId then return end
        local winnerIdx = tonumber(payload.winnerIdx) or 1
        lobby.pollHistory[#lobby.pollHistory + 1] = {
            question = lobby.poll.question,
            options = lobby.poll.options,
            winnerIdx = winnerIdx,
            counts = payload.counts or {}
        }
        while #lobby.pollHistory > 5 do
            table.remove(lobby.pollHistory, 1)
        end
        -- Prefer host-built announce (includes tallies); fall back to short form.
        local announce = tostring(payload.announce or "")
        if announce == "" then
            announce = "Poll closed: " .. tostring(lobby.poll.question)
                .. " -> " .. tostring(lobby.poll.options[winnerIdx] or "?")
        end
        add_chat_message("System", announce)
        lobby.poll = nil
        pcall(function()
            if _G.multitode ~= nil then
                _G.multitode._quickPollDirty = true
            end
        end)
        -- Toast only when neither chat nor the full window is already showing it.
        pcall(function()
            if multitode.lobby.chatOpen ~= true
                and multitode.lobby.menuOpen ~= true
                and multitode.show_toast ~= nil then
                multitode.show_toast(announce)
            end
        end)
        mark_ui_dirty()
    end)

    -- Clients: poll notice (rejection/info).
    multitode.net.onClient(CHANNEL, "poll_notice", function(_, payload)
        if payload == nil then return end
        add_chat_message("System", tostring(payload.text or "Poll notice"))
    end)

    -- Host receives ready update from a client: apply + rebroadcast to all
    multitode.net.onHost(CHANNEL, "player_ready", function(ctx, payload)
        if payload == nil then return end
        local playerId = tonumber(payload.playerId) or tonumber(ctx.senderPlayerId) or 0
        if lobby.players[playerId] then
            lobby.players[playerId].ready = payload.ready
        end
        multitode.net.broadcast(CHANNEL, "player_ready", {
            playerId = playerId,
            ready = payload.ready
        })
        flag_ready_refresh()
    end)

    -- Host receives chat from a client: log + rebroadcast to everyone
    multitode.net.onHost(CHANNEL, "chat", function(ctx, payload)
        if payload == nil then return end
        local senderId = tonumber(payload.senderId) or tonumber(ctx.senderPlayerId) or 0
        -- Skip our own loopback echo (host broadcasts reach its own client too)
        if senderId == get_self_id() then
            return
        end
        add_chat_message(payload.sender or "?", payload.message or "", payload.refs)
        pcall(function()
            multitode.slog("CHAT", string.format("HOST-RECV from=%s: %s",
                tostring(payload.sender or "?"), tostring(payload.message or "")))
        end)
        multitode.net.broadcast(CHANNEL, "chat", {
            sender = payload.sender,
            senderId = senderId,
            message = payload.message,
            refs = payload.refs
        })
        mark_ui_dirty()
    end)

    -- All: receive lobby state update
    multitode.net.onClient(CHANNEL, "state", function(_, payload)
        if payload == nil then return end

        -- The host broadcasts lobby state to EVERY connection, so a client that has
        -- not joined was still painting the host's roster (the phantom "1/8 on both
        -- sides": the other window mirrored a lobby it was never a member of).
        -- A client that is not in the roster must not adopt this lobby.
        local selfId = get_self_id()
        local isMember = false
        if payload.players ~= nil then
            for _, p in ipairs(payload.players) do
                if tonumber(p.id) == selfId then
                    isMember = true
                end
            end
        end

        local isHostRole = false
        pcall(function()
            local st = multitode.state()
            isHostRole = (st ~= nil and (st.role == "HOST" or st.role == "HOST_AND_CLIENT"))
        end)

        pcall(function()
            multitode.slog("LOBBY", string.format(
                "state from host: players=%s self=%s member=%s hostRole=%s state=%s",
                tostring(payload.players ~= nil and #payload.players or 0),
                tostring(selfId), tostring(isMember), tostring(isHostRole),
                tostring(payload.state)))
        end)

        if not isHostRole and not isMember then
            -- ignore it for display purposes, but remember who owns it
            lobby.hostLobbyName = payload.lobbyName
            lobby.hostLobbyPlayers = (payload.players ~= nil) and #payload.players or 0
            mark_ui_dirty()
            return
        end

        lobby.lobbyName = payload.lobbyName or lobby.lobbyName
        lobby.maxPlayers = payload.maxPlayers or lobby.maxPlayers
        lobby.state = payload.state or lobby.state
        lobby.selectedLevel = payload.selectedLevel

        -- Adopt host's "Polls for all" so clients show New Poll / can create.
        if payload.allowPollsForEveryone ~= nil then
            multitode.settings = multitode.settings or {}
            multitode.settings.allowPollsForEveryone = (payload.allowPollsForEveryone == true)
        end

        -- Adopt host boost mode. Release: forced to "host" (vote stub).
        if payload.bonusMode ~= nil then
            multitode.settings = multitode.settings or {}
            multitode.settings.bonusMode = "host"
        end

        -- Per-map channel tag for multi-map play.
        lobby.mapChannel = payload.mapCh or lobby.mapChannel

        -- Rebuild player list from broadcast
        local oldIds = {}
        for id in pairs(lobby.players or {}) do
            oldIds[id] = true
        end
        lobby.players = {}
        if payload.players then
            for _, p in ipairs(payload.players) do
                local id = tonumber(p.id) or 0
                lobby.players[id] = {
                    name = p.name,
                    ready = p.ready,
                    connected = p.connected,
                    marksOff = (p.marksOff == true)
                }
            end
        end
        -- Same crew, maybe new flags (ready flips ride lobby_state too):
        -- touch up in place instead of rebuilding.
        local membershipSame = true
        for id in pairs(lobby.players) do
            if not oldIds[id] then
                membershipSame = false
                break
            end
        end
        if membershipSame then
            for id in pairs(oldIds) do
                if lobby.players[id] == nil then
                    membershipSame = false
                    break
                end
            end
        end
        if membershipSame then
            flag_ready_refresh()
        else
            mark_ui_dirty()
        end
    end)

    -- All: marks on/off flag for the "marks off" roster badge.
    multitode.net.on(CHANNEL, "marks_flag", function(ctx, payload)
        if payload == nil then return end
        local playerId = tonumber(payload.playerId) or tonumber(ctx and ctx.senderPlayerId) or 0
        local off = (payload.enabled ~= true)
        if lobby.players[playerId] then
            lobby.players[playerId].marksOff = off
        end
        if ctx ~= nil and ctx.receiverContext == "HOST" then
            pcall(function()
                multitode.net.broadcast(CHANNEL, "marks_flag",
                    { playerId = playerId, enabled = (payload.enabled == true) })
            end)
        end
        flag_ready_refresh()
    end)

    -- All: receive chat message (skip own echo: sender already logged locally)
    -- NOTE: this registration REPLACES the onHost(CHANNEL, "chat") above, because
    -- multitode.net keeps one handler per channel+name. So it must also do the host's job:
    -- without the relay below, a client's chat reached the host and stopped there.
    multitode.net.on(CHANNEL, "chat", function(ctx, payload)
        if payload == nil then return end
        local senderId = tonumber(payload.senderId) or -1
        if senderId == get_self_id() then
            return
        end

        -- Per-map channel filter: drop traffic tagged for a different map when
        -- multi-map mode is active (mapCh present and different from ours).
        local ourCh = lobby.mapChannel or lobby.selectedLevel
        local msgCh = payload.mapCh
        if ourCh ~= nil and msgCh ~= nil and tostring(msgCh) ~= "*" and tostring(ourCh) ~= "*"
                and tostring(msgCh) ~= tostring(ourCh) then
            pcall(function()
                multitode.slog("CHAT", "dropped cross-map msg mapCh=" .. tostring(msgCh)
                    .. " ours=" .. tostring(ourCh))
            end)
            return
        end

        -- Chat is pushed through BOTH routes on purpose (sendToHost and a broadcast): a
        -- client's broadcast reaches the host, which is its only peer, so a lost send is
        -- unlikely to lose the message. The price is that the host receives the same
        -- message twice, so collapse an exact repeat from the same sender in a short window.
        local chatKey = tostring(senderId) .. "|" .. tostring(payload.sender or "") .. "|" .. tostring(payload.message or "")
        local nowMs = 0
        pcall(function() nowMs = multitode.now_ms() end)
        lobby.recentChat = lobby.recentChat or {}
        if lobby.recentChatCount == nil then lobby.recentChatCount = 0 end
        if lobby.recentChat[chatKey] ~= nil and nowMs > 0
                and (nowMs - lobby.recentChat[chatKey]) < 1500 then
            return
        end
        lobby.recentChat[chatKey] = nowMs
        lobby.recentChatCount = lobby.recentChatCount + 1
        if lobby.recentChatCount > 300 then
            lobby.recentChatCount = 0
            lobby.recentChat = {}
        end

        -- Cross-map status panel: remember last activity per map channel.
        pcall(function()
            local ch = tostring(msgCh or ourCh or "*")
            lobby.mapActivity = lobby.mapActivity or {}
            lobby.mapActivity[ch] = {
                lastAt = nowMs,
                lastSender = tostring(payload.sender or "?")
            }
        end)

        if ctx ~= nil and ctx.receiverContext == "HOST" then
            pcall(function()
                multitode.net.broadcast(CHANNEL, "chat", payload)
            end)
        end
        add_chat_message(payload.sender or "?", payload.message or "", payload.refs)
        pcall(function()
            multitode.slog("CHAT", string.format("GOT %s: %s",
                tostring(payload.sender or "?"), tostring(payload.message or "")))
        end)
        -- Chat is live-appended (embed + detached). Do NOT mark_ui_dirty —
        -- that rebuilt the whole multiplayer window on every message.
    end)

    -- All: player ready status update
    -- (Also replaces the onHost registration above, so it relays as well - otherwise the
    -- host applied a client's ready flag but no other client ever saw it.)
    multitode.net.on(CHANNEL, "player_ready", function(ctx, payload)
        if payload == nil then return end
        local playerId = tonumber(payload.playerId) or 0
        if lobby.players[playerId] then
            lobby.players[playerId].ready = payload.ready
        end
        flag_ready_refresh()
        if ctx ~= nil and ctx.receiverContext == "HOST" then
            pcall(function()
                multitode.net.broadcast(CHANNEL, "player_ready",
                    { playerId = playerId, ready = payload.ready })
            end)
        end
    end)

    -- Client: join accepted
    multitode.net.onClient(CHANNEL, "join_accepted", function(_, payload)
        lobby.joinPending = false
        lobby.lastError = nil
        if payload then
            lobby.lobbyName = payload.lobbyName or lobby.lobbyName
            lobby.selectedLevel = payload.selectedLevel
            lobby.state = payload.state or "WAITING"
        else
            lobby.state = "WAITING"
        end
        -- Tell everyone our marks on/off state so the roster badge is correct.
        pcall(function()
            if multitode.marks ~= nil and multitode.marks.broadcast_enabled_flag ~= nil then
                multitode.marks.broadcast_enabled_flag()
            end
        end)
        mark_ui_dirty()
        logger:i("Join accepted into lobby: %s", tostring(lobby.lobbyName))
    end)

    -- Client: join rejected
    multitode.net.onClient(CHANNEL, "join_rejected", function(_, payload)
        local reason = payload and payload.reason or "Unknown reason"
        logger:w("Join rejected: %s", reason)
        lobby.lastError = "Failed to join: " .. reason
        add_chat_message("System", lobby.lastError)
        reset_lobby()
        -- reset_lobby clears lastError via UI refresh only; keep the message visible
        lobby.lastError = "Failed to join: " .. reason
        mark_ui_dirty()
    end)

    -- All: kicked
    multitode.net.on(CHANNEL, "kicked", function(_, payload)
        if payload == nil then return end
        local localId = get_self_id()
        if tonumber(payload.playerId) == localId then
            add_chat_message("System", "You were kicked from the lobby")
            reset_lobby()
        else
            mark_ui_dirty()
        end
    end)

    -- All: lobby closed
    multitode.net.on(CHANNEL, "lobby_closed", function(_, payload)
        -- Hosts ignore their own loopback echo (roster already reset by leave())
        if is_host_role() then
            return
        end
        local reason = payload and payload.reason or "Lobby closed"
        add_chat_message("System", reason)
        reset_lobby()
    end)

    -- Client: receive level start from host (triggers level_sync)
    multitode.net.onClient(CHANNEL, "start_level", function(_, payload)
        if payload == nil or payload.levelName == nil then return end
        lobby.state = "IN_GAME"
        mark_ui_dirty()
        -- The level_sync module handles the actual loading
    end)

    lobby.handlersRegistered = true
    logger:i("Lobby handlers registered")
end

-- ============================================================
-- Auto-initialize when role is set
-- ============================================================

-- Register handlers when script loads
ensure_handlers_registered()

-- ============================================================
-- Watchdogs: keep the roster honest without user action
-- ============================================================

local function watchdog_tick()
    if lobby.state == "IDLE" then
        return
    end

    -- Poll expiry + live tally refresh (host side).
    if is_host_role() and lobby.poll ~= nil then
        local poll = lobby.poll
        local t = now_ms()
        local durationSec = tonumber(poll.durationSec) or 0
        if durationSec < 1 or durationSec > 3600 then
            durationSec = 20
        end
        -- Repair a missing/corrupt deadline instead of treating it as expired
        -- (expiresAt or 0 → t >= 0 closed every poll after the first instantly).
        -- expiresAt is milliseconds.
        local expiresAt = tonumber(poll.expiresAt) or 0
        if expiresAt <= 0 then
            local openedAt = tonumber(poll.openedAt) or 0
            if openedAt <= 0 then
                openedAt = t
                poll.openedAt = openedAt
            end
            expiresAt = openedAt + durationSec * 1000
            poll.expiresAt = expiresAt
            logger:w("Poll %s had invalid expiresAt; repaired to %s",
                tostring(poll.id), tostring(expiresAt))
        end
        if t >= expiresAt then
            lobby.closePollNow()
        elseif t - (lobby.lastPollUpdateAt or 0) >= POLL_UPDATE_INTERVAL_SEC * 1000 then
            -- Keep peers' clocks in sync; do NOT mark the lobby UI dirty —
            -- a 5 s rebuild was thrashing the window for a one-second tick.
            broadcast_poll_update(lobby.poll)
        end
    end

    local active = is_session_active()
    local t = now_sec()

    if active then
        lobby.lastSessionActiveAt = t
        return
    end

    if is_host_role() then
        -- Host side: drop roster entries whose transport is gone (e.g. the
        -- client closed the game) and tell everyone else.
        if t - lobby.lastReconcileAt < HOST_RECONCILE_INTERVAL_SEC then
            return
        end
        lobby.lastReconcileAt = t

        local ids = get_link_peer_ids()
        if ids == nil then
            return
        end
        local selfId = get_self_id()
        local present = {}
        for _, id in ipairs(ids) do
            present[tonumber(id) or 0] = true
        end

        local removed = false
        for id, info in pairs(lobby.players) do
            local numId = tonumber(id) or 0
            if numId ~= selfId and not present[numId] then
                add_chat_message("System", tostring(info.name) .. " disconnected")
                lobby.players[id] = nil
                removed = true
            end
        end
        if removed then
            broadcast_lobby_state()
            mark_ui_dirty()
            logger:i("Reconciled lobby roster after peer disconnect")
        end
    else
        -- Client side: if the host is gone (closed game / lobby destroyed),
        -- exit the lobby instead of showing a stale 1/8 roster forever.
        if lobby.lastSessionActiveAt == 0 then
            lobby.lastSessionActiveAt = t
            return
        end
        if t - lobby.lastSessionActiveAt >= CLIENT_LOBBY_TIMEOUT_SEC then
            add_chat_message("System", "Disconnected from host, left the lobby")
            logger:w("Host connection lost, leaving lobby")
            reset_lobby()
        end
    end
end

local function ensure_watchdog_registered()
    if lobby.watchdogRegistered then
        return
    end
    C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
        local ok, err = pcall(watchdog_tick)
        if not ok then
            logger:e("Lobby watchdog error: %s", tostring(err))
        end
    end))
    lobby.watchdogRegistered = true
end

ensure_watchdog_registered()

logger:i("Multitode lobby module loaded")
