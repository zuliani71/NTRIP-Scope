import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'geo.dart';
import 'sky.dart';
import 'receiver_fix.dart';
import 'sky_view.dart';

class ScopeMapScreen extends StatelessWidget {
  const ScopeMapScreen({
    super.key,
    required this.positions,
    this.sky,
    this.name = '',
    this.tileProvider,
    this.fixStatus,
    this.receiverActive = false,
    this.manualRover = false,
  });
  final String name;
  final ReceiverFixStatus? fixStatus;
  final bool receiverActive, manualRover;
  final ValueListenable<GeoSnapshot> positions;
  final ValueListenable<SkySnapshot>? sky;
  final TileProvider? tileProvider;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: Text(name.isEmpty ? 'Map & sky' : 'Map & sky · $name'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Map'),
            Tab(text: 'GPS sky'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          children: [
            ValueListenableBuilder<GeoSnapshot>(
              valueListenable: positions,
              builder: (context, value, _) => ScopeMap(
                snapshot: value,
                tileProvider: tileProvider,
                name: name,
                fixStatus: fixStatus,
                receiverActive: receiverActive,
                manualRover: manualRover,
              ),
            ),
            ValueListenableBuilder<GeoSnapshot>(
              valueListenable: positions,
              builder: (context, value, _) => sky == null
                  ? GpsSkyView(positions: value, snapshot: const SkySnapshot())
                  : ValueListenableBuilder<SkySnapshot>(
                      valueListenable: sky!,
                      builder: (context, snapshot, _) =>
                          GpsSkyView(positions: value, snapshot: snapshot),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class ScopeMap extends StatefulWidget {
  const ScopeMap({
    super.key,
    required this.snapshot,
    this.networkTiles = true,
    this.tileProvider,
    this.name = '',
    this.fixStatus,
    this.receiverActive = false,
    this.manualRover = false,
  });
  final String name;
  final ReceiverFixStatus? fixStatus;
  final bool receiverActive, manualRover;
  final GeoSnapshot snapshot;
  final bool networkTiles;
  final TileProvider? tileProvider;
  @override
  State<ScopeMap> createState() => ScopeMapState();
}

class ScopeMapState extends State<ScopeMap> {
  final controller = MapController();
  bool street = true, ready = false, positioned = false;
  List<Polygon> land = [];
  double zoom = 3, latitude = 0;
  double get currentZoom => ready ? controller.camera.zoom : zoom;
  late final GeoSnapshot _initialSnapshot;
  late final List<LatLng> _initialPoints;
  LatLng point(GeoPosition p) => LatLng(p.latitude, p.longitude);
  @override
  void initState() {
    super.initState();
    // Capture the first view before late rover updates can alter its camera.
    _initialSnapshot = widget.snapshot;
    _initialPoints = [
      if (_initialSnapshot.station != null) point(_initialSnapshot.station!),
      if (_initialSnapshot.rover != null) point(_initialSnapshot.rover!),
    ];
    loadLand();
  }

  Future<void> loadLand() async {
    final rings =
        jsonDecode(await rootBundle.loadString('assets/land.json')) as List;
    final polygons = [
      for (final ring in rings)
        Polygon(
          points: [
            for (final pair in ring as List)
              LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble()),
          ],
          color: const Color(0xffbfdbb3),
          borderColor: const Color(0xff7c9d73),
          borderStrokeWidth: 0.5,
        ),
    ];
    if (mounted) setState(() => land = polygons);
  }

  @override
  void didUpdateWidget(covariant ScopeMap old) {
    super.didUpdateWidget(old);
    if (old.snapshot.key != widget.snapshot.key) positioned = false;
    if (!positioned && widget.snapshot.station != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) initialFit();
      });
    }
  }

  void initialFit() {
    if (!ready || positioned || widget.snapshot.station == null) return;
    positioned = true;
    showBoth();
  }

  void showBoth() {
    if (!ready) return;
    final positions = [
      if (widget.snapshot.station != null) point(widget.snapshot.station!),
      if (widget.snapshot.rover != null) point(widget.snapshot.rover!),
    ];
    if (positions.isEmpty) return;
    if (positions.length == 1 || positions[0] == positions.last) {
      controller.move(positions.first, 14);
      return;
    }
    controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(positions),
        padding: const EdgeInsets.all(55),
        maxZoom: 18,
      ),
    );
  }

