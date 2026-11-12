import Foundation

@main struct MonitorCheck {
    static func msmPacket(code: Int, cnr: Int) -> Data {
        var bits: [UInt8] = []
        func add(_ value: UInt64, _ width: Int) {
            for bit in (0..<width).reversed() { bits.append(UInt8((value >> bit) & 1)) }
        }
        func signed(_ value: Int, _ width: Int) { add(UInt64(bitPattern: Int64(value)), width) }
        add(1077, 12); add(1, 12); add(0, 49)
        add(UInt64(1) << 63, 64); add(1 << 30, 32); add(1, 1)
        add(70, 8); add(0, 4); add(512, 10); signed(-23, 14)
        signed(code, 20); signed(-200, 24); add(0, 10); add(0, 1)
        add(UInt64(cnr), 10); signed(1250, 15)
        while bits.count % 8 != 0 { bits.append(0) }
        var payload: [UInt8] = []
        for i in stride(from: 0, to: bits.count, by: 8) {
            payload.append(bits[i..<i+8].reduce(0) { ($0 << 1) | $1 })
        }
        var packet: [UInt8] = [0xd3, UInt8(payload.count >> 8), UInt8(payload.count & 255)] + payload
        var crc: UInt32 = 0
        for byte in packet {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x1000000 != 0 { crc ^= 0x1864cfb }
            }
        }
        packet += [UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)]
        return Data(packet)
    }

    @MainActor static func main() async throws {
        precondition(BluetoothSPPPort.isHC06Path("/dev/cu.HC-06"))
        precondition(BluetoothSPPPort.isHC06Path("/dev/tty.HC-06"))
        precondition(!BluetoothSPPPort.isHC06Path("/dev/cu.usbserial"))
        precondition(!BluetoothSPPPort.isHC06Path("/dev/cu.Bluetooth-Incoming-Port"))
        try await WindowLayoutChecks.run()
        try await SerialPortChecks.run()
        RoverMapChecks.run()
        var incoming = RTCMDecoder()
        let generation = UUID()
        var model = RTCMMonitorState()
        var raw = StreamMonitorSnapshot()
        incoming.receive(msmPacket(code: 100, cnr: 643))
        model.update(incoming, generation: generation)
        precondition(model.selectedType == 1077 && model.displayedFrame != nil, "First valid type must display details immediately")
        model.selectType(1077)
        precondition(!model.paused, "Selecting a type must not pause live details")
        let original = try model.displayedFrame!.measurements()[0]
        precondition(abs(original.cnr! - 40.1875) < 1e-8)
        precondition(abs(original.pseudorange! - (70.5 + 100 * pow(2, -29)) * 299_792.458) < 1e-6)

        // A burst of receiver traffic must not invalidate decoder controls.
        for i in 0..<200 {
            raw.update(status: "Receiving", count: 1, recent: Data([0xd3]),
                       receivers: ["Bluetooth": Data("$GPGGA,\(i)\r\n".utf8)], receiverCounts: ["Bluetooth": i * 20])
            precondition(!model.needsUpdate(incoming, generation: generation))
            precondition(model.selectedType == 1077 && model.displayedFrame?.id == 1)
        }
        // Live MSM range and signal/noise values must actually change.
        for i in 1...50 {
            incoming.receive(msmPacket(code: 100 + i, cnr: 643 + i))
            precondition(model.needsUpdate(incoming, generation: generation))
            model.update(incoming, generation: generation)
            precondition(model.selectedType == 1077 && !model.paused)
            let measurements = try model.displayedFrame!.measurements()
            precondition(abs(measurements[0].cnr! - Double(643 + i) / 16) < 1e-8)
            precondition(measurements[0].pseudorange! > original.pseudorange!)
        }
        model.selectFrame(model.availableFrames.first!.id)
        let pinned = model.displayedFrame!
        let pinnedRange = try pinned.measurements()[0].pseudorange
        for i in 0..<100 {
            incoming.receive(msmPacket(code: 500 + i, cnr: 700))
            model.update(incoming, generation: generation)
        }
        precondition(!incoming.messages[1077]!.frames.contains { $0.id == pinned.id })
        precondition(model.availableFrames.contains { $0.id == pinned.id })
        precondition(model.displayedFrame!.id == pinned.id)
        let retainedRange = try model.displayedFrame!.measurements()[0].pseudorange
        precondition(retainedRange == pinnedRange)
        model.selectFrame(nil)
        precondition(model.displayedFrame!.id == 151)
        model.paused = true
        incoming.receive(msmPacket(code: 900, cnr: 800))
        precondition(!model.needsUpdate(incoming, generation: generation))
        model.paused = false
        model.update(incoming, generation: generation)
        precondition(model.displayedFrame!.id == 152)
        model.update(RTCMDecoder(), generation: UUID())
        precondition(model.selectedType == nil && model.pinnedFrame == nil && !model.paused)
        print("PASS: receiver traffic leaves decoder unchanged; live MSM pseudorange and C/N0 update; historical frames stay pinned; resume and session reset work")
    }
}
