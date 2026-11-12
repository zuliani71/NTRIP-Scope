import 'dart:math' as math;
import 'gga.dart';

class GeoPosition {
  const GeoPosition(this.latitude, this.longitude, [this.height]);
  final double latitude, longitude;
  final double? height;

  static GeoPosition? fromGga(String sentence) {
    if (!validGga(sentence)) return null;
    final f = sentence.substring(1, sentence.length - 3).split(',');
    double angle(String raw, int width, String hemisphere) {
      final value =
          double.parse(raw.substring(0, width)) +
          double.parse(raw.substring(width)) / 60;
      return hemisphere == 'S' || hemisphere == 'W' ? -value : value;
    }

    double? height;
    if (f[10] == 'M' && f[12] == 'M' && f[9].isNotEmpty && f[11].isNotEmpty) {
      final h = double.parse(f[9]) + double.parse(f[11]);
      if (h.isFinite) height = h;
    }
    return GeoPosition(angle(f[2], 2, f[3]), angle(f[4], 3, f[5]), height);
  }

  static GeoPosition? fromEcef(double x, double y, double z) {
    const a = 6378137.0, e2 = 0.00669437999014;
    final p = math.sqrt(x * x + y * y);
    final radius = math.sqrt(p * p + z * z);
    if (!radius.isFinite || radius < 6000000 || radius > 7000000) return null;
    var lat = math.atan2(z, p * (1 - e2));
    for (var i = 0; i < 8; i++) {
      final n = a / math.sqrt(1 - e2 * math.pow(math.sin(lat), 2));
      lat = math.atan2(z + n * e2 * math.sin(lat), p);
    }
    final n = a / math.sqrt(1 - e2 * math.pow(math.sin(lat), 2));
    final h =
        p * math.cos(lat) +
        z * math.sin(lat) -
        n * (1 - e2 * math.pow(math.sin(lat), 2));
    return GeoPosition(
      lat * 180 / math.pi,
      math.atan2(y, x) * 180 / math.pi,
      h,
    );
  }

  double distanceKm(GeoPosition other) {
    final lat1 = latitude * math.pi / 180,
        lat2 = other.latitude * math.pi / 180;
    final dl =
        ((other.longitude - longitude + 540) % 360 - 180) * math.pi / 180;
    final h =
        math.pow(math.sin((lat2 - lat1) / 2), 2) +
        math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dl / 2), 2);
    return 2 * 6371.0088 * math.asin(math.sqrt(h.clamp(0, 1)));
  }

  static String dms(double value, bool latitude) {
    final units = (value.abs() * 36000000).round();
    final d = units ~/ 36000000, m = units ~/ 600000 % 60;
    final seconds = (units % 600000 / 10000).toStringAsFixed(4).padLeft(7, '0');
    return '$d° ${m.toString().padLeft(2, '0')}′ $seconds″ ${latitude ? (value < 0 ? 'S' : 'N') : (value < 0 ? 'W' : 'E')}';
  }

  @override
  bool operator ==(Object o) =>
      o is GeoPosition &&
      latitude == o.latitude &&
      longitude == o.longitude &&
      height == o.height;
  @override
  int get hashCode => Object.hash(latitude, longitude, height);
}

class GeoSnapshot {
  const GeoSnapshot({
    this.key = '',
    this.station,
    this.rover,
    this.source = '',
    this.lastKnown = false,
  });
  final String key, source;
  final GeoPosition? station, rover;
  final bool lastKnown;
  @override
  bool operator ==(Object o) =>
      o is GeoSnapshot &&
      key == o.key &&
      station == o.station &&
      rover == o.rover &&
      source == o.source &&
      lastKnown == o.lastKnown;
  @override
  int get hashCode => Object.hash(key, station, rover, source, lastKnown);
}

class RoverMapModel {
  final stations = <String, GeoPosition>{};
  final _readers = <String, GgaReader>{};
  String key = '', source = '';
  bool active = false, _freshStation = false;
  GeoPosition? manual, received;
  void begin(String streamKey, GeoPosition? manualPosition) {
    if (key != streamKey) {
      received = null;
      source = '';
    }
    key = streamKey;
    manual = manualPosition;
    active = true;
    _freshStation = false;
    _readers.clear();
  }

  void stop() {
    active = false;
    _readers.clear();
  }

  void accept(String name, List<int> bytes) {
    if (!active) return;
    for (final sentence
        in _readers.putIfAbsent(name, GgaReader.new).add(bytes)) {
      final point = GeoPosition.fromGga(sentence);
      if (point != null) {
        received = point;
        source = 'GGA · $name';
      }
    }
  }

  void remember(GeoPosition? station) {
    if (!active || station == null) return;
    if (stations.length >= 100 && !stations.containsKey(key)) stations.clear();
    stations[key] = station;
    _freshStation = true;
  }

  GeoSnapshot get snapshot => GeoSnapshot(
    key: key,
    station: stations[key],
    rover: manual ?? received,
    source: manual != null ? 'Manual rover position' : source,
    lastKnown: !active || !_freshStation,
  );
}
