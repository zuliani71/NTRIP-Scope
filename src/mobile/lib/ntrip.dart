import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'config.dart';
import 'gga.dart';

class NtripSession {
  Socket? _socket;
  ConnectionTask<Socket>? _connecting;
  _Input? _input;
  final _cancelled = Completer<void>();
  bool releaseReceiverOnStop = false;
  Timer? _ggaTimer;
  bool _stopped = false;
  bool get stopped => _stopped;
  var _externalReader = GgaReader();
  final void Function(String)? onGgaSource;
  String? _externalGga;
  DateTime? _externalReceived;
  DateTime? _externalSent;
  Rover? _manualRover;
  bool _streaming = false;

  NtripSession({this.onGgaSource});

  void receiveExternal(List<int> bytes) {
    if (_stopped) return;
    for (final sentence in _externalReader.add(bytes)) {
      _externalGga = sentence;
      _externalReceived = DateTime.now();
    }
    _sendExternal();
  }

  void externalDisconnected() {
    _externalReader = GgaReader();
    _externalGga = null;
    _externalReceived = null;
  }

  void _sendExternal() {
    final now = DateTime.now();
    if (!_streaming ||
        _manualRover != null ||
        _stopped ||
        _externalGga == null ||
        _socket == null ||
        (_externalSent != null &&
            now.difference(_externalSent!).inMilliseconds < 1000))
      return;
    final sentence = _externalGga!;
    _externalGga = null;
    if (_externalReceived == null ||
        now.difference(_externalReceived!).inSeconds >= 5)
      return;
    _socket!.add(ascii.encode('$sentence\r\n'));
    _externalSent = now;
    onGgaSource?.call('GGA from receiver → caster');
  }

  void stop({bool releaseReceiver = false}) {
    releaseReceiverOnStop |= releaseReceiver;
    _stopped = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    _close();
  }

  void _close() {
    _streaming = false;
    externalDisconnected();
    _ggaTimer?.cancel();
    _ggaTimer = null;
    _connecting?.cancel();
    _connecting = null;
    final input = _input;
    _input = null;
    if (input != null) unawaited(input.cancel().catchError((Object _) {}));
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
    _manualRover = list ? null : caster.rover;
    const connectTimeout = Duration(seconds: 8);
    var abandoned = false;
    final taskFuture = caster.tls
        ? SecureSocket.startConnect(caster.host, caster.port)
        : Socket.startConnect(caster.host, caster.port);
    final socketFuture = taskFuture.then<Socket>((task) async {
      _connecting = task;
      if (_stopped || abandoned) task.cancel();
      final socket = await task.socket;
      if (_stopped || abandoned) socket.destroy();
      return socket;
    });
    final socket = await Future.any<Socket>([
      socketFuture.timeout(
        connectTimeout,
        onTimeout: () {
          abandoned = true;
          _connecting?.cancel();
          throw TimeoutException('Caster connection timed out');
        },
      ),
      _cancelled.future.then<Socket>(
        (_) => throw const SocketException('NTRIP connection cancelled'),
      ),
    ]);
    _connecting = null;
    if (_stopped) {
      socket.destroy();
      return;
    }
    _socket = socket;
    final input = _Input(socket.timeout(const Duration(seconds: 30)));
    _input = input;
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
      _streaming = !list;
      if (rover != null) {
        onGgaSource?.call('Manual rover GGA → caster');
        void send() {
          if (!_stopped) socket.add(ascii.encode('${rover.gga()}\r\n'));
        }

        send();
        _ggaTimer = Timer.periodic(const Duration(seconds: 10), (_) => send());
      } else if (!list) {
        _sendExternal();
        _ggaTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => _sendExternal(),
        );
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

  Future<void>? _cancelFuture;
  Future<void> cancel() => _cancelFuture ??= _packets.cancel();
}