  void zoomBy(double delta) {
    if (ready)
      controller.move(
        controller.camera.center,
        (controller.camera.zoom + delta).clamp(2, 19),
      );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Widget coordinates(String title, GeoPosition p, {String? source}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$title${source == null || source.isEmpty ? '' : ' · $source'}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Table(
          columnWidths: const {
            0: FlexColumnWidth(0.7),
            1: FlexColumnWidth(1),
            2: FlexColumnWidth(1.6),
          },
          children: [
            const TableRow(
              children: [
                Text(''),
                Text('Decimal degrees', style: TextStyle(fontSize: 11)),
                Text(
                  'Degrees, minutes, seconds',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
            for (final (label, value, isLat) in [
              ('Latitude', p.latitude, true),
              ('Longitude', p.longitude, false),
            ])
              TableRow(
                children: [
                  Text(label, style: const TextStyle(fontSize: 12)),
                  Text(
                    '${value.toStringAsFixed(6)}°',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    GeoPosition.dms(value, isLat),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
          ],
        ),
        Text(
          'Ellipsoidal height: ${p.height?.toStringAsFixed(3) ?? 'Unavailable'}${p.height == null ? '' : ' m'}',
          style: const TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
  Marker marker(GeoPosition p, String label, Color color) => Marker(
    point: point(p),
    width: 110,
    height: 60,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Icon(Icons.circle, color: color, size: 17),
        Positioned(
          top: 42,
          child: Container(
            color: Colors.white.withValues(alpha: 0.9),
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
            ),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot.station, r = widget.snapshot.rover;
    final distance = s != null && r != null ? s.distanceKm(r) : null;
    final points = [if (s != null) point(s), if (r != null) point(r)];
    final mpp =
        math.cos(latitude * math.pi / 180) *
        2 *
        math.pi *
        6378137 /
        (256 * math.pow(2, zoom));
    final target = math.max(0.000001, mpp * 90 / 1000);
    final power = math
        .pow(10, (math.log(target) / math.ln10).floor())
        .toDouble();
    final nice =
        [
          1.0,
          2.0,
          5.0,
          10.0,
        ].lastWhere((n) => n * power <= target, orElse: () => 1.0) *
        power;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<bool>(
                  isExpanded: true,
                  value: street,
                  items: const [
                    DropdownMenuItem(value: true, child: Text('Street map')),
                    DropdownMenuItem(value: false, child: Text('Offline map')),
                  ],
                  onChanged: (value) => setState(() => street = value!),
                ),
              ),
              IconButton(
                tooltip: 'Zoom in',
                onPressed: () => zoomBy(1),
                icon: const Icon(Icons.add),
              ),
              IconButton(
                tooltip: 'Zoom out',
                onPressed: () => zoomBy(-1),
                icon: const Icon(Icons.remove),
              ),
              TextButton(
                onPressed: points.isEmpty ? null : showBoth,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                child: const Text('Show both', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        if (s == null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('Waiting for RTCM 1005/1006 station coordinates'),
          ),
        Expanded(
          child: Stack(
            children: [
              FlutterMap(
                mapController: controller,
                options: MapOptions(
                  initialCenter: _initialPoints.isEmpty
                      ? const LatLng(0, 0)
                      : _initialPoints.first,
                  initialZoom: _initialPoints.isEmpty ? 3 : 14,
                  initialCameraFit:
                      _initialPoints.length > 1 &&
                          _initialPoints.first != _initialPoints.last
                      ? CameraFit.bounds(
                          bounds: LatLngBounds.fromPoints(_initialPoints),
                          padding: const EdgeInsets.all(55),
                          maxZoom: 18,
                        )
                      : null,
                  minZoom: 2,
                  maxZoom: 19,
                  backgroundColor: const Color(0xffd8e7ef),
                  onMapReady: () {
                    setState(() {
                      ready = true;
                      zoom = controller.camera.zoom;
                      latitude = controller.camera.center.latitude;
                      positioned = _initialSnapshot.station != null;
                    });
                    // Initial framing belongs to MapOptions: moving the camera here
                    // can leave the first TileLayer incompletely loaded.
                    if (!positioned && widget.snapshot.station != null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) initialFit();
                      });
                    }
                  },
                  onPositionChanged: (camera, _) {
                    setState(() {
                      zoom = camera.zoom;
                      latitude = camera.center.latitude;
                    });
                  },
                ),
                children: [
                  if (street && widget.networkTiles)
                    TileLayer(
                      tileProvider: widget.tileProvider,
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName:
                          'io.github.zuliani71.ntripscope_mobile',
                      panBuffer: 0,
                    ),
                  if (!street || !widget.networkTiles)
                    PolygonLayer(polygons: land),
                  if (s != null && r != null)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: points,
                          color: Colors.blue,
                          strokeWidth: 3,
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: [
                      if (s != null) marker(s, 'Mountpoint', Colors.red),
                      if (r != null) marker(r, 'Rover', Colors.blue),
                      if (s != null && r != null)
                        Marker(
                          point: LatLng(
                            (s.latitude + r.latitude) / 2,
                            s.longitude +
                                ((r.longitude - s.longitude + 540) % 360 -
                                        180) /
                                    2,
                          ),
                          width: 100,
                          height: 24,
                          child: Container(
                            alignment: Alignment.center,
                            color: Colors.white.withValues(alpha: 0.9),
                            child: Text(
                              '${distance!.toStringAsFixed(3)} km',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              Positioned(
                bottom: 4,
                left: 4,
                child: InkWell(
                  onTap: () => launchUrl(
                    Uri.parse(
                      street
                          ? 'https://www.openstreetmap.org/copyright'
                          : 'https://www.naturalearthdata.com/',
                    ),
                  ),
                  child: ColoredBox(
                    color: Colors.white.withValues(alpha: 0.85),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Text(
                        street
                            ? '© OpenStreetMap contributors'
                            : 'Natural Earth · 1:110m',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 7,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  color: Colors.white.withValues(alpha: 0.85),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${nice.toStringAsFixed(nice < 1 ? 3 : 1)} km',
                        style: const TextStyle(fontSize: 10),
                      ),
                      Container(
                        width: (nice * 1000 / mpp).clamp(1, 100),
                        height: 5,
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(),
                            left: BorderSide(),
                            right: BorderSide(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 230),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (s != null)
                  coordinates(
                    'Mountpoint: ${widget.name.isEmpty ? '—' : widget.name}',
                    s,
                    source: widget.snapshot.lastKnown
                        ? 'Last known RTCM position'
                        : 'RTCM 1005/1006',
                  ),
                if (r != null)
                  coordinates('Rover', r, source: widget.snapshot.source),
                if (r == null)
                  const Text(
                    'Rover',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ReceiverFixBadge(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  status: widget.fixStatus,
                  active: widget.receiverActive,
                  manual: widget.manualRover,
                ),
                if (distance != null)
                  Text(
                    'Distance from mountpoint: ${distance.toStringAsFixed(3)} km',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
