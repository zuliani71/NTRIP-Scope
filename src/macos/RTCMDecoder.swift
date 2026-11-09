import Foundation

struct RTCMDecoder {
    private var buffer = [UInt8]()
    private(set) var messages = [Int: Summary]()
    private(set) var badCRC = 0

    private(set) var antenna: StationPosition?
    private(set) var gpsOrbits: [Int: GPSEphemeris] = [:]
    private(set) var gpsEpoch: GPSEpoch?

    struct GPSEpoch {
        let tow: Double
        let week: Int

        init(tow: Double, receivedAt: Date) {
            self.tow = tow
            // Use reception time only to resolve the week around the transmitted GPS epoch.
            let secondsSinceGPSEpoch = receivedAt.timeIntervalSince1970 - 315_964_800
            week = Int(((secondsSinceGPSEpoch - tow) / 604_800).rounded())
        }
    }

    struct Summary: Identifiable {
        let id: Int
        var count = 0
        var signals = Set<Int>()
        var frames: [Frame] = []

        var name: String {
            if let system = RTCMDecoder.systems[id / 10], (1...7).contains(id % 10) {
                return "\(system) MSM\(id % 10)"
            }
            return tr(RTCMDecoder.names[id] ?? "Messaggio RTCM3")
        }

        var signalList: String { RTCMDecoder.labels(signals.sorted(), type: id) }
    }

    mutating func receive(_ data: Data) {
        buffer.append(contentsOf: data)
        var cursor = 0
        while cursor < buffer.count {
            guard buffer[cursor] == 0xD3 else { cursor += 1; continue }
            guard buffer.count - cursor >= 3 else { break }
            let high = buffer[cursor + 1]
            let length = (Int(high & 3) << 8) | Int(buffer[cursor + 2])
            guard high & 0xFC == 0, length >= 2 else { cursor += 1; continue }
            let end = cursor + 3 + length
            guard buffer.count >= end + 3 else { break }
            let expected = (UInt32(buffer[end]) << 16) | (UInt32(buffer[end + 1]) << 8) | UInt32(buffer[end + 2])
            guard Self.crc24q(buffer[cursor..<end]) == expected else {
                badCRC += 1
                cursor += 1
                continue
            }
            let payload = Array(buffer[(cursor + 3)..<end])
            let type = (Int(payload[0]) << 4) | Int(payload[1] >> 4)
            var summary = messages[type] ?? Summary(id: type)
            summary.count += 1
            let frame = Frame(id: summary.count, time: Date(), type: type, payload: payload)
            summary.frames.append(frame)
            if summary.frames.count > 20 { summary.frames.removeFirst() }
            if let msm = try? frame.msm() {
                summary.signals.formUnion(msm.cells.flatMap { $0.signals })
                if type / 10 == 107 && msm.epoch < 604_800_000 {
                    gpsEpoch = GPSEpoch(tow: Double(msm.epoch) / 1000, receivedAt: frame.time)
                }
            }
            if let coordinates = try? frame.antennaECEF() {
                antenna = StationPosition(ecef: coordinates) ?? antenna
            }
            if let orbit = try? frame.gpsEphemeris() {
                gpsOrbits[orbit.prn] = orbit
            }
            messages[type] = summary
            cursor = end + 3
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
    }

    private static func crc24q(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0
        for byte in bytes {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x1000000 != 0 { crc ^= 0x1864CFB }
            }
        }
        return crc
    }

    static func labels(_ ids: [Int], type: Int) -> String {
        let codes = signalCodes[type / 10] ?? [:]
        return ids.map { codes[$0] ?? "ID \($0)" }.joined(separator: ", ")
    }

    private static let systems = [107: "GPS", 108: "GLONASS", 109: "Galileo", 110: "SBAS",
                                  111: "QZSS", 112: "BeiDou", 113: "NavIC"]
    private static let names = [
        1001: "Osservazioni GPS L1", 1002: "Osservazioni GPS L1 estese",
        1003: "Osservazioni GPS L1/L2", 1004: "Osservazioni GPS L1/L2 estese",
        1005: "Coordinate stazione", 1006: "Coordinate e altezza antenna",
        1007: "Descrittore antenna", 1008: "Descrittore e seriale antenna",
        1009: "Osservazioni GLONASS L1", 1010: "Osservazioni GLONASS L1 estese",
        1011: "Osservazioni GLONASS L1/L2", 1012: "Osservazioni GLONASS L1/L2 estese",
        1013: "Parametri di sistema", 1019: "Effemeridi GPS", 1020: "Effemeridi GLONASS",
        1033: "Descrittori ricevitore e antenna", 1041: "Effemeridi NavIC",
        1042: "Effemeridi BeiDou", 1043: "Effemeridi SBAS", 1044: "Effemeridi QZSS",
        1045: "Effemeridi Galileo F/NAV", 1046: "Effemeridi Galileo I/NAV", 1230: "Bias di codice GLONASS"
    ]

