-- ===================================================================== stress harness
-- ###################################################################################
-- ## DEVELOPMENT / TEST TOOLING - NOT NEEDED TO PLAY, AND NOT MEANT TO SHIP.       ##
-- ##                                                                                ##
-- ## It is INERT unless enabled with Shift+F9 (deliberate two-key action, so it     ##
-- ## cannot be triggered by accident, and it stays off for normal players). While   ##
-- ## disabled it does nothing at all: no key floods, no log spam.                   ##
-- ##                                                                                ##
-- ## To ship without it: DELETE THIS ONE FILE. Nothing else references it.          ##
-- ###################################################################################
-- Multitode stress / benchmark. Floods the REAL network paths at a controlled rate and
-- reports what survived, so "does it hold up under load" is a measurement instead of a
-- guess. It deliberately uses the same calls the features use (tile marks through both
-- routes, extra state-hash reports) rather than a private shortcut, so whatever it breaks
-- is something a player could hit too.
--
--   F9 = run a 10s burst at 120 marks/s
--   multitode.stress.start(seconds, perSecond)   -- from anywhere
--   multitode.stress.lastSummary                 -- read by the MOD window
--
-- The report is a single line in the super-log:
--   STRESS done: secs=10 sent=1180 recv=1172 lost=0.7% dup=0 avgRtt=34ms maxRtt=118ms peakPending=9 hashes=20
-- lost > 0 means messages are being dropped; a rising peakPending means the receiving
-- side cannot keep up; maxRtt climbing means the link is saturating.

local stress = multitode.stress or {}
multitode.stress = stress

stress.running = false
stress.lastSummary = nil

local function now_ms()
    local v = 0
    pcall(function() v = multitode.now_ms() end)
    return v
end

local function current_systems()
    local systems = nil
    pcall(function()
        local scr = C.Game.i.screenManager:getCurrentScreen()
        if scr ~= nil then
            systems = scr.S
        end
    end)
    return systems
end

local function count_messages()
    local n = 0
    pcall(function() n = tonumber(multitode.net.getPendingCount()) or 0 end)
    return n
end

local function latency_ms()
    local v = "-"
    pcall(function()
        local l = tonumber(multitode.getApi():getLatencyMillis())
        if l ~= nil and l >= 0 then
            v = l
        end
    end)
    return v
end

--- Flood one mark through both routes, exactly like the real feature does.
local function send_mark(x, y, isWarning)
    local payload = { x = x, y = y, mode = isWarning and "no" or "ok", from = 0 }
    local hostOk = false
    pcall(function()
        hostOk = multitode.getApi():sendLuaMessageToHost("itd", "tile_mark",
            multitode.net.encodePayload(payload)) ~= false
    end)
    local bcastOk = false
    pcall(function()
        bcastOk = multitode.net.broadcast("itd", "tile_mark", payload) ~= false
    end)
    -- A client has no peer fan-out, so its broadcast legitimately reports false while
    -- sendToHost is what actually delivers. Counting only the broadcast made every
    -- client send look like a failure.
    return (hostOk or bcastOk), hostOk, bcastOk
end

