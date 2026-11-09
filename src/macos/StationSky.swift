import Foundation
import MapKit
import SwiftUI

struct StationPosition: Equatable {
    let latitude: Double
    let longitude: Double
    var height = 0.0

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    init?(ecef: SIMD3<Double>) {
        let a = 6_378_137.0
        let e2 = 0.00669437999014
        let p = hypot(ecef.x, ecef.y)
        guard (6_000_000...7_000_000).contains(hypot(p, ecef.z)) else { return nil }
        let lon = atan2(ecef.y, ecef.x)
        var lat = atan2(ecef.z, p * (1 - e2))
        for _ in 0..<8 {
            let n = a / sqrt(1 - e2 * pow(sin(lat), 2))
            lat = atan2(ecef.z + n * e2 * sin(lat), p)
        }
        self.init(latitude: lat * 180 / .pi, longitude: lon * 180 / .pi)
        let n = a / sqrt(1 - e2 * pow(sin(lat), 2))
        height = p * cos(lat) + ecef.z * sin(lat) - n * (1 - e2 * pow(sin(lat), 2))
    }

    var ecef: SIMD3<Double> {
        let lat = latitude * .pi / 180, lon = longitude * .pi / 180
        let e2 = 0.00669437999014
        let n = 6_378_137 / sqrt(1 - e2 * pow(sin(lat), 2))
        return SIMD3((n + height) * cos(lat) * cos(lon),
                     (n + height) * cos(lat) * sin(lon),
                     (n * (1 - e2) + height) * sin(lat))
    }

    func skyPoint(for satellite: SIMD3<Double>) -> SkyPoint? {
        let d = satellite - ecef
        let lat = latitude * .pi / 180, lon = longitude * .pi / 180
        let east = -sin(lon) * d.x + cos(lon) * d.y
        let north = -sin(lat) * (cos(lon) * d.x + sin(lon) * d.y) + cos(lat) * d.z
        let up = cos(lat) * (cos(lon) * d.x + sin(lon) * d.y) + sin(lat) * d.z
        guard up >= 0 else { return nil }
        return SkyPoint(azimuth: atan2(east, north), elevation: atan2(up, hypot(east, north)))
    }
}

struct SkyPoint {
    let azimuth: Double
    let elevation: Double
}

struct GPSEphemeris {
    let prn: Int
    let week: Int
    let toe: Double
    let semiMajor: Double
    let eccentricity: Double
    let meanAnomaly: Double
    let deltaMotion: Double
    let inclination: Double
    let inclinationRate: Double
    let node: Double
    let nodeRate: Double
    let perigee: Double
    let crs: Double, crc: Double, cus: Double, cuc: Double, cis: Double, cic: Double

    // GPS broadcast orbit model. Time of week is GPST, position is ECEF in meters.
    func position(tow: Double, fullWeek: Int) -> SIMD3<Double>? {
        let difference = (fullWeek - week + 512) & 1023
        let elapsed = Double(difference - 512) * 604_800 + tow - toe
        guard abs(elapsed) <= 7200 else { return nil }
        let earthRotation = 7.2921151467e-5
        let motion = sqrt(3.986005e14 / pow(semiMajor, 3)) + deltaMotion
        let mean = meanAnomaly + motion * elapsed
        var anomaly = mean
        for _ in 0..<10 {
            anomaly -= (anomaly - eccentricity * sin(anomaly) - mean) / (1 - eccentricity * cos(anomaly))
        }
        let trueAnomaly = atan2(sqrt(1 - eccentricity * eccentricity) * sin(anomaly),
                                cos(anomaly) - eccentricity)
        let angle = trueAnomaly + perigee
        let s = sin(2 * angle), c = cos(2 * angle)
        let argument = angle + cus * s + cuc * c
        let radius = semiMajor * (1 - eccentricity * cos(anomaly)) + crs * s + crc * c
        let tilt = inclination + inclinationRate * elapsed + cis * s + cic * c
        let longitude = node + (nodeRate - earthRotation) * elapsed - earthRotation * toe
        let x = radius * cos(argument), y = radius * sin(argument)
        return SIMD3(x * cos(longitude) - y * cos(tilt) * sin(longitude),
                     x * sin(longitude) + y * cos(tilt) * cos(longitude), y * sin(tilt))
    }
}