    // RTCM signal mask positions and RINEX codes, as used by RTKLIB demo5.
    private static let signalCodes: [Int: [Int: String]] = [
        107: [2:"1C", 3:"1P", 4:"1W", 8:"2C", 9:"2P", 10:"2W", 15:"2S", 16:"2L",
              17:"2X", 22:"5I", 23:"5Q", 24:"5X", 30:"1S", 31:"1L", 32:"1X"],
        108: [2:"1C", 3:"1P", 8:"2C", 9:"2P"],
        109: [2:"1C", 3:"1A", 4:"1B", 5:"1X", 6:"1Z", 8:"6C", 9:"6A", 10:"6B", 11:"6X",
              12:"6Z", 14:"7I", 15:"7Q", 16:"7X", 18:"8I", 19:"8Q", 20:"8X", 22:"5I", 23:"5Q", 24:"5X"],
        110: [2:"1C", 22:"5I", 23:"5Q", 24:"5X"],
        111: [2:"1C", 9:"6S", 10:"6L", 11:"6X", 15:"2S", 16:"2L", 17:"2X",
              22:"5I", 23:"5Q", 24:"5X", 30:"1S", 31:"1L", 32:"1X"],
        112: [2:"2I", 3:"2Q", 4:"2X", 8:"6I", 9:"6Q", 10:"6X", 14:"7I", 15:"7Q",
              16:"7X", 22:"5D", 23:"5P", 24:"5X", 25:"7D", 30:"1D", 31:"1P", 32:"1X"],
        113: [8:"9A", 22:"5A"]
    ]

    struct Frame: Identifiable {
        let id: Int
        let time: Date
        let type: Int
        let payload: [UInt8]

        func antennaECEF() throws -> SIMD3<Double>? {
            guard type == 1005 || type == 1006 else { return nil }
            var bits = Bits(payload)
            try bits.skip(22)
            let x = try bits.signed(38)
            try bits.skip(2)
            let y = try bits.signed(38)
            try bits.skip(2)
            let z = try bits.signed(38)
            return SIMD3(Double(x), Double(y), Double(z)) / 10_000
        }

        func gpsEphemeris() throws -> GPSEphemeris? {
            guard type == 1019, payload.count >= 61 else { return nil }
            var bits = Bits(payload)
            let prn = try bits.read(6)
            let week = try bits.read(10)
            try bits.skip(6)
            let inclinationRate = try Double(bits.signed(14)) * 0x1p-43 * .pi
            try bits.skip(80)
            let crs = try Double(bits.signed(16)) * 0x1p-5
            let deltaMotion = try Double(bits.signed(16)) * 0x1p-43 * .pi
            let meanAnomaly = try Double(bits.signed(32)) * 0x1p-31 * .pi
            let cuc = try Double(bits.signed(16)) * 0x1p-29
            let eccentricity = try Double(bits.read(32)) * 0x1p-33
            let cus = try Double(bits.signed(16)) * 0x1p-29
            let root = try Double(bits.read(32)) * 0x1p-19
            let toe = try Double(bits.read(16)) * 16
            let cic = try Double(bits.signed(16)) * 0x1p-29
            let node = try Double(bits.signed(32)) * 0x1p-31 * .pi
            let cis = try Double(bits.signed(16)) * 0x1p-29
            let inclination = try Double(bits.signed(32)) * 0x1p-31 * .pi
            let crc = try Double(bits.signed(16)) * 0x1p-5
            let perigee = try Double(bits.signed(32)) * 0x1p-31 * .pi
            let nodeRate = try Double(bits.signed(24)) * 0x1p-43 * .pi
            try bits.skip(8)
            let health = try bits.read(6)
            guard (1...32).contains(prn), health == 0, (4500...6000).contains(root), toe < 604_800 else { return nil }
            return GPSEphemeris(prn: prn, week: week, toe: toe, semiMajor: root * root,
                               eccentricity: eccentricity, meanAnomaly: meanAnomaly,
                               deltaMotion: deltaMotion, inclination: inclination,
                               inclinationRate: inclinationRate, node: node, nodeRate: nodeRate,
                               perigee: perigee, crs: crs, crc: crc, cus: cus, cuc: cuc, cis: cis, cic: cic)
        }

