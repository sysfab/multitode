package dev.multitode.bridge.shared;

public enum SessionRole {
    CLIENT,
    HOST,
    HOST_AND_CLIENT;

    public boolean runsClient() {
        return this == CLIENT || this == HOST_AND_CLIENT;
    }

    public boolean runsHost() {
        return this == HOST || this == HOST_AND_CLIENT;
    }
}
