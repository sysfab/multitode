package dev.multitode.bridge.shared;

public interface BridgeModule {
    ModuleKind getKind();

    void start();

    void stop();
}
