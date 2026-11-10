import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'ntrip.dart';
import 'outputs.dart';
import 'rtcm.dart';

void main() => runApp(const ScopeApp());

class ScopeApp extends StatelessWidget {
  const ScopeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'NTRIP Scope',
    theme: ThemeData(colorSchemeSeed: const Color(0xff1b5e9c)),
    home: const ScopeHome(),
  );
}

class ScopeHome extends StatefulWidget {
  const ScopeHome({super.key});
  @override
  State<ScopeHome> createState() => _ScopeHomeState();
}

class _ScopeHomeState extends State<ScopeHome> with WidgetsBindingObserver {
  final host = TextEditingController();
  final port = TextEditingController(text: '2101');
  final mount = TextEditingController();
  final user = TextEditingController();
  final password = TextEditingController();
  final latitude = TextEditingController();
  final longitude = TextEditingController();
  final height = TextEditingController(text: '0.000');
  final geoid = TextEditingController(text: '0.000');
  final preview = <int>[];
  RtcmDecoder decoder = RtcmDecoder();
  final rtcmRevision = ValueNotifier<int>(0);
  NtripSession? session;
  File? capture;
  StreamOutputs? activeOutputs;
  String? fileUri;
  String? bluetoothAddress;
  String? bluetoothName;
  String? outputNotice;
  final tcpPort = TextEditingController(text: '5000');
  bool forwardTcp = false;
  bool allowNetwork = false;
  List<String> mountpoints = [];
  Map<String, String> desktopOutputs = const {};
  Timer? redraw;
  var count = 0;
  var version = 2;
  var status = 'Ready';
  var tls = false;
  var sendRover = false;
  var record = false;
  var readingSettings = false;
  bool get busy => session != null || readingSettings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) stopSession();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stopSession();
    tcpPort.dispose();
    redraw?.cancel();
    rtcmRevision.dispose();
    for (final field in [
      host,
      port,
      mount,
      user,
      password,
      latitude,
      longitude,
      height,
      geoid,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  void showStatus(String message) {
    if (mounted) setState(() => status = message);
  }

  String errorText(Object error) {
    if (error is PlatformException) return error.message ?? error.code;
    if (error is FormatException) return error.message;
    if (error is TimeoutException)
      return 'No response from caster within the timeout';
    if (error is HandshakeException)
      return 'TLS handshake or certificate verification failed';
    if (error is SocketException) return 'Network error · ${error.message}';
    if (error is FileSystemException) return 'File error · ${error.message}';
    return error.toString();
  }

  Future<void> loadConfiguration() async {
    setState(() => readingSettings = true);
    try {
      final picked = await FilePicker.platform.pickFiles();
      if (picked == null || !mounted) return;
      final path = picked.files.single.path;
      if (path == null)
        throw const FormatException('The selected file is unavailable');
      final file = File(path);
      if (await file.length() > 1024 * 1024)
        throw const FormatException('INI file too large');
      final config = Caster.fromIni(await file.readAsString());
      if (!mounted) return;
      setState(() {
        host.text = config.host;
        port.text = '${config.port}';
        mount.text = config.mount;
        user.text = config.username;
        password.text = config.password;
        version = config.version;
        tls = config.tls;
        desktopOutputs = config.desktopOutputs;
        mountpoints = [];
        final rover = config.rover;
        sendRover = rover != null;
        latitude.text = rover?.latitude.toStringAsFixed(6) ?? '';
        longitude.text = rover?.longitude.toStringAsFixed(6) ?? '';
        height.text = rover?.height.toStringAsFixed(3) ?? '0.000';
        geoid.text = rover?.geoid.toStringAsFixed(3) ?? '0.000';
        status = 'Configuration loaded';
      });
    } catch (error) {
      showStatus(errorText(error));
    } finally {
      if (mounted) setState(() => readingSettings = false);
    }
  }

  Caster currentConfig({bool list = false}) {
    double number(TextEditingController field) =>
        double.parse(field.text.trim().replaceAll(',', '.'));
    return Caster(
      host: host.text.trim(),
      port: int.parse(port.text.trim()),
      mount: mount.text.trim(),
      username: user.text,
      password: password.text,
      version: version,
      tls: tls,
      rover: !list && sendRover
          ? Rover(
              number(latitude),
              number(longitude),
              number(height),
              number(geoid),
            )
          : null,
      desktopOutputs: desktopOutputs,
    );
  }

  Future<void> saveConfiguration() async {
    setState(() => readingSettings = true);
    try {
      final bytes = Uint8List.fromList(utf8.encode(currentConfig().toIni()));
      final destination = await FilePicker.platform.saveFile(
        fileName: 'ntripscope.ini',
        bytes: bytes,
      );
      if (destination != null) {
        showStatus(
          password.text.isEmpty
              ? 'Configuration saved'
              : 'Configuration saved without password',
        );
      }
    } catch (error) {
      showStatus(errorText(error));
    } finally {
      if (mounted) setState(() => readingSettings = false);
    }
  }

  Future<void> locate() async {
    setState(() => readingSettings = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const FormatException('Enable location services on the device');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        throw const FormatException(
          'Allow location access while using NTRIP Scope',
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      setState(() {
        latitude.text = position.latitude.toStringAsFixed(6);
        longitude.text = position.longitude.toStringAsFixed(6);
        status =
            'Position loaded · horizontal accuracy ${position.accuracy.round()} m';
      });
    } catch (error) {
      showStatus(errorText(error));
    } finally {
      if (mounted) setState(() => readingSettings = false);
    }
  }

  void outputStatus(String message) {
    if (mounted) setState(() => outputNotice = message);
  }

  void stopSession() {
    session?.stop();
    final outputs = activeOutputs;
    if (outputs != null)
      unawaited(
        outputs.close().catchError((Object error) {
          outputStatus(errorText(error));
        }),
      );
  }

  Future<void> chooseOutputFile() async {
    setState(() => readingSettings = true);
    try {
      final uri = await StreamOutputs.channel.invokeMethod<String>(
        'chooseFile',
      );
      if (mounted && uri != null) setState(() => fileUri = uri);
    } catch (error) {
      outputStatus(errorText(error));
    } finally {
      if (mounted) setState(() => readingSettings = false);
    }
  }

  Future<void> chooseBluetooth() async {
    setState(() => readingSettings = true);
    try {
      final devices =
          await StreamOutputs.channel.invokeListMethod<Map>('pairedDevices') ??
          [];
      if (!mounted) return;
      if (devices.isEmpty) {
        outputStatus(
          'Pair a Bluetooth Classic SPP receiver in Android settings',
        );
        return;
      }
      final selected = await showDialog<Map>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Paired Bluetooth devices'),
          children: [
            for (final device in devices)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, device),
                child: Text(device['name'] as String),
              ),
          ],
        ),
      );
      if (mounted && selected != null)
        setState(() {
          bluetoothAddress = selected['address'] as String;
          bluetoothName = selected['name'] as String;
        });
    } catch (error) {
      outputStatus(errorText(error));
    } finally {
      if (mounted) setState(() => readingSettings = false);
    }
  }

  Future<void> run({required bool list}) async {
    if (busy) return;
    FocusScope.of(context).unfocus();
    Caster config;
    int? listenPort;
    try {
      config = currentConfig(list: list);
      if (!list && forwardTcp) {
        listenPort = int.tryParse(tcpPort.text.trim());
        if (listenPort == null || listenPort < 1 || listenPort > 65535) {
          throw const FormatException('Choose a TCP port between 1 and 65535');
        }
      }
      if (!list && config.mount.replaceAll('/', '').isEmpty) {
        throw const FormatException('Choose a mountpoint');
      }
    } on FormatException catch (error) {
      showStatus(error.message);
      return;
    }
    final active = NtripSession();
    setState(() {
      session = active;
      status = list ? 'Fetching mountpoints…' : 'Connecting…';
      outputNotice = null;
      if (!list) {
        decoder = RtcmDecoder();
        preview.clear();
        count = 0;
      }
    });
    File? pending;
    RandomAccessFile? output;
    try {
      if (list) {
        final result = await active.mountpoints(config);
        if (mounted && !active.stopped) {
          setState(() {
            mountpoints = result;
            status = '${result.length} mountpoints available';
          });
        }
      } else {
        final destinations = StreamOutputs(outputStatus);
        activeOutputs = destinations;
        await destinations.open(
          file: fileUri,
          port: listenPort,
          network: allowNetwork,
          bluetooth: bluetoothAddress,
        );
        if (active.stopped) return;
        if (listenPort != null) {
          outputStatus(
            'TCP listening on ${allowNetwork ? 'the local network' : '127.0.0.1'}:${destinations.tcpPort}',
          );
        }
        if (record) {
          final folder = await getTemporaryDirectory();
          pending = File(
            '${folder.path}/ntrip-${DateTime.now().microsecondsSinceEpoch}.rtcm',
          );
          output = await pending.open(mode: FileMode.write);
        }
        await for (final bytes in active.stream(config)) {
          if (!mounted) break;
          await destinations.write(bytes);
          if (output != null) await output.writeFrom(bytes);
          if (!mounted) break;
          count += bytes.length;
          preview.addAll(
            bytes.length > 256 ? bytes.sublist(bytes.length - 256) : bytes,
          );
          if (preview.length > 256)
            preview.removeRange(0, preview.length - 256);
          decoder.add(bytes);
          redraw ??= Timer(const Duration(milliseconds: 150), () {
            redraw = null;
            if (mounted) rtcmRevision.value++;
            showStatus('Receiving data');
          });
        }
        if (!active.stopped) {
          showStatus(
            count == 0 ? 'Stream closed without data' : 'Stream ended',
          );
        }
      }
    } catch (error) {
      if (!active.stopped) showStatus(errorText(error));
    } finally {
      if (active.stopped) showStatus('Disconnected');
      active.stop();
      redraw?.cancel();
      redraw = null;
      final destinations = activeOutputs;
      activeOutputs = null;
      try {
        await destinations?.close();
      } catch (error) {
        outputStatus(errorText(error));
      }
      try {
        await output?.close();
        if (pending != null && await pending.length() > 0) {
          capture = pending;
        } else {
          await pending?.delete();
        }
      } catch (error) {
        showStatus(errorText(error));
      }
      if (mounted) {
        if (!list) rtcmRevision.value++;
        setState(() => session = null);
      }
    }
  }

  Future<void> shareCapture(BuildContext anchorContext) async {
    final file = capture;
    if (file == null) return;
    final box = anchorContext.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/octet-stream')],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (error) {
      showStatus(errorText(error));
    }
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    bool numeric = false,
    VoidCallback? onChanged,
  }) => TextField(
    controller: controller,
    enabled: !busy,
    autocorrect: false,
    enableSuggestions: !secret,
    obscureText: secret,
    keyboardType: numeric
        ? const TextInputType.numberWithOptions(decimal: true, signed: true)
        : TextInputType.text,
    decoration: InputDecoration(labelText: label),
    onChanged: onChanged == null ? null : (_) => onChanged(),
  );

  void clearMountpoints() {
    if (mountpoints.isNotEmpty) setState(() => mountpoints = []);
  }

  Future<void> showProjectInfo() async {
    final package = await PackageInfo.fromPlatform();
    if (!mounted) return;
    final project = Uri.https('github.com', '/zuliani71/NTRIP-Scope');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About NTRIP Scope'),
        content: SingleChildScrollView(
          child: Text(
            'Version ${package.version} (build ${package.buildNumber})\n'
            'David Zuliani (zuliani71)\n\n'
            'Software: MIT License\n'
            'Original published project materials: CC BY 4.0 unless indicated otherwise.\n\n'
            '$project',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () async {
              if (!await launchUrl(
                    project,
                    mode: LaunchMode.externalApplication,
                  ) &&
                  context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Could not open GitHub')),
                );
              }
            },
            child: const Text('Open on GitHub'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/orbit.png', width: 32, height: 32),
            ),
            const SizedBox(width: 12),
            const Text('NTRIP Scope'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'About NTRIP Scope',
            onPressed: showProjectInfo,
            icon: const Icon(Icons.info_outline),
          ),
        ],
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Connection'),
            Tab(text: 'Live stream'),
            Tab(text: 'RTCM3'),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            ListTile(
              dense: true,
              leading: Icon(
                session == null ? Icons.sensors_off : Icons.sensors,
              ),
              title: Text(status),
              subtitle: Text(
                '$count bytes · ${decoder.invalidCrc} invalid CRC',
              ),
              trailing: session == null
                  ? null
                  : TextButton(
                      onPressed: () {
                        stopSession();
                        redraw?.cancel();
                        redraw = null;
                        showStatus('Disconnecting…');
                      },
                      child: const Text('Stop'),
                    ),
            ),
            if (session != null) const LinearProgressIndicator(),
            Expanded(
              child: TabBarView(
                children: [
                  connection(context),
                  ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Text('Latest bytes · HEX and ASCII'),
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SelectableText(
                          preview.isEmpty
                              ? 'Waiting for data'
                              : hexAscii(preview),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  frameList(context),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget connection(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    children: [
      OutlinedButton.icon(
        onPressed: busy ? null : loadConfiguration,
        icon: const Icon(Icons.folder_open),
        label: const Text('Load configuration'),
      ),
      OutlinedButton.icon(
        onPressed: busy ? null : saveConfiguration,
        icon: const Icon(Icons.save_outlined),
        label: const Text('Save configuration'),
      ),
      Row(
        children: [
          Expanded(
            flex: 3,
            child: field(host, 'Caster host', onChanged: clearMountpoints),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: field(
              port,
              'Port',
              numeric: true,
              onChanged: clearMountpoints,
            ),
          ),
        ],
      ),
      Row(
        children: [
          Expanded(child: field(mount, 'Mountpoint')),
          PopupMenuButton<String>(
            tooltip: 'Select mountpoint',
            enabled: !busy && mountpoints.isNotEmpty,
            onSelected: (name) => setState(() => mount.text = name),
            itemBuilder: (_) => [
              for (final name in mountpoints)
                PopupMenuItem(value: name, child: Text(name)),
            ],
          ),
        ],
      ),
      field(user, 'Username', onChanged: clearMountpoints),
      field(password, 'Password', secret: true, onChanged: clearMountpoints),
      Row(
        children: [
          Expanded(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('TLS'),
              value: tls,
              onChanged: busy
                  ? null
                  : (value) => setState(() {
                      tls = value;
                      mountpoints = [];
                    }),
            ),
          ),
          const SizedBox(width: 20),
          DropdownButton<int>(
            value: version,
            onChanged: busy
                ? null
                : (value) => setState(() {
                    version = value!;
                    mountpoints = [];
                  }),
            items: const [
              DropdownMenuItem(value: 1, child: Text('NTRIP 1.0')),
              DropdownMenuItem(value: 2, child: Text('NTRIP 2.0')),
            ],
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Send rover GGA'),
        value: sendRover,
        onChanged: busy ? null : (value) => setState(() => sendRover = value),
      ),
      if (sendRover) ...[
        Row(
          children: [
            Expanded(child: field(latitude, 'Latitude (°)', numeric: true)),
            const SizedBox(width: 12),
            Expanded(child: field(longitude, 'Longitude (°)', numeric: true)),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: field(height, 'Ellipsoidal height (m)', numeric: true),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: field(geoid, 'Geoid separation (m)', numeric: true),
            ),
          ],
        ),
        TextButton.icon(
          onPressed: busy ? null : locate,
          icon: const Icon(Icons.my_location),
          label: const Text('Use phone latitude and longitude'),
        ),
      ],
      if (Platform.isAndroid) androidOutputs(),
      if (outputNotice != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(outputNotice!),
        ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Record RTCM'),
        value: record,
        onChanged: busy ? null : (value) => setState(() => record = value!),
      ),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton(
            onPressed: busy ? null : () => run(list: false),
            child: const Text('Connect'),
          ),
          OutlinedButton(
            onPressed: busy ? null : () => run(list: true),
            child: const Text('Fetch mountpoints'),
          ),
          if (capture != null)
            Builder(
              builder: (anchor) => OutlinedButton.icon(
                onPressed: busy ? null : () => shareCapture(anchor),
                icon: const Icon(Icons.share),
                label: const Text('Export capture'),
              ),
            ),
        ],
      ),
    ],
  );

  Widget androidOutputs() => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: const Text('Stream outputs'),
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Write RTCM to file'),
        subtitle: Text(
          fileUri == null
              ? 'Off'
              : 'Destination selected. Replaced at connection.',
        ),
        onTap: busy ? null : chooseOutputFile,
        trailing: fileUri == null
            ? null
            : IconButton(
                tooltip: 'Disable file output',
                onPressed: busy ? null : () => setState(() => fileUri = null),
                icon: const Icon(Icons.clear),
              ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('TCP server'),
        value: forwardTcp,
        onChanged: busy ? null : (value) => setState(() => forwardTcp = value),
      ),
      if (forwardTcp) ...[
        field(tcpPort, 'TCP port', numeric: true),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allow clients on the local network'),
          subtitle: const Text('TCP output has no authentication'),
          value: allowNetwork,
          onChanged: busy
              ? null
              : (value) => setState(() => allowNetwork = value),
        ),
      ],
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Bluetooth Classic (SPP)'),
        subtitle: Text(bluetoothName ?? 'Off · select a paired receiver'),
        onTap: busy ? null : chooseBluetooth,
        trailing: bluetoothAddress == null
            ? null
            : IconButton(
                tooltip: 'Disable Bluetooth output',
                onPressed: busy
                    ? null
                    : () => setState(() {
                        bluetoothAddress = null;
                        bluetoothName = null;
                      }),
                icon: const Icon(Icons.clear),
              ),
      ),
    ],
  );

  Widget frameList(BuildContext context) {
    final types = decoder.counts.keys.toList()..sort();
    if (types.isEmpty)
      return const Center(child: Text('No valid RTCM3 frames received'));
    return ListView.builder(
      itemCount: types.length,
      itemBuilder: (context, index) {
        final type = types[index];
        final frames = decoder.frames[type]!;
        return ListTile(
          title: Text('$type · ${frames.first.name}'),
          subtitle: Text('${decoder.counts[type]} frames'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FrameView(frames: frames, updates: rtcmRevision),
            ),
          ),
        );
      },
    );
  }
}

