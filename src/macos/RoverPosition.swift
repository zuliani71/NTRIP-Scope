import Foundation
import SwiftUI

struct RoverPosition {
    let latitude: Double
    let longitude: Double
    let ellipsoidalHeight: Double
    let geoidSeparation: Double

    func gga(at date: Date = Date()) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let utc = calendar.dateComponents([.hour, .minute, .second], from: date)
        let time = String(format: "%02d%02d%02d.00", utc.hour ?? 0, utc.minute ?? 0, utc.second ?? 0)
        func coordinate(_ angle: Double, latitude: Bool) -> String {
            let units = Int((abs(angle) * 60 * 1_000_000).rounded())
            let degrees = units / 60_000_000
            let minutes = units / 1_000_000 % 60
            let fraction = units % 1_000_000
            return String(format: latitude ? "%02d%02d.%06d" : "%03d%02d.%06d", degrees, minutes, fraction)
        }
        let lat = coordinate(latitude, latitude: true)
        let lon = coordinate(longitude, latitude: false)
        let altitude = String(format: "%.3f", locale: locale, ellipsoidalHeight - geoidSeparation)
        let geoid = String(format: "%.3f", locale: locale, geoidSeparation)
        let body = "GPGGA,\(time),\(lat),\(latitude.sign == .minus ? "S" : "N"),\(lon),\(longitude.sign == .minus ? "W" : "E"),1,00,1.0,\(altitude),M,\(geoid),M,,"
        return "$" + body + String(format: "*%02X", Int(body.utf8.reduce(0, ^)))
    }
}

struct RoverAngleDraft {
    var decimal = ""
    var degrees = ""
    var minutes = ""
    var seconds = ""
    var negative = false
    private(set) var value: Double?

    static func number(_ text: String) -> Double? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(clean), value.isFinite else { return nil }
        return value
    }

    static func display(_ value: Double, digits: Int, locale: Locale) -> String {
        value.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(digits)))
    }

    mutating func updateDecimal(limit: Double, locale: Locale) {
        guard let angle = Self.number(decimal), abs(angle) <= limit else {
            value = nil
            degrees = ""
            minutes = ""
            seconds = ""
            return
        }
        value = angle
        negative = angle.sign == .minus
        formatDMS(locale: locale)
    }

    mutating func formatDMS(locale: Locale) {
        guard let value else { return }
        let units = Int((abs(value) * 36_000_000).rounded())
        degrees = String(units / 36_000_000)
        minutes = String(units / 600_000 % 60)
        seconds = Self.display(Double(units % 600_000) / 10_000, digits: 4, locale: locale)
    }

    mutating func updateDMS(limit: Double, locale: Locale) {
        guard let d = Int(degrees), let m = Int(minutes), let s = Self.number(seconds),
              d >= 0, Double(d) <= limit, (0..<60).contains(m), (0..<60).contains(s),
              Double(d) < limit || (m == 0 && s == 0) else {
            value = nil
            decimal = ""
            return
        }
        let absolute = Double(d) + Double(m) / 60 + s / 3600
        let angle = negative ? -absolute : absolute
        value = angle
        decimal = Self.display(angle, digits: 6, locale: locale)
    }
}

struct RoverDraft {
    var enabled = false
    var latitude = RoverAngleDraft()
    var longitude = RoverAngleDraft()
    var height = ""
    var separation = ""

    var position: RoverPosition? {
        guard let lat = latitude.value, let lon = longitude.value,
              let height = RoverAngleDraft.number(height), abs(height) < 100_000 else { return nil }
        let text = separation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let geoid = text.isEmpty ? 0 : RoverAngleDraft.number(text),
              abs(geoid) < 100_000 else { return nil }
        func millimeters(_ value: Double) -> Double { (value * 1_000).rounded() / 1_000 }
        return RoverPosition(latitude: lat, longitude: lon, ellipsoidalHeight: millimeters(height),
                             geoidSeparation: millimeters(geoid))
    }
}

struct RoverPositionEditor: View {
    @Binding var draft: RoverDraft
    @Binding var raw: String
    @Environment(\.locale) private var locale
    @FocusState private var focus: Field?

