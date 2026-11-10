import 'dart:math';

class RtcmDecoder {
  final _buffer = <int>[];
  final counts = <int, int>{};
  final frames = <int, List<RtcmFrame>>{};
  int invalidCrc = 0;

  void add(List<int> bytes) {
    _buffer.addAll(bytes);
    var start = 0;
    while (start < _buffer.length) {
      final preamble = _buffer.indexOf(0xd3, start);
      if (preamble < 0) {
        start = _buffer.length;
        break;
      }
      start = preamble;
      if (_buffer.length - start < 3) break;
      if (_buffer[start + 1] & 0xfc != 0) {
        start++;
        continue;
      }
      final size = ((_buffer[start + 1] & 3) << 8) | _buffer[start + 2];
      final end = start + 3 + size;
      if (_buffer.length < end + 3) break;
      final expected =
          (_buffer[end] << 16) | (_buffer[end + 1] << 8) | _buffer[end + 2];
      if (crc24q(_buffer.getRange(start, end)) != expected) {
        invalidCrc++;
        start++;
        continue;
      }
      if (size >= 2) {
        final frame = RtcmFrame(_buffer.sublist(start + 3, end));
        counts.update(frame.type, (value) => value + 1, ifAbsent: () => 1);
        final recent = frames.putIfAbsent(frame.type, () => []);
        recent.insert(0, frame);
        if (recent.length > 20) recent.removeLast();
      }
      start = end + 3;
    }
    _buffer.removeRange(0, start);
  }

  static int crc24q(Iterable<int> bytes) {
    var crc = 0;
    for (final byte in bytes) {
      crc ^= byte << 16;
      for (var bit = 0; bit < 8; bit++) {
        crc <<= 1;
        if (crc & 0x1000000 != 0) crc ^= 0x1864cfb;
      }
    }
    return crc;
  }
}

class RtcmFrame {
  RtcmFrame(this.payload) : type = (payload[0] << 4) | (payload[1] >> 4);
  final List<int> payload;
  final int type;
  final DateTime timestamp = DateTime.now();

  static const systems = {
    107: 'GPS',
    108: 'GLONASS',
    109: 'Galileo',
    110: 'SBAS',
    111: 'QZSS',
    112: 'BeiDou',
    113: 'NavIC',
  };
  static const names = {
    1005: 'Station antenna coordinates',
    1006: 'Antenna coordinates and height',
    1007: 'Antenna descriptor',
    1008: 'Antenna descriptor and serial',
    1013: 'System parameters',
    1019: 'GPS ephemeris',
    1020: 'GLONASS ephemeris',
    1033: 'Receiver and antenna descriptors',
    1042: 'BeiDou ephemeris',
    1045: 'Galileo F/NAV ephemeris',
    1046: 'Galileo I/NAV ephemeris',
    1230: 'GLONASS code biases',
  };

  bool get isMsm =>
      systems.containsKey(type ~/ 10) && type % 10 >= 1 && type % 10 <= 7;
  String get name => isMsm
      ? '${systems[type ~/ 10]} MSM${type % 10}'
      : names[type] ?? 'RTCM3 message';

  Map<String, String> details() {
    final bits = _Bits(payload)..read(12);
    if (!{1005, 1006, 1007, 1008, 1013, 1033}.contains(type) && !isMsm)
      return {};
    final fields = {'Station': '${bits.read(12)}'};
    if (isMsm) {
      final epoch = bits.read(30);
      fields['Epoch'] = type ~/ 10 == 108
          ? 'Day ${epoch >> 27}, ${epoch & 0x7ffffff} ms'
          : '$epoch ms';
      fields['More messages in epoch'] = bits.read(1) == 1 ? 'Yes' : 'No';
    } else if (type == 1005 || type == 1006) {
      bits.read(10);
      fields['ECEF X (m)'] = (bits.signed(38) / 10000).toStringAsFixed(4);
      bits.read(2);
      fields['ECEF Y (m)'] = (bits.signed(38) / 10000).toStringAsFixed(4);
      bits.read(2);
      fields['ECEF Z (m)'] = (bits.signed(38) / 10000).toStringAsFixed(4);
      if (type == 1006)
        fields['Antenna height (m)'] = (bits.read(16) / 10000).toStringAsFixed(
          4,
        );
    } else if (type == 1013) {
      fields['Modified Julian day'] = '${bits.read(16)}';
      fields['Seconds of day'] = '${bits.read(17)}';
      final count = bits.read(5);
      fields['Leap seconds'] = '${bits.read(8)}';
      for (var index = 0; index < count; index++) {
        final id = bits.read(12);
        final synchronous = bits.read(1) == 1;
        fields['Message $id'] =
            '${bits.read(16) / 10} s${synchronous ? ', synchronous' : ''}';
      }
    } else {
      fields['Antenna descriptor'] = bits.text();
      fields['Antenna setup'] = '${bits.read(8)}';
      if (type != 1007) fields['Antenna serial'] = bits.text();
      if (type == 1033) {
        fields['Receiver type'] = bits.text();
        fields['Receiver firmware'] = bits.text();
        fields['Receiver serial'] = bits.text();
      }
    }
    return fields;
  }

