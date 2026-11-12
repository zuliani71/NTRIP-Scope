import Flutter
import UIKit

/// iOS grants finite background time: finish shutdown, never promise continuous TCP streaming.
final class SessionLifecycle {
    private let channel: FlutterMethodChannel
    private let receiver: BluetoothReceiver
    private let documents: PlatformDocuments
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var shuttingDown = false
    private var generation = 0
    private var keepAwake = false
    private var active = false
    private var observers: [NSObjectProtocol] = []

    init(messenger: FlutterBinaryMessenger, receiver: BluetoothReceiver, documents: PlatformDocuments) {
        self.receiver = receiver; self.documents = documents
        channel = FlutterMethodChannel(name: "ntripscope/lifecycle", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            switch call.method {
            case "setSession":
                let args = call.arguments as? [String: Bool] ?? [:]
                if args["active"] == true && self.shuttingDown {
                    result(FlutterError(code: "shutdown", message: "Wait for the previous session to finish closing", details: nil)); return
                }
                self.active = args["active"] == true
                self.keepAwake = args["keepAwake"] == true
                self.updateIdleTimer()
                result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        }
        for name in [UIScene.didEnterBackgroundNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.suspend() })
        }
        for name in [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateIdleTimer() })
        }
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = active && keepAwake && UIApplication.shared.applicationState == .active
    }
    private func suspend() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard !shuttingDown else { return }
        shuttingDown = true; generation += 1
        let current = generation
        task = UIApplication.shared.beginBackgroundTask(withName: "NTRIP session shutdown") { [weak self] in
            self?.closeNative(current)
            self?.finish(current)
        }
        // Dart closes the caster/TCP; native cleanup also covers a suspended Dart engine.
        channel.invokeMethod("suspend", arguments: nil) { [weak self] _ in self?.closeNative(current) }
        receiver.shutdownForBackground()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.closeNative(current) }
    }
    private func closeNative(_ current: Int) {
        guard shuttingDown && current == generation else { return }
        receiver.shutdownForBackground { [weak self] in
            guard let self, self.shuttingDown && current == self.generation else { return }
            self.documents.closeForBackground { [weak self] in self?.finish(current) }
        }
    }
    private func finish(_ current: Int) {
        guard shuttingDown && current == generation else { return }
        active = false; shuttingDown = false
        UIApplication.shared.isIdleTimerDisabled = false
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