    private enum Field: Hashable { case latDecimal, latSeconds, lonDecimal, lonSeconds, height, separation }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(tr("Invia posizione rover manuale (GGA)"), isOn: $draft.enabled).toggleStyle(.checkbox)
            if draft.enabled {
                Label(tr("La GGA generata da queste coordinate ha priorità sulle GGA ricevute da altre sorgenti (Bluetooth, seriale o TCP)."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                angleEditor(tr("Latitudine"), angle: $draft.latitude, limit: 90, positive: "N", negative: "S",
                            decimalFocus: .latDecimal, secondsFocus: .latSeconds)
                angleEditor(tr("Longitudine"), angle: $draft.longitude, limit: 180, positive: "E", negative: tr("O"),
                            decimalFocus: .lonDecimal, secondsFocus: .lonSeconds)
                HStack {
                    TextField(tr("Quota ellissoidica (m)"), text: $draft.height).focused($focus, equals: .height)
                    TextField(tr("Separazione geoidica (m)"), text: $draft.separation,
                              prompt: Text("0.000")).focused($focus, equals: .separation)
                }
                Text(tr("Separazione geoidica facoltativa. Se omessa, la GGA usa 0,000 m."))
                    .font(.caption).foregroundStyle(.secondary)
                if let position = draft.position {
                    Text(position.gga()).font(.caption.monospaced()).textSelection(.enabled)
                } else {
                    Text(tr("Completa latitudine, longitudine e quota ellissoidica."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                TextField("NMEA GGA", text: $raw, prompt: Text(tr("Facoltativa, per caster VRS")))
            }
        }
        .onChange(of: focus) { [focus] _ in normalize(focus) }
        .onDisappear { normalize(focus) }
    }

    private func angleEditor(_ name: String, angle: Binding<RoverAngleDraft>, limit: Double,
                             positive: String, negative: String, decimalFocus: Field, secondsFocus: Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).fontWeight(.semibold)
            TextField(tr("Gradi decimali"), text: Binding(
                get: { angle.wrappedValue.decimal },
                set: { text in
                    angle.wrappedValue.decimal = text
                    angle.wrappedValue.updateDecimal(limit: limit, locale: locale)
                }
            )).focused($focus, equals: decimalFocus)
            HStack {
                TextField(tr("Gradi"), text: dmsBinding(angle, \.degrees, limit: limit))
                TextField(tr("Minuti"), text: dmsBinding(angle, \.minutes, limit: limit))
                TextField(tr("Secondi"), text: dmsBinding(angle, \.seconds, limit: limit))
                    .focused($focus, equals: secondsFocus)
                Picker(tr("Emisfero"), selection: Binding(
                    get: { angle.wrappedValue.negative },
                    set: { value in
                        angle.wrappedValue.negative = value
                        angle.wrappedValue.updateDMS(limit: limit, locale: locale)
                    }
                )) {
                    Text(positive).tag(false)
                    Text(negative).tag(true)
                }.labelsHidden().fixedSize()
            }
        }
    }

    private func dmsBinding(_ angle: Binding<RoverAngleDraft>, _ key: WritableKeyPath<RoverAngleDraft, String>,
                            limit: Double) -> Binding<String> {
        Binding(
            get: { angle.wrappedValue[keyPath: key] },
            set: { value in
                angle.wrappedValue[keyPath: key] = value
                angle.wrappedValue.updateDMS(limit: limit, locale: locale)
            }
        )
    }

    private func normalize(_ field: Field?) {
        func format(_ text: inout String, digits: Int) {
            if let value = RoverAngleDraft.number(text) {
                text = RoverAngleDraft.display(value, digits: digits, locale: locale)
            }
        }
        switch field {
        case .latDecimal: if draft.latitude.value != nil { format(&draft.latitude.decimal, digits: 6) }
        case .latSeconds: draft.latitude.formatDMS(locale: locale)
        case .lonDecimal: if draft.longitude.value != nil { format(&draft.longitude.decimal, digits: 6) }
        case .lonSeconds: draft.longitude.formatDMS(locale: locale)
        case .height: format(&draft.height, digits: 3)
        case .separation: format(&draft.separation, digits: 3)
        case nil: break
        }
    }
}