  List<Observation> observations() {
    if (!isMsm) return [];
    final bits = _Bits(payload)..read(73);
    final satellites = bits.mask(64);
    final signals = bits.mask(32);
    final cells = <(int, int)>[];
    for (var sat = 0; sat < satellites.length; sat++) {
      for (final signal in signals) {
        if (bits.read(1) == 1) cells.add((sat, signal));
      }
    }
    final level = type % 10;
    final extended = level >= 6;
    final hasRate = level == 5 || level == 7;
    final count = satellites.length;
    final n = cells.length;
    final whole = level >= 4 ? bits.values(count, 8) : List.filled(count, 0);
    if (hasRate) bits.skip(count * 4);
    final modulo = bits.values(count, 10);
    final roughRate = hasRate
        ? bits.values(count, 14, signed: true)
        : const <int>[];
    final codeWidth = extended ? 20 : 15;
    final phaseWidth = extended ? 24 : 22;
    final code = level != 2
        ? bits.values(n, codeWidth, signed: true)
        : const <int>[];
    final phase = level != 1
        ? bits.values(n, phaseWidth, signed: true)
        : const <int>[];
    if (level != 1) bits.skip(n * (extended ? 11 : 5));
    final cnr = level >= 4 ? bits.values(n, extended ? 10 : 6) : const <int>[];
    final fineRate = hasRate ? bits.values(n, 15, signed: true) : const <int>[];
    const metersPerMs = 299792.458;
    return List.generate(n, (i) {
      final (sat, signal) = cells[i];
      final base = (whole[sat] + modulo[sat] / 1024) * metersPerMs;
      double? range(List<int> values, int width, int power) =>
          whole[sat] == 255 ||
              values.isEmpty ||
              values[i] == -(1 << (width - 1))
          ? null
          : base + values[i] * metersPerMs / (1 << power);
      return Observation(
        satellites[sat],
        _signalCodes[type ~/ 10]?[signal] ?? 'ID $signal',
        range(code, codeWidth, extended ? 29 : 24),
        range(phase, phaseWidth, extended ? 31 : 29),
        cnr.isEmpty || cnr[i] == 0 ? null : cnr[i] / (extended ? 16 : 1),
        !hasRate || roughRate[sat] == -8192 || fineRate[i] == -16384
            ? null
            : roughRate[sat] + fineRate[i] * 0.0001,
      );
    });
  }
}

class Observation {
  const Observation(
    this.slot,
    this.signal,
    this.code,
    this.phase,
    this.cnr,
    this.rate,
  );
  final int slot;
  final String signal;
  final double? code, phase, cnr, rate;
}

class _Bits {
  _Bits(this.bytes);
  final List<int> bytes;
  int _offset = 0;
  void skip(int count) {
    _offset += count;
    if (_offset > bytes.length * 8)
      throw const FormatException('Truncated RTCM payload');
  }

  int read(int width) {
    final start = _offset;
    skip(width);
    var value = 0;
    for (var i = start; i < _offset; i++) {
      value = (value << 1) | ((bytes[i ~/ 8] >> (7 - i % 8)) & 1);
    }
    return value;
  }

  int signed(int width) {
    final value = read(width);
    return value >= 1 << (width - 1) ? value - (1 << width) : value;
  }

  List<int> values(int count, int width, {bool signed = false}) =>
      List.generate(count, (_) => signed ? this.signed(width) : read(width));
  List<int> mask(int count) => [
    for (var i = 1; i <= count; i++)
      if (read(1) == 1) i,
  ];
  String text() => String.fromCharCodes(values(read(8), 8));
}

String hexAscii(List<int> data) => [
  for (var start = 0; start < data.length; start += 16)
    _hexLine(data.sublist(start, min(start + 16, data.length))),
].join('\n');

String _hexLine(List<int> bytes) {
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
  final ascii = String.fromCharCodes(
    bytes.map((byte) => byte >= 32 && byte < 127 ? byte : 46),
  );
  return '${hex.padRight(47)}  |$ascii|';
}

// RTCM signal mask positions, shared with the desktop decoder.
const _signalCodes = {
  107: {
    2: '1C',
    3: '1P',
    4: '1W',
    8: '2C',
    9: '2P',
    10: '2W',
    15: '2S',
    16: '2L',
    17: '2X',
    22: '5I',
    23: '5Q',
    24: '5X',
    30: '1S',
    31: '1L',
    32: '1X',
  },
  108: {2: '1C', 3: '1P', 8: '2C', 9: '2P'},
  109: {
    2: '1C',
    3: '1A',
    4: '1B',
    5: '1X',
    6: '1Z',
    8: '6C',
    9: '6A',
    10: '6B',
    11: '6X',
    12: '6Z',
    14: '7I',
    15: '7Q',
    16: '7X',
    18: '8I',
    19: '8Q',
    20: '8X',
    22: '5I',
    23: '5Q',
    24: '5X',
  },
  110: {2: '1C', 22: '5I', 23: '5Q', 24: '5X'},
  111: {
    2: '1C',
    9: '6S',
    10: '6L',
    11: '6X',
    15: '2S',
    16: '2L',
    17: '2X',
    22: '5I',
    23: '5Q',
    24: '5X',
    30: '1S',
    31: '1L',
    32: '1X',
  },
  112: {
    2: '2I',
    3: '2Q',
    4: '2X',
    8: '6I',
    9: '6Q',
    10: '6X',
    14: '7I',
    15: '7Q',
    16: '7X',
    22: '5D',
    23: '5P',
    24: '5X',
    25: '7D',
    30: '1D',
    31: '1P',
    32: '1X',
  },
  113: {8: '9A', 22: '5A'},
};
