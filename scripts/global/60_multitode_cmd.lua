local logger = C.TLog:forTag("multitode/cmd.lua")

cmd.multitode = function(role)
    if role == "?" then
        return {
            args = "string role - CLIENT / HOST / HOST_AND_CLIENT",
            descr = "Initialize and start the Multitode bridge"
        }
    end

    multitode.start(role)
    logger:i(multitode.describe())
end

cmd.multitode_state = function(a1)
    if a1 == "?" then
        return {
            descr = "Print current Multitode bridge state"
        }
    end

    logger:i(multitode.describe())
end

cmd.multitode_config = function(a1)
    if a1 == "?" then
        return {
            descr = "Print current Multitode session config"
        }
    end

    logger:i(multitode.getBridgeApi():describeConfig())
end

cmd.multitode_validate = function(a1)
    if a1 == "?" then
        return {
            descr = "Validate current Multitode session config"
        }
    end

    local valid, validationError = multitode.validateConfig()
    if valid then
        logger:i("Multitode config is valid")
        return
    end

    logger:e("Multitode config is invalid: %s", validationError)
end

cmd.multitode_save_config = function(a1)
    if a1 == "?" then
        return {
            descr = "Save current Multitode session config"
        }
    end

    multitode.saveConfig()
end

cmd.multitode_load_config = function(a1)
    if a1 == "?" then
        return {
            descr = "Load Multitode session config from disk"
        }
    end

    local loaded = multitode.loadConfig()
    if loaded then
        logger:i(multitode.getBridgeApi():describeConfig())
        return
    end

    logger:w("Multitode config file does not exist")
end

cmd.multitode_session = function(a1)
    if a1 == "?" then
        return {
            descr = "Print current Multitode session registry state"
        }
    end

    logger:i(multitode.describeSession())
end

cmd.multitode_peers = function(a1)
    if a1 == "?" then
        return {
            descr = "Print connected Multitode peers"
        }
    end

    logger:i(multitode.describePeers())
end

cmd.multitode_dispatch = function(a1)
    if a1 == "?" then
        return {
            descr = "Dispatch pending Multitode Lua messages"
        }
    end

    local processed = multitode.net.dispatchPending(tonumber(a1) or 100)
    logger:i("Dispatched %s pending Multitode messages", tostring(processed))
end

cmd.multitode_stop = function(a1)
    if a1 == "?" then
        return {
            descr = "Stop the Multitode bridge"
        }
    end

    multitode.stop()
    logger:i(multitode.describe())
end

cmd.multitode_itd = function(a1)
    if a1 == "?" then
        return {
            args = "string mode - status / on / off",
            descr = "Print or toggle Multitode ITD interception"
        }
    end

    local mode = tostring(a1 or "status")
    if mode == "on" then
        multitode.itd.setInterceptionEnabled(true)
    elseif mode == "off" then
        multitode.itd.setInterceptionEnabled(false)
    end

    logger:i(
        "Multitode ITD interceptors installed=%s blocking=%s authoritativeApply=%s",
        tostring(multitode.itd.installedSession ~= nil),
        tostring(multitode.itd.enforceInterception),
        tostring(multitode.itd.isAuthoritativeApplyActive())
    )
end
