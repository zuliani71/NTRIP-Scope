import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/config.dart';
import 'package:ntripscope_mobile/gga.dart';
import 'package:ntripscope_mobile/ntrip.dart';
import 'package:ntripscope_mobile/rtcm.dart';

void main() {
  test(
    'fragmented NMEA input accepts valid fixes and rejects corrupt data',
    () {
      final sentence = Rover(46.125, 13.333333, 100, 0).gga();
      final input = GgaReader();
      expect(input.add(List.filled(4096, 255)), isEmpty);
      expect(input.add(ascii.encode(sentence.substring(0, 24))), isEmpty);
      expect(input.add(ascii.encode('${sentence.substring(24)}\r\n')), [
        sentence,
      ]);
      expect(
        validGga('${sentence.substring(0, sentence.length - 2)}ZZ'),
        isFalse,
      );
    },
  );

  for (final manual in [false, true]) {
    test('reverse GGA flow with manual priority $manual', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final upstream = Completer<String>();
      final rover = Rover(46.125, 13.333333, 100, 0);
      final external = Rover(45.5, 12.5, 21, 0).gga();
      final session = NtripSession();
      addTearDown(session.stop);
      final worker = server.listen((socket) {
        var headers = false;
        var pending = '';
        socket.listen((bytes) {
          pending += ascii.decode(bytes);
          if (!headers) {
            final end = pending.indexOf('\r\n\r\n');
            if (end < 0) return;
            pending = pending.substring(end + 4);
            headers = true;
            socket.write('ICY 200 OK\r\n');
            session.receiveExternal(ascii.encode(external.substring(0, 23)));
            session.receiveExternal(
              ascii.encode('${external.substring(23)}\r\n'),
            );
          }
          if (pending.contains('\r\n') && !upstream.isCompleted) {
            upstream.complete(pending.split('\r\n').first);
            socket.add([0xd3, 0, 0xff, 0]);
            socket.close();
          }
        });
      });
      addTearDown(worker.cancel);
      final bytes = await session
          .stream(
            Caster(
              host: '127.0.0.1',
              port: server.port,
              mount: 'VRS',
              version: 1,
              rover: manual ? rover : null,
            ),
          )
          .expand((data) => data)
          .toList()
          .timeout(const Duration(seconds: 5));
      final sent = await upstream.future;
      expect(bytes, [0xd3, 0, 0xff, 0]);
      expect(sent, manual ? startsWith(r'$GPGGA,') : external);
      if (manual) expect(sent, contains(',4607.500000,N,01319.999980,E,'));
    });
  }

  test('shared CLI INI and GGA with signed coordinates and geoid', () {
    final ini = File('assets/ntripscope-vrs.example.ini').readAsStringSync();
    final config = Caster.fromIni(ini);
    final saved = config.toIni();
    final restored = Caster.fromIni(saved);
    expect(restored.mount, config.mount);
    expect(restored.desktopOutputs, config.desktopOutputs);
    expect(restored.rover?.longitude, config.rover?.longitude);
    expect(
      Caster(host: 'example.org', password: 'secret').toIni(),
      isNot(contains('secret')),
    );
    expect(config.mount, 'VRS');
    expect(config.rover?.latitude, 46.125);
    expect(config.rover?.height, 100);
    final sentence = Rover(
      -46.125,
      13.333333,
      100,
      12,
    ).gga(DateTime.utc(2026, 1, 1, 12, 34, 56));
    expect(
      sentence,
      startsWith(
        r'$GPGGA,123456.00,4607.500000,S,01319.999980,E,1,00,1.0,88.000,M,12.000,M,,*',
      ),
    );
    final (body, checksum) = (
      sentence.substring(1, sentence.length - 3),
      sentence.substring(sentence.length - 2),
    );
    expect(
      int.parse(checksum, radix: 16),
      body.codeUnits.fold(0, (value, byte) => value ^ byte),
    );
    expect(
      () => Caster.fromIni('[caster]\nhost=x\n[rover]\nlatitude=45'),
      throwsFormatException,
    );
  });

  test('CRC, fragmented RTCM 1006 and GPS MSM4 measurement', () {
    final antenna = frame([
      (1006, 12),
      (17, 12),
      (0, 10),
      (123456, 38),
      (0, 2),
      (-234567, 38),
      (0, 2),
      (345678, 38),
      (1234, 16),
    ]);
    final msm = frame([
      (1074, 12),
      (17, 12),
      (1234, 30),
      (0, 19),
      for (var i = 1; i <= 64; i++) (i == 6 ? 1 : 0, 1),
      for (var i = 1; i <= 32; i++) (i == 2 ? 1 : 0, 1),
      (1, 1),
      (80, 8),
      (512, 10),
      (0, 15),
      (0, 22),
      (0, 5),
      (42, 6),
    ]);
    final decoder = RtcmDecoder();
    decoder.add([0, 0xd3, 0xff, ...antenna.take(9)]);
    decoder.add(antenna.skip(9).toList());
    decoder.add([...msm.take(msm.length - 1), msm.last ^ 0xff, ...msm]);
    expect(decoder.invalidCrc, 1);
    expect(decoder.counts, {1006: 1, 1074: 1});
    final fields = decoder.frames[1006]!.first.details();
    expect(fields['ECEF Y (m)'], '-23.4567');
    expect(fields['Antenna height (m)'], '0.1234');
    final observation = decoder.frames[1074]!.first.observations().single;
    expect(observation.slot, 6);
    expect(observation.signal, '1C');
    expect(observation.cnr, 42);
    expect(observation.code, closeTo(80.5 * 299792.458, 0.001));
  });

  test(
    'NTRIP 2 request, authentication and fragmented chunked sourcetable',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final request = <int>[];
      final handler = server.listen((socket) {
        socket.listen((data) {
          request.addAll(data);
          if (!latin1.decode(request).contains('\r\n\r\n')) return;
          socket.write('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n');
          for (final block in ['STR;B\r\nSTR;A\r\nEND', 'SOURCETABLE\r\n']) {
            socket.write('${block.length.toRadixString(16)}\r\n$block\r\n');
          }
          socket.write('0\r\n\r\n');
          socket.close();
        });
      });
      addTearDown(handler.cancel);
      final config = Caster(
        host: '127.0.0.1',
        port: server.port,
        username: 'user',
        password: 'pass',
      );
      expect(await NtripSession().mountpoints(config), ['A', 'B']);
      expect(
        latin1.decode(request),
        contains('Authorization: Basic dXNlcjpwYXNz'),
      );
      expect(latin1.decode(request), contains('Ntrip-Version: Ntrip/2.0'));
    },
  );

  test('Legacy ICY stream preserves bytes and sends GGA', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final request = <int>[];
    var accepted = false;
    final handler = server.listen((socket) {
      socket.listen((data) {
        request.addAll(data);
        final text = latin1.decode(request);
        if (!accepted && text.contains('\r\n\r\n')) {
          accepted = true;
          socket.write('ICY 200 OK\r\n');
        }
        if (text.contains(r'$GPGGA,')) {
          socket.add([0xd3, 0, 0, 255]);
          socket.close();
        }
      });
    });
    addTearDown(handler.cancel);
    final config = Caster(
      host: '127.0.0.1',
      port: server.port,
      mount: 'VRS',
      version: 1,
      rover: Rover(46, 13, 100, 0),
    );
    final data = await NtripSession()
        .stream(config)
        .expand((block) => block)
        .toList();
    expect(data, [0xd3, 0, 0, 255]);
    expect(latin1.decode(request), startsWith('GET /VRS HTTP/1.0'));
    expect(latin1.decode(request), contains(r'$GPGGA,'));
  });
}

List<int> frame(List<(int, int)> fields) {
  final bits = <int>[
    for (final (value, width) in fields)
      for (var bit = width - 1; bit >= 0; bit--) (value >> bit) & 1,
  ];
  while (bits.length % 8 != 0) {
    bits.add(0);
  }
  final payload = [
    for (var offset = 0; offset < bits.length; offset += 8)
      bits
          .getRange(offset, offset + 8)
          .fold(0, (value, bit) => (value << 1) | bit),
  ];
  final message = [0xd3, payload.length >> 8, payload.length & 255, ...payload];
  final crc = RtcmDecoder.crc24q(message);
  return [...message, crc >> 16, (crc >> 8) & 255, crc & 255];
}
