import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class StreamOutputs {
  static const channel = MethodChannel('ntripscope/outputs');
  static const bluetoothEvents = EventChannel('ntripscope/bluetooth');
  StreamSubscription<dynamic>? _bluetoothInput;
  final void Function(List<int>)? onReceiverData;
  final void Function(String, List<int>)? onMonitorData;
  final void Function()? onReceiverDisconnected;
  ServerSocket? _server;
  StreamSubscription<Socket>? _listener;
  Socket? _receiver;
  bool _file = false;
  bool _bluetooth = false;
  bool _closed = false;
  final _cancelled = Completer<void>();
  Future<void>? _closeFuture;
  Future<void>? _bluetoothCloseFuture;
  final void Function(String) onError;

  StreamOutputs(
    this.onError, {
    this.onReceiverData,
    this.onMonitorData,
    this.onReceiverDisconnected,
  });

  int? get tcpPort => _server?.port;
  Future<T> _untilClosed<T>(Future<T> future) => Future.any<T>([
    future,
    _cancelled.future.then<T>((_) => throw StateError('Stream outputs closed')),
  ]);

  Future<void> open({
    String? file,
    int? port,
    bool network = false,
    String? bluetooth,
    Map<String, String>? bleProfile,
  }) async {
    if (port != null) {
      final server = await ServerSocket.bind(
        network ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
        port,
      );
      if (_closed) {
        await server.close();
        return;
      }
      _server = server;
      _listener = server.listen((socket) {
        if (_receiver != null) {
          socket.destroy();
          return;
        }
        _receiver = socket;
        socket.done.then<void>(
          (_) => _drop(socket),
          onError: (_) => _drop(socket),
        );
        socket.listen(
          (data) {
            if (!_closed && identical(_receiver, socket)) {
              onMonitorData?.call("TCP · ${_server?.port}", data);
            }
          },
          onDone: () => _drop(socket),
          onError: (_) => _drop(socket),
        );
      });
    }
    if (bluetooth != null) {
      if (Platform.isAndroid) {
        // Request Nearby devices access again if Android revoked it while idle.
        await _untilClosed(channel.invokeListMethod<dynamic>('pairedDevices'));
        if (_closed) return;
      }
      _bluetoothInput = bluetoothEvents.receiveBroadcastStream().listen(
        (event) {
          if (_closed) return;
          if (event is Uint8List) {
            onMonitorData?.call(
              Platform.isIOS ? "Bluetooth LE" : "Bluetooth SPP",
              event,
            );
            onReceiverData?.call(event);
          } else if (event is Map && event['disconnected'] == true) {
            _bluetooth = false;
            onReceiverDisconnected?.call();
            onError('Bluetooth receiver disconnected');
          }
        },
        onError: (Object error) {
          onReceiverDisconnected?.call();
          onError('Bluetooth input · $error');
        },
      );
      _bluetooth = true;
      try {
        await _untilClosed(
          channel
              .invokeMethod<void>(
                bleProfile == null ? 'openBluetooth' : 'openBle',
                {'address': bluetooth, ...?bleProfile},
              )
              .timeout(const Duration(seconds: 12)),
        );
      } catch (_) {
        await channel
            .invokeMethod<void>(Platform.isIOS ? 'closeBle' : 'closeBluetooth')
            .timeout(const Duration(seconds: 10));
        _bluetooth = false;
        rethrow;
      }
    }
    if (_closed) {
      if (bluetooth != null)
        await channel
            .invokeMethod<void>(Platform.isIOS ? 'closeBle' : 'closeBluetooth')
            .timeout(const Duration(seconds: 10));
      return;
    }
    if (file != null) {
      _file = true;
      await _untilClosed(
        channel
            .invokeMethod<void>('openFile', {'uri': file})
            .timeout(const Duration(seconds: 8)),
      );
    }
  }

  void _drop(Socket socket) {
    if (identical(_receiver, socket)) _receiver = null;
    socket.destroy();
  }

  Future<void> write(Uint8List bytes) async {
    if (_closed) return;
    if (_file) {
      try {
        await _untilClosed(
          channel
              .invokeMethod<void>('writeFile', bytes)
              .timeout(const Duration(seconds: 3)),
        );
      } catch (error) {
        if (_closed) return;
        _file = false;
        try {
          await channel
              .invokeMethod<void>('closeFile')
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          // The original write error is the useful failure to report.
        }
        onError('File · ${error is PlatformException ? error.message : error}');
      }
    }
    if (_closed) return;
    final receiver = _receiver;
    if (receiver != null) {
      try {
        receiver.add(bytes);
        await receiver.flush().timeout(const Duration(seconds: 2));
      } catch (_) {
        _drop(receiver);
        onError('TCP receiver disconnected');
      }
    }
    if (_closed) return;
    if (_bluetooth) {
      try {
        await _untilClosed(
          channel
              .invokeMethod<void>(
                Platform.isIOS ? 'writeBle' : 'writeBluetooth',
                bytes,
              )
              .timeout(const Duration(seconds: 3)),
        );
      } catch (error) {
        if (_closed) return;
        _bluetooth = false;
        onReceiverDisconnected?.call();
        await channel
            .invokeMethod<void>(Platform.isIOS ? 'closeBle' : 'closeBluetooth')
            .timeout(const Duration(seconds: 10));
        onError(
          'Bluetooth · ${error is PlatformException ? error.message : error}',
        );
      }
    }
  }

  Future<void> close({bool keepBluetooth = false}) {
    _closed = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    // All callers await the same cleanup. A foreground Stop can later be
    // upgraded to a full release when the phone locks or the app is hidden.
    if (!keepBluetooth && _bluetoothInput != null) {
      _bluetoothCloseFuture ??= channel
          .invokeMethod<void>(Platform.isIOS ? 'closeBle' : 'closeBluetooth')
          .timeout(const Duration(seconds: 10));
    }
    _closeFuture ??= _closeResources();
    return Future.wait<void>([
      _closeFuture!,
      if (_bluetoothCloseFuture != null) _bluetoothCloseFuture!,
    ]).then((_) {});
  }

  Future<void> _closeResources() async {
    final receiver = _receiver;
    if (receiver != null) _drop(receiver);
    await Future.wait([
      if (_server != null) _server!.close(),
      if (_listener != null) _listener!.cancel(),
      if (_bluetoothInput != null) _bluetoothInput!.cancel(),
      if (_file)
        channel
            .invokeMethod<void>('closeFile')
            .timeout(const Duration(seconds: 10)),
    ]);
  }
}