--- Report the state hash for the current tick (exercises the host's sample comparison).
local function send_hash()
    local tick = -1
    local h = nil
    -- Use the shared probe (same accessor the heartbeat/hash watchdog uses):
    -- the old local lookup returned nothing whenever the current screen was
    -- not shaped the way this file expected, so the load test ran with
    -- hashes=0 and never exercised divergence detection.
    pcall(function()
        if multitode.superlog_probe_state ~= nil then
            local st = multitode.superlog_probe_state()
            if st ~= nil and tonumber(st.tick) ~= nil then
                tick = tonumber(st.tick)
            end
        end
    end)
    if tick < 0 then
        pcall(function()
            local systems = current_systems()
            if systems ~= nil and systems.state ~= nil then
                tick = tonumber(systems.state.updateNumber) or -1
            end
        end)
    end
    pcall(function()
        if multitode.superlog_state_hash ~= nil then
            h = multitode.superlog_state_hash()
        end
    end)
    if tick < 0 or h == nil then
        -- Distinguish "not in a match" (expected: start one) from a real
        -- in-match probe failure, and re-log whenever the reason changes
        -- instead of swallowing everything behind a single first-try flag.
        local inMatch = false
        pcall(function()
            local scr = C.Game.i.screenManager:getCurrentScreen()
            inMatch = scr ~= nil and C.GameScreen:_isInstance(scr)
        end)
        local reason
        if not inMatch then
            reason = "not in a match - start a level, then re-run the stress test"
        else
            reason = "in-match probe failed: tick=" .. tostring(tick)
                .. " hash=" .. tostring(h)
        end
        if stress.hashProbeWhy ~= reason then
            stress.hashProbeWhy = reason
            pcall(function()
                multitode.slog("STRESS", "hash probe could not run: " .. reason)
                logger:w("Stress hash probe could not run: %s", reason)
            end)
        end
        return false
    end
    stress.hashProbeWhy = nil
    pcall(function()
        multitode.net.sendToHost("itd", "state_hash", { hash = h, tick = tick })
    end)
    return true
end

function stress.start(seconds, perSecond)
    if stress.running then
        return false
    end
    stress.running = true
    stress.seconds = tonumber(seconds) or 10
    stress.perSecond = tonumber(perSecond) or 120
    stress.startedAt = now_ms()
    stress.endsAt = stress.startedAt + stress.seconds * 1000
    stress.nextSendAt = stress.startedAt
    stress.lastHashAt = stress.startedAt
    stress.stats = {
        sent = 0, sendFailed = 0, hashes = 0, viaHost = 0, viaBroadcast = 0,
        recvStart = 0, peakPending = 0, maxRtt = 0, rttSamples = 0, rttTotal = 0
    }
    pcall(function()
        if multitode.marks ~= nil then
            stress.stats.recvStart = tonumber(multitode.marks.recvCount) or 0
        end
    end)
    pcall(function()
        multitode.slog("STRESS", string.format("START secs=%s rate=%s/s",
            tostring(stress.seconds), tostring(stress.perSecond)))
        logger:i("Stress start: %ss at %s marks/s (F9 to run again)", tostring(stress.seconds), tostring(stress.perSecond))
    end)
    return true
end

function stress.stop(summary)
    if not stress.running then
        return stress.lastSummary
    end
    stress.running = false

    local stats = stress.stats or {}
    local recvEnd = 0
    pcall(function()
        if multitode.marks ~= nil then
            recvEnd = tonumber(multitode.marks.recvCount) or 0
        end
    end)
    local recv = recvEnd - (stats.recvStart or 0)
    local sent = stats.sent or 0
    local lostPct = 0
    if sent > 0 and recv < sent then
        lostPct = (sent - recv) / sent * 100
    end
    local avgRtt = "-"
    if (stats.rttSamples or 0) > 0 then
        avgRtt = string.format("%.0f", (stats.rttTotal or 0) / stats.rttSamples)
    end
    local line = string.format(
        "STRESS done: secs=%.1f sent=%d recv=%d lost=%.1f%% avgRtt=%sms maxRtt=%sms peakPending=%d hashes=%d sendFailed=%d",
        ((now_ms() - (stress.startedAt or now_ms())) / 1000),
        sent, recv, lostPct, tostring(avgRtt), tostring(stats.maxRtt or 0),
        stats.peakPending or 0, stats.hashes or 0, stats.sendFailed or 0)
    line = line .. string.format(" viaHost=%d viaBroadcast=%d",
        stats.viaHost or 0, stats.viaBroadcast or 0)
    stress.lastSummary = line
    pcall(function()
        multitode.slog("STRESS", line)
        logger:i(line)
    end)
    if summary ~= false then
        pcall(function()
            logger:i("Stress result: sent=%d recv=%d lost=%.1f%% maxRtt=%sms peakPending=%d",
                sent, recv, lostPct, tostring(stats.maxRtt or 0), stats.peakPending or 0)
        end)
    end
    return line
end

stress.summary = function()
    return stress.lastSummary or "not run yet"
end

-- --------------------------------------------------------------------------- driver
stress.driverRegistered = false
local function install_driver()
    if stress.driverRegistered then
        return
    end
    stress.driverRegistered = true
    pcall(function()
        C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
            pcall(function()
                if not stress.running then
                    return
                end

                local now = now_ms()
                local stats = stress.stats

                -- rate-limited sends, accumulated so the rate is honoured even if a frame
                -- is long (a slow frame must not silently reduce the load)
                if stats.nextSendAt == nil then
                    stats.nextSendAt = now
                end
                local intervalMs = 1000 / math.max(1, stress.perSecond)
                local budget = 0
                while now >= stats.nextSendAt and budget < 64 do
                    stats.nextSendAt = stats.nextSendAt + intervalMs
                    budget = budget + 1
                end
                for i = 1, budget do
                    local x = math.random(0, 45)
                    local y = math.random(0, 25)
                    local isWarning = (i % 5 == 0)
                    local ok, hostOk, bcastOk = send_mark(x, y, isWarning)
                    if ok then
                        stats.sent = stats.sent + 1
                    else
                        stats.sendFailed = stats.sendFailed + 1
                    end
                    if hostOk then stats.viaHost = (stats.viaHost or 0) + 1 end
                    if bcastOk then stats.viaBroadcast = (stats.viaBroadcast or 0) + 1 end
                end

                -- extra hash reports: this is what tells us whether the worlds stayed
                -- identical while all that traffic was in flight
                if now - (stress.lastHashAt or now) >= 500 then
                    stress.lastHashAt = now
                    if send_hash() then
                        stats.hashes = stats.hashes + 1
                    end
                end

                -- queue depth + latency samples
                local pending = count_messages()
                if pending > (stats.peakPending or 0) then
                    stats.peakPending = pending
                end
                local rtt = tonumber(latency_ms())
                -- 0ms is not a real round trip: it means this side has no measurement yet
                -- (the client does not currently get one - see the report line below).
                if rtt ~= nil and rtt > 0 then
                    stats.rttSamples = (stats.rttSamples or 0) + 1
                    stats.rttTotal = (stats.rttTotal or 0) + rtt
                    if rtt > (stats.maxRtt or 0) then
                        stats.maxRtt = rtt
                    end
                end

                if now >= stress.endsAt then
                    stress.stop(true)
                end
            end)
        end))
    end)
