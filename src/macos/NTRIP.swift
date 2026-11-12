import AppKit
import Charts
import SwiftUI
import Network
import Darwin
import UniformTypeIdentifiers

@MainActor
final class Radio: ObservableObject {
    @Published private(set) var roverMap = RoverMapState()
    var mapRover: StationPosition? { roverMap.effective?.position }
    func setManualMapRover(_ position: StationPosition?, enabled: Bool) {
        roverMap.setManual(position, enabled: enabled)
    }
    @Published var status = "Pronto"
    @Published var count = 0
    @Published var mounts: [String] = []
    @Published private(set) var advertisedLocations: [String: StationPosition] = [:]
    private(set) var sourceCaster = ""
    private(set) var streamKey = ""
    private var requestCaster = ""

    static func casterKey(_ host: String, _ port: String, _ tls: Bool) -> String {
        let name = host.trimmingCharacters(in: .whitespaces).lowercased()
        return "\(name)|\(UInt16(port) ?? 0)|\(tls)"
    }

    static func cleanMount(_ mount: String) -> String {
        mount.trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.newlines))
    }
    @Published var busy = false
    @Published private(set) var recent = Data()
    private(set) var monitorGeneration = UUID()
    @Published private(set) var receiverStreams: [String: Data] = [:]
    @Published private(set) var receiverCounts: [String: Int] = [:]
    @Published private(set) var rtcm = RTCMDecoder()
    @Published private(set) var lastData: Date?
    private(set) var activityStart: Date?
    static let activityTimeout: TimeInterval = 2.5
    @Published private(set) var outputStatus = ""
    @Published private(set) var receiverError = ""
    @Published private(set) var stationPositions: [String: StationPosition] = [:]

    func stationPosition(for key: String) -> StationPosition? {
        if key == streamKey, let position = rtcm.antenna { return position }
        return stationPositions[key]
    }

    private func rememberStation() {
        guard !streamKey.isEmpty, let position = rtcm.antenna,
              stationPositions[streamKey] != position else { return }
        if stationPositions.count >= 100 && stationPositions[streamKey] == nil { stationPositions.removeAll() }
        stationPositions[streamKey] = position
    }
    private var listener: NWListener?
    private var tcpClient: NWConnection?
    private var tcpReady = false
    private var tcpPending = 0
    private var serial: SerialPort?
    private var bluetoothSPP: BluetoothSPPPort?
    private var closingSerial: SerialPort?
    private var serialID = UUID()
    private var serialBaud = 0
    var receiverConnected: Bool { serial != nil || bluetoothSPP != nil }
    private var serialPath = ""

    private var connection: NWConnection?
    private var files: [FileHandle] = []
    private var timer: Timer?
    private var buffer = Data()
    private var readingHeader = true
    private var listing = false
    private var chunked = false
    private var chunkSize: Int?
    private var gga = ""
    private var rover: RoverPosition?
    private var ggaTimer: Timer?
    private var serialGGA = NMEAGGAReader()
    private var tcpGGA = NMEAGGAReader()
    private var externalGGA: (sentence: String, received: Date)?
    private var lastExternalSent = Date.distantPast
    @Published private(set) var ggaSource = ""
    @Published private(set) var receiverFix: ReceiverFixStatus?
    private var fixReaders: [String: NMEAGGAReader] = [:]

    func stop(_ message: String = "NTRIP disconnesso") {
        rememberStation()
        serialGGA = NMEAGGAReader()
        serial?.discardPendingOutput()
        bluetoothSPP?.discardPendingOutput()
        listener?.cancel()
        listener = nil
        tcpClient?.cancel()
        tcpClient = nil
        tcpGGA = NMEAGGAReader()
        tcpReady = false
        tcpPending = 0
        externalGGA = nil
        lastExternalSent = .distantPast
        ggaSource = ""
        outputStatus = ""
        ggaTimer?.invalidate()
        ggaTimer = nil
        timer?.invalidate()
        timer = nil
        connection?.cancel()
        connection = nil
        for file in files { try? file.close() }
        files.removeAll()
        busy = false
        status = message
        updateOutputs()
    }

    func disconnectReceiver() {
        serialID = UUID()
        bluetoothSPP?.close()
        bluetoothSPP = nil
        serial?.close()
        closingSerial = serial ?? closingSerial
        serial = nil
        serialPath = ""
        serialBaud = 0
        serialGGA = NMEAGGAReader()
        externalGGA = nil
        updateOutputs()
    }

    func start(host: String, port: String, mount: String, user: String, password: String,
               tls: Bool, version2: Bool, list: Bool, gga: String, output: URL?,
               tcpPort: String? = nil, serialDevice: String? = nil, baud: Int = 115200,
               rover: RoverPosition? = nil, additionalFiles: [URL] = []) {
        stop()
        let host = host.trimmingCharacters(in: .whitespaces)
        let mount = Self.cleanMount(mount)
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || "/?#".contains($0) }),
              let number = UInt16(port), number > 0, let endpointPort = NWEndpoint.Port(rawValue: number),
              list || !mount.isEmpty else {
            status = "Controlla caster, porta e mountpoint"
            return
        }
        let gga = gga.trimmingCharacters(in: .whitespacesAndNewlines)
        guard gga.isEmpty || (gga.hasPrefix("$") && gga.prefix(6).hasSuffix("GGA") &&
                             !gga.contains(where: \.isNewline)) else {
            status = "Inserisci una singola frase NMEA GGA"
            return
        }
        receiverError = ""
        if !list {
            do {
                if let serialDevice { try openSerial(serialDevice, baud: baud) }
                else { disconnectReceiver() }
                if let tcpPort { try openTCP(tcpPort) }
            } catch {
                stop(error.localizedDescription)
                return
            }
        }
        if !list, let output {
            do {
                for url in [output] + additionalFiles {
                    try Data().write(to: url, options: .atomic)
                    files.append(try FileHandle(forWritingTo: url))
                }
            } catch {
                stop("File: \(error.localizedDescription)")
                return
            }
        }
        self.gga = list ? "" : gga
        self.rover = list ? nil : rover
        buffer = Data()
        count = 0
        recent = Data()
        let nextStreamKey = list ? "" : "\(Self.casterKey(host, port, tls))|\(mount)"
        if nextStreamKey != streamKey { roverMap.resetReceived() }
        receiverFix = nil
        fixReaders = [:]
        receiverStreams = [:]
        receiverCounts = [:]
        requestCaster = Self.casterKey(host, port, tls)
        streamKey = list ? "" : "\(requestCaster)|\(mount)"
        monitorGeneration = UUID()
        rtcm = RTCMDecoder()
        lastData = nil
        activityStart = nil
        readingHeader = true
        listing = list
        chunked = false
        chunkSize = nil
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let path = list ? "" : (mount.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        let hostHeader = host.contains(":") ? "[\(host)]" : host
        var request = "GET /\(path) HTTP/\(version2 ? "1.1" : "1.0")\r\nHost: \(hostHeader):\(number)\r\nUser-Agent: NTRIP MacRadio/1.0\r\nConnection: close\r\n"
        if version2 {
            request += "Ntrip-Version: Ntrip/2.0\r\n"
            let initialGGA = self.rover?.gga() ?? self.gga
            if !initialGGA.isEmpty { request += "Ntrip-GGA: \(initialGGA)\r\n" }
        }
        if !user.isEmpty || !password.isEmpty {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            request += "Authorization: Basic \(token)\r\n"
        }
        let payload = Data((request + "\r\n").utf8)
        let client = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                  using: tls ? .tls : .tcp)
        connection = client
        busy = true
        status = "Connessione in corso…"
        client.stateUpdateHandler = { [weak self, weak client] state in
            MainActor.assumeIsolated {
                guard let self, let client, self.connection === client else { return }
                switch state {
                case .ready:
                    client.send(content: payload, completion: .contentProcessed { [weak self, weak client] error in
                        MainActor.assumeIsolated {
                            guard let self, let client, self.connection === client else { return }
                            if let error { self.stop(error.localizedDescription) }
                            else { self.receive(client) }
                        }
                    })
                case .failed(let error), .waiting(let error):
                    self.stop(error.localizedDescription)
                default: break
                }
            }
        }
        client.start(queue: .main)
        timeout(client)
    }

    private func timeout(_ client: NWConnection) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self, weak client] _ in
            MainActor.assumeIsolated {
                guard let self, let client, self.connection === client else { return }
                if self.listing && !self.readingHeader { self.finishList() }
                else { self.stop("Nessun dato ricevuto per 30 secondi") }
            }
        }
    }

    private func sendGGA(_ client: NWConnection) {
        let sentence: String
        if let rover {
            sentence = rover.gga()
            ggaSource = tr("GGA manuale → caster")
        } else if !gga.isEmpty {
            sentence = gga
            ggaSource = tr("GGA manuale → caster")
        } else {
            guard !readingHeader, !listing, let external = externalGGA,
                  Date().timeIntervalSince(lastExternalSent) >= 1 else { return }
            externalGGA = nil
            guard Date().timeIntervalSince(external.received) <= 5 else { return }
            sentence = external.sentence
            lastExternalSent = Date()
            ggaSource = tr("GGA seriale / Bluetooth → caster")
        }
        client.send(content: Data((sentence + "\r\n").utf8), completion: .contentProcessed { [weak self, weak client] error in
            MainActor.assumeIsolated {
                guard let self, let client, self.connection === client, let error else { return }
                self.stop(error.localizedDescription)
            }
        })
    }

    private func sendGGAFromSerial(_ client: NWConnection) {
        guard rover == nil, gga.isEmpty else { return }
        sendGGA(client)
    }

    private var table = Data()
    private let crlf = Data([13, 10])
    private let headerEnd = Data([13, 10, 13, 10])

    private func receive(_ client: NWConnection) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak client] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, let client, self.connection === client else { return }
                if let data, !data.isEmpty {
                    self.timeout(client)
                    self.buffer.append(data)
                    self.consume(client)
                }
                guard self.connection === client else { return }
                if let error { self.stop(error.localizedDescription) }
                else if done {
                    if self.listing && !self.readingHeader { self.finishList() }
                    else { self.stop("Connessione chiusa dal caster") }
                } else { self.receive(client) }
            }
        }
    }

    private func consume(_ client: NWConnection) {
        if readingHeader {
            guard let first = buffer.range(of: crlf) else {
                if buffer.count > 16384 { stop("Risposta del caster non valida") }
                return
            }
            let line = String(decoding: buffer[..<first.lowerBound], as: UTF8.self)
            let legacy = line.hasPrefix("ICY ")
            let source = line.hasPrefix("SOURCETABLE ")
            guard (legacy || source || line.hasPrefix("HTTP/")),
                  line.split(separator: " ").dropFirst().first == "200" else {
                stop("Caster: \(line.prefix(160))")
                return
            }
            guard !source || listing else { stop("Il caster ha restituito l’elenco dei mountpoint"); return }
            if legacy {
                buffer.removeSubrange(..<first.upperBound)
            } else {
                guard let end = buffer.range(of: headerEnd) else {
                    if buffer.count > 16384 { stop("Intestazione del caster troppo lunga") }
                    return
                }
                let headers = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).lowercased()
                if !listing && headers.contains("gnss/sourcetable") {
                    stop("Il caster ha restituito l’elenco dei mountpoint")
                    return
                }
                chunked = headers.split(whereSeparator: \.isNewline).contains {
                    $0.hasPrefix("transfer-encoding:") && $0.contains("chunked")
                }
                buffer.removeSubrange(..<end.upperBound)
            }
            readingHeader = false
            table = Data()
            status = listing ? "Lettura mountpoint…" : "Connesso, in attesa di dati…"
            if !listing {
                sendGGA(client)
                let interval: TimeInterval = rover != nil || !gga.isEmpty ? 10 : 1
                ggaTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self, weak client] _ in
                    MainActor.assumeIsolated {
                        guard let self, let client, self.connection === client else { return }
                        self.sendGGA(client)
                    }
                }
            }
        }

        if chunked {
            while connection === client {
                if chunkSize == nil {
                    guard let end = buffer.range(of: crlf) else {
                        if buffer.count > 1024 { stop("Blocco NTRIP non valido") }
                        return
                    }
                    let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    guard let hex = line.split(separator: ";").first,
                          let size = Int(hex, radix: 16), (0...8_388_608).contains(size) else {
                        stop("Blocco NTRIP non valido")
                        return
                    }
                    buffer.removeSubrange(..<end.upperBound)
                    if size == 0 {
                        if listing { finishList() }
                        else { stop("Flusso terminato dal caster") }
                        return
                    }
                    chunkSize = size
                }
                guard let size = chunkSize, buffer.count >= size + 2 else { return }
                let end = buffer.index(buffer.startIndex, offsetBy: size)
                guard buffer[end...].prefix(2).elementsEqual(crlf) else {
                    stop("Blocco NTRIP non valido")
                    return
                }
                let payload = Data(buffer[..<end])
                buffer.removeSubrange(..<buffer.index(end, offsetBy: 2))
                chunkSize = nil
                deliver(payload)
            }
        } else if !buffer.isEmpty {
            let payload = buffer
            buffer = Data()
            deliver(payload)
        }
    }

    private func deliver(_ data: Data) {
        if listing {
            table.append(data)
            if table.range(of: Data("ENDSOURCETABLE".utf8)) != nil { finishList() }
            else if table.count > 4_000_000 { stop("Elenco mountpoint troppo grande") }
            return
        }
        do { for file in files { try file.write(contentsOf: data) } }
        catch { stop("Registrazione interrotta: \(error.localizedDescription)"); return }
        forward(data)
        count += data.count
        recent = Data((recent + data.suffix(256)).suffix(256))
        rtcm.receive(data)
        rememberStation()
        let now = Date()
        if lastData.map({ now.timeIntervalSince($0) >= Self.activityTimeout }) ?? true {
            activityStart = now
        }
        lastData = now
        if status != "Ricezione in corso" { status = "Ricezione in corso" }
    }

    private func openTCP(_ value: String) throws {
        guard let number = UInt16(value), number > 0, let port = NWEndpoint.Port(rawValue: number) else {
            throw OutputError("Inserisci una porta TCP tra 1 e 65535")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let server = try NWListener(using: parameters)
        listener = server
        server.stateUpdateHandler = { [weak self, weak server] state in
            MainActor.assumeIsolated {
                guard let self, let server, self.listener === server else { return }
                switch state {
                case .ready:
                    self.updateOutputs()
                case .failed(let error):
                    self.stop("Uscita TCP: \(error.localizedDescription)")
                default: break
                }
            }
        }
        server.newConnectionHandler = { [weak self, weak server] peer in
            MainActor.assumeIsolated {
                guard let self, let server, self.listener === server, self.tcpClient == nil else {
                    peer.cancel()
                    return
                }
                self.tcpClient = peer
                peer.stateUpdateHandler = { [weak self, weak peer] state in
                    MainActor.assumeIsolated {
                        guard let self, let peer, self.tcpClient === peer else { return }
                        switch state {
                        case .ready:
                            self.tcpReady = true
                            self.updateOutputs()
                            self.watchTCP(peer)
                        case .failed, .cancelled:
                            self.closeTCPPeer()
                        default: break
                        }
                    }
                }
                peer.start(queue: .main)
            }
        }
        server.start(queue: .main)
    }

    private func monitorReceiver(_ data: Data, source: String) {
        var reader = fixReaders[source] ?? NMEAGGAReader(includeNoFix: true)
        for sentence in reader.feed(data) {
            if let quality = NMEAGGAReader.quality(sentence) {
                receiverFix = ReceiverFixStatus(quality: quality, received: Date(), source: source)
            }
        }
        fixReaders[source] = reader
        receiverStreams[source] = Data(((receiverStreams[source] ?? Data()) + data.suffix(8192)).suffix(8192))
        receiverCounts[source, default: 0] += data.count
    }

    private func watchTCP(_ peer: NWConnection) {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak peer] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, let peer, self.tcpClient === peer else { return }
                if let data, !data.isEmpty {
                    self.monitorReceiver(data, source: "TCP · \(self.listener?.port?.rawValue ?? 0)")
                    for sentence in self.tcpGGA.feed(data) { self.roverMap.receive(sentence, source: "GGA · TCP") }
                }
                if done || error != nil { self.closeTCPPeer() }
                else { self.watchTCP(peer) }
            }
        }
    }

    private func closeTCPPeer() {
        tcpClient?.cancel()
        tcpClient = nil
        tcpGGA = NMEAGGAReader()
        tcpReady = false
        tcpPending = 0
        updateOutputs()
    }

    private func updateOutputs() {
        var outputs: [String] = []
        if let port = listener?.port {
            let state = tcpReady ? tr("collegato") : tr("in ascolto")
            outputs.append("TCP 127.0.0.1:\(port.rawValue) · \(state)")
        }
        if bluetoothSPP != nil { outputs.append("Bluetooth SPP · HC-06 (direct)") }
        else if !serialPath.isEmpty { outputs.append(tr("Seriale \(serialPath)")) }
        outputStatus = outputs.joined(separator: "  |  ")
    }

    private func openSerial(_ path: String, baud: Int) throws {
        guard (path.hasPrefix("/dev/cu.") || path.hasPrefix("/dev/tty")),
              !path.dropFirst(5).contains("/") else {
            throw OutputError("Scegli una porta seriale")
        }
        if receiverConnected, serialPath == path, serialBaud == baud,
           bluetoothSPP?.isReusable ?? true { return }
        disconnectReceiver()
        if let closingSerial {
            guard closingSerial.close(wait: true) else { throw OutputError("Serial receiver is still closing") }
            self.closingSerial = nil
        }
        let id = UUID()
        serialID = id
        let dataHandler: (Data) -> Void = { [weak self] bytes in
            MainActor.assumeIsolated {
                guard let self, self.serialID == id, self.receiverConnected,
                      self.busy, !self.listing else { return }
                self.monitorReceiver(bytes, source: self.bluetoothSPP != nil ? "Bluetooth SPP · HC-06" : "Serial / Bluetooth · \(self.serialPath)")
                for sentence in self.serialGGA.feed(bytes) {
                    self.roverMap.receive(sentence, source: "GGA · Serial / Bluetooth")
                    if self.rover == nil && self.gga.isEmpty {
                        self.externalGGA = (sentence, Date())
                    }
                }
                if let client = self.connection, !self.readingHeader { self.sendGGAFromSerial(client) }
            }
        }
        let errorHandler: (String) -> Void = { [weak self] message in
            MainActor.assumeIsolated {
                guard let self, self.serialID == id else { return }
                self.disableSerial(message)
            }
        }
        if BluetoothSPPPort.isHC06Path(path) {
            bluetoothSPP = try BluetoothSPPPort(onData: dataHandler, onError: errorHandler)
        } else {
            serial = try SerialPort(path: path, baud: baud, onData: dataHandler, onError: errorHandler)
        }
        serialPath = path
        serialBaud = baud
        updateOutputs()
    }

    private func forward(_ data: Data) {
        if let peer = tcpClient, tcpReady {
            if tcpPending + data.count > 262_144 {
                closeTCPPeer()
            } else {
                tcpPending += data.count
                peer.send(content: data, completion: .contentProcessed { [weak self, weak peer] error in
                    MainActor.assumeIsolated {
                        guard let self, let peer, self.tcpClient === peer else { return }
                        if error != nil { self.closeTCPPeer() }
                        else { self.tcpPending -= data.count }
                    }
                })
            }
        }
        serial?.write(data)
        bluetoothSPP?.write(data)
    }

    private func disableSerial(_ message: String) {
        let wasBusy = busy
        disconnectReceiver()
        receiverError = message
        if wasBusy { stop(tr("Errore ricevitore") + ": " + message) }
    }

    private struct OutputError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func finishList() {
        var names = Set<String>()
        var locations: [String: StationPosition] = [:]
        for line in String(decoding: table, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("STR;") else { continue }
            let fields = line.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[1].isEmpty else { continue }
            let name = String(fields[1])
            names.insert(name)
            if fields.count > 10, let lat = Double(fields[9]), let lon = Double(fields[10]),
               lat != 0 || lon != 0, let position = StationPosition(latitude: lat, longitude: lon) {
                locations[name] = position
            }
        }
        sourceCaster = requestCaster
        advertisedLocations = locations
        mounts = names.sorted()
        stop(mounts.isEmpty ? "Nessun mountpoint trovato" : "\(mounts.count) mountpoint disponibili")
    }
}

