package dev.multitode.bridge.shared;

import com.prineside.tdi2.utils.logging.TLog;

public final class SharedModule extends AbstractBridgeModule {
    private static final TLog LOGGER = TLog.forTag("multitode/SharedModule");

    public SharedModule(BridgeContext context) {
        super(context);
    }

    @Override
    public ModuleKind getKind() {
        return ModuleKind.SHARED;
    }

    @Override
    public void start() {
        LOGGER.i("Shared module start for role %s", getContext().getRole().name());
    }

    @Override
    public void stop() {
        LOGGER.i("Shared module stop for role %s", getContext().getRole().name());
    }
}
