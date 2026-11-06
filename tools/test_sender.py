#!/usr/bin/env python3
"""
Test sender for OpenCardboard. Streams ffmpeg's test pattern to the phone as a
world-locked virtual screen, so you can check link, decoding, lens mapping and
timewarp before the SteamVR driver exists.

Usage:
  python test_sender.py <phone-ip> [port] [ffmpeg-path] [kbps] [width] [height] [fps]

Defaults: 15000 kbps, 2560x1280, 60 fps.
Light test:      python test_sender.py <ip> 9000 <ffmpeg> 6000 1280 640 30
Ping-only test:  python test_sender.py <ip> 9000 <ffmpeg> 0      (no video, 30 s)
"""
import re, socket, struct, subprocess, sys, threading, time

MAGIC = 0x3143564F
HDR = struct.Struct("<IHHI")
T_HELLO, T_CONFIG, T_POSE, T_VIDEO, T_PING, T_PONG, T_KEYREQ = 1, 2, 3, 4, 5, 6, 7
wlock = threading.Lock()
hello = {"ev": threading.Event()}


def send(sock, t, payload=b""):
    with wlock:
        sock.sendall(HDR.pack(MAGIC, t, 0, len(payload)) + payload)


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise ConnectionError("connection closed")
        buf += c
    return buf


def reader(sock):
    last_print = 0.0
    try:
        while True:
            magic, t, _, ln = HDR.unpack(recv_exact(sock, HDR.size))
            if magic != MAGIC:
                raise ValueError("bad magic")
            p = recv_exact(sock, ln) if ln else b""
            if t == T_HELLO:
                v = struct.unpack("<4H5f8f", p[:60])
                hello["screen"] = v[1:3]
                hello["frusta"] = v[9:17]
                hello["ev"].set()
            elif t == T_PING:
                send(sock, T_PONG, p)
            elif t == T_PONG:
                rtt = (time.perf_counter_ns() - struct.unpack("<Q", p[:8])[0]) / 1e6
                if time.time() - last_print > 2:
                    print(f"round trip {rtt:.1f} ms")
                    last_print = time.time()
            elif t == T_KEYREQ:
                pass  # test stream sends a keyframe every second anyway
    except Exception as e:
        print("reader stopped:", e)


def pinger(sock):
    try:
        while True:
            time.sleep(1)
            send(sock, T_PING, struct.pack("<Q", time.perf_counter_ns()))
    except Exception:
        pass


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    host = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9000
    ffmpeg = sys.argv[3] if len(sys.argv) > 3 else "ffmpeg"
    kbps = int(sys.argv[4]) if len(sys.argv) > 4 else 15000
    W = int(sys.argv[5]) if len(sys.argv) > 5 else 2560
    H = int(sys.argv[6]) if len(sys.argv) > 6 else 1280
    FPS = int(sys.argv[7]) if len(sys.argv) > 7 else 60

    sock = socket.create_connection((host, port), timeout=10)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.settimeout(None)
    threading.Thread(target=reader, args=(sock,), daemon=True).start()
    if not hello["ev"].wait(5):
        print("No Hello from phone. Is the app open and in the foreground?")
        return
    print("Phone screen:", hello["screen"])

    if kbps <= 0:
        # Ping-only: no video at all, just measure round trips for 30 seconds.
        threading.Thread(target=pinger, args=(sock,), daemon=True).start()
        print("Ping-only test (no video) for 30 s...")
        time.sleep(30)
        print("Ping-only test finished.")
        return

    send(sock, T_CONFIG, struct.pack("<4B2H8f", 1, 0, 0, 0, W, H, *hello["frusta"]))
    threading.Thread(target=pinger, args=(sock,), daemon=True).start()

    cmd = [ffmpeg, "-loglevel", "error", "-re", "-f", "lavfi",
           "-i", f"testsrc2=size={W}x{H}:rate={FPS}",
           "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
           "-bf", "0", "-g", str(FPS), "-pix_fmt", "yuv420p",
           "-b:v", f"{kbps}k", "-maxrate", f"{kbps}k", "-bufsize", f"{max(kbps // FPS, 100)}k",
           "-x264-params", "aud=1:repeat-headers=1", "-f", "h264", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)

    aud = re.compile(b"\x00\x00\x01\x09")
    ident = struct.pack("<12f", 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)  # world-locked at identity
    buf, seq = b"", 0
    print(f"Streaming {W}x{H} @ {FPS} fps, {kbps} kbps... Ctrl+C to stop.")
    try:
        while True:
            chunk = proc.stdout.read1(1 << 16)
            if not chunk:
                break
            buf += chunk
            starts = [m.start() for m in aud.finditer(buf)]
            for a, b in zip(starts, starts[1:]):
                seq += 1
                send(sock, T_VIDEO, struct.pack("<II", seq, 0) + ident + buf[a:b])
            if len(starts) >= 2:
                buf = buf[starts[-1]:]
    except (KeyboardInterrupt, ConnectionError, OSError):
        pass
    finally:
        proc.kill()


if __name__ == "__main__":
    main()