struct MountpointField: NSViewRepresentable {
    @Binding var text: String
    let items: [String]

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSComboBox {
        let field = NSComboBox()
        field.placeholderString = "Mountpoint"
        field.setAccessibilityLabel("Mountpoint")
        field.numberOfVisibleItems = 12
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSComboBox, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.updating = true
        defer { coordinator.updating = false }
        if coordinator.items != items {
            coordinator.items = items
            field.removeAllItems()
            field.addItems(withObjectValues: items)
        }
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>
        var items: [String] = []
        var updating = false

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard !updating, let field = notification.object as? NSComboBox else { return }
            text.wrappedValue = field.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !updating, let field = notification.object as? NSComboBox,
                  let value = field.objectValueOfSelectedItem as? String else { return }
            text.wrappedValue = value
        }
    }
}

struct RadioView: View {
    @StateObject private var radio = Radio()
    @AppStorage(AppLanguage.key) private var language = "en"
    @AppStorage("casterHost") private var host = ""
    @AppStorage("casterPort") private var port = "2101"
    @AppStorage("casterMount") private var mount = ""
    @AppStorage("casterUser") private var user = ""
    @AppStorage("casterTLS") private var tls = false
    @AppStorage("casterVersion2") private var version2 = true
    @AppStorage("tcpEnabled") private var tcp = false
    @AppStorage("tcpPort") private var tcpPort = "5000"
    @State private var password = ""
    @State private var gga = ""
    @State private var roverDraft = RoverDraft()
    @State private var showRover = false
    @State private var showOptions = false
    @State private var save = false
    @State private var output: URL?
    @State private var importedFiles: [URL] = []
    @AppStorage("serialEnabled") private var serial = false
    @AppStorage("serialDevice") private var device = ""
    @State private var devices: [String] = []
    @AppStorage("serialBaud") private var baud = 115200
    @State private var monitor: NSWindow?
    @State private var mapWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 65, height: 65)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("NTRIP Scope").font(.title2.bold())
                            Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"))
                                .font(.caption.bold()).foregroundStyle(.primary)
                        }.fixedSize(horizontal: true, vertical: false)
                        Text(tr("Client NTRIP · Decoder RTCM"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    Button(tr("Mappa e cielo")) { openMap() }
                    Button(tr("Flusso in diretta")) { openMonitor() }
                    Button(tr("Opzioni…")) { showOptions = true }.disabled(radio.busy)
                    Button {
                        NTRIPDecoderClientApp.showAbout(language: language)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel(NTRIPDecoderClientApp.aboutTitle(language: language))
                    .help(NTRIPDecoderClientApp.aboutTitle(language: language))
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField(tr("Indirizzo caster"), text: $host, prompt: Text(tr("caster.esempio.it")))
                    TextField(tr("Porta"), text: $port).frame(width: 110)
                }
                HStack {
                    MountpointField(text: $mount, items: radio.mounts)
                        .frame(maxWidth: .infinity).frame(height: 24)
                    Button(tr("Scarica elenco")) { connect(list: true) }.disabled(host.isEmpty)
                }
                HStack {
                    TextField(tr("Utente"), text: $user)
                    Button(tr("Posizione rover manuale…")) { showRover = true }
                }
                SecureField("Password", text: $password)
            }
            .disabled(radio.busy)
            Spacer(minLength: 0)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(radio.status)).lineLimit(2)
                    ReceiverFixSummary(status: radio.receiverFix, active: radio.busy, manual: roverDraft.enabled)
                    if !radio.outputStatus.isEmpty { Text(radio.outputStatus).font(.caption) }
                    if !radio.ggaSource.isEmpty { Text(radio.ggaSource).font(.caption) }
                    if !radio.receiverError.isEmpty { Text(radio.receiverError).font(.caption).foregroundStyle(.red) }
                    StreamActivityBar(busy: radio.busy, start: radio.activityStart, last: radio.lastData)
                    Text("\(radio.count.formatted()) \(tr("byte ricevuti"))").font(.caption.monospacedDigit())
                }
                Spacer()
                if radio.busy {
                    Button(tr("Ferma")) { radio.stop() }
                } else {
                    Button(tr("Connetti")) { connect(list: false) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(host.isEmpty || mount.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 608, minHeight: 290)
        .background(InitialWindowWidth(width: 608))
        .environment(\.locale, Locale(identifier: language))
        .sheet(isPresented: $showOptions) { options }
        .onAppear { updateMapRover(); refreshDevices() }
        .onChange(of: roverDraft.enabled) { _ in updateMapRover() }
        .onChange(of: roverDraft.height) { _ in updateMapRover() }
        .onChange(of: roverDraft.separation) { _ in updateMapRover() }
        .onChange(of: roverDraft.latitude.value) { _ in updateMapRover() }
        .onChange(of: roverDraft.longitude.value) { _ in updateMapRover() }
        .sheet(isPresented: $showRover) {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("Posizione rover manuale")).font(.title2.bold())
                Divider()
                ScrollView {
                    RoverPositionEditor(draft: $roverDraft, raw: $gga)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(3)
                }
                Divider()
                HStack {
                    Spacer()
                    Button(tr("Fine")) { showRover = false }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 540, height: 410)
            .environment(\.locale, Locale(identifier: language))
        }
        .onChange(of: language) { _ in
            monitor?.title = tr("Flusso in diretta")
            mapWindow?.title = tr("Mappa e cielo")
        }
        .onDisappear {
            radio.stop()
            radio.disconnectReceiver()
            monitor?.close()
            mapWindow?.close()
        }
    }

    private func updateMapRover() {
        var position: StationPosition?
        if let lat = roverDraft.latitude.value, let lon = roverDraft.longitude.value {
            position = StationPosition(latitude: lat, longitude: lon)
            position?.height = RoverAngleDraft.number(roverDraft.height) ?? 0
        }
        radio.setManualMapRover(position, enabled: roverDraft.enabled)
    }

    private func openMap() {
        if let mapWindow {
            mapWindow.makeKeyAndOrderFront(nil)
            return
        }
        let panel = ScopeAuxiliaryWindows.make(title: tr("Mappa e cielo"),
            size: NSSize(width: 740, height: 700), minimum: NSSize(width: 560, height: 540),
            name: "NTRIPScope.MapWindow", right: false)
        panel.contentView = NSHostingView(rootView: MapWindowContent(radio: radio))
        mapWindow = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Opzioni NTRIP")).font(.title2.bold())
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(tr("Lingua"), selection: $language) {
                        Text("Italiano").tag("it")
                        Text("English").tag("en")
                    }.pickerStyle(.segmented)
                    Picker(tr("Versione NTRIP"), selection: $version2) {
                        Text("1.0").tag(false)
                        Text("2.0").tag(true)
                    }.pickerStyle(.segmented)
                    Toggle(tr("Connessione TLS"), isOn: $tls)
                    Toggle(tr("Salva RTCM su file"), isOn: $save).toggleStyle(.checkbox)
                    if save {
                        HStack {
                            Button(tr("Scegli file…")) {
                                let panel = NSSavePanel()
                                panel.nameFieldStringValue = "correzioni.rtcm"
                                if panel.runModal() == .OK { output = panel.url }
                            }
                            if let output { Text(output.lastPathComponent).lineLimit(1) }
                        }
                    }
                    Toggle(tr("Inoltra su TCP"), isOn: $tcp)
                    if tcp {
                        HStack {
                            Text(tr("Indirizzo locale 127.0.0.1"))
                            TextField(tr("Porta TCP"), text: $tcpPort).frame(width: 110)
                        }
                    }
                    Toggle(tr("Seriale / Bluetooth SPP (RTCM in uscita, GGA in ingresso)"), isOn: $serial)
                        .onChange(of: serial) { if $0 { refreshDevices() } }
                    if serial {
                        Text(tr("Stop ferma NTRIP e congela i dati visualizzati, mantenendo aperto il collegamento al ricevitore. Usa Disconnetti ricevitore per chiudere la porta."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if radio.receiverConnected {
                            Button(tr("Disconnetti ricevitore")) { radio.disconnectReceiver() }
                        }
                    }
                    if serial {
                        Text(tr("La posizione rover manuale attiva ha priorità sulla GGA ricevuta.")).font(.caption)
                        HStack {
                            Picker(tr("Porta"), selection: $device) {
                                Text(tr("Scegli porta")).tag("")
                                ForEach(devices, id: \.self) { Text($0).tag($0) }
                            }
                            Button(tr("Aggiorna")) { refreshDevices() }
                        }
                        Picker(tr("Velocità"), selection: $baud) {
                            ForEach([4800, 9600, 19200, 38400, 57600, 115200, 230400], id: \.self) {
                                Text("\($0) baud").tag($0)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            Divider()
            HStack {
                Spacer()
                Button(tr("Carica configurazione…")) { loadINI() }
                Button(tr("Salva configurazione…")) { saveINI() }
                Button(tr("Fine")) { showOptions = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 340)
    }

    private func saveINI() {
        do {
            let casterHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !casterHost.isEmpty,
                  !casterHost.contains(where: { $0.isWhitespace || "/?#".contains($0) }),
                  let casterPort = Int(port), (1...65535).contains(casterPort) else {
                throw INIConfiguration.Invalid(tr("Indirizzo o porta del caster non validi"))
            }
            let filePaths: [String]
            if save {
                guard let output else { throw INIConfiguration.Invalid(tr("Scegli file…")) }
                let selected = output == importedFiles.first ? importedFiles : [output]
                filePaths = selected.map(\.path)
            } else { filePaths = [] }
            let values = [casterHost, mount, user, device] + filePaths
            guard !values.contains(where: { $0.contains(where: \.isNewline) }) else {
                throw INIConfiguration.Invalid(tr("I valori INI devono stare su una sola riga"))
            }
            var lines = [
                "[caster]", "host = \(casterHost)", "port = \(casterPort)", "mountpoint = \(mount)",
                "username = \(user)", "version = \(version2 ? 2 : 1)", "tls = \(tls)",
            ]
            if roverDraft.enabled {
                guard let rover = roverDraft.position else {
                    throw INIConfiguration.Invalid(tr("Coordinate rover non valide"))
                }
                let locale = Locale(identifier: "en_US_POSIX")
                lines += [
                    "", "[rover]",
                    String(format: "latitude = %.6f", locale: locale, rover.latitude),
                    String(format: "longitude = %.6f", locale: locale, rover.longitude),
                    String(format: "height = %.3f", locale: locale, rover.ellipsoidalHeight),
                    String(format: "geoid = %.3f", locale: locale, rover.geoidSeparation),
                ]
            } else if !gga.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw INIConfiguration.Invalid(tr("Inserisci le coordinate del rover per esportare le impostazioni GGA"))
            }
            if save || tcp || serial { lines += ["", "[outputs]"] }
            if let first = filePaths.first {
                lines.append("file = \(first)")
                lines += filePaths.dropFirst().map { "    \($0)" }
            }
            if tcp {
                guard let port = Int(tcpPort), (1...65535).contains(port) else {
                    throw INIConfiguration.Invalid(tr("Porta TCP non valida"))
                }
                lines.append("tcp = \(port)")
            }
            if serial {
                guard !device.isEmpty, baud > 0 else { throw INIConfiguration.Invalid(tr("Scegli porta")) }
                lines.append("serial = \(device):\(baud)")
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "ntripscope.ini"
            if let type = UTType(filenameExtension: "ini") { panel.allowedContentTypes = [type] }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            radio.status = password.isEmpty ? "Configurazione salvata" : "Configurazione salvata senza password"
            showOptions = false
        } catch {
            let alert = NSAlert()
            alert.messageText = tr("Impossibile salvare la configurazione")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func loadINI() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let config = try INIConfiguration(url: url)
            host = config.host; port = String(config.port); mount = config.mount
            user = config.username; password = config.password; tls = config.tls
            version2 = config.version == 2
            importedFiles = config.files
            save = !config.files.isEmpty; output = config.files.first
            tcp = config.tcp != nil; tcpPort = String(config.tcp ?? 5000)
            refreshDevices()
            serial = config.serial != nil; device = config.serial?.0 ?? ""; baud = config.serial?.1 ?? 115200
            if !device.isEmpty && !devices.contains(device) { devices.append(device) }
            gga = ""
            roverDraft = RoverDraft()
            if let (lat, lon) = config.coordinates {
                let locale = Locale(identifier: language)
                roverDraft.enabled = true
                roverDraft.latitude.decimal = String(lat)
                roverDraft.longitude.decimal = String(lon)
                roverDraft.latitude.updateDecimal(limit: 90, locale: locale)
                roverDraft.longitude.updateDecimal(limit: 180, locale: locale)
                roverDraft.height = String(config.height)
                roverDraft.separation = String(config.geoid)
            }
            radio.status = "Configurazione caricata"
            showOptions = false
        } catch {
            let alert = NSAlert()
            alert.messageText = tr("Configurazione INI non valida")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func refreshDevices() {
        let available = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        devices = available.filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/" + $0 }
        // Keep the saved selection even when the paired device is temporarily unavailable.
        if !device.isEmpty && !devices.contains(device) { devices.append(device) }
    }

    private func connect(list: Bool) {
        let rover = roverDraft.enabled ? roverDraft.position : nil
        if !list && roverDraft.enabled && rover == nil {
            radio.status = "Completa latitudine, longitudine e quota ellissoidica."
            showRover = true
            return
        }
        if !list && save && output == nil {
            radio.status = "Scegli il file RTCM nelle opzioni"
            showOptions = true
            return
        }
        let extra = save && output == importedFiles.first ? Array(importedFiles.dropFirst()) : []
        if !list, save, let output, ([output] + extra).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let alert = NSAlert()
            alert.messageText = tr("Sovrascrivere i file di uscita esistenti?")
            alert.addButton(withTitle: tr("Sovrascrivi"))
            alert.addButton(withTitle: tr("Annulla"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        radio.start(host: host, port: port, mount: mount, user: user, password: password,
                    tls: tls, version2: version2, list: list, gga: roverDraft.enabled ? "" : gga,
                    output: save ? output : nil, tcpPort: tcp ? tcpPort : nil,
                    serialDevice: serial ? device : nil, baud: baud, rover: rover, additionalFiles: extra)
    }

    private func openMonitor() {
        if let monitor {
            monitor.makeKeyAndOrderFront(nil)
            return
        }
        let panel = ScopeAuxiliaryWindows.make(title: tr("Flusso in diretta"),
            size: NSSize(width: 760, height: 660), minimum: NSSize(width: 560, height: 470),
            name: "NTRIPScope.LiveWindow", right: true)
        panel.contentView = NSHostingView(rootView: StreamMonitor(radio: radio))
        monitor = panel
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct StreamActivityBar: View {
    let busy: Bool
    let start: Date?
    let last: Date?
    private let segments = 12
    private let step: TimeInterval = 0.12

    var body: some View {
        TimelineView(.periodic(from: .now, by: step)) { context in
            let active = busy && last.map { context.date.timeIntervalSince($0) < Radio.activityTimeout } == true
            let elapsed = max(0, start.map { context.date.timeIntervalSince($0) } ?? 0)
            let lit = active ? Int(elapsed / step) % (segments + 1) : 0

            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index < lit ? Color.green : Color.secondary.opacity(0.20))
                }
            }
            .frame(width: 150, height: 9)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr(active ? "Dati in arrivo" : "Nessun dato recente"))
        }
    }
}

private struct MapWindowContent: View {
    @ObservedObject var radio: Radio
    @AppStorage(AppLanguage.key) private var language = "en"
    @AppStorage("casterHost") private var host = ""
    @AppStorage("casterPort") private var port = "2101"
    @AppStorage("casterMount") private var mount = ""
    @AppStorage("casterTLS") private var tls = false

    var body: some View {
        let name = Radio.cleanMount(mount)
        let caster = Radio.casterKey(host, port, tls)
        let activeStream = radio.streamKey == "\(caster)|\(name)"
        let fromStream = radio.stationPosition(for: "\(caster)|\(name)")
        let lastKnown = fromStream != nil && (!activeStream || radio.rtcm.antenna == nil || !radio.busy)
        let advertised = radio.sourceCaster == caster ? radio.advertisedLocations[name] : nil
        MountpointMap(name: name, position: fromStream ?? advertised, fromRTCM: fromStream != nil, rover: radio.mapRover,
                      stationIsLastKnown: lastKnown,
                      roverSource: radio.roverMap.effective?.source ?? "",
                      roverHeightAvailable: radio.roverMap.effective?.heightAvailable ?? false,
                      receiverFix: radio.receiverFix, receiverActive: radio.busy, manualRover: radio.roverMap.manualIsEnabled,
                      ephemerides: activeStream ? Array(radio.rtcm.gpsOrbits.values) : [],
                      epoch: activeStream ? radio.rtcm.gpsEpoch : nil)
            .padding(16)
            .environment(\.locale, Locale(identifier: language))
    }
}

private func hexDump(_ bytes: [UInt8], ascii: Bool = false) -> String {
    stride(from: 0, to: bytes.count, by: 16).map { offset in
        let line = bytes[offset..<min(offset + 16, bytes.count)]
        let hex = line.map { String(format: "%02X", Int($0)) }.joined(separator: " ")
        guard ascii else { return hex }
        let text = String(decoding: line.map { (32...126).contains($0) ? $0 : 46 }, as: UTF8.self)
        return hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  |" + text + "|"
    }.joined(separator: "\n")
}

@MainActor
struct StreamMonitor: View {
    let radio: Radio
    @AppStorage(AppLanguage.key) private var language = "en"
    @State private var decode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(tr("Vista"), selection: $decode) {
                Text(tr("HEX e ASCII")).tag(false)
                Text(tr("Decoder RTCM3")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            // Each child owns its updates. Receiver traffic cannot invalidate decoder controls.
            ZStack {
                RawStreamMonitor(radio: radio, active: !decode)
                    .opacity(decode ? 0 : 1).allowsHitTesting(!decode).accessibilityHidden(decode)
                RTCMStreamMonitor(radio: radio, active: decode)
                    .opacity(decode ? 1 : 0).allowsHitTesting(decode).accessibilityHidden(!decode)
            }
        }
        .padding(16)
        .environment(\.locale, Locale(identifier: language))
    }
}

@MainActor
private struct RawStreamMonitor: View {
    let radio: Radio
    let active: Bool
    @State private var selectedReceiver = ""
    @State private var display = StreamMonitorSnapshot()
    private let refresh = Timer.publish(every: 0.25, on: .main, in: .default).autoconnect()

    private var receiverText: String {
        guard let data = display.receivers[selectedReceiver] else { return tr("In attesa di dati dal ricevitore…") }
        let bytes = Array(data)
        let ascii = String(bytes.map { (32..<127).contains($0) || $0 == 10 || $0 == 13 ? Character(UnicodeScalar(Int($0))!) : "." })
        return "ASCII\n\(ascii)\n\nHEX + ASCII · \(tr("Ultimi 256 byte"))\n" + hexDump(Array(bytes.suffix(256)), ascii: true)
    }

    private func streamPane(title: String, count: Int, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(count.formatted()) \(tr("byte ricevuti"))").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(text).font(.system(.body, design: .monospaced))
                    .fixedSize().textSelection(.enabled).padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(8)
        .frame(minHeight: 100)
    }

    private func updateSnapshot() {
        display.update(status: radio.status, count: radio.count, recent: radio.recent,
                       receivers: radio.receiverStreams, receiverCounts: radio.receiverCounts)
        if selectedReceiver.isEmpty || display.receivers[selectedReceiver] == nil {
            let source = display.receivers.keys.sorted().first ?? ""
            if source != selectedReceiver { selectedReceiver = source }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr(display.status)).font(.headline)
                VSplitView {
                    streamPane(title: tr("Caster → RTCM"), count: display.count,
                               text: display.recent.isEmpty ? tr("In attesa di dati…") : hexDump(Array(display.recent), ascii: true))
                    VStack(alignment: .leading, spacing: 4) {
                        if !display.receivers.isEmpty {
                            Picker(tr("Sorgente ricevitore"), selection: $selectedReceiver) {
                                ForEach(display.receivers.keys.sorted(), id: \.self) { source in
                                    Text(source).tag(source)
                                }
                            }.padding(.horizontal, 8)
                        }
                        streamPane(title: tr("Ricevitore → Client"), count: display.receiverCounts[selectedReceiver] ?? 0,
                                   text: receiverText)
                    }.frame(minHeight: 140)
                }
                Text(tr("Pannelli indipendenti · Trascina il separatore per ridimensionarli."))
                    .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { updateSnapshot() }
        .onChange(of: active) { visible in if visible { updateSnapshot() } }
        .onReceive(refresh) { _ in if active { updateSnapshot() } }
    }
}

@MainActor
private struct RTCMStreamMonitor: View {
    let radio: Radio
    let active: Bool
    @State private var graph = false
    @State private var detailTab = "fields"
    @State private var model = RTCMMonitorState()
    // Default mode deliberately does not update native popup menus during tracking.
    private let refresh = Timer.publish(every: 0.25, on: .main, in: .default).autoconnect()

    private func updateDecoder() {
        if model.needsUpdate(radio.rtcm, generation: radio.monitorGeneration) {
            model.update(radio.rtcm, generation: radio.monitorGeneration)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(tr("Pausa aggiornamento decoder"), isOn: $model.paused).toggleStyle(.checkbox)
                Spacer()
                Text(tr(model.paused ? "Vista ferma · Ricezione e registrazione continuano" : "Dettagli in tempo reale"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            decoder
        }
        .onAppear { updateDecoder() }
        .onChange(of: active) { visible in if visible { updateDecoder() } }
        .onChange(of: model.paused) { paused in if !paused { updateDecoder() } }
        .onReceive(refresh) { _ in if active { updateDecoder() } }
    }

    private var decoder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(tr("Frame con CRC errato")): \(model.decoder.badCRC.formatted()) · \(tr("Segnali MSM osservati nella sessione"))")
                .font(.caption).foregroundStyle(.secondary)
            if model.decoder.messages.isEmpty {
                Text(tr("In attesa di un messaggio RTCM3 valido…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                Table(model.decoder.messages.values.sorted { $0.id < $1.id }, selection: Binding(get: { model.selectedType }, set: { model.selectType($0) })) {
                    TableColumn(tr("Tipo")) { Text(String($0.id)) }.width(min: 45, ideal: 55)
                    TableColumn(tr("Messaggio"), value: \.name).width(min: 110, ideal: 195)
                    TableColumn(tr("N.")) { Text($0.count.formatted()) }.width(min: 40, ideal: 55)
                    TableColumn(tr("Segnali / dettagli")) { message in
                        let signals = message.signalList
                        Text(signals.isEmpty ? tr("Seleziona per il dettaglio") : signals)
                            .help(signals)
                    }
                }.frame(minHeight: 140, maxHeight: .infinity)
                if let selectedType = model.selectedType, let message = model.decoder.messages[selectedType] {
                    details(message)
                } else {
                    Text(tr("Seleziona un tipo per consultare i singoli frame."))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: .infinity, alignment: .topLeading)
                }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func details(_ message: RTCMDecoder.Summary) -> some View {
        let frame = model.displayedFrame
        let choice = Binding<Int?>(
            get: { model.pinnedFrame?.id },
            set: { model.selectFrame($0) }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("\(message.id) · \(message.name)").font(.headline)
                Spacer()
                Picker("Frame", selection: choice) {
                    Text(tr("Ultimo ricevuto")).tag(nil as Int?)
                    ForEach(model.availableFrames.reversed()) { frame in
                        Text("#\(frame.id) · \(frame.time.formatted(date: .omitted, time: .standard))")
                            .tag(Optional(frame.id))
                    }
                }.fixedSize()
            }
            Text(tr("Fino a 20 frame recenti per tipo")).font(.caption).foregroundStyle(.secondary)
            if let frame {
                RTCMDetailTabs(selection: $detailTab)
                Group {
                    if detailTab == "fields" {
                        LeadingDecoderScroll {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("RTCM \(frame.type) · \(frame.payload.count) \(tr("byte"))").font(.caption.bold())
                                Text(frame.detail).textSelection(.enabled)
                                Text("Payload HEX").font(.caption.bold())
                                Text(hexDump(frame.payload)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    } else if detailTab == "measurements" {
                        LeadingDecoderScroll {
                            VStack(alignment: .leading) {
                                if let rows = try? frame.measurements(), !rows.isEmpty {
                                    numericMeasurements(rows, compact: frame.type % 10 <= 3)
                                } else {
                                    Text(tr("Nessuna misura decodificabile in questo frame."))
                                }
                            }
                        }
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            if let rows = try? frame.measurements() {
                                signalChart(rows).padding(8)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity, alignment: .topLeading)

            }
        }.frame(maxWidth: .infinity, minHeight: 230, maxHeight: .infinity, alignment: .topLeading)
    }
    @ViewBuilder
    private func signalChart(_ rows: [RTCMDecoder.Frame.Measurement]) -> some View {
        let valid = rows.filter { $0.cnr != nil }
        if valid.isEmpty {
            Text(tr("Nessun valore C/N₀ disponibile in questo frame."))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(Array(valid.enumerated()), id: \.offset) { _, row in
                    if let cnr = row.cnr {
                        PointMark(
                            x: .value(tr("Slot satellite"), String(row.slot)),
                            y: .value("C/N₀", cnr)
                        )
                        .foregroundStyle(by: .value(tr("Segnale"), row.signal))
                        .symbol(by: .value(tr("Segnale"), row.signal))
                        .symbolSize(64)
                    }
                }
            }
            .chartYScale(domain: 0...65)
            .chartXAxisLabel(tr("Slot satellite"))
            .chartYAxisLabel("C/N₀ (dB-Hz)")
            .chartLegend(position: .bottom)
            .frame(height: 190)
            .padding(.vertical, 5)
            Text(tr("Ogni punto rappresenta un segnale ricevuto per lo slot indicato."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func measurementTable(_ frame: RTCMDecoder.Frame) -> some View {
        if let rows = try? frame.measurements(), !rows.isEmpty {
            Text(tr("Misure per satellite e segnale")).font(.headline)
            Picker(tr("Vista"), selection: $graph) {
                Text(tr("Tabella")).tag(false)
                Text(tr("Grafico C/N₀")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if graph {
                signalChart(rows)
            } else {
                numericMeasurements(rows, compact: frame.type % 10 <= 3)
            }
        } else {
            Text(tr("Nessuna misura decodificabile in questo frame."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func numericMeasurements(_ rows: [RTCMDecoder.Frame.Measurement], compact: Bool) -> some View {
        if compact {
            Text(tr("MSM compatto · Distanze modulo 1 ms, con ambiguità di millisecondi interi."))
                .font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading) {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("Slot")
                    Text(tr("Segnale"))
                    Text(tr("Pseudodist. (m)"))
                    Text(tr("Fase (m)"))
                    Text("C/N₀ (dB-Hz)")
                    Text(tr("Velocità (m/s)"))
                }.fontWeight(.semibold)
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(String(row.slot))
                        Text(row.signal)
                        Text(measurement(row.pseudorange, digits: 4))
                        Text(measurement(row.phaseRange, digits: 4))
                        Text(measurement(row.cnr, digits: 4))
                        Text(measurement(row.rate, digits: 4))
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize()
        }
        Text(tr("— indica una misura assente o non valida. La fase è espressa come distanza equivalente."))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func measurement(_ value: Double?, digits: Int) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(digits)))
    }

}

@main
struct NTRIPDecoderClientApp: App {
    @AppStorage(AppLanguage.key) private var language = "en"

    static func aboutTitle(language: String) -> String {
        language == "it" ? "Informazioni su NTRIP Scope" : "About NTRIP Scope"
    }

    @MainActor
    static func showAbout(language: String) {
        let italian = language == "it"
        let project = URL(string: "https://github.com/zuliani71/NTRIP-Scope")!
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let alert = NSAlert()
        alert.messageText = "NTRIP Scope"
        alert.icon = NSApp.applicationIconImage
        let versionLabel = italian ? "Versione" : "Version"
        let materials = italian
            ? "Materiali originali pubblicati dal progetto con licenza CC BY 4.0, salvo diversa indicazione."
            : "Original published project materials use CC BY 4.0 unless indicated otherwise."
        alert.informativeText = "\(versionLabel) \(version)\nDavid Zuliani (zuliani71)\n\nSoftware MIT\n\(materials)\n\n\(project.absoluteString)"
        alert.addButton(withTitle: italian ? "Chiudi" : "Close")
        alert.addButton(withTitle: italian ? "Apri su GitHub" : "Open on GitHub")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(project) }
    }

    var body: some Scene {
        WindowGroup("NTRIP Scope") { RadioView() }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 608, height: 340)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .appInfo) {
                    Button(Self.aboutTitle(language: language)) { Self.showAbout(language: language) }
                }
            }
    }
}
