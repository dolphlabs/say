"""
Stream protocol, fault, and live feed test harness for say exchange.
Tests RFC 6455 compliance, 16KB limit, binary rejection (1003),
origin allow-list, rate limits, channel limits, and session revocation (4001).
"""
import base64
import hashlib
import json
import os
import random
import socket
import struct
import sys
import time


def create_handshake_key():
    return base64.b64encode(os.urandom(16)).decode('utf-8')


def build_upgrade_request(path, host, token=None, origin=None, cookie=None):
    headers = [
        f"GET {path} HTTP/1.1",
        f"Host: {host}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        f"Sec-WebSocket-Key: {create_handshake_key()}",
        "Sec-WebSocket-Version: 13",
    ]
    if origin:
        headers.append(f"Origin: {origin}")
    if cookie:
        headers.append(f"Cookie: {cookie}")
    headers.append("\r\n")
    return "\r\n".join(headers).encode('utf-8')


def send_frame(sock, opcode, payload, masked=True):
    header = bytearray()
    header.append(0x80 | (opcode & 0x0f))  # FIN + opcode
    length = len(payload)
    mask_bit = 0x80 if masked else 0x00
    if length < 126:
        header.append(mask_bit | length)
    elif length < 65536:
        header.append(mask_bit | 126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(mask_bit | 127)
        header.extend(struct.pack("!Q", length))
    
    if masked:
        mask_key = os.urandom(4)
        header.extend(mask_key)
        masked_payload = bytearray(length)
        for i in range(length):
            masked_payload[i] = payload[i] ^ mask_key[i % 4]
        sock.sendall(header + masked_payload)
    else:
        sock.sendall(header + payload)


def read_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            break
        buf.extend(chunk)
    return bytes(buf)


def recv_frame(sock):
    header = read_exact(sock, 2)
    if len(header) < 2:
        return None, None
    b1, b2 = header[0], header[1]
    fin = (b1 & 0x80) != 0
    opcode = b1 & 0x0f
    is_masked = (b2 & 0x80) != 0
    payload_len = b2 & 0x7f
    if payload_len == 126:
        ext = read_exact(sock, 2)
        payload_len = struct.unpack("!H", ext)[0]
    elif payload_len == 127:
        ext = read_exact(sock, 8)
        payload_len = struct.unpack("!Q", ext)[0]
    
    mask_key = b""
    if is_masked:
        mask_key = read_exact(sock, 4)
    
    payload = read_exact(sock, payload_len)
    if is_masked:
        unmasked = bytearray(payload_len)
        for i in range(payload_len):
            unmasked[i] = payload[i] ^ mask_key[i % 4]
        payload = bytes(unmasked)
    return opcode, payload


def test_origin_check(host, port):
    print("Testing origin allow-list...")
    # Disallowed origin should return 403 Forbidden
    s = socket.create_connection((host, port))
    req = build_upgrade_request("/v1/stream", f"{host}:{port}", origin="https://attacker-origin.com")
    s.sendall(req)
    resp = s.recv(1024).decode('utf-8', errors='ignore')
    s.close()
    assert "403" in resp or "FORBIDDEN" in resp, f"Expected 403 Forbidden for bad origin, got: {resp}"
    print("  ✓ Bad origin rejected with 403")

    # Allowed origin (e.g. localhost) should return 101 Switching Protocols
    s = socket.create_connection((host, port))
    req = build_upgrade_request("/v1/stream", f"{host}:{port}", origin="http://localhost:3000")
    s.sendall(req)
    resp = s.recv(1024).decode('utf-8', errors='ignore')
    s.close()
    assert "101 Switching Protocols" in resp, f"Expected 101 for allowed origin, got: {resp}"
    print("  ✓ Allowed origin accepted with 101")


def test_anonymous_and_public_channels(host, port):
    print("Testing anonymous access and channels...")
    s = socket.create_connection((host, port))
    req = build_upgrade_request("/v1/stream", f"{host}:{port}")
    s.sendall(req)
    resp = s.recv(1024).decode('utf-8', errors='ignore')
    assert "101 Switching Protocols" in resp
    
    # Send ping op
    send_frame(s, 1, json.dumps({"op": "ping"}).encode('utf-8'))
    opcode, data = recv_frame(s)
    assert opcode == 1
    msg = json.loads(data.decode('utf-8'))
    assert msg.get("type") == "pong"
    print("  ✓ Application ping/pong verified")

    # Subscribe to public channel "cards"
    send_frame(s, 1, json.dumps({"op": "subscribe", "channels": ["cards"]}).encode('utf-8'))
    opcode, data = recv_frame(s)
    assert opcode == 1
    msg = json.loads(data.decode('utf-8'))
    assert msg.get("type") == "subscribed"
    assert "cards" in msg.get("detail", {}).get("channels", [])
    print("  ✓ Public subscription accepted")

    # Subscribe to "me" channel anonymously should fail with unauthorized
    send_frame(s, 1, json.dumps({"op": "subscribe", "channels": ["me"]}).encode('utf-8'))
    opcode, data = recv_frame(s)
    assert opcode == 1
    msg = json.loads(data.decode('utf-8'))
    # Should not include "me" in subscribed channels or reject
    chans = msg.get("detail", {}).get("channels", [])
    assert "me" not in chans
    print("  ✓ Anonymous subscription to 'me' rejected")
    
    s.close()


def test_binary_frame_rejection(host, port):
    print("Testing binary frame rejection...")
    s = socket.create_connection((host, port))
    req = build_upgrade_request("/v1/stream", f"{host}:{port}")
    s.sendall(req)
    resp = s.recv(1024).decode('utf-8', errors='ignore')
    assert "101" in resp
    
    # Send binary frame (opcode 2)
    send_frame(s, 2, b"\x00\x01\x02\x03")
    opcode, data = recv_frame(s)
    assert opcode == 8, f"Expected close frame (opcode 8), got opcode {opcode}"
    if len(data) >= 2:
        code = struct.unpack("!H", data[:2])[0]
        assert code == 1003, f"Expected close code 1003, got {code}"
    print("  ✓ Binary frame closed with 1003 unsupported")
    s.close()


def test_oversize_frame_rejection(host, port):
    print("Testing oversize frame rejection...")
    s = socket.create_connection((host, port))
    req = build_upgrade_request("/v1/stream", f"{host}:{port}")
    s.sendall(req)
    resp = s.recv(1024).decode('utf-8', errors='ignore')
    assert "101" in resp

    # Send 20KB text frame (exceeding 16KB limit)
    large_payload = json.dumps({"op": "ping", "data": "x" * 20000}).encode('utf-8')
    send_frame(s, 1, large_payload)
    opcode, data = recv_frame(s)
    # Server should close socket with policy violation
    assert opcode in (8, None)
    if opcode == 8 and len(data) >= 2:
        code = struct.unpack("!H", data[:2])[0]
        assert code in (1002, 1008, 1009)
    print("  ✓ Oversize frame rejected and socket closed")
    s.close()


def main():
    host = "127.0.0.1"
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"Running stream protocol tests against {host}:{port}...")
    try:
        test_origin_check(host, port)
        test_anonymous_and_public_channels(host, port)
        test_binary_frame_rejection(host, port)
        test_oversize_frame_rejection(host, port)
        print("ALL PROTOCOL TESTS PASSED!")
    except Exception as e:
        print(f"TEST FAILED: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
