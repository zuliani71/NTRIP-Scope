import Flutter
import UIKit
import UniformTypeIdentifiers

/// Document access is granted only by the system picker. Selection alone never overwrites a configuration.
final class PlatformDocuments: NSObject, UIDocumentPickerDelegate {
    private let channel: FlutterMethodChannel
    private let queue = DispatchQueue(label: "ntripscope.documents")
    private var pending: FlutterResult?
    private var selectingOutput = false
    private var selectedConfiguration: URL?
    private var selectedOutput: URL?
    private var exportTemporary: URL?
    private var output: FileHandle?
    private var outputScope: URL?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "ntripscope/configuration", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            switch call.method {
            case "chooseExisting": self.pick(output: false, result: result)
            case "replace":
                guard let args = call.arguments as? [String: Any],
                      let url = self.selectedConfiguration,
                      args["uri"] as? String == url.absoluteString,
                      let name = args["name"] as? String,
                      args["confirmedOverwrite"] as? Bool == true,
                      let bytes = args["bytes"] as? FlutterStandardTypedData else {
                    result(FlutterError(code: "configuration", message: "Select a file and confirm replacement first", details: nil)); return
                }
                self.perform(result) { try Self.replace(url: url, expectedName: name, bytes: bytes.data) }
            default: result(FlutterMethodNotImplemented)
            }
        }
    }

    static func replace(url: URL, expectedName: String, bytes: Data) throws {
        guard url.lastPathComponent == expectedName, bytes.count <= 1_048_576 else {
            throw NSError(domain: "NTRIPScope", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected file name changed or configuration is too large"])
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            do {
                guard target.lastPathComponent == expectedName, FileManager.default.fileExists(atPath: target.path) else {
                    throw NSError(domain: "NTRIPScope", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected file is no longer available"])
                }
                try bytes.write(to: target, options: .atomic)
            } catch { writeError = error }
        }
        if let error = coordinationError { throw error }
        if let error = writeError { throw error }
    }

    /// Routed from the outputs channel so file and BLE outputs share one channel handler.
    func handleOutput(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
        switch call.method {
        case "chooseFile": pick(output: true, result: result)
        case "openFile":
            guard let args = call.arguments as? [String: String], let url = selectedOutput,
                  args["uri"] == url.absoluteString else {
                result(FlutterError(code: "file", message: "Choose the RTCM destination again", details: nil)); return true
            }
            perform(result) {
                try self.closeFile()
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.truncate(atOffset: 0)
                    self.output = handle
                    self.outputScope = scoped ? url : nil
                } catch {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
            }
        case "writeFile":
            guard let bytes = call.arguments as? FlutterStandardTypedData else { result(FlutterError(code: "file", message: "Invalid RTCM data", details: nil)); return true }
            perform(result) {
                guard let handle = self.output else { throw NSError(domain: "NTRIPScope", code: 3, userInfo: [NSLocalizedDescriptionKey: "RTCM file is closed"]) }
                try handle.write(contentsOf: bytes.data)
            }
        case "closeFile": perform(result) { try self.closeFile() }
        default: return false
        }
        return true
    }

    func closeForBackground(completion: @escaping () -> Void) {
        queue.async { try? self.closeFile(); DispatchQueue.main.async(execute: completion) }
    }
    private func closeFile() throws {
        let handle = output; output = nil
        let scope = outputScope; outputScope = nil
        defer { scope?.stopAccessingSecurityScopedResource() }
        defer { try? handle?.close() }
        try handle?.synchronize()
    }
    private func perform(_ result: @escaping FlutterResult, work: @escaping () throws -> Void) {
        queue.async {
            do { try work(); DispatchQueue.main.async { result(nil) } }
            catch { DispatchQueue.main.async { result(FlutterError(code: "file", message: error.localizedDescription, details: nil)) } }
        }
    }
    private func pick(output: Bool, result: @escaping FlutterResult) {
        guard pending == nil else { result(FlutterError(code: "busy", message: "A file picker is already open", details: nil)); return }
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            result(FlutterError(code: "file", message: "No active window", details: nil)); return
        }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        let picker: UIDocumentPickerViewController
        if output {
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("ntripscope.rtcm")
                try Data().write(to: file)
                exportTemporary = directory
                picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
            } catch { result(FlutterError(code: "file", message: error.localizedDescription, details: nil)); return }
        } else { picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false) }
        pending = result; selectingOutput = output
        picker.delegate = self; picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { finish(nil); return }
        if selectingOutput { selectedOutput = url; finish(url.absoluteString) }
        else {
            selectedConfiguration = url
            let scoped = url.startAccessingSecurityScopedResource()
            let writable = (try? url.resourceValues(forKeys: [.isWritableKey]).isWritable) ?? false
            if scoped { url.stopAccessingSecurityScopedResource() }
            finish(["uri": url.absoluteString, "name": url.lastPathComponent, "writable": writable])
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    private func finish(_ value: Any?) {
        let result = pending; pending = nil
        if let directory = exportTemporary { try? FileManager.default.removeItem(at: directory); exportTemporary = nil }
        result?(value)
    }
}
