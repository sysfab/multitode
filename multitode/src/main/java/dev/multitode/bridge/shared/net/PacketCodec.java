package dev.multitode.bridge.shared.net;

import dev.multitode.bridge.shared.SessionRole;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;

public final class PacketCodec {
    private PacketCodec() {
    }

    public static void writeHello(DataOutputStream outputStream, HelloPacket packet) throws IOException {
        outputStream.writeInt(PacketType.HELLO.getId());
        outputStream.writeInt(packet.getProtocolVersion());
        outputStream.writeUTF(packet.getPlayerName());
        outputStream.writeUTF(packet.getRequestedRole().name());
        outputStream.flush();
    }

    public static HelloPacket readHello(DataInputStream inputStream) throws IOException {
        ensureType(inputStream, PacketType.HELLO);
        return readHelloPayload(inputStream);
    }

    public static HelloPacket readHelloPayload(DataInputStream inputStream) throws IOException {
        return new HelloPacket(
                inputStream.readInt(),
                inputStream.readUTF(),
                SessionRole.valueOf(inputStream.readUTF())
        );
    }

    public static void writeHelloAccepted(DataOutputStream outputStream, HelloAcceptedPacket packet) throws IOException {
        outputStream.writeInt(PacketType.HELLO_ACCEPTED.getId());
        outputStream.writeUTF(packet.getSessionId());
        outputStream.writeInt(packet.getPlayerId());
        outputStream.writeInt(packet.getSnapshotIntervalTicks());
        outputStream.flush();
    }

    public static HelloAcceptedPacket readHelloAccepted(DataInputStream inputStream) throws IOException {
        ensureType(inputStream, PacketType.HELLO_ACCEPTED);
        return readHelloAcceptedPayload(inputStream);
    }

    public static HelloAcceptedPacket readHelloAcceptedPayload(DataInputStream inputStream) throws IOException {
        return new HelloAcceptedPacket(
                inputStream.readUTF(),
                inputStream.readInt(),
                inputStream.readInt()
        );
    }

    public static void writeHelloRejected(DataOutputStream outputStream, HelloRejectedPacket packet) throws IOException {
        outputStream.writeInt(PacketType.HELLO_REJECTED.getId());
        outputStream.writeUTF(packet.getReason());
        outputStream.flush();
    }

    public static HelloRejectedPacket readHelloRejected(DataInputStream inputStream) throws IOException {
        ensureType(inputStream, PacketType.HELLO_REJECTED);
        return readHelloRejectedPayload(inputStream);
    }

    public static HelloRejectedPacket readHelloRejectedPayload(DataInputStream inputStream) throws IOException {
        return new HelloRejectedPacket(inputStream.readUTF());
    }

    public static void writeDisconnect(DataOutputStream outputStream, DisconnectPacket packet) throws IOException {
        outputStream.writeInt(PacketType.DISCONNECT.getId());
        outputStream.writeUTF(packet.getReason());
        outputStream.flush();
    }

    public static DisconnectPacket readDisconnect(DataInputStream inputStream) throws IOException {
        ensureType(inputStream, PacketType.DISCONNECT);
        return readDisconnectPayload(inputStream);
    }

    public static DisconnectPacket readDisconnectPayload(DataInputStream inputStream) throws IOException {
        return new DisconnectPacket(inputStream.readUTF());
    }

    public static void writePing(DataOutputStream outputStream, PingPacket packet) throws IOException {
        outputStream.writeInt(PacketType.PING.getId());
        outputStream.writeLong(packet.getSentAtMillis());
        outputStream.flush();
    }

    public static PingPacket readPing(DataInputStream inputStream) throws IOException {
        ensureType(inputStream, PacketType.PING);
        return readPingPayload(inputStream);
    }

    public static PingPacket readPingPayload(DataInputStream inputStream) throws IOException {
        return new PingPacket(inputStream.readLong());
    }

    public static void writeLuaMessage(DataOutputStream outputStream, LuaMessagePacket packet) throws IOException {
        outputStream.writeInt(PacketType.LUA_MESSAGE.getId());
        outputStream.writeUTF(packet.getMessageChannel());
        outputStream.writeUTF(packet.getMessageName());
        outputStream.writeInt(packet.getSenderPlayerId());
        outputStream.writeUTF(packet.getPayloadJson());
        outputStream.flush();
    }

    public static LuaMessagePacket readLuaMessage(DataInputStream inputStream) throws IOException {
        ensureType(inputStream, PacketType.LUA_MESSAGE);
        return readLuaMessagePayload(inputStream);
    }

    public static LuaMessagePacket readLuaMessagePayload(DataInputStream inputStream) throws IOException {
        return new LuaMessagePacket(
                inputStream.readUTF(),
                inputStream.readUTF(),
                inputStream.readInt(),
                inputStream.readUTF()
        );
    }

    public static PacketType readType(DataInputStream inputStream) throws IOException {
        return PacketType.fromId(inputStream.readInt());
    }

    private static void ensureType(DataInputStream inputStream, PacketType expectedType) throws IOException {
        PacketType actualType = readType(inputStream);
        if (actualType != expectedType) {
            throw new IOException("Expected packet " + expectedType + " but received " + actualType);
        }
    }
}
