"""Reusable desktop serial/Bluetooth links; paused sessions drain input silently."""
import queue
import threading
import time


class SerialReceiverHub:
    def __init__(self, factory=None):
        self.factory = factory
        self.devices = {}
        self.active = False
        self.failure = None
        self.events = queue.Queue(maxsize=64)
        self.lock = threading.RLock()
        self.closed = threading.Event()
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def configure(self, ports):
        self.pause()
        import serial
        factory = self.factory or serial.Serial
        desired = dict(ports)
        with self.lock:
            for path, entry in list(self.devices.items()):
                device, baud, failed = entry
                if path not in desired or desired[path] != baud or failed or not device.is_open:
                    device.close()
                    del self.devices[path]
            for path, baud in ports:
                if path not in self.devices:
                    self.devices[path] = [factory(path, baud, timeout=0, write_timeout=1,
                                                  rtscts=False, dsrdtr=False), baud, False]
            self.failure = None
            self.active = True
            return [self.devices[path][0] for path, _ in ports]

    def pause(self):
        self.active = False
        while True:
            try: self.events.get_nowait()
            except queue.Empty: break

    def poll(self):
        if not self.active:
            return []
        if self.failure:
            raise OSError(self.failure)
        result = []
        for _ in range(64):
            try: result.append(self.events.get_nowait())
            except queue.Empty: break
        return result

    def _read(self):
        while not self.closed.wait(.02):
            with self.lock:
                entries = list(self.devices.items())
            for path, entry in entries:
                device, _, failed = entry
                if failed: continue
                try:
                    waiting = device.in_waiting
                    if waiting:
                        data = device.read(min(waiting, 4096))
                        if data and self.active:
                            try: self.events.put_nowait(("Serial / Bluetooth · " + path, data))
                            except queue.Full:
                                self.failure = "Receiver monitor is too slow: " + path
                except Exception as error:
                    with self.lock:
                        if self.devices.get(path) is entry:
                            entry[2] = True
                            self.failure = f"Receiver {path}: {error}"

    def disconnect(self):
        self.pause()
        with self.lock:
            entries = list(self.devices.values())
            self.devices.clear()
        for device, _, _ in entries:
            try: device.close()
            except OSError: pass
        self.failure = None

    def close(self):
        self.closed.set()
        self.disconnect()
