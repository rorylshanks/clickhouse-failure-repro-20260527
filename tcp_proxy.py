#!/usr/bin/env python3

import argparse
import selectors
import signal
import socket
import struct
import threading


class Proxy:
    def __init__(self, listen_host, listen_port, target_host, target_port, control_port):
        self.listen_host = listen_host
        self.listen_port = listen_port
        self.target_host = target_host
        self.target_port = target_port
        self.control_port = control_port
        self.listener = None
        self.listener_lock = threading.Lock()
        self.accepting_new = True
        self.stop_event = threading.Event()

    def serve(self):
        signal.signal(signal.SIGTERM, lambda *_: self.stop_event.set())
        signal.signal(signal.SIGINT, lambda *_: self.stop_event.set())

        self.listener = self._make_listener(self.listen_port)
        control = self._make_listener(self.control_port)

        threading.Thread(target=self._accept_data, daemon=True).start()
        threading.Thread(target=self._accept_control, args=(control,), daemon=True).start()

        self.stop_event.wait()

    def _make_listener(self, port):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((self.listen_host, port))
        sock.listen()
        print(f"listening on {self.listen_host}:{port}", flush=True)
        return sock

    def _accept_data(self):
        while not self.stop_event.is_set():
            with self.listener_lock:
                listener = self.listener

            if listener is None:
                self.stop_event.wait(0.1)
                continue

            try:
                client, _ = listener.accept()
            except OSError:
                continue

            if not self.accepting_new:
                self._reset(client)
                continue

            threading.Thread(target=self._handle_data, args=(client,), daemon=True).start()

    def _accept_control(self, control):
        while not self.stop_event.is_set():
            try:
                client, _ = control.accept()
            except OSError:
                continue

            with client:
                command = client.recv(1024).decode(errors="replace").strip()
                if command == "close_listener":
                    self.close_listener()
                    client.sendall(b"closed\n")
                elif command == "reject_new":
                    self.accepting_new = False
                    client.sendall(b"rejecting\n")
                elif command == "stop":
                    self.stop_event.set()
                    client.sendall(b"stopping\n")
                else:
                    client.sendall(b"unknown\n")

    def close_listener(self):
        with self.listener_lock:
            if self.listener is not None:
                try:
                    self.listener.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                self.listener.close()
                self.listener = None
                print("data listener closed; existing connections remain open", flush=True)

    def _reset(self, client):
        linger = struct.pack("ii", 1, 0)
        client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, linger)
        client.close()
        print("rejected new data connection", flush=True)

    def _handle_data(self, client):
        try:
            upstream = socket.create_connection((self.target_host, self.target_port), timeout=10)
        except OSError:
            client.close()
            return

        with client, upstream:
            self._forward_pair(client, upstream)

    def _forward_pair(self, left, right):
        sel = selectors.DefaultSelector()
        left.setblocking(False)
        right.setblocking(False)
        sel.register(left, selectors.EVENT_READ, right)
        sel.register(right, selectors.EVENT_READ, left)

        while not self.stop_event.is_set():
            events = sel.select(1)
            if not events:
                continue

            for key, _ in events:
                src = key.fileobj
                dst = key.data
                try:
                    data = src.recv(65536)
                except OSError:
                    return

                if not data:
                    return

                try:
                    dst.sendall(data)
                except OSError:
                    return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--listen-port", required=True, type=int)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", required=True, type=int)
    parser.add_argument("--control-port", required=True, type=int)
    args = parser.parse_args()

    Proxy(
        args.listen_host,
        args.listen_port,
        args.target_host,
        args.target_port,
        args.control_port,
    ).serve()


if __name__ == "__main__":
    main()