        struct MSM {
            let station: Int
            let epoch: Int
            let multiple: Bool
            let cells: [(slot: Int, signals: [Int])]
        }

        func msm() throws -> MSM? {
            guard RTCMDecoder.systems[type / 10] != nil, (1...7).contains(type % 10) else { return nil }
            var bits = Bits(payload)
            let station = try bits.read(12)
            let epoch = try bits.read(30)
            let multiple = try bits.read(1) == 1
            _ = try bits.read(18)
            let satellites = try bits.mask(64)
            let signals = try bits.mask(32)
            var cells: [(Int, [Int])] = []
            for slot in satellites {
                var active: [Int] = []
                for signal in signals {
                    if try bits.read(1) == 1 { active.append(signal) }
                }
                cells.append((slot, active))
            }
            return MSM(station: station, epoch: epoch, multiple: multiple, cells: cells)
        }

        struct Measurement {
            let slot: Int
            let signal: String
            let pseudorange: Double?
            let phaseRange: Double?
            let cnr: Double?
            let rate: Double?
        }

        func measurements() throws -> [Measurement] {
            guard let msm = try msm() else { return [] }
            let level = type % 10
            let extended = level >= 6
            let hasRate = level == 5 || level == 7
            let hasCode = level != 2
            let hasPhase = level != 1
            let satelliteCount = msm.cells.count
            let cellCount = msm.cells.reduce(0) { $0 + $1.signals.count }
            var bits = Bits(payload)
            try bits.skip(12 + 30 + 1 + 18)
            _ = try bits.mask(64)
            let signalCount = try bits.mask(32).count
            try bits.skip(satelliteCount * signalCount)

            let integer = level >= 4 ? try bits.values(satelliteCount, width: 8) : Array(repeating: 0, count: satelliteCount)
            if hasRate { try bits.skip(satelliteCount * 4) }
            let modulo = try bits.values(satelliteCount, width: 10)
            let roughRate = hasRate ? try bits.values(satelliteCount, width: 14, signed: true) : []
            let codeWidth = extended ? 20 : 15
            let phaseWidth = extended ? 24 : 22
            let code = hasCode ? try bits.values(cellCount, width: codeWidth, signed: true) : []
            let phase = hasPhase ? try bits.values(cellCount, width: phaseWidth, signed: true) : []
            if hasPhase { try bits.skip(cellCount * (extended ? 11 : 5)) }
            let cnr = level >= 4 ? try bits.values(cellCount, width: extended ? 10 : 6) : []
            let fineRate = hasRate ? try bits.values(cellCount, width: 15, signed: true) : []
            let metersPerMillisecond = 299_792.458
            let codeScale = metersPerMillisecond / Double(1 << (extended ? 29 : 24))
            let phaseScale = metersPerMillisecond / Double(1 << (extended ? 31 : 29))

            var index = 0
            var rows: [Measurement] = []
            for (satellite, cell) in msm.cells.enumerated() {
                let base = (Double(integer[satellite]) + Double(modulo[satellite]) / 1024) * metersPerMillisecond
                let validBase = integer[satellite] != 255
                for signal in cell.signals {
                    let pseudorange = hasCode && validBase && code[index] != -(1 << (codeWidth - 1))
                        ? base + Double(code[index]) * codeScale : nil
                    let phaseRange = hasPhase && validBase && phase[index] != -(1 << (phaseWidth - 1))
                        ? base + Double(phase[index]) * phaseScale : nil
                    let carrierNoise = level >= 4 && cnr[index] != 0
                        ? Double(cnr[index]) / (extended ? 16 : 1) : nil
                    let rate = hasRate && roughRate[satellite] != -8192 && fineRate[index] != -16384
                        ? Double(roughRate[satellite]) + Double(fineRate[index]) * 0.0001 : nil
                    rows.append(Measurement(slot: cell.slot, signal: RTCMDecoder.labels([signal], type: type),
                                            pseudorange: pseudorange, phaseRange: phaseRange,
                                            cnr: carrierNoise, rate: rate))
                    index += 1
                }
            }
            return rows
        }

        var detail: String {
            do { return try decodedLines().joined(separator: "\n") }
            catch { return "\(tr("Payload troppo corto per i campi del tipo")) \(type)." }
        }

