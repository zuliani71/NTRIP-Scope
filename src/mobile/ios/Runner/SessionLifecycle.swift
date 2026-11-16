import Flutter
import UIKit

/// A preference alone cannot keep a session alive: a subscribed physical BLE link is required.
struct BLEBackgroundPolicy {
    var active = false
    var enabled = false
    func allowsContinuation(bleReady: Bool) -> Bool { active && enabled && bleReady }
    func mustCloseAfterLinkChange(inBackground: Bool, bleReady: Bool) -> Bool {
        inBackground && active && !allowsContinuation(bleReady: bleReady)
    }
}

/// CoreBluetooth wakes the app for BLE events. This is not an unlimited TCP execution lease.
final class SessionLifecycle {
    private let channel: FlutterMethodChannel
    private let receiver: BluetoothReceiver
    private let documents: PlatformDocuments
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var shuttingDown = false
    private var generation = 0
    private var keepAwake = false
    private var policy = BLEBackgroundPolicy()
    private var inBackground = false
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
                self.policy.active = args["active"] == true
                self.policy.enabled = args["keepBle"] == true
                self.keepAwake = args["keepAwake"] == true
                self.updateIdleTimer()
                result(nil)
            case "status":
                result(["active": self.policy.active, "bleReady": self.receiver.isReadyForBackground,
                        "backgroundEligible": self.policy.allowsContinuation(bleReady: self.receiver.isReadyForBackground),
                        "inBackground": self.inBackground, "closing": self.shuttingDown])
            default: result(FlutterMethodNotImplemented)
            }
        }
        for name in [UIScene.didEnterBackgroundNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.enteredBackground() })
        }
        for name in [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.inBackground = false
                self?.updateIdleTimer()
            })
        }
    }
    func receiverLinkChanged() {
        if policy.mustCloseAfterLinkChange(inBackground: inBackground, bleReady: receiver.isReadyForBackground) { suspend() }
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = policy.active && keepAwake && !inBackground && UIApplication.shared.applicationState == .active
    }
    private func enteredBackground() {
        inBackground = true
        UIApplication.shared.isIdleTimerDisabled = false
        if policy.allowsContinuation(bleReady: receiver.isReadyForBackground), !shuttingDown {
            channel.invokeMethod("backgroundBle", arguments: nil)
        } else { suspend() }
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
        policy.active = false; shuttingDown = false
        UIApplication.shared.isIdleTimerDisabled = false
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