struct MountpointMap: View {
    let name: String
    let position: StationPosition?
    let fromRTCM: Bool
    let rover: StationPosition?
    let ephemerides: [GPSEphemeris]
    let epoch: RTCMDecoder.GPSEpoch?
    @State private var sky = false
    @State private var offline = false
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name.isEmpty ? tr("Mappa e cielo") : name).font(.title2.bold())
            Picker(tr("Vista"), selection: $sky) {
                Text(tr("Mappa")).tag(false)
                Text(tr("Cielo GPS")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if let position {
                Text(fromRTCM ? tr("Antenna dal flusso RTCM 1005/1006") : tr("Posizione indicativa dalla sourcetable"))
                    .font(.caption).foregroundStyle(.secondary)
                if sky {
                    if let epoch, !ephemerides.isEmpty {
                        GPSSkyView(position: position, ephemerides: ephemerides, epoch: epoch)
                    } else {
                        placeholder(tr("Servono effemeridi GPS RTCM 1019 e un’epoca GPS MSM nel flusso."))
                    }
                } else {
                    Picker(tr("Vista"), selection: $offline) {
                        Text(tr("Mappa stradale")).tag(false)
                        Text(tr("Mappa offline")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    Group {
                        if offline {
                            OfflineStationMap(position: position, name: name, rover: rover)
                        } else {
                            StationMap(position: position, name: name, rover: rover)
                        }
                    }.id(position.coordinateKey)
                    coordinateDetails(position)
                }
            } else {
                placeholder(tr("Scarica l’elenco e scegli un mountpoint, oppure connettiti a un flusso con RTCM 1005/1006."))
            }
        }
    }

    private func coordinateDetails(_ position: StationPosition) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text(tr("Gradi decimali")).fontWeight(.semibold)
                Text(tr("Gradi sessagesimali")).fontWeight(.semibold)
            }
            GridRow {
                Text(tr("Latitudine"))
                Text(decimal(position.latitude, digits: 6) + "°")
                Text(Self.dms(position.latitude, positive: "N", negative: "S", locale: locale))
            }
            GridRow {
                Text(tr("Longitudine"))
                Text(decimal(position.longitude, digits: 6) + "°")
                Text(Self.dms(position.longitude, positive: "E", negative: tr("O"), locale: locale))
            }
            GridRow {
                Text(tr("Quota ellissoidica"))
                Text(fromRTCM ? decimal(position.height, digits: 3) + " m" : tr("Non disponibile"))
                    .gridCellColumns(2)
            }
        }
        .font(.caption.monospacedDigit())
        .textSelection(.enabled)
        .padding(.vertical, 3)
    }

    private func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(digits)))
    }

    static func dms(_ angle: Double, positive: String, negative: String, locale: Locale) -> String {
        // Round before splitting so seconds carry into the minutes correctly.
        let units = Int((abs(angle) * 36_000_000).rounded())
        let degrees = units / 36_000_000
        let minutes = units / 600_000 % 60
        let seconds = units / 10_000 % 60
        let fraction = units % 10_000
        let separator = locale.decimalSeparator ?? "."
        let display = String(format: "%02d", seconds) + separator + String(format: "%04d", fraction)
        return "\(degrees)° \(String(format: "%02d", minutes))′ \(display)″ \(angle < 0 ? negative : positive)"
    }

    private func placeholder(_ message: String) -> some View {
        Text(message).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension StationPosition {
    var coordinateKey: String { "\(latitude)/\(longitude)" }
}

struct MapRuler {
    let kilometers: Double
    let width: CGFloat

    init?(latitude: Double, longitudeSpan: Double, mapWidth: CGFloat) {
        let latitude = min(85, max(-85, latitude))
        let projectedWidth = longitudeSpan / 360 * MKMapRect.world.width
        let visibleKilometers = projectedWidth * MKMetersPerMapPointAtLatitude(latitude) / 1000
        guard visibleKilometers.isFinite, visibleKilometers > 0, mapWidth.isFinite, mapWidth > 0 else { return nil }
        let maximum = visibleKilometers * min(150, mapWidth * 0.45) / mapWidth
        let order = pow(10, floor(log10(maximum)))
        let normalized = maximum / order
        let step = normalized >= 5 ? 5.0 : normalized >= 2 ? 2.0 : 1.0
        kilometers = step * order
        width = mapWidth * kilometers / visibleKilometers
    }
}

private struct MapScaleView: View {
    let ruler: MapRuler
    @Environment(\.locale) private var locale

    var body: some View {
        let distance = ruler.kilometers.formatted(.number.locale(locale).precision(.fractionLength(0...5)))
        VStack(alignment: .leading, spacing: 3) {
            Text(tr("Scala mappa")).font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("0")
                Spacer(minLength: 4)
                Text("\(distance) km")
            }
            .font(.caption.monospacedDigit())
            .frame(minWidth: ruler.width)
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 0, y: 7))
                path.addLine(to: CGPoint(x: ruler.width, y: 7))
                path.addLine(to: CGPoint(x: ruler.width, y: 1))
                path.move(to: CGPoint(x: ruler.width / 2, y: 7))
                path.addLine(to: CGPoint(x: ruler.width / 2, y: 3))
            }
            .stroke(.primary, lineWidth: 1.5)
            .frame(width: ruler.width, height: 8)
        }
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tr("Scala mappa")), \(distance) km")
    }
}

