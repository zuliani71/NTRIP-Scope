import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ExistingConfiguration {
  const ExistingConfiguration(this.uri, this.name, {this.writable = true});
  final String uri, name;
  final bool writable;
}

abstract class ConfigurationStorage {
  Future<ExistingConfiguration?> chooseExisting();
  Future<bool> create(String name, Uint8List bytes);
  Future<void> replace(ExistingConfiguration file, Uint8List bytes);
}

class AndroidConfigurationStorage implements ConfigurationStorage {
  static const channel = MethodChannel('ntripscope/configuration');
  @override
  Future<ExistingConfiguration?> chooseExisting() async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'chooseExisting',
    );
    if (result == null) return null;
    return ExistingConfiguration(
      result['uri'] as String,
      result['name'] as String,
      writable: result['writable'] == true,
    );
  }

  @override
  Future<bool> create(String name, Uint8List bytes) async =>
      await FilePicker.platform.saveFile(fileName: name, bytes: bytes) != null;
  @override
  Future<void> replace(ExistingConfiguration file, Uint8List bytes) =>
      channel.invokeMethod<void>('replace', {
        'uri': file.uri,
        'name': file.name,
        'confirmedOverwrite': true,
        'bytes': bytes,
      });
}

class _SaveRequest {
  _SaveRequest(this.name, this.existing);
  final String name;
  final ExistingConfiguration? existing;
}

Future<String?> saveConfigurationFile(
  BuildContext context,
  Uint8List bytes, {
  String initialName = 'ntripscope.ini',
  ConfigurationStorage? storage,
}) async {
  final target = storage ?? AndroidConfigurationStorage();
  final request = await showDialog<_SaveRequest>(
    context: context,
    builder: (_) =>
        _ConfigurationNameDialog(initialName: initialName, storage: target),
  );
  if (request == null) return null;
  if (request.existing case final file?) {
    await target.replace(file, bytes);
  } else if (!await target.create(request.name, bytes)) {
    return null;
  }
  return request.name;
}

class _ConfigurationNameDialog extends StatefulWidget {
  const _ConfigurationNameDialog({
    required this.initialName,
    required this.storage,
  });
  final String initialName;
  final ConfigurationStorage storage;
  @override
  State<_ConfigurationNameDialog> createState() =>
      _ConfigurationNameDialogState();
}

class _ConfigurationNameDialogState extends State<_ConfigurationNameDialog> {
  late final name = TextEditingController(text: widget.initialName);
  ExistingConfiguration? selected;
  bool choosing = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  bool get replacing => selected != null && name.text.trim() == selected!.name;
  bool get valid =>
      name.text.trim().isNotEmpty &&
      !RegExp(r'[/\\\x00-\x1f]').hasMatch(name.text) &&
      !['.', '..'].contains(name.text.trim());
  Future<void> choose() async {
    setState(() {
      choosing = true;
      error = null;
    });
    try {
      final file = await widget.storage.chooseExisting();
      if (mounted && file != null)
        setState(() {
          selected = file;
          name.text = file.name;
        });
    } catch (e) {
      if (mounted) setState(() => error = 'Cannot select file: $e');
    } finally {
      if (mounted) setState(() => choosing = false);
    }
  }

  Future<void> save() async {
    if (!valid) return;
    if (replacing) {
      if (!selected!.writable) {
        setState(
          () => error =
              'This file is read-only. Change its name to save a new copy.',
        );
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace existing configuration?'),
          content: Text(
            '“${selected!.name}” will be overwritten with the current configuration. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    if (mounted)
      Navigator.pop(
        context,
        _SaveRequest(name.text.trim(), replacing ? selected : null),
      );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save configuration'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'File name'),
            onChanged: (_) => setState(() => error = null),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: choosing ? null : choose,
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose existing file'),
          ),
          const SizedBox(height: 8),
          if (choosing) const LinearProgressIndicator(),
          Text(
            selected == null
                ? 'Choose a name for a new file, or select an existing configuration.'
                : replacing
                ? 'The selected file will be replaced after confirmation.'
                : 'The selected file is kept. A new file will be saved with this name.',
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: choosing ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: choosing || !valid ? null : save,
        child: Text(replacing ? 'Save changes' : 'Save as'),
      ),
    ],
  );
}