end

install_driver()

-- ------------------------------------------------------------------------ key bind
-- ------------------------------------------------------------------------ key binds
-- The lab is driven by keys with on-screen toasts. The MOD window buttons never showed
-- up (they depended on a helper that was not in scope where the rows were added), and a
-- test you cannot start is useless, so this path uses only plain input + a toast, both of
-- which already work elsewhere in the mod.
--
--   F9  = marks 10s @120/s      (light, realistic)
--   F10 = HARD 15s @1500/s + 8x (beyond any real game)
--   F11 = speed test 1x/2x/4x/8x
--   F12 = watch actions 30s     (build towers while it counts)
--   Shift+F12 = report the current lab counters

-- The harness stays disabled until Shift+F9. The choice is remembered via the bridge
-- settings, so once you turn it on it stays on for that machine.
stress.enabled = false
pcall(function()
    local saved = multitode.getApi():getSetting("lab.enabled", "0")
    stress.enabled = (tostring(saved) == "1")
end)

stress.setEnabled = function(on)
    stress.enabled = on and true or false
    pcall(function()
        multitode.getApi():setSetting("lab.enabled", stress.enabled and "1" or "0")
    end)
    stress.toast(stress.enabled
        and "Lab ENABLED (F9 marks, F10 hard, F11 speed, F12 watch, Shift+F9 off)"
        or "Lab disabled")
end

stress.toast = function(text)
    pcall(function()
        if multitode.show_toast ~= nil then
            multitode.show_toast(text)
        end
    end)
    pcall(function() logger:i("Lab: %s", tostring(text)) end)
end

local function key_code(name, fallback)
    local code = nil
    pcall(function() code = C.Input_Keys[name] end)
    if code == nil then pcall(function() code = C.Input.Keys[name] end) end
    if code == nil then
        code = fallback
    end
    return code
