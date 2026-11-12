import Foundation
import Darwin

// Shared BluetoothSPPPort uses the desktop error type; the helper needs only this value.
enum SerialPort {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

@main
struct NativeBluetoothBridge {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--version") {
            print("ntripscope Bluetooth bridge 1.32"); return
        }
        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        var port: BluetoothSPPPort?
        func finish(_ code: Int32) {
            _ = port?.close()
            exit(code)
        }
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { finish(0) } }
            source.resume()
            return source
        }
        do {
            port = try BluetoothSPPPort(onData: { data in
                do { try FileHandle.standardOutput.write(contentsOf: data) }
                catch { finish(1) }
            }, onError: { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
                finish(1)
            })
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            finish(1)
        }
        // Only one chunk can be outstanding: slow radio output is bounded by the shared port.
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let data = FileHandle.standardInput.availableData
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        if data.isEmpty { finish(0) }
                        else { port?.write(data) }
                    }
                }
                if data.isEmpty { break }
            }
        }
        withExtendedLifetime(signals) { RunLoop.main.run() }
    }
}
