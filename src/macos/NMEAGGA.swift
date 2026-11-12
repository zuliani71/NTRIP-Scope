import Foundation

struct NMEAGGAReader {
    private var buffer: [UInt8] = []
    var includeNoFix = false
    init(includeNoFix: Bool = false) { self.includeNoFix = includeNoFix }

    mutating func feed(_ bytes: Data) -> [String] {
        var sentences: [String] = []
        for byte in bytes {
            if byte == 36 {
                buffer = [byte]
            } else if byte == 10 || byte == 13 {
                if let sentence = String(bytes: buffer, encoding: .ascii), (includeNoFix ? Self.quality(sentence) != nil : Self.valid(sentence)) {
                    sentences.append(sentence)
                }
                buffer.removeAll(keepingCapacity: true)
            } else if !buffer.isEmpty {
                if (32...126).contains(byte) && buffer.count < 256 { buffer.append(byte) }
                else { buffer.removeAll(keepingCapacity: true) }
            }
        }
        return sentences
    }

    static func quality(_ sentence: String) -> Int? {
        let bytes = Array(sentence.utf8)
        guard bytes.count <= 256, bytes.count > 9, bytes[0] == 36,
              bytes[bytes.count-3] == 42,
              let expected = UInt8(String(sentence.suffix(2)), radix: 16),
              bytes[1..<bytes.count-3].reduce(UInt8(0), ^) == expected else { return nil }
        let fields = sentence.dropFirst().dropLast(3).split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 15, fields[0].count == 5, fields[0].hasSuffix("GGA"),
              fields[0].prefix(2).allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              fields[6].count == 1, let quality = Int(fields[6]), (0...8).contains(quality),
              quality == 0 || valid(sentence) else { return nil }
        return quality
    }

    static func valid(_ sentence: String) -> Bool {
        let bytes = Array(sentence.utf8)
        guard bytes.count <= 256, bytes.count > 9, bytes[0] == 36,
              bytes[bytes.count - 3] == 42,
              let expected = UInt8(String(sentence.suffix(2)), radix: 16),
              bytes[1..<bytes.count - 3].reduce(UInt8(0), ^) == expected else { return false }
        let fields = sentence.dropFirst().dropLast(3).split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 15, fields[0].count == 5, fields[0].hasSuffix("GGA"),
              fields[0].prefix(2).allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              let fix = Int(fields[6]), (1...8).contains(fix) else { return false }
        for (raw, hemisphere, width, limit) in [(fields[2], fields[3], 2, 90.0), (fields[4], fields[5], 3, 180.0)] {
            guard (width == 2 ? ["N", "S"] : ["E", "W"]).contains(String(hemisphere)),
                  raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  raw.split(separator: ".").first?.count == width + 2,
                  let degrees = Double(raw.prefix(width)), let minutes = Double(raw.dropFirst(width)),
                  minutes.isFinite, (0..<60).contains(minutes), degrees + minutes / 60 <= limit else { return false }
        }
        for index in [9, 11] where !fields[index].isEmpty {
            guard let number = Double(fields[index]), number.isFinite else { return false }
        }
        return true
    }
    /// NMEA GGA altitude is orthometric (H); ellipsoidal height is H + geoid separation.
    static func location(_ sentence: String) -> (position: StationPosition, heightAvailable: Bool)? {
        guard valid(sentence) else { return nil }
        let f = sentence.dropFirst().dropLast(3).split(separator: ",", omittingEmptySubsequences: false)
        func angle(_ raw: Substring, _ width: Int, _ hemisphere: Substring) -> Double {
            let value = Double(raw.prefix(width))! + Double(raw.dropFirst(width))! / 60
            return hemisphere == "S" || hemisphere == "W" ? -value : value
        }
        guard var position = StationPosition(latitude: angle(f[2], 2, f[3]), longitude: angle(f[4], 3, f[5])) else { return nil }
        var heightAvailable = !f[9].isEmpty && !f[11].isEmpty && f[10] == "M" && f[12] == "M"
        if heightAvailable {
            let height = Double(f[9])! + Double(f[11])!
            heightAvailable = height.isFinite
            if heightAvailable { position.height = height }
        }
        return (position, heightAvailable)
    }

}


struct RoverMapState {
    struct Location {
        let position: StationPosition
        let heightAvailable: Bool
        let source: String
    }
    private var manual: StationPosition?
    private var manualEnabled = false
    var manualIsEnabled: Bool { manualEnabled }
    private var received: Location?

    var effective: Location? {
        let manualLocation = manual.map { Location(position: $0, heightAvailable: true, source: "Coordinate manuali") }
        if manualEnabled, let manualLocation { return manualLocation }
        return received ?? manualLocation
    }

    mutating func setManual(_ position: StationPosition?, enabled: Bool) {
        manual = position
        manualEnabled = enabled
    }
    mutating func receive(_ sentence: String, source: String) {
        guard let result = NMEAGGAReader.location(sentence) else { return }
        received = Location(position: result.position, heightAvailable: result.heightAvailable, source: source)
    }
    mutating func resetReceived() { received = nil }
}

struct ReceiverFixStatus {
    let quality: Int
    let received: Date
    let source: String
    var label: String {
        [0: "NO FIX", 1: "GNSS", 2: "DGNSS", 4: "RTK FIXED", 5: "RTK FLOAT", 6: "ESTIMATED"][quality] ?? "QUALITY \(quality)"
    }
    func age(_ now: Date) -> Int { max(0, Int(now.timeIntervalSince(received))) }
    func stale(_ now: Date) -> Bool { age(now) > 5 }
}
