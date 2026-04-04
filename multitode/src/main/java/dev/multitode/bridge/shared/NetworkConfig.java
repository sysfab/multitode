package dev.multitode.bridge.shared;

public final class NetworkConfig {
    private String host = "127.0.0.1";
    private int port = 24812;
    private int listenPort = 24812;

    public String getHost() {
        return host;
    }

    public void setHost(String host) {
        if (host == null || host.isBlank()) {
            this.host = "127.0.0.1";
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

    public int getListenPort() {
        return listenPort;
    }

    public void setListenPort(int listenPort) {
        if (listenPort <= 0) {
            this.listenPort = 24812;
            return;
        }

        this.listenPort = listenPort;
    }
}
