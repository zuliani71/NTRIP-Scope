import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'config.dart';

class NtripSession {
  Socket? _socket;
  Timer? _ggaTimer;
  bool _stopped = false;
  bool get stopped => _stopped;

  void stop() {
    _stopped = true;
    _close();
  }

  void _close() {
    _ggaTimer?.cancel();
    _socket?.destroy();
    _socket = null;
  }

  Future<List<String>> mountpoints(Caster caster) async {
    final table = BytesBuilder();
    await for (final data in stream(caster, list: true)) {
      table.add(data);
      if (table.length > 4000000)
        throw const FormatException('Sourcetable too large');
      // The marker can cross a packet boundary.
      if (latin1.decode(table.toBytes()).contains('ENDSOURCETABLE')) break;
    }
    return (const LineSplitter()
        .convert(utf8.decode(table.takeBytes(), allowMalformed: true))
        .where((line) => line.startsWith('STR;'))
        .map((line) => line.split(';')[1])
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList()
      ..sort());
  }

  Stream<Uint8List> stream(Caster caster, {bool list = false}) async* {
    if (!list && caster.mount.trim().isEmpty)
      throw const FormatException('Choose a mountpoint');
    if (_stopped) return;
    const connectTimeout = Duration(seconds: 8);
    final socket = caster.tls
        ? await SecureSocket.connect(
            caster.host,
            caster.port,
            timeout: connectTimeout,
          )
        : await Socket.connect(
            caster.host,
            caster.port,
            timeout: connectTimeout,
          );
    if (_stopped) {
      socket.destroy();
      return;
    }
    _socket = socket;
    final input = _Input(socket.timeout(const Duration(seconds: 30)));
    try {
      final host = caster.host.contains(':') ? '[${caster.host}]' : caster.host;
      final path = list
          ? ''
          : Uri.encodeComponent(
              caster.mount.trim().replaceFirst(RegExp(r'^/+'), ''),
            );
      final rover = list ? null : caster.rover;
      final headers = [
        'GET /$path HTTP/1.${caster.version == 2 ? 1 : 0}',
        'Host: $host:${caster.port}',
        'User-Agent: NTRIP NTRIP Scope Mobile/0.1',
        'Connection: close',
        if (caster.version == 2) 'Ntrip-Version: Ntrip/2.0',
        if (caster.version == 2 && rover != null) 'Ntrip-GGA: ${rover.gga()}',
        if (caster.username.isNotEmpty || caster.password.isNotEmpty)
          'Authorization: Basic ${base64Encode(utf8.encode('${caster.username}:${caster.password}'))}',
      ];
      socket.add(ascii.encode('${headers.join('\r\n')}\r\n\r\n'));
      final status = (await input.line()).split(RegExp(r' +'));
      if (status.length < 2 || status[1] != '200') {
        throw FormatException('Caster response ${status.take(2).join(' ')}');
      }
      final legacy = status.first == 'ICY';
      final sourcetable = status.first == 'SOURCETABLE';
      if (!(legacy || sourcetable || status.first.startsWith('HTTP/'))) {
        throw const FormatException('Invalid NTRIP response');
      }
      if (!list && sourcetable)
        throw const FormatException('Caster returned a sourcetable');
      final response = <String, String>{};
      if (!legacy) {
        var length = 0;
        while (true) {
          final line = await input.line();
          if (line.isEmpty) break;
          length += line.length + 2;
          if (length > 16384)
            throw const FormatException('NTRIP header too large');
          final colon = line.indexOf(':');
          if (colon > 0)
            response[line.substring(0, colon).toLowerCase()] = line
                .substring(colon + 1)
                .trim();
        }
      }
      if (!list &&
          (response['content-type'] ?? '').toLowerCase().contains(
            'sourcetable',
          )) {
        throw const FormatException('Caster returned a sourcetable');
      }
      if (rover != null) {
        void send() {
          if (!_stopped) socket.add(ascii.encode('${rover.gga()}\r\n'));
        }

        send();
        _ggaTimer = Timer.periodic(const Duration(seconds: 10), (_) => send());
      }

      if ((response['transfer-encoding'] ?? '').toLowerCase().contains(
        'chunked',
      )) {
        while (!_stopped) {
          final size = int.tryParse(
            (await input.line()).split(';').first.trim(),
            radix: 16,
          );
          if (size == null || size < 0 || size > 8 * 1024 * 1024) {
            throw const FormatException('Invalid NTRIP chunk length');
          }
          if (size == 0) break;
          var remaining = size;
          while (remaining > 0 && !_stopped) {
            final part = min(remaining, 65536);
            yield await input.take(part);
            remaining -= part;
          }
          if (_stopped) break;
          final crlf = await input.take(2);
          if (crlf[0] != 13 || crlf[1] != 10)
            throw const FormatException('Invalid NTRIP chunk ending');
        }
      } else if (response.containsKey('content-length')) {
        final length = int.tryParse(response['content-length']!);
        if (length == null || length < 0) {
          throw const FormatException('Invalid NTRIP content length');
        }
        var remaining = length;
        while (remaining > 0 && !_stopped) {
          final part = min(remaining, 65536);
          yield await input.take(part);
          remaining -= part;
        }
      } else {
        while (!_stopped) {
          final part = await input.available();
          if (part == null) break;
          yield part;
        }
      }
    } finally {
      _close();
      await input.cancel();
    }
  }
}

class _Input {
  _Input(Stream<Uint8List> stream) : _packets = StreamIterator(stream);
  final StreamIterator<Uint8List> _packets;
  Uint8List _data = Uint8List(0);
  int _offset = 0;

  Future<bool> _fill() async {
    while (_offset == _data.length) {
      if (!await _packets.moveNext()) return false;
      _data = _packets.current;
      _offset = 0;
    }
    return true;
  }

  Future<String> line() async {
    final bytes = <int>[];
    while (await _fill()) {
      final byte = _data[_offset++];
      if (byte == 10 && bytes.isNotEmpty && bytes.last == 13) {
        return latin1.decode(bytes..removeLast());
      }
      bytes.add(byte);
      if (bytes.length > 16384)
        throw const FormatException('NTRIP line too long');
    }
    throw const FormatException('Incomplete NTRIP response');
  }

  Future<Uint8List> take(int count) async {
    final result = Uint8List(count);
    var offset = 0;
    while (offset < count) {
      if (!await _fill()) throw const FormatException('Incomplete NTRIP chunk');
      final length = min(count - offset, _data.length - _offset);
      result.setRange(offset, offset + length, _data, _offset);
      _offset += length;
      offset += length;
    }
    return result;
  }

  Future<Uint8List?> available() async {
    if (!await _fill()) return null;
    final result = Uint8List.sublistView(_data, _offset);
    _offset = _data.length;
    return result;
  }

  Future<void> cancel() => _packets.cancel();
}
