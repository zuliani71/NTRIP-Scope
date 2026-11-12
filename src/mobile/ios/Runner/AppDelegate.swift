import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var receiver: BluetoothReceiver?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NtripBluetooth")!
    receiver = BluetoothReceiver(messenger: registrar.messenger())
  }
}

import CoreBluetooth

/// Configurable BLE serial service. RTCM is written and GGA is received by notification.
final class BluetoothReceiver: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, FlutterStreamHandler {
  private var central: CBCentralManager?
  private var events: FlutterEventSink?
  private var devices: [UUID: CBPeripheral] = [:]
  private var discovered: [UUID: String] = [:]
  private var scanResult: FlutterResult?
  private var scanTimer: Timer?
  private var openResult: FlutterResult?
  private var peripheral: CBPeripheral?
  private var serviceID = CBUUID(string: "0000")
  private var writeID = CBUUID(string: "0000")
  private var readID = CBUUID(string: "0000")
  private var writer: CBCharacteristic?
  private var reader: CBCharacteristic?
  private var pendingWrite: (bytes: Data, offset: Int, result: FlutterResult)?
  private var waitingForAck = false

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "ntripscope/outputs", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self else { return }
        switch call.method {
        case "scanBle":
          guard self.scanResult == nil else {
            result(FlutterError(code: "busy", message: "Bluetooth scan is already running", details: nil)); return
          }
          self.scanResult = result
          self.discovered.removeAll()
          if self.central == nil {
            self.central = CBCentralManager(delegate: self, queue: .main)
          } else { self.beginScan() }
        case "openBle":
          guard let args = call.arguments as? [String: String],
                let id = args["address"].flatMap(UUID.init(uuidString:)),
                let device = self.devices[id], self.openResult == nil, self.peripheral == nil else {
            result(FlutterError(code: "bluetooth", message: "Select a BLE receiver before connecting", details: nil)); return
          }
          self.serviceID = CBUUID(string: args["service"]!)
          self.writeID = CBUUID(string: args["write"]!)
          self.readID = CBUUID(string: args["read"]!)
          self.openResult = result
          self.peripheral = device
          device.delegate = self
          self.central?.connect(device)
        case "writeBle":
          guard self.pendingWrite == nil, self.writer != nil, let data = call.arguments as? FlutterStandardTypedData else {
            result(FlutterError(code: "bluetooth", message: "BLE receiver is disconnected or busy", details: nil)); return
          }
          self.pendingWrite = (data.data, 0, result)
          self.sendNext()
        case "closeBle":
          self.close()
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
    FlutterEventChannel(name: "ntripscope/bluetooth", binaryMessenger: messenger).setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    events = eventSink
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { events = nil; return nil }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if scanResult != nil { beginScan() }
    if central.state != .poweredOn, peripheral != nil {
      fail("Bluetooth is unavailable or disabled")
    }
  }

  private func beginScan() {
    guard let central, scanResult != nil, scanTimer == nil else { return }
    if central.state == .unknown || central.state == .resetting { return }
    guard central.state == .poweredOn else {
      let result = scanResult; scanResult = nil
      result?(FlutterError(code: "bluetooth", message: "Enable and authorize Bluetooth on this device", details: nil))
      return
    }
    central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    scanTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
      guard let self else { return }
      self.central?.stopScan()
      self.scanTimer = nil
      let result = self.scanResult; self.scanResult = nil
      result?(self.discovered.sorted { $0.value < $1.value }.map { ["address": $0.key.uuidString, "name": $0.value] })
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    devices[peripheral.identifier] = peripheral
    discovered[peripheral.identifier] = peripheral.name ??
      advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.identifier.uuidString
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard self.peripheral === peripheral else { central.cancelPeripheralConnection(peripheral); return }
    peripheral.discoverServices([serviceID])
  }
  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    if self.peripheral === peripheral { fail(error?.localizedDescription ?? "BLE connection failed") }
  }
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    if self.peripheral === peripheral { fail(error?.localizedDescription ?? "BLE receiver disconnected") }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard self.peripheral === peripheral else { return }
    guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
      fail("The selected BLE service is unavailable"); return
    }
    peripheral.discoverCharacteristics([writeID, readID], for: service)
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard self.peripheral === peripheral else { return }
    writer = service.characteristics?.first { $0.uuid == writeID }
    reader = service.characteristics?.first { $0.uuid == readID }
    guard error == nil, let writer, let reader,
          writer.properties.contains(.write) || writer.properties.contains(.writeWithoutResponse),
          reader.properties.contains(.notify) || reader.properties.contains(.indicate) else {
      fail("Select a writable RTCM characteristic and a notifying GGA characteristic"); return
    }
    peripheral.setNotifyValue(true, for: reader)
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    guard self.peripheral === peripheral, characteristic === reader else { return }
    guard error == nil, characteristic.isNotifying else { fail("Could not subscribe to receiver GGA"); return }
    let result = openResult; openResult = nil
    result?(nil)
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard self.peripheral === peripheral, characteristic === reader else { return }
    guard error == nil else { fail("Could not read BLE receiver data"); return }
    if let data = characteristic.value { events?(FlutterStandardTypedData(bytes: data)) }
  }

  private func sendNext() {
    guard let peripheral, let writer, var pending = pendingWrite, !waitingForAck else { return }
    if pending.offset == pending.bytes.count {
      pendingWrite = nil
      pending.result(nil)
      return
    }
    let kind: CBCharacteristicWriteType = writer.properties.contains(.write) ? .withResponse : .withoutResponse
    if kind == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
    let size = min(peripheral.maximumWriteValueLength(for: kind), pending.bytes.count - pending.offset)
    let bytes = pending.bytes.subdata(in: pending.offset..<pending.offset + size)
    pending.offset += size
    pendingWrite = pending
    waitingForAck = kind == .withResponse
    peripheral.writeValue(bytes, for: writer, type: kind)
    if kind == .withoutResponse { DispatchQueue.main.async { [weak self] in self?.sendNext() } }
  }
  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard self.peripheral === peripheral, characteristic === writer else { return }
    if let error { fail(error.localizedDescription); return }
    waitingForAck = false
    sendNext()
  }
  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    if self.peripheral === peripheral { sendNext() }
  }

  private func fail(_ message: String) {
    close(message: message)
    events?(["disconnected": true])
  }
  private func close(message: String = "Bluetooth session closed") {
    let device = peripheral
    peripheral = nil
    writer = nil
    reader = nil
    waitingForAck = false
    let opening = openResult; openResult = nil
    let writing = pendingWrite; pendingWrite = nil
    opening?(FlutterError(code: "bluetooth", message: message, details: nil))
    writing?.result(FlutterError(code: "bluetooth", message: message, details: nil))
    if let device { central?.cancelPeripheralConnection(device) }
  }
}