class FrameView extends StatefulWidget {
  const FrameView({super.key, required this.frames, required this.updates});
  final List<RtcmFrame> frames;
  final Listenable updates;
  @override
  State<FrameView> createState() => _FrameViewState();
}

class _FrameViewState extends State<FrameView> {
  static const latest = 'latest';
  RtcmFrame? selectedFrame;
  int? slot;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.updates,
    builder: (context, _) => frameDetails(),
  );

  Widget frameDetails() {
    final frame = selectedFrame ?? widget.frames.first;
    final history = widget.frames.skip(1).toList();
    if (selectedFrame != null && !history.contains(selectedFrame)) {
      history.add(selectedFrame!);
    }
    String time(RtcmFrame item) =>
        item.timestamp.toLocal().toIso8601String().substring(11, 23);

    Map<String, String> fields = {};
    List<Observation> observations = [];
    String? warning;
    try {
      fields = frame.details();
      observations = frame.observations();
    } on FormatException catch (error) {
      warning = error.message;
    }
    final slots = {
      for (final row in observations) row.slot,
      if (slot != null) slot!,
    }.toList()..sort();
    String measurement(double? value) => value?.toStringAsFixed(4) ?? '—';

    return Scaffold(
      appBar: AppBar(title: Text('${frame.type} · ${frame.name}')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButton<Object>(
              isExpanded: true,
              value: selectedFrame ?? latest,
              items: [
                DropdownMenuItem(
                  value: latest,
                  child: Text('Latest frame · ${time(widget.frames.first)}'),
                ),
                for (final previous in history)
                  DropdownMenuItem(
                    value: previous,
                    child: Text('Frame · ${time(previous)}'),
                  ),
              ],
              onChanged: (value) => setState(() {
                selectedFrame = value is RtcmFrame ? value : null;
                slot = null;
              }),
            ),
            for (final entry in fields.entries)
              Text('${entry.key} · ${entry.value}'),
            if (warning != null) Text(warning),
            if (slots.isNotEmpty) ...[
              const SizedBox(height: 10),
              DropdownButton<int>(
                value: slot,
                hint: const Text('All satellite slots'),
                items: [
                  const DropdownMenuItem<int>(
                    value: null,
                    child: Text('All satellite slots'),
                  ),
                  for (final satellite in slots)
                    DropdownMenuItem(
                      value: satellite,
                      child: Text('Slot $satellite'),
                    ),
                ],
                onChanged: (value) => setState(() => slot = value),
              ),
              if (slot != null && observations.every((row) => row.slot != slot))
                const Text('Selected satellite is absent from this frame.'),
              if (frame.type % 10 <= 3)
                const Text('Ranges are modulo 1 ms for MSM1–3.'),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: [
                    for (final label in [
                      'Slot',
                      'Signal',
                      'Code (m)',
                      'Phase (m)',
                      'C/N₀ (dB-Hz)',
                      'Rate (m/s)',
                    ])
                      DataColumn(label: Text(label)),
                  ],
                  rows: [
                    for (final row in observations.where(
                      (row) => slot == null || row.slot == slot,
                    ))
                      DataRow(
                        cells: [
                          for (final value in [
                            '${row.slot}',
                            row.signal,
                            measurement(row.code),
                            measurement(row.phase),
                            measurement(row.cnr),
                            measurement(row.rate),
                          ])
                            DataCell(Text(value)),
                        ],
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            const Text('Payload · HEX and ASCII'),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                hexAscii(frame.payload),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
