package dev.multitode.bridge.shared;

import java.util.Objects;

public abstract class AbstractBridgeModule implements BridgeModule {
    private final BridgeContext context;

    protected AbstractBridgeModule(BridgeContext context) {
        this.context = Objects.requireNonNull(context, "context");
    }

    protected final BridgeContext getContext() {
        return context;
    }
}
