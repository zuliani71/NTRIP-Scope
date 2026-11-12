import Foundation
import AppKit
import Network
import Darwin

@main struct RadioSessionCheck {
    static func stationPacket() -> Data {
        // Valid Earth-surface coordinates, unlike the arbitrary numeric decoder fixture.
        let xyz = StationPosition(latitude: 45.5, longitude: 12.5)!.ecef
        var bits: [UInt8] = []
        func add(_ value: Int64, _ width: Int) {
            let raw = UInt64(bitPattern: value)
            for i in (0..<width).reversed() { bits.append(UInt8((raw >> i) & 1)) }
        }
        add(1006, 12); add(1, 12); add(0, 6)
        add(1, 1); add(1, 1); add(1, 1); add(0, 1)
        add(Int64((xyz.x * 10000).rounded()), 38); add(0, 2)
        add(Int64((xyz.y * 10000).rounded()), 38); add(0, 2)
        add(Int64((xyz.z * 10000).rounded()), 38); add(10000, 16)
        while bits.count % 8 != 0 { bits.append(0) }
        var payload: [UInt8] = []
        for i in stride(from: 0, to: bits.count, by: 8) {
            payload.append(bits[i..<i+8].reduce(0) { ($0 << 1) | $1 })
        }
        var data: [UInt8] = [0xd3, 0, UInt8(payload.count)] + payload
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x1000000 != 0 { crc ^= 0x1864cfb }
            }
        }
        data += [UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)]
        return Data(data)
    }
    @MainActor static func main() async throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        precondition(openpty(&master, &slave, &name, nil, nil) == 0)
        let path = String(cString: name)
        Darwin.close(slave)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        defer { Darwin.close(master) }
        let listener = try NWListener(using: .tcp, on: .any)
        var connectionCount = 0
        var ggaCount = 0
        var peers: [NWConnection] = []
        listener.newConnectionHandler = { peer in
            MainActor.assumeIsolated {
                peers.append(peer)
                connectionCount += 1
                let index = connectionCount
                var buffer = Data()
                var headers = true
                func read() {
                    peer.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
                        MainActor.assumeIsolated {
                            if let data { buffer.append(data) }
                            if headers, let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                                buffer.removeSubrange(..<end.upperBound)
                                headers = false
                                // Only the first session supplies station coordinates.
                                peer.send(content: Data("ICY 200 OK\r\n".utf8) + (index == 1 ? stationPacket() : Data()), completion: .idempotent)
                            }
                            if !headers {
                                while let end = buffer.range(of: Data("\r\n".utf8)) {
                                    let sentence = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                                    if NMEAGGAReader.valid(sentence) { ggaCount += 1 }
                                    buffer.removeSubrange(..<end.upperBound)
                                }
                            }
                            if !done && error == nil { read() }
                        }
                    }
                }
                peer.start(queue: .main); read()
            }
        }
        listener.start(queue: .main)
        for _ in 0..<100 {
            if (listener.port?.rawValue ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let port = listener.port, port.rawValue > 0 else { fatalError("No local caster") }
        let radio = Radio()
        let source = Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                let position = RoverPosition(latitude: 45.5 + Double(tick) * 0.000001, longitude: 12.5,
                                             ellipsoidalHeight: 100, geoidSeparation: 40)
                let bytes = Data((position.gga() + "\r\n").utf8)
                bytes.withUnsafeBytes { _ = Darwin.write(master, $0.baseAddress!, $0.count) }
                tick += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        func connect() {
            radio.start(host: "127.0.0.1", port: String(port.rawValue), mount: "TEST", user: "", password: "",
                        tls: false, version2: false, list: false, gga: "", output: nil,
                        serialDevice: path, baud: 115200)
        }
        connect()
        let key = radio.streamKey
        for _ in 0..<200 {
            if radio.rtcm.antenna != nil && radio.mapRover != nil && ggaCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let station = radio.stationPosition(for: key), let rover = radio.mapRover else { fatalError("No station/rover: " + radio.status + " / " + radio.outputStatus + " / frames=" + String(radio.rtcm.messages.count) + " GGA=" + String(ggaCount)) }
        let received = radio.receiverCounts
        radio.stop()
        precondition(radio.receiverConnected)
        try await Task.sleep(for: .milliseconds(400))
        precondition(radio.receiverCounts == received, "Stop must freeze receiver preview/counters")
        precondition(radio.mapRover == rover, "Stop must freeze rover coordinates/distance")
        precondition(radio.stationPosition(for: key) == station, "Stop must preserve master")
        let previousGga = ggaCount
        connect()
        precondition(radio.rtcm.antenna == nil)
        precondition(radio.stationPosition(for: key) == station, "Reconnect must preserve master before a new RTCM 1006")
        precondition(radio.mapRover == rover, "Reconnect must retain last known rover until the next fix")
        for _ in 0..<200 {
            if ggaCount > previousGga && radio.mapRover != rover { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(ggaCount > previousGga && radio.mapRover != rover)
        precondition(radio.stationPosition(for: key) == station)
        precondition(radio.stationPosition(for: key + "-other") == nil, "Never reuse master across caster/mountpoint keys")
        // A receiver failure must stop NTRIP and remain visible after subsequent Stop.
        source.cancel()
        Darwin.close(master); master = -1
        for _ in 0..<100 {
            if !radio.busy && !radio.receiverError.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(!radio.busy && !radio.receiverError.isEmpty, "Receiver failure must remain visible")
        let receiverError = radio.receiverError
        radio.stop()
        precondition(radio.receiverError == receiverError)
        precondition(radio.stationPosition(for: key) == station)
        radio.disconnectReceiver()
        listener.cancel(); for peer in peers { peer.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        print("PASS: Stop freezes continuously changing rover/receiver data, preserves master; Connect resumes GGA on same port and retains station until fresh 1006; cache is stream-specific; receiver errors persist")
    }
}