private func longitudeDelta(_ value: Double) -> Double {
    (value + 540).truncatingRemainder(dividingBy: 360) - 180
}

private func roverDistance(_ station: StationPosition, _ rover: StationPosition) -> Double {
    let a = station.latitude * .pi / 180
    let b = rover.latitude * .pi / 180
    let d = longitudeDelta(rover.longitude - station.longitude) * .pi / 180
    let h = pow(sin((b-a)/2), 2) + cos(a)*cos(b)*pow(sin(d/2), 2)
    return 2 * 6371.0088 * asin(sqrt(min(1, max(0, h))))
}

private func drawRover(_ context: GraphicsContext, station: CGPoint, rover: CGPoint, distance: Double) {
    let path = Path { line in line.move(to: station); line.addLine(to: rover) }
    context.stroke(path, with: .color(.white), lineWidth: 5)
    context.stroke(path, with: .color(.blue), lineWidth: 3)
    let dot = Path(ellipseIn: CGRect(x: rover.x-6, y: rover.y-6, width: 12, height: 12))
    context.fill(dot, with: .color(.blue))
    context.stroke(dot, with: .color(.white), lineWidth: 1.5)
    for (label, point, anchor) in [
        ("Rover", CGPoint(x: rover.x+10, y: rover.y), UnitPoint.leading),
        ("\(distance.formatted(.number.precision(.fractionLength(3)))) km",
         CGPoint(x: (station.x+rover.x)/2, y: (station.y+rover.y)/2-12), UnitPoint.center)
    ] {
        let text = context.resolve(Text(label).font(.caption.bold()).foregroundColor(.white))
        let size = text.measure(in: CGSize(width: 240,height: 40))
        let box = CGRect(x: point.x-size.width*anchor.x-4, y: point.y-size.height/2-2,
                         width: size.width+8,height: size.height+4)
        context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(.black.opacity(0.8)))
        context.draw(text, at: point, anchor: anchor)
    }
}

private struct OfflineStationMap: View {
    let position: StationPosition
    let name: String
    let rover: StationPosition?
    @State private var center: CGPoint?
    @State private var scale = 12.0
    @GestureState private var drag = CGSize.zero

