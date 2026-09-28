package dev.multitode.bridge.shared;

public final class PlayerConfig {
    private String name = "Player";

    public String getName() {
        return name;
    }

    public void setName(String name) {
        if (name == null || name.isBlank()) {
            this.name = "Player";
            return;
        }

        this.name = name.trim();
    }
}
