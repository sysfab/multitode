package dev.multitode.bridge.shared.net;

public enum PacketType {
    HELLO(1),
    HELLO_ACCEPTED(2),
    HELLO_REJECTED(3),
    DISCONNECT(4),
    PING(5),
    LUA_MESSAGE(6);

    private final int id;

    PacketType(int id) {
        this.id = id;
    }

    public int getId() {
        return id;
    }

    public static PacketType fromId(int id) {
        for (PacketType value : values()) {
            if (value.id == id) {
                return value;
            }
        }

        throw new IllegalArgumentException("Unknown packet type id: " + id);
    }
}
