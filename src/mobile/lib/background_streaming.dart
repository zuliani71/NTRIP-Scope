import 'dart:async';
import 'package:flutter/services.dart';

/// One foreground-service lease per NTRIP session. Stop also covers pending start.
class BackgroundStreaming {
  static const channel = MethodChannel('ntripscope/background');
  Future<void>? _start;
  Future<void>? _stop;
  bool _closed = false;
  bool ready = false;
  static Future<Map<Object?, Object?>> prepare() async =>
      await channel.invokeMapMethod<Object?, Object?>('prepare') ?? {};
  static Future<void> batterySettings() =>
      channel.invokeMethod<void>('batterySettings');
  Future<void> start(String mountpoint) => _start ??= _begin(mountpoint);
  Future<void> _begin(String mountpoint) async {
    if (_closed) return;
    await channel
        .invokeMethod<void>('start', {'mountpoint': mountpoint})
        .timeout(const Duration(seconds: 8));
    ready = !_closed;
  }

  Future<void> stop() {
    _closed = true;
    ready = false;
    return _stop ??= _finish();
  }

  Future<void> _finish() async {
    if (_start == null) return;
    try {
      await _start;
    } catch (_) {
      /* Stop still releases a failed start. */
    }
    await channel
        .invokeMethod<void>('stop')
        .timeout(const Duration(seconds: 5));
  }
}