    private static let rings: [[[Double]]] = {
        guard let url = Bundle.main.url(forResource: "land", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rings = try? JSONDecoder().decode([[[Double]]].self, from: data) else { return [] }
        return rings
    }()

    var body: some View {
        let origin = center ?? CGPoint(x: position.longitude, y: position.latitude)
        let lon = origin.x - drag.width / scale
        let lat = min(90, max(-90, origin.y + drag.height / scale))
        GeometryReader { proxy in
            Canvas { context, size in
                func pixel(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: size.width / 2 + (x - lon) * scale,
                            y: size.height / 2 - (y - lat) * scale)
                }
                for ring in Self.rings {
                    guard let first = ring.first else { continue }
                    for shift in [-360.0, 0.0, 360.0] {
                        let points = ring.map { pixel($0[0] + shift, $0[1]) }
                        let x = points.map(\.x), y = points.map(\.y)
                        guard x.min() ?? 0 < size.width, x.max() ?? 0 > 0,
                              y.min() ?? 0 < size.height, y.max() ?? 0 > 0 else { continue }
                        var path = Path()
                        path.move(to: pixel(first[0] + shift, first[1]))
                        for point in points.dropFirst() { path.addLine(to: point) }
                        path.closeSubpath()
                        context.fill(path, with: .color(Color(red: 0.20, green: 0.35, blue: 0.40)))
                        context.stroke(path, with: .color(.teal.opacity(0.65)), lineWidth: 0.7)
                    }
                }
                let delta = (position.longitude - lon + 540).truncatingRemainder(dividingBy: 360) - 180
                let marker = pixel(lon + delta, position.latitude)
                if let rover {
                    let end = pixel(lon + longitudeDelta(rover.longitude-lon), rover.latitude)
                    drawRover(context, station: marker, rover: end, distance: roverDistance(position, rover))
                }
                let dot = Path(ellipseIn: CGRect(x: marker.x-6,y: marker.y-6,width: 12,height: 12))
                context.fill(dot, with: .color(.red))
                context.stroke(dot, with: .color(.white), lineWidth: 1.5)
                context.draw(Text(name).font(.caption.bold()).foregroundColor(.white),
                             at: CGPoint(x: marker.x+11,y: marker.y), anchor: .leading)
            }
            .background(Color(red: 0.06, green: 0.15, blue: 0.22))
            .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    let longitude = (origin.x - value.translation.width/scale + 540)
                        .truncatingRemainder(dividingBy: 360) - 180
                    center = CGPoint(x: longitude, y: min(90, max(-90, origin.y + value.translation.height/scale)))
                })
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    Button { scale = min(32768, scale*2) } label: { Image(systemName: "plus") }
                        .help(tr("Ingrandisci"))
                    Button { scale = max(2, scale/2) } label: { Image(systemName: "minus") }
                        .help(tr("Riduci"))
                }.controlSize(.large).padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                if let ruler = MapRuler(latitude: lat, longitudeSpan: proxy.size.width/scale, mapWidth: proxy.size.width) {
                    MapScaleView(ruler: ruler).padding(8).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text("Natural Earth · 1:110m").font(.caption2).foregroundStyle(.white).padding(7)
                    .allowsHitTesting(false)
            }
            .onAppear { fitRover(proxy.size) }
            .onChange(of: rover) { _ in fitRover(proxy.size) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    private func fitRover(_ size: CGSize) {
        guard let rover else { return }
        let delta = longitudeDelta(rover.longitude-position.longitude)
        center = CGPoint(x: position.longitude+delta/2, y: (position.latitude+rover.latitude)/2)
        scale = min(32768, max(2,min(size.width*0.65/max(0.001,abs(delta)),
                                     size.height*0.65/max(0.001,abs(rover.latitude-position.latitude)))))
    }

}

private struct StationMap: View {
    let position: StationPosition
    let name: String
    let rover: StationPosition?
    @State private var region: MKCoordinateRegion

    init(position: StationPosition, name: String, rover: StationPosition?) {
        self.position = position
        self.name = name
        self.rover = rover
        _region = State(initialValue: MKCoordinateRegion(center: position.coordinate,
                         latitudinalMeters: 30_000, longitudinalMeters: 30_000))
    }

