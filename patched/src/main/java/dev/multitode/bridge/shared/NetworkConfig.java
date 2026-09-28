package dev.multitode.bridge.shared;

public final class NetworkConfig {
    private String host = "0.0.0.0";
    private int port = 24812;

    public String getHost() {
        return host;
    }

    public void setHost(String host) {
        if (host == null || host.isBlank()) {
            this.host = "0.0.0.0";
            return;
        }

        this.host = host.trim();
    }

    public int getPort() {
        return port;
    }

    public void setPort(int port) {
        if (port <= 0) {
            this.port = 24812;
            return;
        }

        this.port = port;
    }
}
