import Foundation
import Darwin

enum SerialPortChecks {
    @MainActor static func run() async throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        precondition(openpty(&master, &slave, &name, nil, nil) == 0)
        let path = String(cString: name)
        Darwin.close(slave)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        defer { Darwin.close(master) }
        var incoming = Data()
        var errors: [String] = []
        let port = try SerialPort(path: path, baud: 115200, onData: { incoming.append($0) }, onError: { errors.append($0) })
        var options = termios()
        precondition(tcgetattr(master, &options) == 0)
        precondition(options.c_cflag & tcflag_t(HUPCL | CCTS_OFLOW | CRTS_IFLOW) == 0)
        let sentence = Data("$GPGGA,raw receiver data\r\n".utf8)
        _ = sentence.withUnsafeBytes { Darwin.write(master, $0.baseAddress!, $0.count) }
        for _ in 0..<100 {
            if incoming == sentence { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(incoming == sentence)
        let correction = Data([0xd3, 0, 2, 0xff, 0, 13, 10])
        port.write(correction)
        var received = Data()
        for _ in 0..<100 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(master, &bytes, bytes.count)
            if n > 0 { received.append(contentsOf: bytes.prefix(n)) }
            if received == correction { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(received == correction)
        // Stop must not close the receiver; discard unsent output, continue reading.
        port.discardPendingOutput()
        let next = Data("$GNGGA,next fix\r\n".utf8)
        _ = next.withUnsafeBytes { Darwin.write(master, $0.baseAddress!, $0.count) }
        for _ in 0..<100 {
            if incoming == sentence + next { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(incoming == sentence + next)
        // Fill output while the peer is not reading: close cannot wait for a drain.
        port.write(Data(repeating: 0x55, count: 200_000))
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        precondition(port.close(wait: true))
        precondition(Date().timeIntervalSince(start) < 1.5)
        precondition(port.close(wait: true))
        precondition(errors.isEmpty, "Unexpected serial error: \(errors)")
        // Repeated quiet closes and reopen must also release an idle read promptly.
        for _ in 0..<20 {
            let reopened = try SerialPort(path: path, baud: 115200, onData: { _ in }, onError: { _ in })
            precondition(reopened.close(wait: true))
        }
        print("PASS: serial duplex, receiver retained on Stop, no HUPCL/CTS, bounded close with blocked writes, 20 reopen cycles")
    }
}