        private func decodedLines() throws -> [String] {
            if let msm = try msm() {
                let epoch = type / 10 == 108
                    ? "\(tr("Epoca GLONASS")): \(tr("giorno")) \(msm.epoch >> 27), \(msm.epoch & 0x7FFFFFF) ms"
                    : "\(tr("Epoca GNSS")): \(msm.epoch) ms"
                return ["\(tr("Stazione")) \(msm.station)", epoch,
                        "\(tr("Altri messaggi nella stessa epoca")): \(msm.multiple ? tr("sì") : tr("no"))",
                        "\(tr("Satelliti nella maschera")): \(msm.cells.count)", ""]
                    + msm.cells.map { cell in
                        let names = RTCMDecoder.labels(cell.signals, type: type)
                        return "\(tr("Slot satellite")) \(cell.slot) · \(names.isEmpty ? tr("nessuna cella attiva") : names)"
                    }
            }
            var bits = Bits(payload)
            switch type {
            case 1005, 1006:
                let station = try bits.read(12)
                let itrf = try bits.read(6)
                _ = try bits.read(4)
                let x = try bits.signed(38)
                _ = try bits.read(2)
                let y = try bits.signed(38)
                _ = try bits.read(2)
                let z = try bits.signed(38)
                var lines = ["\(tr("Stazione")) \(station)", "\(tr("Indicatore ITRF")): \(itrf)",
                             tr("Coordinate ECEF del punto di riferimento antenna (ARP)"),
                             "X: \(meters(x))", "Y: \(meters(y))", "Z: \(meters(z))"]
                if type == 1006 { lines.append("\(tr("Altezza antenna")): \(meters(try bits.read(16)))") }
                return lines
            case 1007, 1008, 1033:
                var lines = ["\(tr("Stazione")) \(try bits.read(12))",
                             "\(tr("Descrittore antenna")): \(try bits.text())",
                             "\(tr("ID configurazione antenna")): \(try bits.read(8))"]
                if type != 1007 { lines.append("\(tr("Seriale antenna")): \(try bits.text())") }
                if type == 1033 {
                    lines.append("\(tr("Modello ricevitore")): \(try bits.text())")
                    lines.append("\(tr("Firmware ricevitore")): \(try bits.text())")
                    lines.append("\(tr("Seriale ricevitore")): \(try bits.text())")
                }
                return lines
            case 1013:
                let station = try bits.read(12)
                let mjd = try bits.read(16)
                let seconds = try bits.read(17)
                let count = try bits.read(5)
                let leap = try bits.read(8)
                var lines = ["\(tr("Stazione")) \(station)", "\(tr("Giorno giuliano modificato")): \(mjd)",
                             "\(tr("Secondi del giorno UTC")): \(seconds)", "GPS − UTC: \(leap) s",
                             "\(tr("Messaggi annunciati")): \(count)"]
                for _ in 0..<count {
                    let announced = try bits.read(12)
                    let synchronized = try bits.read(1) == 1
                    let interval = try bits.read(16)
                    let period = interval == 0 ? tr("intervallo non dichiarato") : "\(Double(interval) / 10) s"
                    lines.append("\(tr("Tipo")) \(announced) · \(period) · \(tr("sincronizzato")): \(synchronized ? tr("sì") : tr("no"))")
                }
                return lines
            default:
                return [tr("Campi non decodificati per questo tipo.")]
            }
        }

        private func meters(_ value: Int) -> String {
            String(format: "%.4f m", Double(value) / 10_000)
        }
    }

    private struct Bits {
        let bytes: [UInt8]
        private var position = 12
        private struct End: Error {}
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func read(_ count: Int) throws -> Int {
            guard position + count <= bytes.count * 8 else { throw End() }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((bytes[position / 8] >> (7 - position % 8)) & 1)
                position += 1
            }
            return value
        }

        mutating func skip(_ count: Int) throws {
            guard position + count <= bytes.count * 8 else { throw End() }
            position += count
        }

        mutating func values(_ count: Int, width: Int, signed isSigned: Bool = false) throws -> [Int] {
            var result: [Int] = []
            for _ in 0..<count { result.append(try isSigned ? signed(width) : read(width)) }
            return result
        }

        mutating func signed(_ count: Int) throws -> Int {
            let value = try read(count)
            return value >= (1 << (count - 1)) ? value - (1 << count) : value
        }

        mutating func mask(_ count: Int) throws -> [Int] {
            var active: [Int] = []
            for index in 1...count {
                if try read(1) == 1 { active.append(index) }
            }
            return active
        }

        mutating func text() throws -> String {
            let count = try read(8)
            var text: [UInt8] = []
            for _ in 0..<count { text.append(UInt8(try read(8))) }
            return text.isEmpty ? tr("non trasmesso") : String(decoding: text, as: UTF8.self)
        }
    }
}
