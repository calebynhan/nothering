#!/usr/bin/env python3
# A SOCKS5 proxy that leads nowhere, for scripts/ci/probe-offline-network.sh: it accepts every
# CONNECT, writes down what it was asked for, and answers any HTTP request itself. With it the
# probe sees whether a program followed the system's proxy setting, and whether it sent the name
# or looked it up first, on a machine with no network to reach anything real.
#   scripts/ci/fake-socks.py <port> <log file>
import socket
import sys
import threading

BODY = b"the stand-in network carried this\n"


def read_exactly(connection, count):
    data = b""
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk:
            raise ConnectionError("closed early")
        data += chunk
    return data


def serve(connection, log):
    try:
        connection.settimeout(10)
        version, method_count = read_exactly(connection, 2)
        read_exactly(connection, method_count)
        if version != 5:
            return
        connection.sendall(b"\x05\x00")
        version, command, _, address_type = read_exactly(connection, 4)
        if address_type == 1:
            target = "address " + socket.inet_ntoa(read_exactly(connection, 4))
        elif address_type == 3:
            target = "name " + read_exactly(connection, read_exactly(connection, 1)[0]).decode("ascii", "replace")
        elif address_type == 4:
            target = "address " + socket.inet_ntop(socket.AF_INET6, read_exactly(connection, 16))
        else:
            return
        port = int.from_bytes(read_exactly(connection, 2), "big")
        with open(log, "a") as file:
            file.write(f"command {command} to {target} port {port}\n")
        if command != 1:
            connection.sendall(b"\x05\x07\x00\x01" + bytes(6))
            return
        connection.sendall(b"\x05\x00\x00\x01" + bytes(6))
        request = b""
        while b"\r\n\r\n" not in request and len(request) < 65536:
            chunk = connection.recv(4096)
            if not chunk:
                return
            request += chunk
        connection.sendall(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: "
            + str(len(BODY)).encode()
            + b"\r\n\r\n"
            + BODY
        )
    except (OSError, ValueError):
        pass
    finally:
        connection.close()


def main():
    port, log = int(sys.argv[1]), sys.argv[2]
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(16)
    open(log, "a").close()
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=serve, args=(connection, log), daemon=True).start()


if __name__ == "__main__":
    main()
