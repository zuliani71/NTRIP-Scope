import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'geo.dart';
import 'sky.dart';

class GpsSkyView extends StatefulWidget {
  const GpsSkyView({
    super.key,
    required this.positions,
    required this.snapshot,
  });
  final GeoSnapshot positions;
  final SkySnapshot snapshot;
  @override
  State<GpsSkyView> createState() => _GpsSkyViewState();
}

class _GpsSkyViewState extends State<GpsSkyView> {
  bool rover = false;
  @override
  Widget build(BuildContext context) {
    final p = widget.positions;
    final observer = rover ? p.rover : p.station;
    final epoch = widget.snapshot.epoch;
    final tracks = observer == null
        ? <SkyTrack>[]
        : skyTracks(observer, widget.snapshot);
    final visible = tracks.where((t) => t.points[15] != null).toList();
    final valid = tracks.where((t) => t.points.any((p) => p != null)).toList();
    final message = observer == null
        ? 'Observer position unavailable. Connect to a stream with RTCM 1005/1006 or select a rover position.'
        : epoch == null || widget.snapshot.orbits.isEmpty
        ? 'Waiting for GPS ephemerides (RTCM 1019) and a GPS MSM epoch (1071–1077).'
        : valid.isEmpty
        ? 'No GPS trajectories above the horizon with fresh ephemerides (within 2 hours).'
        : null;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text(
          'GPS sky plot',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Mountpoint')),
            ButtonSegment(value: true, label: Text('Rover')),
          ],
          selected: {rover},
          onSelectionChanged: (v) => setState(() => rover = v.first),
        ),
        if (observer != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${observer.latitude.toStringAsFixed(6)}°, ${observer.longitude.toStringAsFixed(6)}°${observer.height == null ? ' · height assumed 0 m' : ''}',
            ),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(message),
          ),
        AspectRatio(
          aspectRatio: 1,
          child: Semantics(
            label: 'GPS satellite azimuth, elevation and trajectories',
            child: CustomPaint(
              painter: _SkyPainter(
                valid,
                Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
        const Text(
          'North up · East right · Elevation rings: 0°, 30°, 60°; centre: 90°.',
        ),
        const SizedBox(height: 6),
        Text(
          'GPS · ±30 minutes around the latest stream epoch${epoch == null ? '' : ' · TOW ${epoch.tow.toStringAsFixed(1)} s, week ${epoch.week}'}. The dot marks the satellite at that epoch.',
        ),
        const SizedBox(height: 6),
        Text(
          '${visible.length} satellites above the horizon at the stream epoch · ${widget.snapshot.orbits.length} ephemerides received.',
        ),
        const Text(
          'Positions are calculated from the caster ephemerides, not from the phone GNSS. Other constellations are not plotted yet.',
        ),
        for (final t in visible)
          ListTile(
            dense: true,
            leading: Icon(Icons.satellite_alt, color: skyColor(t.prn)),
            title: Text('G${t.prn.toString().padLeft(2, '0')}'),
            subtitle: Text(
              'Az ${((t.points[15]!.azimuth * 180 / math.pi + 360) % 360).toStringAsFixed(1)}° · El ${(t.points[15]!.elevation * 180 / math.pi).toStringAsFixed(1)}°',
            ),
          ),
      ],
    );
  }
}

Color skyColor(int prn) =>
    HSVColor.fromAHSV(1, (prn * 0.61803398875 % 1) * 360, .72, .78).toColor();

class _SkyPainter extends CustomPainter {
  _SkyPainter(this.tracks, this.foreground);
  final List<SkyTrack> tracks;
  final Color foreground;
  void label(Canvas c, String text, Offset at, {Color? color}) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color ?? foreground,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(c, at - Offset(p.width / 2, p.height / 2));
  }

  @override
  void paint(Canvas c, Size size) {
    final centre = Offset(size.width / 2, size.height / 2),
        r = math.max(1.0, math.min(size.width, size.height) / 2 - 30);
    final grid = Paint()
      ..color = foreground.withValues(alpha: .25)
      ..style = PaintingStyle.stroke;
    for (final f in [1.0, 2 / 3, 1 / 3]) {
      c.drawCircle(centre, r * f, grid);
    }
    c.drawLine(centre - Offset(r, 0), centre + Offset(r, 0), grid);
    c.drawLine(centre - Offset(0, r), centre + Offset(0, r), grid);
    for (final (name, x, y) in [
      ('N', 0, -1),
      ('E', 1, 0),
      ('S', 0, 1),
      ('W', -1, 0),
    ]) {
      label(c, name, centre + Offset(x * (r + 17), y * (r + 17)));
    }
    for (final (name, f) in [('0°', 1.0), ('30°', 2 / 3), ('60°', 1 / 3)]) {
      label(c, name, centre + Offset(18, -r * f + 8));
    }
    Offset project(SkyPoint p) {
      final radius = r * (1 - p.elevation / (math.pi / 2));
      return centre +
          Offset(radius * math.sin(p.azimuth), -radius * math.cos(p.azimuth));
    }

    for (final track in tracks) {
      final path = Path();
      var started = false;
      for (final p in track.points) {
        if (p == null) {
          started = false;
          continue;
        }
        final at = project(p);
        if (started) {
          path.lineTo(at.dx, at.dy);
        } else {
          path.moveTo(at.dx, at.dy);
          started = true;
        }
      }
      c.drawPath(
        path,
        Paint()
          ..color = skyColor(track.prn)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.7,
      );
      final current = track.points[15];
      if (current != null) {
        final at = project(current);
        c.drawCircle(at, 4, Paint()..color = skyColor(track.prn));
        label(
          c,
          'G${track.prn.toString().padLeft(2, '0')}',
          at + const Offset(12, -10),
          color: skyColor(track.prn),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SkyPainter old) => true;
}
