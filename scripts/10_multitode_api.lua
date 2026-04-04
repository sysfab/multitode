local logger = C.TLog:forTag("multitode/api.lua")

local bridgeApiClassName = "dev.multitode.bridge.shared.BridgeApi"
local bridgeApiClass = nil
local bridgeApi = nil
local bridgeApiBindError = nil
local jsonReader = C.JsonReader.new()
local autoDispatchRegistered = false

local function get_bridge_api()
    if bridgeApi ~= nil then
        return bridgeApi
    end
    if bridgeApiBindError ~= nil then
        error(bridgeApiBindError)
    end

    local ok, result = pcall(luajava.bindClass, bridgeApiClassName)
    if not ok then
        bridgeApiBindError = "failed to bind " .. bridgeApiClassName .. ": " .. tostring(result)
        error(bridgeApiBindError)
    end

    bridgeApiClass = result

    local ok, instance = pcall(function()
        return bridgeApiClass.INSTANCE
    end)
    if not ok then
        bridgeApiBindError = "failed to access " .. bridgeApiClassName .. ".INSTANCE: " .. tostring(instance)
        error(bridgeApiBindError)
    end
    if instance == nil then
        bridgeApiBindError = bridgeApiClassName .. ".INSTANCE is nil"
        error(bridgeApiBindError)
    end

    bridgeApi = instance
    return bridgeApi
end

local function normalize_role(role)
    if role == nil then
        return "HOST_AND_CLIENT"
    end

    local normalized = tostring(role):upper():gsub("-", "_"):gsub("%s+", "_")
    if normalized == "LOCAL" or normalized == "LOCALHOST" then
        return "HOST_AND_CLIENT"
    end
    return normalized
end

local function escape_json_string(value)
    return tostring(value)
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\b", "\\b")
        :gsub("\f", "\\f")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
end

local function is_dense_array(value)
    local count = 0
    local maxIndex = 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false, 0
        end
        count = count + 1
        if key > maxIndex then
            maxIndex = key
        end
    end

    return maxIndex == count, count
end

local encode_json_value

