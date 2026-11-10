import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class StreamOutputs {
  static const channel = MethodChannel('ntripscope/outputs');
  ServerSocket? _server;
  StreamSubscription<Socket>? _listener;
  Socket? _receiver;
  bool _file = false;
  bool _bluetooth = false;
  bool _closed = false;
  final void Function(String) onError;

  StreamOutputs(this.onError);

  int? get tcpPort => _server?.port;

  Future<void> open({
    String? file,
    int? port,
    bool network = false,
    String? bluetooth,
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
          (_) {},
          onDone: () => _drop(socket),
          onError: (_) => _drop(socket),
        );
      });
    }
    if (bluetooth != null) {
      _bluetooth = true;
      try {
        await channel
            .invokeMethod<void>('openBluetooth', {'address': bluetooth})
            .timeout(const Duration(seconds: 12));
      } catch (_) {
        await channel.invokeMethod<void>('closeBluetooth');
        _bluetooth = false;
        rethrow;
      }
    }
    if (_closed) return;
    if (file != null) {
      await channel.invokeMethod<void>('openFile', {'uri': file});
      if (_closed) {
        await channel.invokeMethod<void>('closeFile');
        return;
      }
      _file = true;
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
        await channel.invokeMethod<void>('writeFile', bytes);
      } on PlatformException catch (error) {
        _file = false;
        try {
          await channel.invokeMethod<void>('closeFile');
        } on PlatformException {
          // The original write error is the useful failure to report.
        }
        onError('File · ${error.message}');
      }
    }
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
    if (_bluetooth) {
      try {
        await channel
            .invokeMethod<void>('writeBluetooth', bytes)
            .timeout(const Duration(seconds: 3));
      } catch (error) {
        _bluetooth = false;
        await channel.invokeMethod<void>('closeBluetooth');
        onError(
          'Bluetooth · ${error is PlatformException ? error.message : error}',
        );
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final receiver = _receiver;
    if (receiver != null) _drop(receiver);
    await Future.wait([
      if (_server != null) _server!.close(),
      if (_listener != null) _listener!.cancel(),
      if (_bluetooth) channel.invokeMethod<void>('closeBluetooth'),
      if (_file) channel.invokeMethod<void>('closeFile'),
    ]);
  }
}
