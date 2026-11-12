import 'dart:convert';

/// Bounded NMEA framing. Only checksum-verified GGA positions are forwarded.
class GgaReader {
  GgaReader({this.includeNoFix = false});
  final bool includeNoFix;
  final _buffer = <int>[];

  List<String> add(List<int> data) {
    final result = <String>[];
    for (final byte in data) {
      if (byte == 36) {
        _buffer.clear();
        _buffer.add(byte);
      } else if (byte == 10 || byte == 13) {
        if (_buffer.isNotEmpty) {
          final sentence = ascii.decode(_buffer);
          if (includeNoFix ? ggaQuality(sentence) != null : validGga(sentence))
            result.add(sentence);
        }
        _buffer.clear();
      } else if (_buffer.isNotEmpty) {
        if (byte >= 32 && byte <= 126 && _buffer.length < 256) {
          _buffer.add(byte);
        } else {
          _buffer.clear();
        }
      }
    }
    return result;
  }
}

bool validGga(String sentence) {
  if (sentence.length > 256 ||
      !RegExp(
        r'^\$[A-Z0-9]{2}GGA,[ -~]+\*[0-9A-Fa-f]{2}$',
      ).hasMatch(sentence)) {
    return false;
  }
  final body = sentence.substring(1, sentence.length - 3);
  final checksum = int.tryParse(
    sentence.substring(sentence.length - 2),
    radix: 16,
  );
  if (body.codeUnits.fold(0, (value, byte) => value ^ byte) != checksum)
    return false;
  final fields = body.split(',');
  final fix = fields.length > 6 ? int.tryParse(fields[6]) : null;
  if (fields.length < 15 || fix == null || fix < 1 || fix > 8) return false;
  for (final (raw, hemisphere, width, limit) in [
    (fields[2], fields[3], 2, 90),
    (fields[4], fields[5], 3, 180),
  ]) {
    if (!(width == 2 ? ['N', 'S'] : ['E', 'W']).contains(hemisphere) ||
        !RegExp(r'^[0-9]+(\.[0-9]+)?$').hasMatch(raw) ||
        raw.split('.').first.length != width + 2)
      return false;
    final degrees = int.tryParse(raw.substring(0, width));
    final minutes = double.tryParse(raw.substring(width));
    if (degrees == null ||
        minutes == null ||
        !minutes.isFinite ||
        minutes < 0 ||
        minutes >= 60 ||
        degrees + minutes / 60 > limit)
      return false;
  }
  for (final index in [9, 11]) {
    if (fields[index].isNotEmpty &&
        double.tryParse(fields[index])?.isFinite != true)
      return false;
  }
  return true;
}

int? ggaQuality(String sentence) {
  if (sentence.length > 256 ||
      !RegExp(r'^\$[A-Z0-9]{2}GGA,[ -~]+\*[0-9A-Fa-f]{2}$').hasMatch(sentence))
    return null;
  final body = sentence.substring(1, sentence.length - 3);
  if (body.codeUnits.fold(0, (value, byte) => value ^ byte) !=
      int.tryParse(sentence.substring(sentence.length - 2), radix: 16))
    return null;
  final fields = body.split(',');
  if (fields.length < 15 || !RegExp(r'^[0-8]$').hasMatch(fields[6]))
    return null;
  final quality = int.parse(fields[6]);
  return quality == 0 || validGga(sentence) ? quality : null;
}