end

stress.binds = {
    { key = key_code("F9", 139),  label = "marks 10s @120/s",      run = function() stress.start(10, 120) end },
    { key = key_code("F10", 140), label = "HARD 15s @1500/s + 8x", run = function() stress.startHard() end },
    { key = key_code("F11", 141), label = "speed 1x/2x/4x/8x",     run = function() stress.startSpeed() end },
    { key = key_code("F12", 142), label = "watch actions 30s",     run = function() stress.watchStart() end },
}
stress.held = {}

pcall(function()
    C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
        pcall(function()
            local input = C.Gdx.input
            if input == nil then
                return
            end

            local shift = false
            pcall(function() shift = input:isKeyPressed(key_code("SHIFT_LEFT", 59)) end)
            local f9 = key_code("F9", 139)

            -- Shift+F9 toggles the whole lab. This is the only key that works while the
            -- lab is off, and it needs a deliberate two-key press on purpose: a player who
            -- leans on F9 must not start a flood or fill their log.
            local toggleSlot = "F9:shift"
            if shift and input:isKeyPressed(f9) then
                if not stress.held[toggleSlot] then
                    stress.held[toggleSlot] = true
                    stress.setEnabled(not stress.enabled)
                    -- bring the lab window up so the toggles are reachable without the
                    -- keyboard once the mode is on
                    if stress.enabled then
                        pcall(function()
                            if multitode.open_lab_window ~= nil then
                                multitode.open_lab_window()
                            end
                        end)
                    end
                end
                return
            end
            stress.held[toggleSlot] = false

            if not stress.enabled then
                return
            end

            -- Shift+F12 = report the counters without starting anything
            local reportKey = key_code("F12", 142)
            if shift and input:isKeyPressed(reportKey) and not stress.held[reportKey .. ":shift"] then
                stress.held[reportKey .. ":shift"] = true
                stress.toast(stress.labReport())
            elseif not shift then
                stress.held[reportKey .. ":shift"] = false
            end

            for i = 1, #stress.binds do
                local bind = stress.binds[i]
                local down = input:isKeyPressed(bind.key)
                if down and not stress.held[bind.key] then
                    stress.held[bind.key] = true
                    local started = bind.run()
                    if started ~= false then
                        stress.toast("Lab: " .. bind.label .. " started")
                    else
                        stress.toast("Lab: " .. bind.label .. " - already running")
                    end
                elseif not down then
                    stress.held[bind.key] = false
                end
            end
        end)
    end))
end)

-- One line, and only when someone is actually looking: a disabled lab must not chatter.
pcall(function()
    if stress.enabled then
        logger:i("Development lab ACTIVE (F9 marks / F10 hard / F11 speed / F12 watch, Shift+F9 to disable)")
    else
        logger:i("Development lab present but disabled (Shift+F9 to enable for testing)")
    end
end)
-- ===================================================================== lab modes
-- A small "lab" so behaviour can be measured instead of argued about. All modes use the
-- same real paths a player uses; nothing here has a private shortcut.
--
--   marks  - 10s at 120 marks/s                (light, realistic)
--   hard   - 15s at 1500 marks/s + speed 8x    (deliberately beyond any real game)
--   speed  - walks the host speed 1x/2x/4x/8x  (does the other side track it?)
--   watch  - 30s of action bookkeeping         (build towers while it runs)

multitode.actStats = multitode.actStats or {}

local function read_act_stats()
    local s = multitode.actStats or {}
    return { allowed = s.allowed or 0, captured = s.captured or 0,
             hostSent = s.hostSent or 0, unhandled = s.unhandled or 0 }
end

local function set_speed(x)
    local ok = false
    pcall(function()
        local systems = current_systems()
        if systems ~= nil and systems.state ~= nil then
            systems.state:setGameSpeed(x)
            ok = true
        end
    end)
    return ok
end

local function get_speed()
    local v = nil
    pcall(function()
        local systems = current_systems()
        if systems ~= nil and systems.state ~= nil then
            v = tonumber(systems.state:getGameSpeed())
        end
    end)
    return v
