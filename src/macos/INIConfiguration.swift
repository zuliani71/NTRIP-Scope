import Foundation

struct INIConfiguration {
    struct Invalid: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    var host: String
    var port: Int
    var mount: String
    var username: String
    var password: String
    var tls: Bool
    var version: Int
    var coordinates: (Double, Double)?
    var height: Double
    var geoid: Double
    var files: [URL]
    var tcp: Int?
    var serial: (String, Int)?

    init(url: URL) throws {
        let allowed = [
            "caster": Set(["host", "port", "mountpoint", "username", "password", "tls", "version", "list"]),
            "rover": Set(["latitude", "longitude", "height", "geoid"]),
            "outputs": Set(["file", "tcp", "serial", "stdout"])
        ]
        var values: [String: String] = [:]
        var section = ""
        var previous: String?
        let contents = try String(contentsOf: url, encoding: .utf8)
        for (index, raw) in contents.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                guard allowed[section] != nil else { throw Invalid("Unknown INI section: \(section)") }
                previous = nil
                continue
            }
            if raw.first?.isWhitespace == true, let previous,
               ["outputs.file", "outputs.tcp", "outputs.serial"].contains(previous) {
                values[previous, default: ""] += "\n" + line
                continue
            }
            guard let equal = line.firstIndex(of: "=") else { throw Invalid("Invalid INI line \(index+1)") }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces).lowercased()
            let field = "\(section).\(key)"
            guard allowed[section]?.contains(key) == true, values[field] == nil else {
                throw Invalid("Unknown or repeated INI key: \(field)")
            }
            values[field] = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            previous = field
        }
        func number(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let input = values[key] else { return fallback }
            guard let value = Int(input), range.contains(value) else { throw Invalid("Invalid INI value: \(key)") }
            return value
        }
        func boolean(_ key: String) throws -> Bool {
            guard let value = values[key]?.lowercased() else { return false }
            if ["1","yes","on","true"].contains(value) { return true }
            if ["0","no","off","false"].contains(value) { return false }
            throw Invalid("Invalid INI boolean: \(key)")
        }
        func decimal(_ key: String, limit: Double) throws -> Double? {
            guard let raw = values[key] else { return nil }
            guard let value = Double(raw), value.isFinite, abs(value) <= limit else {
                throw Invalid("Invalid INI value: \(key)")
            }
            return value
        }
        func entries(_ key: String) -> [String] {
            var seen = Set<String>()
            return (values[key] ?? "").split(separator: "\n").map(String.init).filter { seen.insert($0).inserted }
        }
        let rawHost = values["caster.host"] ?? ""
        host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || "/?#[]".contains($0) }) else {
            throw Invalid("Invalid caster.host")
        }
        port = try number("caster.port", default: 2101, range: 1...65535)
        mount = values["caster.mountpoint"] ?? ""
        username = values["caster.username"] ?? ""
        password = values["caster.password"] ?? ""
        tls = try boolean("caster.tls")
        _ = try boolean("caster.list")
        _ = try boolean("outputs.stdout")
        version = try number("caster.version", default: 2, range: 1...2)
        let lat = try decimal("rover.latitude", limit: 90)
        let lon = try decimal("rover.longitude", limit: 180)
        let h = try decimal("rover.height", limit: 99999.999)
        let n = try decimal("rover.geoid", limit: 99999.999)
        if let lat, let lon { coordinates = (lat, lon) }
        else if lat != nil || lon != nil || h != nil || n != nil { throw Invalid("Rover needs both latitude and longitude") }
        height = h ?? 0
        geoid = n ?? 0
        files = entries("outputs.file").map { URL(fileURLWithPath: $0) }
        let ports = entries("outputs.tcp")
        let devices = entries("outputs.serial")
        guard ports.count <= 1, devices.count <= 1 else {
            throw Invalid("macOS supports one TCP and one serial output per connection. Use ntripscope for additional ports.")
        }
        if let value = ports.first {
            guard let port = Int(value), (1...65535).contains(port) else { throw Invalid("Invalid outputs.tcp") }
            tcp = port
        }
        if let value = devices.first {
            let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
            let baud = pieces.count == 2 ? Int(pieces[1]) : 115200
            guard pieces.count <= 2, let name = pieces.first, !name.isEmpty, let baud, baud > 0 else {
                throw Invalid("Invalid outputs.serial")
            }
            serial = (String(name), baud)
        }
    }
}
