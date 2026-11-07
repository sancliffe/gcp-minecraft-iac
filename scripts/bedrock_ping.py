import socket, struct, sys, time

host = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 19132
MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")
ping = b"\x01" + struct.pack(">Q", int(time.time() * 1000)) + MAGIC + struct.pack(">Q", 1)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
for attempt in range(3):
    s.sendto(ping, (host, port))
    try:
        data, _ = s.recvfrom(2048)
    except socket.timeout:
        continue
    if data[0] == 0x1C:
        print("OPEN. Server replied:")
        print(data[35:35 + struct.unpack(">H", data[33:35])[0]].decode(errors="replace"))
        sys.exit(0)
print("No reply: UDP %d is blocked, the server is down, or the address is wrong." % port)
sys.exit(1)