    var body: some View {
        Map(coordinateRegion: $region, interactionModes: [.pan, .zoom],
            annotationItems: [Marker(name: name)]) { _ in
            MapMarker(coordinate: position.coordinate, tint: .red)
        }
        .overlay {
            if let rover {
                Canvas { context, size in
                    let center = MKMapPoint(region.center)
                    let width = MKMapRect.world.width * region.span.longitudeDelta / 360
                    guard width > 0 else { return }
                    func screen(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
                        let point = MKMapPoint(coordinate)
                        let dx = MKMapRect.world.width * longitudeDelta(coordinate.longitude-region.center.longitude)/360
                        return CGPoint(x: size.width/2+dx*size.width/width,
                                       y: size.height/2+(point.y-center.y)*size.width/width)
                    }
                    drawRover(context, station: screen(position.coordinate), rover: screen(rover.coordinate),
                              distance: roverDistance(position, rover))
                }.allowsHitTesting(false)
            }
        }
        .onAppear { fitRover() }
        .onChange(of: rover) { _ in fitRover() }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 4) {
                Button { zoom(by: 0.5) } label: { Image(systemName: "plus") }
                    .help(tr("Ingrandisci")).accessibilityLabel(tr("Ingrandisci"))
                Button { zoom(by: 2) } label: { Image(systemName: "minus") }
                    .help(tr("Riduci")).accessibilityLabel(tr("Riduci"))
            }
            .controlSize(.large)
            .padding(8)
        }
        .overlay {
            GeometryReader { geometry in
                if let ruler = MapRuler(latitude: region.center.latitude,
                                        longitudeSpan: region.span.longitudeDelta,
                                        mapWidth: geometry.size.width) {
                    MapScaleView(ruler: ruler)
                        .padding(.trailing, 8)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fitRover() {
        guard let rover else { return }
        let delta = longitudeDelta(rover.longitude-position.longitude)
        let center = CLLocationCoordinate2D(latitude: (position.latitude+rover.latitude)/2,
                                            longitude: longitudeDelta(position.longitude+delta/2))
        region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(
            latitudeDelta: min(150,max(0.004,abs(rover.latitude-position.latitude)*1.7)),
            longitudeDelta: min(300,max(0.004,abs(delta)*1.7))
        ))
    }

    private func zoom(by factor: Double) {
        let span = region.span
        region = MKCoordinateRegion(center: region.center, span: MKCoordinateSpan(
            latitudeDelta: min(150, max(0.0002, span.latitudeDelta * factor)),
            longitudeDelta: min(300, max(0.0002, span.longitudeDelta * factor))
        ))
    }

    private struct Marker: Identifiable {
        let name: String
        var id: String { name }
    }
}

private struct GPSSkyView: View {
    let position: StationPosition
    let ephemerides: [GPSEphemeris]
    let epoch: RTCMDecoder.GPSEpoch

    var body: some View {
        let tracks = ephemerides.sorted { $0.prn < $1.prn }.map { orbit in
            (prn: orbit.prn, points: stride(from: -1800, through: 1800, by: 120).map { offset in
                orbit.position(tow: epoch.tow + Double(offset), fullWeek: epoch.week)
                    .flatMap { position.skyPoint(for: $0) }
            })
        }.filter { $0.points.contains { $0 != nil } }
        if tracks.isEmpty {
            Text(tr("Nessuna traiettoria GPS sopra l’orizzonte con le effemeridi disponibili."))
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = max(10, min(size.width, size.height) / 2 - 30)
                for fraction in [1.0, 2.0 / 3.0, 1.0 / 3.0] {
                    let r = radius * fraction
                    context.stroke(Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r,
                                                          width: 2*r, height: 2*r)),
                                   with: .color(.secondary.opacity(0.5)))
                }
                for (label, x, y) in [("N", 0.0, -1.0), ("E", 1.0, 0.0),
                                      ("S", 0.0, 1.0), (tr("O"), -1.0, 0.0)] {
                    context.draw(Text(label).font(.caption.bold()),
                                 at: CGPoint(x: center.x + x*(radius+14), y: center.y + y*(radius+14)))
                }
                func project(_ point: SkyPoint) -> CGPoint {
                    let r = radius * (1 - point.elevation / (.pi / 2))
                    return CGPoint(x: center.x + r*sin(point.azimuth), y: center.y - r*cos(point.azimuth))
                }
                for track in tracks {
                    let color = Color(hue: (Double(track.prn) * 0.61803398875).truncatingRemainder(dividingBy: 1), saturation: 0.68, brightness: 0.78)
                    var line = Path()
                    var started = false
                    for point in track.points {
                        guard let point else { started = false; continue }
                        let p = project(point)
                        if started { line.addLine(to: p) } else { line.move(to: p); started = true }
                    }
                    context.stroke(line, with: .color(color), lineWidth: 2)
                    if let current = track.points[track.points.count / 2] {
                        let p = project(current)
                        context.fill(Path(ellipseIn: CGRect(x: p.x-3, y: p.y-3, width: 6, height: 6)), with: .color(color))
                        context.draw(Text(String(format: "G%02d", track.prn)).font(.caption2.bold()),
                                     at: CGPoint(x: p.x+6, y: p.y-5), anchor: .bottomLeading)
                    }
                }
            }
            .accessibilityLabel(tr("Traiettorie GPS nel cielo"))
            Text(tr("GPS · ±30 min dall’ultima epoca del flusso. Il punto indica la posizione a quell’epoca."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
