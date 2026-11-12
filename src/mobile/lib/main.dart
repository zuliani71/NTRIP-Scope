import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
import 'geo.dart';
import 'map_view.dart';
import 'live_stream_view.dart';
import 'rover_angle_editor.dart';
import 'cnr_chart.dart';
import 'sky.dart';
import 'traffic_bar.dart';
import 'receiver_fix.dart';
import 'background_streaming.dart';
import 'configuration_save.dart';

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
  final receiverPreviews = <String, List<int>>{};
  final receiverCounts = <String, int>{};
  RtcmDecoder decoder = RtcmDecoder();
  final fixModel = ReceiverFixModel();
  final fixRevision = ValueNotifier<int>(0);
  final frameListScroll = ScrollController();
  final rtcmRevision = ValueNotifier<int>(0);
  final trafficRevision = ValueNotifier<int>(0);
  final mapModel = RoverMapModel();
  final skyRevision = ValueNotifier<SkySnapshot>(const SkySnapshot());
  final mapRevision = ValueNotifier<GeoSnapshot>(const GeoSnapshot());
  Timer? receiverRedraw;
  String appVersion = '';
  DateTime? lastCasterAt;
  String? receiverError;
  bool receiverLinked = false;
  int decoderRevision = 0;
  NtripSession? session;
  File? capture;
  StreamOutputs? activeOutputs;
  String? fileUri;
  String? bluetoothAddress;
  String? bluetoothName;
  String? outputNotice;
  String? ggaNotice;
  final bleService = TextEditingController(
    text: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
  );
  final bleWrite = TextEditingController(
    text: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
  );
  final bleRead = TextEditingController(
    text: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
  );
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
  bool get _androidBackground =>
      defaultTargetPlatform == TargetPlatform.android;
  String configurationName = "ntripscope.ini";
  bool keepStreaming = false;
  bool _hidden = false, _disposing = false;
  int _shutdowns = 0;
  Completer<void>? _sessionDone;
  BackgroundStreaming? _backgroundLease;
  static const _lifecycleChannel = MethodChannel('ntripscope/lifecycle');
  bool get busy => session != null || readingSettings || _shutdowns > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycleChannel.setMethodCallHandler((call) async {
      if (call.method == 'suspend') {
        _hidden = true;
        if (_backgroundLease?.ready != true)
          await stopSession(releaseReceiver: true);
      } else if (call.method == 'stop') {
        await stopSession(releaseReceiver: true);
      }
    });
    for (final input in [latitude, longitude, height]) {
      input.addListener(refreshManualMap);
    }
    unawaited(loadLocalSettings());
    PackageInfo.fromPlatform()
        .then((package) {
          if (mounted) setState(() => appVersion = package.version);
        })
        .catchError((Object _) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _hidden = false;
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _hidden = true;
      if (state == AppLifecycleState.detached ||
          _backgroundLease?.ready != true) {
        unawaited(stopSession(releaseReceiver: true));
      }
    }
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleChannel.setMethodCallHandler(null);
    unawaited(stopSession(releaseReceiver: true));
    receiverRedraw?.cancel();
    trafficRevision.dispose();
    mapRevision.dispose();
    skyRevision.dispose();
    tcpPort.dispose();
    bleService.dispose();
    bleWrite.dispose();
    bleRead.dispose();
    redraw?.cancel();
    rtcmRevision.dispose();
    frameListScroll.dispose();
    fixRevision.dispose();
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
        configurationName = picked.files.single.name;
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
      final destination = Platform.isAndroid
          ? await saveConfigurationFile(
              context,
              bytes,
              initialName: configurationName,
            )
          : await FilePicker.platform.saveFile(
              fileName: configurationName,
              bytes: bytes,
            );
      if (destination != null) {
        if (Platform.isAndroid) configurationName = destination;
        unawaited(saveLocalSettings());
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

  void showMap() {
    final key =
        '${host.text.trim().toLowerCase()}|${port.text.trim()}|$tls|${mount.text.trim()}';
    if (!busy && mapModel.key != key) {
      mapModel.begin(key, null);
      skyRevision.value = const SkySnapshot();
      mapModel.stop();
      refreshManualMap();
      mapRevision.value = mapModel.snapshot;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ListenableBuilder(
          listenable: fixRevision,
          builder: (context, child) => ScopeMapScreen(
            fixStatus: fixModel.status,
            receiverActive: session != null && !session!.stopped,
            manualRover: sendRover,
            positions: mapRevision,
            sky: skyRevision,
            name: mount.text.trim(),
          ),
        ),
      ),
    );
  }

  void refreshManualMap() {
    if (!mounted || busy) return;
    final lat = double.tryParse(latitude.text.replaceAll(',', '.')),
        lon = double.tryParse(longitude.text.replaceAll(',', '.')),
        h = double.tryParse(height.text.replaceAll(',', '.'));
    mapModel.manual =
        sendRover &&
            lat != null &&
            lon != null &&
            lat.isFinite &&
            lon.isFinite &&
            lat.abs() <= 90 &&
            lon.abs() <= 180
        ? GeoPosition(lat, lon, h?.isFinite == true ? h : null)
        : null;
    mapRevision.value = mapModel.snapshot;
  }

  Future<File> localSettingsFile() async => File(
    '${(await getApplicationSupportDirectory()).path}/receiver-settings.json',
  );
  Future<void> loadLocalSettings() async {
    try {
      final values =
          jsonDecode(await (await localSettingsFile()).readAsString()) as Map;
      if (!mounted || host.text.isNotEmpty) return;
      setState(() {
        host.text = values['host'] as String? ?? '';
        port.text = values['port'] as String? ?? '2101';
        mount.text = values['mount'] as String? ?? '';
        user.text = values['user'] as String? ?? '';
        tls = values['tls'] == true;
        version = values['version'] as int? ?? 2;
        bluetoothAddress = values['bluetoothAddress'] as String?;
        bluetoothName = values['bluetoothName'] as String?;
        keepStreaming = values['keepStreaming'] == true;
        configurationName =
            values['configurationName'] as String? ?? 'ntripscope.ini';
      });
    } catch (_) {
      /* No saved non-secret settings yet. */
    }
  }

  Future<void> saveLocalSettings() async {
    try {
      final file = await localSettingsFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'host': host.text,
          'port': port.text,
          'mount': mount.text,
          'user': user.text,
          'tls': tls,
          'version': version,
          'bluetoothAddress': bluetoothAddress,
          'bluetoothName': bluetoothName,
          'keepStreaming': keepStreaming,
          'configurationName': configurationName,
        }),
      );
    } catch (_) {
      /* Configuration export remains available. */
    }
  }

  Future<void> releaseNativeReceiver() async {
    try {
      await StreamOutputs.channel
          .invokeMethod<void>(Platform.isIOS ? 'closeBle' : 'closeBluetooth')
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      if (mounted) outputStatus(errorText(error));
    }
    receiverLinked = false;
  }

  Future<void> disconnectReceiver() async {
    await releaseNativeReceiver();
    if (mounted) setState(() {});
  }

  Future<void> stopSession({bool releaseReceiver = false}) async {
    final active = session;
    active?.stop(releaseReceiver: releaseReceiver);
    if (!_disposing) fixRevision.value++;
    mapModel.stop();
    if (!_disposing) mapRevision.value = mapModel.snapshot;
    redraw?.cancel();
    redraw = null;
    receiverRedraw?.cancel();
    receiverRedraw = null;
    final outputs = activeOutputs;
    final lease = _backgroundLease;
    final done = _sessionDone;
    _shutdowns++;
    if (mounted && !_disposing) setState(() => status = 'Disconnecting…');
    try {
      await Future.wait<void>([
        if (outputs != null)
          outputs.close(keepBluetooth: Platform.isAndroid && !releaseReceiver),
        if (lease != null) lease.stop(),
        if (releaseReceiver && bluetoothAddress != null)
          releaseNativeReceiver(),
        if (done != null) done.future,
      ]);
    } catch (error) {
      if (mounted && !_disposing) outputStatus(errorText(error));
    } finally {
      _shutdowns--;
      if (mounted && !_disposing)
        setState(() {
          if (session == null)
            status = _hidden
                ? 'Session closed · app in background'
                : 'Disconnected';
        });
    }
  }

  Future<void> toggleBackground(bool enabled) async {
    if (busy) return;
    if (!enabled) {
      setState(() => keepStreaming = false);
      unawaited(saveLocalSettings());
      return;
    }
    setState(() => readingSettings = true);
    try {
      final permissions = await BackgroundStreaming.prepare();
      if (!mounted) return;
      setState(() {
        keepStreaming = true;
        outputNotice = permissions['batteryExempt'] == false
            ? 'For long screen-off sessions, allow unrestricted battery use in Battery settings.'
            : null;
      });
      unawaited(saveLocalSettings());
    } catch (error) {
      if (mounted) outputStatus(errorText(error));
    } finally {
      if (mounted) setState(() => readingSettings = false);
    }
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
          await StreamOutputs.channel.invokeListMethod<Map>(
            Platform.isIOS ? 'scanBle' : 'pairedDevices',
          ) ??
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
          title: Text(
            Platform.isIOS ? 'Nearby BLE devices' : 'Paired Bluetooth devices',
          ),
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
      unawaited(saveLocalSettings());
    } catch (error) {
      outputStatus(errorText(error));
    } finally {
      if (mounted) setState(() => readingSettings = false);
    }
  }

  Future<void> run({required bool list}) async {
    if (busy || _hidden) return;
    FocusScope.of(context).unfocus();
    Caster config;
    int? listenPort;
    try {
      config = currentConfig(list: list);
      if (!list && Platform.isIOS && bluetoothAddress != null) {
        final uuid = RegExp(
          r'^(?:[0-9a-fA-F]{4}|[0-9a-fA-F]{8}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$',
        );
        if ([
          bleService,
          bleWrite,
          bleRead,
        ].any((field) => !uuid.hasMatch(field.text.trim()))) {
          throw const FormatException(
            'Enter valid BLE service and characteristic UUIDs',
          );
        }
      }
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
    late final NtripSession active;
    active = NtripSession(
      onGgaSource: (source) {
        if (mounted &&
            session == active &&
            !active.stopped &&
            source != ggaNotice)
          setState(() => ggaNotice = source);
      },
    );
    final finished = Completer<void>();
    _sessionDone = finished;
    setState(() {
      session = active;
      status = list ? 'Fetching mountpoints…' : 'Connecting…';
      outputNotice = null;
      receiverError = null;
      ggaNotice = null;
      if (!list) {
        final streamKey =
            '${config.host.toLowerCase()}|${config.port}|${config.tls}|${config.mount}';
        final manual = config.rover;
        mapModel.begin(
          streamKey,
          manual == null
              ? null
              : GeoPosition(manual.latitude, manual.longitude, manual.height),
        );
        mapRevision.value = mapModel.snapshot;
        decoderRevision = 0;
        lastCasterAt = null;
        decoder = RtcmDecoder();
        skyRevision.value = const SkySnapshot();
        preview.clear();
        receiverPreviews.clear();
        receiverCounts.clear();
        fixModel.reset();
        fixRevision.value++;
        count = 0;
      }
    });
    unawaited(saveLocalSettings());
    File? pending;
    RandomAccessFile? output;
    StreamOutputs? destinations;
    final lease = !list && _androidBackground && keepStreaming
        ? BackgroundStreaming()
        : null;
    _backgroundLease = lease;
    try {
      if (lease != null) {
        await lease.start(config.mount);
        if (active.stopped) return;
      }
      if (list) {
        final result = await active.mountpoints(config);
        if (mounted && !active.stopped) {
          setState(() {
            mountpoints = result;
            status = '${result.length} mountpoints available';
          });
        }
      } else {
        destinations = StreamOutputs(
          (message) {
            if (!mounted || session != active || active.stopped) return;
            if (message.startsWith('Bluetooth')) {
              receiverError = message;
              receiverLinked = false;
              active.stop();
              mapModel.stop();
              mapRevision.value = mapModel.snapshot;
            }
            outputStatus(message);
          },
          onMonitorData: (source, bytes) {
            if (!mounted || session != active || active.stopped) return;
            if (fixModel.add(source, bytes)) fixRevision.value++;
            final buffer = receiverPreviews.putIfAbsent(source, () => <int>[]);
            buffer.addAll(
              bytes.length > 8192 ? bytes.sublist(bytes.length - 8192) : bytes,
            );
            if (buffer.length > 8192)
              buffer.removeRange(0, buffer.length - 8192);
            receiverCounts[source] =
                (receiverCounts[source] ?? 0) + bytes.length;
            mapModel.accept(source, bytes);
            mapRevision.value = mapModel.snapshot;
            receiverRedraw ??= Timer(const Duration(milliseconds: 150), () {
              receiverRedraw = null;
              if (mounted && !active.stopped) trafficRevision.value++;
            });
          },
          onReceiverData: active.receiveExternal,
          onReceiverDisconnected: () {
            if (!mounted || session != active || active.stopped) return;
            receiverLinked = false;
            active.externalDisconnected();
          },
        );
        activeOutputs = destinations;
        await destinations.open(
          file: fileUri,
          port: listenPort,
          network: allowNetwork,
          bluetooth: bluetoothAddress,
          bleProfile: Platform.isIOS
              ? {
                  'service': bleService.text.trim(),
                  'write': bleWrite.text.trim(),
                  'read': bleRead.text.trim(),
                }
              : null,
        );
        if (active.stopped) return;
        receiverLinked = bluetoothAddress != null;
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
          if (!mounted || active.stopped) break;
          await destinations.write(bytes);
          if (output != null) await output.writeFrom(bytes);
          if (!mounted || active.stopped) break;
          lastCasterAt = DateTime.now();
          count += bytes.length;
          preview.addAll(
            bytes.length > 256 ? bytes.sublist(bytes.length - 256) : bytes,
          );
          if (preview.length > 256)
            preview.removeRange(0, preview.length - 256);
          decoder.add(bytes);
          mapModel.remember(decoder.station);
          mapRevision.value = mapModel.snapshot;
          redraw ??= Timer(const Duration(milliseconds: 150), () {
            redraw = null;
            if (!mounted || active.stopped) return;
            trafficRevision.value++;
            final revision = decoder.counts.values.fold(
              decoder.invalidCrc,
              (sum, value) => sum + value,
            );
            if (revision != decoderRevision) {
              decoderRevision = revision;
              rtcmRevision.value++;
              skyRevision.value = decoder.sky;
            }
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
      final wasStopped = active.stopped;
      final finalStatus = status;
      active.stop();
      if (mounted && !_disposing && session == active) {
        mapModel.stop();
        mapRevision.value = mapModel.snapshot;
        receiverRedraw?.cancel();
        receiverRedraw = null;
        redraw?.cancel();
        redraw = null;
        if (!list) showStatus(receiverError ?? 'Disconnecting…');
      }
      try {
        await Future.wait<void>([
          if (destinations != null)
            destinations.close(
              keepBluetooth:
                  Platform.isAndroid &&
                  !active.releaseReceiverOnStop &&
                  !_hidden &&
                  receiverError == null,
            ),
          if (lease != null) lease.stop(),
        ]);
      } catch (error) {
        if (mounted && !_disposing && session == active)
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
        if (mounted && !_disposing && session == active)
          outputStatus(errorText(error));
      } finally {
        if (identical(activeOutputs, destinations)) activeOutputs = null;
        if (identical(_backgroundLease, lease)) _backgroundLease = null;
        if (identical(_sessionDone, finished)) _sessionDone = null;
        if (session == active) {
          if (mounted && !_disposing) {
            if (!list) rtcmRevision.value++;
            setState(() {
              session = null;
              fixRevision.value++;
              status = wasStopped || active.releaseReceiverOnStop
                  ? receiverError ??
                        (_hidden
                            ? 'Session closed · app in background'
                            : 'Disconnected')
                  : finalStatus;
            });
          } else {
            session = null;
          }
        }
        if (!finished.isCompleted) finished.complete();
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
  }) => Focus(
    onFocusChange: (focused) {
      if (!focused && (controller == height || controller == geoid)) {
        final value = double.tryParse(controller.text.replaceAll(',', '.'));
        if (value != null && value.isFinite)
          controller.text = value.toStringAsFixed(3);
      }
    },
    child: TextField(
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
    ),
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
              child: Image.asset('assets/orbit.png', width: 40, height: 40),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('NTRIP Scope', style: TextStyle(fontSize: 16)),
                      const SizedBox(width: 4),
                      if (appVersion.isNotEmpty)
                        Text(
                          'v$appVersion',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                  const Text(
                    'NTRIP client · RTCM decoder',
                    style: TextStyle(fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Map & sky',
            onPressed: showMap,
            icon: const Icon(Icons.map_outlined),
          ),
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
                '$count bytes · ${decoder.invalidCrc} invalid CRC'
                '${ggaNotice == null ? '' : '\n$ggaNotice'}',
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
            ValueListenableBuilder<int>(
              valueListenable: fixRevision,
              builder: (context, _, child) => ReceiverFixBadge(
                status: fixModel.status,
                active: session != null && !session!.stopped,
                manual: sendRover,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TrafficBar(
                active: session != null && !session!.stopped,
                lastData: lastCasterAt,
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  connection(context),
                  LiveStreamsPanel(
                    caster: preview,
                    count: count,
                    receivers: receiverPreviews,
                    receiverCounts: receiverCounts,
                    updates: trafficRevision,
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
        title: const Text('Manual Rover position · send GGA'),
        subtitle: const Text(
          'When enabled, the GGA generated from these coordinates overrides GGA received from Bluetooth, serial or TCP sources.',
        ),
        value: sendRover,
        onChanged: busy
            ? null
            : (value) {
                setState(() => sendRover = value);
                refreshManualMap();
              },
      ),
      if (sendRover) ...[
        RoverAngleEditor(decimal: latitude, latitude: true, enabled: !busy),
        RoverAngleEditor(decimal: longitude, latitude: false, enabled: !busy),
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
      if (receiverLinked && !busy)
        TextButton.icon(
          onPressed: disconnectReceiver,
          icon: const Icon(Icons.bluetooth_disabled),
          label: const Text('Disconnect receiver'),
        ),
      if (receiverError != null)
        Text(
          receiverError!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      if (Platform.isAndroid) androidOutputs(),
      if (Platform.isIOS) bleOutputs(),
      if (outputNotice != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(outputNotice!),
        ),
      if (_androidBackground) ...[
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep streaming with screen off'),
          subtitle: const Text(
            'Keeps NTRIP and receiver streams active in standby. Uses more battery.',
          ),
          value: keepStreaming,
          onChanged: busy ? null : (value) => toggleBackground(value!),
        ),
        if (keepStreaming)
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    try {
                      await BackgroundStreaming.batterySettings();
                    } catch (error) {
                      outputStatus(errorText(error));
                    }
                  },
            child: const Text('Battery settings'),
          ),
      ],
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
                    : () async {
                        await disconnectReceiver();
                        if (mounted)
                          setState(() {
                            bluetoothAddress = null;
                            bluetoothName = null;
                          });
                        unawaited(saveLocalSettings());
                      },
                icon: const Icon(Icons.clear),
              ),
      ),
    ],
  );

  Widget bleOutputs() => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: const Text('Bluetooth LE receiver'),
    children: [
      const Text(
        'Select the UART service defined by your receiver manufacturer. Defaults use Nordic UART Service.',
      ),
      field(bleService, 'BLE service UUID'),
      field(bleWrite, 'Write RTCM characteristic UUID'),
      field(bleRead, 'Receive GGA characteristic UUID'),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Scan for BLE receivers'),
        subtitle: Text(bluetoothName ?? 'No receiver selected'),
        onTap: busy ? null : chooseBluetooth,
        trailing: bluetoothAddress == null
            ? null
            : IconButton(
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
    return Scrollbar(
      controller: frameListScroll,
      thumbVisibility: true,
      child: ListView.builder(
        controller: frameListScroll,
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
                builder: (_) =>
                    FrameView(frames: frames, updates: rtcmRevision),
              ),
            ),
          );
        },
      ),
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
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  RtcmFrame? selectedFrame;
  int? slot;
  bool chart = false, paused = false;
  bool showFields = false;
  RtcmFrame? pausedFrame;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.updates,
    builder: (context, _) => frameDetails(),
  );

  Widget frameDetails() {
    final frame =
        selectedFrame ?? (paused ? pausedFrame : null) ?? widget.frames.first;
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
        child: Scrollbar(
          controller: scroll,
          thumbVisibility: true,
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(16),
            children: [
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Pause decoder updates'),
                subtitle: const Text('Reception and recording continue'),
                value: paused,
                onChanged: (value) => setState(() {
                  paused = value!;
                  pausedFrame = paused ? frame : null;
                }),
              ),
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
                  paused = false;
                  pausedFrame = null;
                  slot = null;
                }),
              ),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Fields')),
                  ButtonSegment(value: false, label: Text('Measurements')),
                ],
                selected: {showFields},
                onSelectionChanged: (v) => setState(() => showFields = v.first),
              ),
              if (showFields || observations.isEmpty) ...[
                Text(
                  'RTCM ${frame.type} · ${frame.payload.length} payload bytes',
                ),
                for (final entry in fields.entries)
                  SelectableText('${entry.key} · ${entry.value}'),
                if (fields.isEmpty)
                  const Text(
                    'Fields are not decoded for this message type. Raw payload is available below.',
                  ),
              ],
              if (warning != null) Text(warning),
              if (!showFields && slots.isNotEmpty) ...[
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
                if (slot != null &&
                    observations.every((row) => row.slot != slot))
                  const Text('Selected satellite is absent from this frame.'),
                if (frame.type % 10 <= 3)
                  const Text('Ranges are modulo 1 ms for MSM1–3.'),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Table')),
                    ButtonSegment(value: true, label: Text('C/N₀ chart')),
                  ],
                  selected: {chart},
                  onSelectionChanged: (value) =>
                      setState(() => chart = value.first),
                ),
                if (chart)
                  CnrChart(
                    rows: observations
                        .where((row) => slot == null || row.slot == slot)
                        .toList(),
                  )
                else
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
      ),
    );
  }
}
