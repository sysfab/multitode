package dev.multitode.bridge.shared;

import dev.multitode.bridge.shared.net.SessionRegistry;

import java.util.Objects;

public final class BridgeContext {
    private final SessionConfig sessionConfig;
    private final SessionRegistry sessionRegistry;
    private BridgeLifecycleState lifecycleState;

    public BridgeContext(SessionConfig sessionConfig) {
        this.sessionConfig = Objects.requireNonNull(sessionConfig, "sessionConfig");
        this.sessionRegistry = new SessionRegistry();
        this.lifecycleState = BridgeLifecycleState.CREATED;
    }

    public SessionConfig getSessionConfig() {
        return sessionConfig;
    }

    public SessionRole getRole() {
        return sessionConfig.getRole();
    }

    public SessionRegistry getSessionRegistry() {
        return sessionRegistry;
    }

    public BridgeLifecycleState getLifecycleState() {
        return lifecycleState;
    }

    public void setLifecycleState(BridgeLifecycleState lifecycleState) {
        this.lifecycleState = Objects.requireNonNull(lifecycleState, "lifecycleState");
    }
}
