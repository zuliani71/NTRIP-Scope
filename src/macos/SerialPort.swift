import Foundation
import Darwin

/// Nonblocking serial I/O. A cancelled read source releases the descriptor on its
/// own queue; no unbounded DispatchIO read or pending-write drain is needed.
final class SerialPort {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private let queue = DispatchQueue(label: "io.ntripscope.serial")
    private let released = DispatchGroup()
    private let fd: Int32
    private var reader: DispatchSourceRead!
    private var retry: DispatchSourceTimer?
    private var pending = Data()
    private var closed = false
    private let onData: (Data) -> Void
    private let onError: (String) -> Void

    init(path: String, baud: Int, onData: @escaping (Data) -> Void,
         onError: @escaping (String) -> Void) throws {
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure(String(cString: strerror(errno))) }
        var options = termios()
        guard tcgetattr(descriptor, &options) == 0 else {
            let error = errno; Darwin.close(descriptor)
            throw Failure(String(cString: strerror(error)))
        }
        cfmakeraw(&options)
        // Do not drop modem control lines on last close; do not wait for CTS.
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CCTS_OFLOW | CRTS_IFLOW | HUPCL)
        options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        guard cfsetspeed(&options, speed_t(baud)) == 0,
              tcsetattr(descriptor, TCSANOW, &options) == 0 else {
            let error = errno; Darwin.close(descriptor)
            throw Failure(String(cString: strerror(error)))
        }
        fd = descriptor
        self.onData = onData
        self.onError = onError
        released.enter()
        let lease = released
        reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        reader.setCancelHandler {
            // The read handler has returned, and all queued writes check closed.
            Darwin.close(descriptor)
            lease.leave()
        }
        reader.resume()
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            guard pending.count + data.count <= 262_144 else {
                fail("Serial output too slow")
                return
            }
            pending.append(data)
            flushAvailable()
        }
    }

    func discardPendingOutput() {
        queue.async { [self] in
            guard !closed else { return }
            pending.removeAll()
            retry?.cancel(); retry = nil
        }
    }

    private func readAvailable() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Bound each handler so continuous receiver traffic cannot delay Stop.
        for _ in 0..<16 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer.prefix(count))
                let callback = onData
                DispatchQueue.main.async { callback(data) }
            } else if count == 0 {
                fail("Serial receiver disconnected")
                return
            } else {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { fail(String(cString: strerror(errno))) }
                return
            }
        }
    }

    private func flushAvailable() {
        guard !closed else { return }
        var written = 0
        while !pending.isEmpty && written < 65_536 {
            let count = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, min($0.count, 4096)) }
            if count > 0 {
                pending.removeFirst(count)
                written += count
            } else if count < 0 && errno == EINTR {
                continue
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                fail(String(cString: strerror(errno)))
                return
            }
        }
        if pending.isEmpty {
            retry?.cancel(); retry = nil
        } else if retry == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.flushAvailable() }
            retry = timer
            timer.resume()
        }
    }

    private func fail(_ message: String) {
        guard !closed else { return }
        closeOnQueue()
        let callback = onError
        DispatchQueue.main.async { callback(message) }
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        pending.removeAll()
        retry?.cancel(); retry = nil
        reader.cancel()
    }

    @discardableResult
    func close(wait: Bool = false) -> Bool {
        queue.async { [self] in closeOnQueue() }
        return !wait || released.wait(timeout: .now() + 2) == .success
    }

    deinit {
        retry?.cancel()
        reader?.cancel()
    }
}
