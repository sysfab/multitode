package dev.multitode.bridge.shared;

import java.util.Objects;

public final class SessionConfig {
    private SessionRole role = SessionRole.HOST_AND_CLIENT;
    private boolean autoStart;
    private boolean autoConnect;
    private final PlayerConfig player = new PlayerConfig();
    private final NetworkConfig network = new NetworkConfig();
    private final SyncConfig sync = new SyncConfig();
    private final DebugConfig debug = new DebugConfig();

    public SessionConfig copy() {
        SessionConfig copy = new SessionConfig();
        copy.setRole(role);
        copy.setAutoStart(autoStart);
        copy.setAutoConnect(autoConnect);
        copy.getPlayer().setName(player.getName());
        copy.getNetwork().setHost(network.getHost());
        copy.getNetwork().setPort(network.getPort());
        copy.getNetwork().setListenPort(network.getListenPort());
        copy.getSync().setSnapshotIntervalTicks(sync.getSnapshotIntervalTicks());
        copy.getDebug().setVerboseLogging(debug.isVerboseLogging());
        copy.getDebug().setLogCommands(debug.isLogCommands());
        copy.getDebug().setLogDesyncs(debug.isLogDesyncs());
        return copy;
    }

    public SessionRole getRole() {
        return role;
    }

    public void setRole(SessionRole role) {
        this.role = Objects.requireNonNull(role, "role");
    }

    public void setRoleName(String roleName) {
        if (roleName == null || roleName.isBlank()) {
            this.role = SessionRole.HOST_AND_CLIENT;
            return;
        }

        this.role = SessionRole.valueOf(roleName.trim().toUpperCase());
    }

    public boolean isAutoStart() {
        return autoStart;
    }

    public void setAutoStart(boolean autoStart) {
        this.autoStart = autoStart;
    }

    public boolean isAutoConnect() {
        return autoConnect;
    }

    public void setAutoConnect(boolean autoConnect) {
        this.autoConnect = autoConnect;
    }

    public PlayerConfig getPlayer() {
        return player;
    }

    public NetworkConfig getNetwork() {
        return network;
    }

    public SyncConfig getSync() {
        return sync;
    }

    public DebugConfig getDebug() {
        return debug;
    }

    public String describe() {
        return "role=" + role.name()
                + ", player=" + player.getName()
                + ", host=" + network.getHost()
                + ":" + network.getPort()
                + ", listenPort=" + network.getListenPort()
                + ", autoStart=" + autoStart
                + ", autoConnect=" + autoConnect
                + ", snapshotIntervalTicks=" + sync.getSnapshotIntervalTicks()
                + ", verboseLogging=" + debug.isVerboseLogging()
                + ", logCommands=" + debug.isLogCommands()
                + ", logDesyncs=" + debug.isLogDesyncs();
    }

    public String getValidationError() {
        if (role == null) {
            return "role must be set";
        }

        if (player.getName() == null || player.getName().isBlank()) {
            return "player name must not be blank";
        }

        if (player.getName().length() > 32) {
            return "player name must be at most 32 characters";
        }

        if (network.getHost() == null || network.getHost().isBlank()) {
            return "host must not be blank";
        }

        if (network.getPort() < 1 || network.getPort() > 65535) {
            return "port must be between 1 and 65535";
        }

        if (network.getListenPort() < 1 || network.getListenPort() > 65535) {
            return "listenPort must be between 1 and 65535";
        }

        if (sync.getSnapshotIntervalTicks() < 1 || sync.getSnapshotIntervalTicks() > 36000) {
            return "snapshotIntervalTicks must be between 1 and 36000";
        }

        if (autoConnect && !role.runsClient()) {
            return "autoConnect requires a role that runs a client";
        }

        return null;
    }

    public boolean isValid() {
        return getValidationError() == null;
    }
}
