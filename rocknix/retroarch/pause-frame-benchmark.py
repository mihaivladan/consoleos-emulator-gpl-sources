#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import json
import os
import re
import socket
import sys
import time


def png_complete(path):
    try:
        if os.path.getsize(path) < 20:
            return False
        with open(path, "rb") as image:
            if image.read(8) != b"\x89PNG\r\n\x1a\n":
                return False
            image.seek(-12, os.SEEK_END)
            return image.read(12) == b"\0\0\0\0IEND\xaeB`\x82"
    except OSError:
        return False


def png_state(directory):
    state = {}
    for entry in os.scandir(directory):
        if entry.is_file() and entry.name.lower().endswith(".png"):
            stat = entry.stat()
            state[entry.path] = [stat.st_ino, stat.st_size, stat.st_mtime_ns]
    return state


def udp_request(host, port, request, expected):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.connect((host, int(port)))
        client.sendall((request + "\n").encode("ascii"))
        if expected == "-":
            return
        client.settimeout(5.0)
        try:
            reply = client.recv(4096).decode("ascii").strip()
        except socket.timeout:
            raise SystemExit(f"no reply for: {request}")
    if re.fullmatch(expected, reply) is None:
        raise SystemExit(f"unexpected reply for {request!r}: {reply!r}")
    print(reply)


def wait_png(directory, snapshot_path):
    with open(snapshot_path, encoding="utf-8") as snapshot_file:
        before = json.load(snapshot_file)
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        for path, current in png_state(directory).items():
            if current != before.get(path) and png_complete(path):
                print(path)
                return
        time.sleep(0.01)
    raise SystemExit("SCREENSHOT did not publish a complete PNG with IEND")


def main():
    if len(sys.argv) == 6 and sys.argv[1] == "udp":
        udp_request(*sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "snapshot":
        with open(sys.argv[3], "w", encoding="utf-8") as output:
            json.dump(png_state(sys.argv[2]), output)
    elif len(sys.argv) == 4 and sys.argv[1] == "wait-png":
        wait_png(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit("invalid benchmark helper invocation")


if __name__ == "__main__":
    main()
