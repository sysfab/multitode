package dev.multitode.bridge;

import com.prineside.tdi2.utils.logging.TLog;
import dev.multitode.bridge.client.ClientModule;
import dev.multitode.bridge.host.HostModule;
import dev.multitode.bridge.shared.BridgeContext;
import dev.multitode.bridge.shared.SessionConfig;
import dev.multitode.bridge.shared.SharedModule;

public final class Bridge {
    private static final TLog LOGGER = TLog.forTag("multitode/Bridge");

    private final BridgeContext context;
    private final SharedModule sharedModule;
    private final ClientModule clientModule;
    private final HostModule hostModule;

    private Bridge(SessionConfig sessionConfig) {
        this.context = new BridgeContext(sessionConfig.copy());
        this.sharedModule = new SharedModule(context);
        this.clientModule = new ClientModule(context);
        this.hostModule = new HostModule(context);

        LOGGER.i("Created bridge with %s", context.getSessionConfig().describe());
    }

    public static Bridge create(SessionConfig sessionConfig) {
        return new Bridge(sessionConfig);
    }

    public void start() {
        LOGGER.i("Starting bridge with role %s", context.getRole().name());
        context.setLifecycleState(dev.multitode.bridge.shared.BridgeLifecycleState.STARTING);
        sharedModule.start();
        if (context.getRole().runsHost()) {
            hostModule.start();
        }
        if (context.getRole().runsClient()) {
            clientModule.start();
        }
        context.setLifecycleState(dev.multitode.bridge.shared.BridgeLifecycleState.RUNNING);
        LOGGER.i("Bridge started with lifecycle %s", context.getLifecycleState().name());
    }

    public void stop() {
        LOGGER.i("Stopping bridge with role %s", context.getRole().name());
        context.setLifecycleState(dev.multitode.bridge.shared.BridgeLifecycleState.STOPPING);
        if (context.getRole().runsHost()) {
            hostModule.stop();
        }
        if (context.getRole().runsClient()) {
            clientModule.stop();
        }
        sharedModule.stop();
        context.setLifecycleState(dev.multitode.bridge.shared.BridgeLifecycleState.STOPPED);
        LOGGER.i("Bridge stopped with lifecycle %s", context.getLifecycleState().name());
    }

    public BridgeContext getContext() {
        return context;
    }

    public SharedModule getSharedModule() {
        return sharedModule;
    }

    public ClientModule getClientModule() {
        return clientModule;
    }

    public HostModule getHostModule() {
        return hostModule;
    }
}
