local logger = C.TLog:forTag("multitode/multitode.getApi().lua")

local jsonReader = C.JsonReader.new()

local autoDispatchRegistered = false

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
        api:configureRole(value)
    elseif key == "name" or key == "playerName" then
        api:setPlayerName(tostring(value))
    elseif key == "host" then
        api:setHost(tostring(value))
    elseif key == "port" then
        local numberValue = tonumber(value)
        if numberValue == nil then
            error("port must be a number")
        end
        multitode.getApi():setPort(numberValue)
    else
        error("unsupported config key: " .. tostring(key))
    end
end

local function create_config_table(api)
    return {
        role = api:getConfiguredRoleName(),
        name = api:getPlayerName(),
        host = api:getHost(),
        port = api:getPort(),
    }
end

_G.multitode = _G.multitode or {}
multitode.net = multitode.net or {
    handlers = {}
}

local bridgeApiClass
local api
multitode.getApi = function()
    if bridgeApiClass == nil then
        bridgeApiClass = luajava.bindClass("dev.multitode.bridge.shared.BridgeApi")
    end

    if api == nil then
        api = bridgeApiClass.INSTANCE
    end

    return api
end

multitode.version = multitode.getApi():getVersion()

multitode.init = function(role)
    if role ~= nil then
        multitode.getApi():configureRole(role)
    end

    multitode.getApi():initialize()
    logger:i("Bridge initialized with role %s", multitode.getApi():getRoleName())
end

multitode.start = function(role)
    if role ~= nil then
        multitode.getApi():configureRole(role)
    end
    local bridge = multitode.getApi():start()
    logger:i("Bridge started as %s (%s)", multitode.getApi():getRoleName(), multitode.getApi():getLifecycleStateName())
    return bridge
end

multitode.stop = function()
    multitode.getApi():stop()
    logger:i("Bridge stopped")
end

multitode.state = function()
    local api = multitode.getApi()
    return {
        initialized = api:isInitialized(),
        role = api:getRoleName(),
        lifecycleState = api:getLifecycleStateName()
    }
end

multitode.configure = function(config)
    if config == nil then
        return create_config_table(multitode.getApi())
    end

    for key, value in pairs(config) do
        apply_config_value(multitode.getApi(), key, value)
    end

    logger:i("Bridge config updated: %s", multitode.getApi():describeConfig())
    return create_config_table(multitode.getApi())
end

multitode.resetConfig = function()
    multitode.getApi():resetConfig()
    logger:i("Bridge config reset: %s", multitode.getApi():describeConfig())
    return create_config_table(multitode.getApi())
end

multitode.getConfig = function()
    return create_config_table(multitode.getApi())
end

multitode.saveConfig = function()
    multitode.getApi():saveConfig()
    logger:i("Bridge config saved to %s", multitode.getApi():getConfigFilePath())
end

multitode.loadConfig = function()
    local loaded = multitode.getApi():loadConfig()
    if loaded then
        logger:i("Bridge config loaded from %s", multitode.getApi():getConfigFilePath())
    else
        logger:i("Bridge config file not found at %s", multitode.getApi():getConfigFilePath())
    end

    return loaded, create_config_table(multitode.getApi())
end

multitode.validateConfig = function()
    local validationError = multitode.getApi():getConfigValidationError()
    if validationError == nil then
        return true, nil
    end

    return false, validationError
end

multitode.getSessionInfo = function()
    local api = multitode.getApi()
    return {
        sessionId = api:getSessionId(),
        localPlayerId = api:getLocalPlayerId(),
        connectionState = api:getConnectionStateName(),
        sessionActive = api:isSessionActive(),
        connectedPeerCount = api:getConnectedPeerCount()
    }
end

multitode.describeSession = function()
    return multitode.getApi():describeSession()
end

multitode.describePeers = function()
    return multitode.getApi():describePeers()
end

multitode.hasPeers = function()
    return multitode.getApi():hasPeers()
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
    local sent = multitode.getApi():sendLuaMessageToHost(messageChannel, messageName, multitode.net.encodePayload(payload))
    if not sent then
        error("failed to send message to host")
    end
end

multitode.net.sendToPeer = function(playerId, messageChannel, messageName, payload)
    assert_user_channel(messageChannel)
    local sent = multitode.getApi():sendLuaMessageToPeer(tonumber(playerId), messageChannel, messageName, multitode.net.encodePayload(payload))
    if not sent then
        error("failed to send message to peer")
    end
end

multitode.net.broadcast = function(messageChannel, messageName, payload)
    assert_user_channel(messageChannel)
    local sent = multitode.getApi():broadcastLuaMessage(messageChannel, messageName, multitode.net.encodePayload(payload))
    if not sent then
        error("failed to broadcast message")
    end
end

multitode.net.getPendingCount = function()
    return multitode.getApi():getPendingLuaMessageCount()
end

multitode.net.poll = function()
    local rawMessageJson = multitode.getApi():pollInboundLuaMessageJson()
    if rawMessageJson == nil then
        return nil
    end

    return decode_json_string(rawMessageJson)
end

multitode.net.dispatchPending = function(limit)
    if limit == nil then return end

    local processed = 0
    local maxCount = limit

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
    if autoDispatchRegistered or limit == nil then
        return
    end

    local Render = com.prineside.tdi2.events.global.Render.class
    C.Game.EVENTS:getListeners(Render):add(C.Listener(function(_)
        multitode.net.dispatchPending(limit)
    end))
    autoDispatchRegistered = true
    logger:i("Enabled automatic message dispatch")
end

multitode.approveQueuedAction = function(targetTick, actionString)
    multitode.getApi():approveQueuedAction(tonumber(targetTick), tostring(actionString))
end

multitode.consumeApprovedQueuedAction = function(targetTick, actionString)
    return multitode.getApi():consumeApprovedQueuedAction(tonumber(targetTick), tostring(actionString))
end

multitode.resetApprovedQueuedActions = function()
    multitode.getApi():resetApprovedQueuedActions()
end

multitode.savePendingStartupSync = function(payload)
    multitode.getApi():savePendingStartupSyncJson(encode_json_value(payload))
end

multitode.getPendingStartupSync = function()
    local rawJson = multitode.getApi():getPendingStartupSyncJson()
    if rawJson == nil then
        return nil
    end

    return decode_json_string(rawJson)
end

multitode.clearPendingStartupSync = function()
    multitode.getApi():clearPendingStartupSync()
end

multitode.captureCurrentGameSnapshotBase64 = function()
    return multitode.getApi():captureCurrentGameSnapshotBase64()
end

multitode.restoreGameSnapshotBase64 = function(snapshotBase64, gameStartTimestamp)
    multitode.getApi():restoreGameSnapshotBase64(tostring(snapshotBase64), tonumber(gameStartTimestamp) or 0)
end

multitode.isInitialized = function()
    return multitode.getApi():isInitialized()
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

multitode.net.enableAutoDispatch(128)

-- Bootstrap config --
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

local state = multitode.state()
if (state.initialized and state.lifecycleState == "RUNNING") ~= true then
    multitode.start()
end
----------------------

logger:i("# Multitode "..multitode.version)
logger:i("Lua API loaded")