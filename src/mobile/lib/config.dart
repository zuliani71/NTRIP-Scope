class Rover {
  Rover(this.latitude, this.longitude, this.height, this.geoid) {
    if (!(latitude.abs() <= 90 &&
        longitude.abs() <= 180 &&
        height.abs() < 100000 &&
        geoid.abs() < 100000)) {
      throw const FormatException('Invalid rover coordinates or height');
    }
  }

  final double latitude, longitude, height, geoid;

  String gga([DateTime? time]) {
    final utc = (time ?? DateTime.now()).toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    String angle(double value, int digits) {
      final units = (value.abs() * 60000000).round();
      final degrees = (units ~/ 60000000).toString().padLeft(digits, '0');
      final minutes = two(units ~/ 1000000 % 60);
      final fraction = (units % 1000000).toString().padLeft(6, '0');
      return '$degrees$minutes.$fraction';
    }

    final clock = '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}.00';
    final ns = latitude < 0 ? 'S' : 'N';
    final ew = longitude < 0 ? 'W' : 'E';
    final altitude = (height - geoid).toStringAsFixed(3);
    final body =
        'GPGGA,$clock,${angle(latitude, 2)},$ns,'
        '${angle(longitude, 3)},$ew,1,00,1.0,$altitude,M,'
        '${geoid.toStringAsFixed(3)},M,,';
    final checksum = body.codeUnits.fold(0, (sum, byte) => sum ^ byte);
    return '\$$body*${checksum.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  }
}

class Caster {
  Caster({
    required String host,
    this.port = 2101,
    this.mount = '',
    this.username = '',
    this.password = '',
    this.version = 2,
    this.tls = false,
    this.rover,
    this.desktopOutputs = const {},
  }) : host = host.startsWith('[') && host.endsWith(']')
           ? host.substring(1, host.length - 1)
           : host {
    if (this.host.isEmpty ||
        RegExp(r'[\s/?#\[\]]').hasMatch(this.host) ||
        port < 1 ||
        port > 65535 ||
        (version != 1 && version != 2)) {
      throw const FormatException('Invalid caster, port or NTRIP version');
    }
  }

  final String host, mount, username, password;
  final int port, version;
  final bool tls;
  final Rover? rover;
  final Map<String, String> desktopOutputs;

  String toIni() {
    final lines = [
      '[caster]',
      'host = $host',
      'port = $port',
      'mountpoint = $mount',
      'username = $username',
      'version = $version',
      'tls = $tls',
    ];
    if ([
      host,
      mount,
      username,
    ].any((value) => value.contains(RegExp(r'[\r\n]')))) {
      throw const FormatException('INI values must fit on one line');
    }
    final position = rover;
    if (position != null) {
      lines.addAll([
        '',
        '[rover]',
        'latitude = ${position.latitude.toStringAsFixed(6)}',
        'longitude = ${position.longitude.toStringAsFixed(6)}',
        'height = ${position.height.toStringAsFixed(3)}',
        'geoid = ${position.geoid.toStringAsFixed(3)}',
      ]);
    }
    if (desktopOutputs.isNotEmpty) {
      lines.addAll(['', '[outputs]']);
      for (final entry in desktopOutputs.entries) {
        final values = entry.value.split('\n');
        lines.add('${entry.key} = ${values.first}');
        lines.addAll(values.skip(1).map((value) => '    $value'));
      }
    }
    return '${lines.join('\n')}\n';
  }

  factory Caster.fromIni(String ini) {
    final schema = {
      'caster': {
        'host',
        'port',
        'mountpoint',
        'username',
        'password',
        'version',
        'tls',
        'list',
      },
      'rover': {'latitude', 'longitude', 'height', 'geoid'},
      'outputs': {'stdout', 'file', 'tcp', 'serial'},
    };
    final fields = <String, String>{};
    var section = '';
    String? previous;
    var previousIndent = 0;
    for (final raw
        in ini.replaceFirst(RegExp(r'^\uFEFF'), '').split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';'))
        continue;
      final indent = raw.length - raw.trimLeft().length;
      if (previous != null && indent > previousIndent) {
        fields[previous] = '${fields[previous]}\n$line';
        continue;
      }
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1);
        if (!schema.containsKey(section))
          throw FormatException('Unknown INI section $section');
        previous = null;
        continue;
      }
      final delimiter = line.indexOf(RegExp(r'[=:]'));
      if (delimiter <= 0) throw const FormatException('Invalid INI setting');
      final key = line.substring(0, delimiter).trim().toLowerCase();
      final field = '$section.$key';
      if (schema[section]?.contains(key) != true || fields.containsKey(field)) {
        throw FormatException('Unknown or repeated setting $field');
      }
      fields[field] = line.substring(delimiter + 1).trim();
      previous = field;
      previousIndent = indent;
    }
    String value(String key, [String fallback = '']) => fields[key] ?? fallback;
    final tls = switch (value('caster.tls', 'false').toLowerCase()) {
      'true' || 'yes' || 'on' || '1' => true,
      'false' || 'no' || 'off' || '0' => false,
      _ => throw const FormatException('Invalid TLS setting'),
    };
    final hasRover = fields.keys.any((key) => key.startsWith('rover.'));
    return Caster(
      host: value('caster.host'),
      port: int.parse(value('caster.port', '2101')),
      mount: value('caster.mountpoint'),
      username: value('caster.username'),
      password: value('caster.password'),
      version: int.parse(value('caster.version', '2')),
      tls: tls,
      desktopOutputs: {
        for (final entry in fields.entries)
          if (entry.key.startsWith('outputs.'))
            entry.key.substring(8): entry.value,
      },
      rover: hasRover
          ? Rover(
              double.parse(value('rover.latitude')),
              double.parse(value('rover.longitude')),
              double.parse(value('rover.height', '0')),
              double.parse(value('rover.geoid', '0')),
            )
          : null,
    );
  }
}
