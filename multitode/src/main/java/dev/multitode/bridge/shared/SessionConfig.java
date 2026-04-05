package dev.multitode.bridge.shared;

import java.util.Objects;

public final class SessionConfig {
    private SessionRole role = SessionRole.HOST_AND_CLIENT;
    private final PlayerConfig player = new PlayerConfig();
    private final NetworkConfig network = new NetworkConfig();

    public SessionConfig copy() {
        SessionConfig copy = new SessionConfig();
        copy.setRole(role);
        copy.getPlayer().setName(player.getName());
        copy.getNetwork().setHost(network.getHost());
        copy.getNetwork().setPort(network.getPort());
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

    public PlayerConfig getPlayer() {
        return player;
    }

    public NetworkConfig getNetwork() {
        return network;
    }

    public String describe() {
        return "role=" + role.name()
                + ", player=" + player.getName()
                + ", host=" + network.getHost()
                + ":" + network.getPort();
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

        return null;
    }

    public boolean isValid() {
        return getValidationError() == null;
    }
}