end

stress.watchStart = function()
    stress.watchFrom = read_act_stats()
    stress.watchStartedAt = now_ms()
    stress.watchUntil = stress.watchStartedAt + 30000
    stress.watching = true
    pcall(function()
        multitode.slog("LAB", "WATCH start (30s) - build towers now")
        logger:i("Lab: watching actions for 30s - build towers as fast as you like")
    end)
end

local function finish_watch()
    stress.watching = false
    local fromStats = stress.watchFrom or {}
    local nowStats = read_act_stats()
    local line = string.format(
        "LAB watch done: seconds=%.1f allowed=%d captured=%d hostSent=%d unhandled=%d",
        (now_ms() - (stress.watchStartedAt or now_ms())) / 1000,
        nowStats.allowed - (fromStats.allowed or 0),
        nowStats.captured - (fromStats.captured or 0),
        nowStats.hostSent - (fromStats.hostSent or 0),
        nowStats.unhandled - (fromStats.unhandled or 0))
    stress.lastWatch = line
    pcall(function()
        multitode.slog("LAB", line)
        logger:i(line)
    end)
end

stress.speedStep = 0
stress.speedPlan = nil

stress.startSpeed = function()
    stress.speedPlan = { 1, 2, 4, 8, 4, 2, 1 }
    stress.speedStep = 0
    stress.speedNextAt = now_ms()
    stress.speedUntil = now_ms() + #stress.speedPlan * 2000
    stress.speeding = true
    pcall(function()
        multitode.slog("LAB", "SPEED-TEST start (1x/2x/4x/8x, 2s each)")
        logger:i("Lab: speed test started - watch the other side's err/HASH lines")
    end)
end

local function tick_speed_test()
    if not stress.speeding then
        return
    end
    local now = now_ms()
    if now >= (stress.speedNextAt or now) then
        stress.speedNextAt = now + 2000
        stress.speedStep = (stress.speedStep or 0) + 1
        local want = stress.speedPlan[stress.speedStep]
        if want == nil then
            stress.speeding = false
            set_speed(1)
            local line = "LAB speed test done: reset to 1x"
            stress.lastSpeed = line
            pcall(function()
                multitode.slog("LAB", line)
                logger:i(line)
            end)
            return
        end
        set_speed(want)
        local got = get_speed()
        pcall(function()
            multitode.slog("LAB", string.format("SPEED-TEST set=%sx engine=%sx", tostring(want), tostring(got)))
            logger:i("Lab speed: asked %sx, engine reports %sx", tostring(want), tostring(got))
        end)
    end
end

stress.labReport = function()
    local a = read_act_stats()
    local line = string.format(
        "LAB actions: allowed=%d captured=%d hostSent=%d unhandled=%d | marks=%s | watch=%s",
        a.allowed, a.captured, a.hostSent, a.unhandled,
        tostring(stress.lastSummary or "-"), tostring(stress.lastWatch or "-"))
    return line
end

-- lab driver: runs the timed tasks that are independent of the mark burst
stress.labDriverRegistered = false
local function install_lab_driver()
    if stress.labDriverRegistered then
        return
    end
    stress.labDriverRegistered = true
    pcall(function()
        C.Game.EVENTS:getListeners(com.prineside.tdi2.events.global.Render.class):add(C.Listener(function(_)
            pcall(function()
                if stress.watching and now_ms() >= (stress.watchUntil or 0) then
                    finish_watch()
                end
                tick_speed_test()
            end)
        end))
    end)
end

install_lab_driver()

-- hard mode: the same flood, but at a rate no real match can produce, plus 8x speed
stress.startHard = function()
    local started = stress.start(15, 1500)
    if started then
        pcall(function()
            local systems = current_systems()
            if systems ~= nil and systems.state ~= nil then
                systems.state:setGameSpeed(8)
            end
        end)
        pcall(function()
            multitode.slog("LAB", "HARD start: 15s at 1500 marks/s with 8x speed")
            logger:i("Lab: HARD mode - 1500 marks/s at 8x speed for 15s (beyond any real game)")
        end)
    end
    return started
end