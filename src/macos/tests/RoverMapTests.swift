import Foundation

enum RoverMapChecks {
    static func sentence(_ body: String) -> String {
        "$" + body + String(format: "*%02X", Int(body.utf8.reduce(0, ^)))
    }
    static func run() {
        let external = sentence("GNGGA,120000.00,4530.0000,N,01230.0000,E,4,15,0.8,60.123,M,40.100,M,,")
        let result = NMEAGGAReader.location(external)!
        precondition(result.position.latitude == 45.5 && result.position.longitude == 12.5)
        precondition(result.heightAvailable && abs(result.position.height - 100.223) < 1e-8)
        let southern = sentence("GPGGA,120001.00,1230.0000,S,12315.0000,W,1,10,1.0,-5.000,M,0.000,M,,")
        let south = NMEAGGAReader.location(southern)!
        precondition(south.position.latitude == -12.5 && south.position.longitude == -123.25)
        precondition(south.position.height == -5)
        let unknownHeight = sentence("GPGGA,120001.00,4530.0000,N,01230.0000,E,1,10,1.0,60.123,M,,M,,")
        precondition(NMEAGGAReader.location(unknownHeight)?.heightAvailable == false)
        let noFix = sentence("GPGGA,120001.00,4530.0000,N,01230.0000,E,0,00,1.0,60.123,M,40.100,M,,")
        precondition(NMEAGGAReader.location(noFix) == nil)
        precondition(NMEAGGAReader.location(String(external.dropLast()) + "Z") == nil)
        let emptyNoFix = sentence("GNGGA,120000.00,,,,,0,00,99.99,,,,,,")
        precondition(NMEAGGAReader.quality(emptyNoFix) == 0)
        precondition(!NMEAGGAReader.valid(emptyNoFix))
        precondition(NMEAGGAReader.quality(external) == 4)
        precondition(NMEAGGAReader.quality(String(external.dropLast(2)) + "ZZ") == nil)
        var telemetry = NMEAGGAReader(includeNoFix: true)
        precondition(telemetry.feed(Data(emptyNoFix.prefix(20).utf8)).isEmpty)
        precondition(telemetry.feed(Data((String(emptyNoFix.dropFirst(20)) + "\r\n").utf8)) == [emptyNoFix])
        var forwarding = NMEAGGAReader()
        precondition(forwarding.feed(Data((emptyNoFix + "\r\n").utf8)).isEmpty)
        let fix = ReceiverFixStatus(quality: 4, received: Date(timeIntervalSince1970: 100), source: "Bluetooth")
        precondition(fix.label == "RTK FIXED" && !fix.stale(Date(timeIntervalSince1970: 105)))
        precondition(fix.stale(Date(timeIntervalSince1970: 106)))
        var state = RoverMapState()
        var manual = StationPosition(latitude: 46.125, longitude: 13.333333)!
        manual.height = 123.456
        state.setManual(manual, enabled: false)
        state.receive(external, source: "GGA · Serial / Bluetooth")
        precondition(state.effective?.position == result.position)
        precondition(state.effective?.source == "GGA · Serial / Bluetooth")
        state.setManual(manual, enabled: true)
        state.receive(southern, source: "GGA · TCP")
        precondition(state.effective?.position == manual)
        state.setManual(manual, enabled: false)
        precondition(state.effective?.position == south.position)
        precondition(state.effective?.source == "GGA · TCP")
        state.receive(noFix, source: "invalid")
        precondition(state.effective?.position == south.position)
        state.resetReceived()
        precondition(state.effective?.position == manual)
        print("PASS: GGA rover map coordinates, hemispheres, ellipsoidal height, invalid fixes and manual priority")
    }
}