local function encode_json_table(value)
    local isArray, size = is_dense_array(value)
    local parts = {}

    if isArray then
        for index = 1, size do
            parts[#parts + 1] = encode_json_value(value[index])
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    for key, itemValue in pairs(value) do
        if type(key) ~= "string" then
            error("json object keys must be strings")
        end
        parts[#parts + 1] = '"' .. escape_json_string(key) .. '":' .. encode_json_value(itemValue)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encode_json_value = function(value)
    local valueType = type(value)
    if valueType == "nil" then
        return "null"
    end
    if valueType == "boolean" then
        return value and "true" or "false"
    end
    if valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("json numbers must be finite")
        end
        return tostring(value)
    end
    if valueType == "string" then
        return '"' .. escape_json_string(value) .. '"'
    end
    if valueType == "table" then
        return encode_json_table(value)
    end

    error("unsupported json value type: " .. valueType)
end

local function decode_json_value(jsonValue)
    if jsonValue:isNull() then
        return nil
    end
    if jsonValue:isBoolean() then
        return jsonValue:asBoolean()
    end
    if jsonValue:isDouble() then
        return jsonValue:asDouble()
    end
    if jsonValue:isLong() then
        return jsonValue:asLong()
    end
    if jsonValue:isString() then
        return jsonValue:asString()
    end
    if jsonValue:isArray() then
        local result = {}
        local child = jsonValue.child
        while child ~= nil do
            result[#result + 1] = decode_json_value(child)
            child = child.next
        end
        return result
    end
    if jsonValue:isObject() then
        local result = {}
        local child = jsonValue.child
        while child ~= nil do
            result[child.name] = decode_json_value(child)
            child = child.next
        end
        return result
    end

    error("unsupported JsonValue type")
end

local function decode_json_string(json)
    return decode_json_value(jsonReader:parse(json))
end

local function assert_user_channel(messageChannel)
    if messageChannel == nil or tostring(messageChannel) == "" then
        error("messageChannel must not be blank")
    end
    if tostring(messageChannel) == "system" then
        error("messageChannel 'system' is reserved")
    end
end

local function apply_config_value(api, key, value)
    if key == "role" then
        api:configureRole(normalize_role(value))
    elseif key == "name" or key == "playerName" then
        api:setPlayerName(tostring(value))
    elseif key == "host" then
        api:setHost(tostring(value))
    elseif key == "port" then
        local numberValue = tonumber(value)
        if numberValue == nil then
            error("port must be a number")
        end
        api:setPort(numberValue)
    elseif key == "listenPort" then
        local numberValue = tonumber(value)
        if numberValue == nil then
            error("listenPort must be a number")
        end
        api:setListenPort(numberValue)
    elseif key == "autoStart" then
        api:setAutoStart(not not value)
    elseif key == "autoConnect" then
        api:setAutoConnect(not not value)
    elseif key == "snapshotIntervalTicks" then
        local numberValue = tonumber(value)
        if numberValue == nil then
            error("snapshotIntervalTicks must be a number")
        end
        api:setSnapshotIntervalTicks(numberValue)
    elseif key == "verboseLogging" then
        api:setVerboseLogging(not not value)
    elseif key == "logCommands" then
        api:setLogCommands(not not value)
    elseif key == "logDesyncs" then
        api:setLogDesyncs(not not value)
    else
        error("unsupported config key: " .. tostring(key))
    end
end

local function create_state_table(api)
    return {
        initialized = api:isInitialized(),
        role = api:getRoleName(),
        lifecycleState = api:getLifecycleStateName()
    }
end

local function create_session_table(api)
    return {
        sessionId = api:getSessionId(),
        localPlayerId = api:getLocalPlayerId(),
        connectionState = api:getConnectionStateName(),
        sessionActive = api:isSessionActive(),
        connectedPeerCount = api:getConnectedPeerCount()
    }
end

local function create_config_table(api)
    return {
        role = api:getConfiguredRoleName(),
        name = api:getPlayerName(),
        host = api:getHost(),
        port = api:getPort(),
        listenPort = api:getListenPort(),
        autoStart = api:isAutoStart(),
        autoConnect = api:isAutoConnect(),
        snapshotIntervalTicks = api:getSnapshotIntervalTicks(),
        verboseLogging = api:isVerboseLogging(),
        logCommands = api:isLogCommands(),
        logDesyncs = api:isLogDesyncs()
    }
end

_G.multitode = _G.multitode or {}
multitode.net = multitode.net or {
    handlers = {}
}

multitode.getBridgeApi = function()
    return get_bridge_api()
end

multitode.init = function(role)
    local api = get_bridge_api()
    if role ~= nil then
        api:configureRole(normalize_role(role))
    end
    local bridge = api:initialize()
    logger:i("Bridge initialized with role %s", api:getRoleName())
    return bridge
end

multitode.start = function(role)
    local api = get_bridge_api()
    if role ~= nil then
        api:configureRole(normalize_role(role))
    end
    local bridge = api:start()
    logger:i("Bridge started as %s (%s)", api:getRoleName(), api:getLifecycleStateName())
    return bridge
end

multitode.stop = function()
    local api = get_bridge_api()
    api:stop()
    logger:i("Bridge stopped")
end

multitode.state = function()
    local api = get_bridge_api()
    return create_state_table(api)
end

multitode.configure = function(config)
    local api = get_bridge_api()
    if config == nil then
        return create_config_table(api)
    end

    for key, value in pairs(config) do
        apply_config_value(api, key, value)
    end

    logger:i("Bridge config updated: %s", api:describeConfig())
    return create_config_table(api)
end

multitode.resetConfig = function()
    local api = get_bridge_api()
    api:resetConfig()
    logger:i("Bridge config reset: %s", api:describeConfig())
    return create_config_table(api)
end

multitode.getConfig = function()
    return create_config_table(get_bridge_api())
end

multitode.saveConfig = function()
    local api = get_bridge_api()
    api:saveConfig()
    logger:i("Bridge config saved to %s", api:getConfigFilePath())
end

multitode.loadConfig = function()
    local api = get_bridge_api()
    local loaded = api:loadConfig()
    if loaded then
        logger:i("Bridge config loaded from %s", api:getConfigFilePath())
    else
        logger:i("Bridge config file not found at %s", api:getConfigFilePath())
    end

    return loaded, create_config_table(api)
end

multitode.validateConfig = function()
    local api = get_bridge_api()
    local validationError = api:getConfigValidationError()
    if validationError == nil then
        return true, nil
    end

    return false, validationError
end

multitode.getSessionInfo = function()
    return create_session_table(get_bridge_api())
end

multitode.describeSession = function()
    return get_bridge_api():describeSession()
end

multitode.describePeers = function()
    return get_bridge_api():describePeers()
end

multitode.hasPeers = function()
    return get_bridge_api():hasPeers()
end

multitode.net.encodePayload = function(payload)
    if type(payload) ~= "table" then
        error("payload must be a table")
    end
    return encode_json_value(payload)
end

multitode.net.decodePayload = function(payloadJson)
    return decode_json_string(payloadJson)
end

multitode.net.on = function(messageChannel, messageName, handler)
    assert_user_channel(messageChannel)
    if type(messageName) ~= "string" or messageName == "" then
        error("messageName must be a non-empty string")
    end
    if type(handler) ~= "function" then
        error("handler must be a function")
    end

    local channelHandlers = multitode.net.handlers[messageChannel]
    if channelHandlers == nil then
        channelHandlers = {}
        multitode.net.handlers[messageChannel] = channelHandlers
    end

    channelHandlers[messageName] = handler
end

multitode.net.onHost = function(messageChannel, messageName, handler)
    multitode.net.on(messageChannel, messageName, function(ctx, payload)
        if ctx.receiverContext ~= "HOST" then
            return
        end

        handler(ctx, payload)
    end)
end

multitode.net.onClient = function(messageChannel, messageName, handler)
    multitode.net.on(messageChannel, messageName, function(ctx, payload)
        if ctx.receiverContext ~= "CLIENT" then
            return
        end

        handler(ctx, payload)
    end)
end

multitode.net.sendToHost = function(messageChannel, messageName, payload)
    assert_user_channel(messageChannel)
    local sent = get_bridge_api():sendLuaMessageToHost(messageChannel, messageName, multitode.net.encodePayload(payload))
    if not sent then
        error("failed to send message to host")
    end
end

multitode.net.sendToPeer = function(playerId, messageChannel, messageName, payload)
    assert_user_channel(messageChannel)
    local sent = get_bridge_api():sendLuaMessageToPeer(tonumber(playerId), messageChannel, messageName, multitode.net.encodePayload(payload))
    if not sent then
        error("failed to send message to peer")
    end
end

multitode.net.broadcast = function(messageChannel, messageName, payload)
    assert_user_channel(messageChannel)
    local sent = get_bridge_api():broadcastLuaMessage(messageChannel, messageName, multitode.net.encodePayload(payload))
    if not sent then
        error("failed to broadcast message")
    end
end

multitode.net.getPendingCount = function()
    return get_bridge_api():getPendingLuaMessageCount()
end

multitode.net.poll = function()
    local rawMessageJson = get_bridge_api():pollInboundLuaMessageJson()
    if rawMessageJson == nil then
        return nil
    end

    return decode_json_string(rawMessageJson)
end

multitode.net.dispatchPending = function(limit)
    local processed = 0
    local maxCount = limit or 100

    while processed < maxCount do
        local envelope = multitode.net.poll()
        if envelope == nil then
            break
        end

        local channelHandlers = multitode.net.handlers[envelope.messageChannel]
        local handler = channelHandlers and channelHandlers[envelope.messageName] or nil
        if handler ~= nil then
            handler({
                receiverContext = envelope.receiverContext,
                messageChannel = envelope.messageChannel,
                messageName = envelope.messageName,
                senderPlayerId = envelope.senderPlayerId
            }, envelope.payload)
        else
            logger:w(
                "No Lua message handler for %s/%s (receiver=%s sender=%s)",
                tostring(envelope.messageChannel),
                tostring(envelope.messageName),
                tostring(envelope.receiverContext),
                tostring(envelope.senderPlayerId)
            )
        end
        processed = processed + 1
    end

    return processed
end

multitode.net.enableAutoDispatch = function(limit)
    if autoDispatchRegistered then
        return
    end

    local Render = com.prineside.tdi2.events.global.Render.class
    C.Game.EVENTS:getListeners(Render):add(C.Listener(function(_)
        multitode.net.dispatchPending(limit or 100)
    end))
    autoDispatchRegistered = true
    logger:i("Enabled automatic Multitode message dispatch")
end

multitode.approveQueuedAction = function(targetTick, actionString)
    get_bridge_api():approveQueuedAction(tonumber(targetTick), tostring(actionString))
end

multitode.consumeApprovedQueuedAction = function(targetTick, actionString)
    return get_bridge_api():consumeApprovedQueuedAction(tonumber(targetTick), tostring(actionString))
end

multitode.resetApprovedQueuedActions = function()
    get_bridge_api():resetApprovedQueuedActions()
end

multitode.savePendingStartupSync = function(payload)
    get_bridge_api():savePendingStartupSyncJson(encode_json_value(payload))
end

multitode.getPendingStartupSync = function()
    local rawJson = get_bridge_api():getPendingStartupSyncJson()
    if rawJson == nil then
        return nil
    end

    return decode_json_string(rawJson)
end

multitode.clearPendingStartupSync = function()
    get_bridge_api():clearPendingStartupSync()
end

multitode.captureCurrentGameSnapshotBase64 = function()
    return get_bridge_api():captureCurrentGameSnapshotBase64()
end

multitode.restoreGameSnapshotBase64 = function(snapshotBase64, gameStartTimestamp)
    get_bridge_api():restoreGameSnapshotBase64(tostring(snapshotBase64), tonumber(gameStartTimestamp) or 0)
end

multitode.isInitialized = function()
    return get_bridge_api():isInitialized()
end

multitode.describe = function()
    local state = multitode.state()
    return string.format(
        "Multitode bridge initialized=%s role=%s lifecycle=%s",
        tostring(state.initialized),
        tostring(state.role),
        tostring(state.lifecycleState)
    )
end

local function bootstrap_saved_config()
    local loaded, config = multitode.loadConfig()
    if not loaded then
        return
    end

    local valid, validationError = multitode.validateConfig()
    if not valid then
        logger:e("Saved bridge config is invalid: %s", validationError)
        return
    end

    logger:i("Saved bridge config applied: role=%s player=%s", tostring(config.role), tostring(config.name))
    if config.autoStart then
        local state = multitode.state()
        if state.initialized and state.lifecycleState == "RUNNING" then
            logger:i("Bridge already running, skipping auto-start during script bootstrap")
            return
        end

        multitode.start()
    end
end

logger:i("Multitode Lua API loaded")
multitode.net.enableAutoDispatch(100)
bootstrap_saved_config()
