import 'dart:math' as m;
import 'geo.dart';

class GpsEpoch {
  const GpsEpoch(this.tow, this.week);
  final double tow;
  final int week;
  factory GpsEpoch.received(double tow, DateTime time) => GpsEpoch(
    tow,
    ((time.millisecondsSinceEpoch / 1000 - 315964800 - tow) / 604800).round(),
  );
}

class GpsEphemeris {
  const GpsEphemeris({
    required this.prn,
    required this.week,
    required this.toe,
    required this.a,
    required this.e,
    required this.mean,
    required this.delta,
    required this.inclination,
    required this.inclinationRate,
    required this.node,
    required this.nodeRate,
    required this.perigee,
    required this.crs,
    required this.crc,
    required this.cus,
    required this.cuc,
    required this.cis,
    required this.cic,
  });
  final int prn, week;
  final double toe,
      a,
      e,
      mean,
      delta,
      inclination,
      inclinationRate,
      node,
      nodeRate,
      perigee,
      crs,
      crc,
      cus,
      cuc,
      cis,
      cic;

  static GpsEphemeris? decode(List<int> payload) {
    if (payload.length < 61 || (payload[0] << 4 | payload[1] >> 4) != 1019)
      return null;
    final b = _Bits(payload)..read(12);
    final prn = b.read(6), week = b.read(10);
    b.read(6);
    double s(int width, int power, [bool angle = false]) =>
        b.signed(width) * m.pow(2, power) * (angle ? m.pi : 1);
    final ir = s(14, -43, true);
    b.read(80);
    final crs = s(16, -5), delta = s(16, -43, true), mean = s(32, -31, true);
    final cuc = s(16, -29), e = b.read(32) * m.pow(2, -33);
    final cus = s(16, -29), root = b.read(32) * m.pow(2, -19);
    final toe = b.read(16) * 16.0, cic = s(16, -29), node = s(32, -31, true);
    final cis = s(16, -29), inc = s(32, -31, true), crc = s(16, -5);
    final perigee = s(32, -31, true), nr = s(24, -43, true);
    b.read(8);
    final health = b.read(6);
    if (prn < 1 ||
        prn > 32 ||
        health != 0 ||
        root < 4500 ||
        root > 6000 ||
        toe >= 604800)
      return null;
    return GpsEphemeris(
      prn: prn,
      week: week,
      toe: toe,
      a: (root * root).toDouble(),
      e: e.toDouble(),
      mean: mean,
      delta: delta,
      inclination: inc,
      inclinationRate: ir,
      node: node,
      nodeRate: nr,
      perigee: perigee,
      crs: crs,
      crc: crc,
      cus: cus,
      cuc: cuc,
      cis: cis,
      cic: cic,
    );
  }

  (double, double, double)? position(double tow, int fullWeek) {
    final dt = ((fullWeek - week + 512) % 1024 - 512) * 604800 + tow - toe;
    if (dt.abs() > 7200 ||
        a < 4500 * 4500 ||
        a > 6000 * 6000 ||
        e < 0 ||
        e >= 1)
      return null;
    const earth = 7.2921151467e-5;
    final anomalyMean = mean + (m.sqrt(3.986005e14 / m.pow(a, 3)) + delta) * dt;
    var anomaly = anomalyMean;
    for (var i = 0; i < 10; i++) {
      anomaly -=
          (anomaly - e * m.sin(anomaly) - anomalyMean) /
          (1 - e * m.cos(anomaly));
    }
    final angle =
        m.atan2(m.sqrt(1 - e * e) * m.sin(anomaly), m.cos(anomaly) - e) +
        perigee;
    final s = m.sin(2 * angle), c = m.cos(2 * angle);
    final r = a * (1 - e * m.cos(anomaly)) + crs * s + crc * c;
    final inc = inclination + inclinationRate * dt + cis * s + cic * c;
    final arg = angle + cus * s + cuc * c;
    final lon = node + (nodeRate - earth) * dt - earth * toe;
    final x = r * m.cos(arg), y = r * m.sin(arg);
    return (
      x * m.cos(lon) - y * m.cos(inc) * m.sin(lon),
      x * m.sin(lon) + y * m.cos(inc) * m.cos(lon),
      y * m.sin(inc),
    );
  }
}

class SkyPoint {
  const SkyPoint(this.azimuth, this.elevation);
  final double azimuth, elevation;
  static SkyPoint? fromEcef(
    GeoPosition observer,
    (double, double, double) sat,
  ) {
    final lat = observer.latitude * m.pi / 180,
        lon = observer.longitude * m.pi / 180;
    const e2 = 0.00669437999014;
    final n = 6378137 / m.sqrt(1 - e2 * m.pow(m.sin(lat), 2));
    final h = observer.height ?? 0;
    final dx = sat.$1 - (n + h) * m.cos(lat) * m.cos(lon),
        dy = sat.$2 - (n + h) * m.cos(lat) * m.sin(lon);
    final dz = sat.$3 - (n * (1 - e2) + h) * m.sin(lat);
    final east = -m.sin(lon) * dx + m.cos(lon) * dy;
    final north =
        -m.sin(lat) * (m.cos(lon) * dx + m.sin(lon) * dy) + m.cos(lat) * dz;
    final up =
        m.cos(lat) * (m.cos(lon) * dx + m.sin(lon) * dy) + m.sin(lat) * dz;
    return up < 0
        ? null
        : SkyPoint(
            m.atan2(east, north),
            m.atan2(up, m.sqrt(east * east + north * north)),
          );
  }
}

class SkySnapshot {
  const SkySnapshot({this.orbits = const [], this.epoch});
  final List<GpsEphemeris> orbits;
  final GpsEpoch? epoch;
}

class SkyTrack {
  SkyTrack(this.prn, this.points);
  final int prn;
  final List<SkyPoint?> points;
}

List<SkyTrack> skyTracks(GeoPosition observer, SkySnapshot snapshot) {
  final epoch = snapshot.epoch;
  if (epoch == null) return [];
  final sorted = [...snapshot.orbits]..sort((a, b) => a.prn.compareTo(b.prn));
  return [
    for (final orbit in sorted)
      SkyTrack(orbit.prn, [
        for (var offset = -1800; offset <= 1800; offset += 120)
          _point(orbit, epoch, observer, offset),
      ]),
  ];
}

class _Bits {
  _Bits(this.bytes);
  final List<int> bytes;
  int offset = 0;
  int read(int width) {
    if (offset + width > bytes.length * 8)
      throw const FormatException('Truncated GPS ephemeris');
    var value = 0;
    for (var i = 0; i < width; i++, offset++) {
      value = (value << 1) | ((bytes[offset ~/ 8] >> (7 - offset % 8)) & 1);
    }
    return value;
  }

  int signed(int width) {
    final value = read(width);
    return value >= 1 << (width - 1) ? value - (1 << width) : value;
  }
}

SkyPoint? _point(
  GpsEphemeris orbit,
  GpsEpoch epoch,
  GeoPosition observer,
  int offset,
) {
  final p = orbit.position(epoch.tow + offset, epoch.week);
  return p == null ? null : SkyPoint.fromEcef(observer, p);
}
