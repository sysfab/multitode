package dev.multitode.bridge;

import dev.multitode.bridge.client.ClientModule;
import dev.multitode.bridge.host.HostModule;
import dev.multitode.bridge.shared.BridgeContext;
import dev.multitode.bridge.shared.BridgeLifecycleState;
import dev.multitode.bridge.shared.SessionConfig;
import dev.multitode.bridge.shared.SessionRole;
import dev.multitode.bridge.shared.SharedModule;

public final class Bridge {
    private static final String VERSION = "v0.2";

    private final BridgeContext context;
    private final SharedModule sharedModule;
    private final ClientModule clientModule;
    private final HostModule hostModule;

    private Bridge(SessionConfig sessionConfig) {
        this.context = new BridgeContext(sessionConfig.copy());
        this.sharedModule = new SharedModule(context);
        this.clientModule = new ClientModule(context);
        this.hostModule = new HostModule(context);
    }

    public static Bridge create(SessionConfig sessionConfig) {
        return new Bridge(sessionConfig);
    }

    public void start() {
        context.setLifecycleState(BridgeLifecycleState.STARTING);
        sharedModule.start();
        if (context.getRole() == SessionRole.HOST_AND_CLIENT) {
            hostModule.start();
        }
        clientModule.start();
        context.setLifecycleState(BridgeLifecycleState.RUNNING);
    }

    public void stop() {
        context.setLifecycleState(BridgeLifecycleState.STOPPING);
        clientModule.stop();
        if (context.getRole() == SessionRole.HOST_AND_CLIENT) {
            hostModule.stop();
        }
        sharedModule.stop();
        context.setLifecycleState(BridgeLifecycleState.STOPPED);
    }

    public static String getVersion() {
        return VERSION;
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
