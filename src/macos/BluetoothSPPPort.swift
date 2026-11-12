import Foundation
@preconcurrency import IOBluetooth

/// Direct SPP transport for the paired HC-06. It never opens /dev/cu.HC-06,
/// avoiding the virtual-serial driver close path observed to block on the Mac.
@MainActor
final class BluetoothSPPPort: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var channel: IOBluetoothRFCOMMChannel?
    private var pending = Data()
    private var inFlight: NSMutableData?
    private var sentAt: Date?
    private var opened = false
    private var closed = false
    private let began = Date()
    private var lastReceived: Date?

    var isReusable: Bool {
        guard !closed else { return false }
        if !opened { return Date().timeIntervalSince(began) < 20 }
        return channel?.isOpen() == true && Date().timeIntervalSince(lastReceived ?? began) < 15
    }
    private var timer: Timer?
    private let onData: (Data) -> Void
    private let onError: (String) -> Void

    static func isHC06Path(_ path: String) -> Bool {
        let tail = (path as NSString).lastPathComponent
        let name = tail.hasPrefix("cu.") ? String(tail.dropFirst(3)) : tail.hasPrefix("tty.") ? String(tail.dropFirst(4)) : tail
        return name.lowercased().filter { $0.isLetter || $0.isNumber } == "hc06"
    }

    init(onData: @escaping (Data) -> Void, onError: @escaping (String) -> Void) throws {
        self.onData = onData
        self.onError = onError
        super.init()
        let devices = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).filter {
            ($0.name ?? "").lowercased().filter { $0.isLetter || $0.isNumber } == "hc06"
        }
        guard devices.count == 1, let device = devices.first else {
            throw SerialPort.Failure("Pair exactly one HC-06 in macOS Bluetooth settings before connecting")
        }
        var id: BluetoothRFCOMMChannelID = 0
        guard let service = device.getServiceRecord(for: IOBluetoothSDPUUID.uuid16(0x1101)),
              service.getRFCOMMChannelID(&id) == 0, id > 0 else {
            throw SerialPort.Failure("HC-06 Serial Port service unavailable; check Bluetooth pairing")
        }
        let result = device.openRFCOMMChannelAsync(&channel, withChannelID: id, delegate: self)
        guard result == 0 else { throw SerialPort.Failure("HC-06 Bluetooth open failed (\(result))") }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func write(_ data: Data) {
        guard !closed else { return }
        guard pending.count + (inFlight?.length ?? 0) + data.count <= 262_144 else {
            fail("HC-06 output too slow; check receiver UART speed")
            return
        }
        pending.append(data)
        pump()
    }

    func discardPendingOutput() { pending.removeAll() }

    private func tick() {
        guard !closed else { return }
        if !opened && Date().timeIntervalSince(began) > 20 {
            fail("HC-06 Bluetooth connection timed out")
        } else if let sentAt, Date().timeIntervalSince(sentAt) > 15 {
            fail("HC-06 Bluetooth write timed out")
        } else { pump() }
    }

    private func pump() {
        guard !closed, opened, inFlight == nil, !pending.isEmpty, let channel,
              !channel.isTransmissionPaused() else { return }
        let length = min(pending.count, max(1, Int(channel.getMTU())))
        let bytes = NSMutableData(data: Data(pending.prefix(length)))
        pending.removeFirst(length)
        inFlight = bytes
        sentAt = Date()
        let result = channel.writeAsync(bytes.mutableBytes, length: UInt16(length), refcon: nil)
        if result != 0 {
            inFlight = nil; sentAt = nil
            fail("HC-06 Bluetooth write failed (\(result))")
        }
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        close()
        onError(message)
    }

    @discardableResult
    func close() -> IOReturn {
        guard !closed else { return 0 }
        closed = true
        timer?.invalidate(); timer = nil
        pending.removeAll()
        let current = channel
        _ = current?.setDelegate(nil)
        let status = current?.close() ?? 0
        channel = nil
        inFlight = nil; sentAt = nil
        return status
    }

    nonisolated func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.closed else { _ = channel?.close(); return }
            guard error == 0 else { self.fail("HC-06 Bluetooth connection failed (\(error))"); return }
            self.channel = channel
            self.opened = true
            self.pump()
        }
    }

    nonisolated func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard length > 0, let pointer else { return }
        // The driver's pointer is valid only during this delegate call.
        let data = Data(bytes: pointer, count: length)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.lastReceived = Date()
            self.onData(data)
        }
    }

    nonisolated func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.inFlight = nil; self.sentAt = nil
            guard error == 0 else { self.fail("HC-06 Bluetooth write failed (\(error))"); return }
            self.pump()
        }
    }

    nonisolated func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.fail("HC-06 Bluetooth receiver disconnected")
        }
    }

    nonisolated func rfcommChannelFlowControlChanged(_ channel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { [weak self] in self?.pump() }
    }
    nonisolated func rfcommChannelQueueSpaceAvailable(_ channel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { [weak self] in self?.pump() }
    }
}
