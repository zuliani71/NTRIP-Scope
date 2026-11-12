import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/configuration_save.dart';

class Store implements ConfigurationStorage {
  ExistingConfiguration? existing = const ExistingConfiguration(
    'content://config/original',
    'rover.ini',
  );
  final writes = <String>[];
  @override
  Future<ExistingConfiguration?> chooseExisting() async => existing;
  @override
  Future<bool> create(String name, Uint8List bytes) async {
    writes.add('new:$name:${String.fromCharCodes(bytes)}');
    return true;
  }

  @override
  Future<void> replace(ExistingConfiguration file, Uint8List bytes) async {
    writes.add('replace:${file.uri}:${String.fromCharCodes(bytes)}');
  }
}

void main() {
  Future<void> launch(
    WidgetTester tester,
    Store store, {
    String name = 'ntripscope.ini',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => saveConfigurationFile(
                context,
                Uint8List.fromList('config'.codeUnits),
                initialName: name,
                storage: store,
              ),
              child: const Text('Export'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'existing file is unchanged until explicit overwrite confirmation',
    (tester) async {
      final store = Store();
      await launch(tester, store);
      await tester.tap(find.text('Choose existing file'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'rover.ini',
      );
      expect(store.writes, isEmpty);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(find.text('Replace existing configuration?'), findsOneWidget);
      expect(store.writes, isEmpty);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(store.writes, isEmpty);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();
      expect(store.writes, ['replace:content://config/original:config']);
    },
  );
  testWidgets('existing name can be recalled and edited to save a new copy', (
    tester,
  ) async {
    final store = Store();
    await launch(tester, store);
    await tester.tap(find.text('Choose existing file'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'rover-new.ini');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save as'));
    await tester.pumpAndSettle();
    expect(store.writes, ['new:rover-new.ini:config']);
    expect(find.text('Replace existing configuration?'), findsNothing);
  });
  testWidgets('cancel and invalid name leave storage untouched', (
    tester,
  ) async {
    final store = Store();
    await launch(tester, store, name: 'previous.ini');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'previous.ini',
    );
    await tester.enterText(find.byType(TextField), 'folder/file.ini');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save as'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.writes, isEmpty);
  });
  testWidgets(
    'read-only selection can supply a name but cannot be overwritten',
    (tester) async {
      final store = Store()
        ..existing = const ExistingConfiguration(
          'content://config/readonly',
          'read.ini',
          writable: false,
        );
      await launch(tester, store);
      await tester.tap(find.text('Choose existing file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('read-only'), findsOneWidget);
      expect(store.writes, isEmpty);
      await tester.enterText(find.byType(TextField), 'read-copy.ini');
    await tester.pumpAndSettle();
      await tester.tap(find.text('Save as'));
      await tester.pumpAndSettle();
      expect(store.writes, ['new:read-copy.ini:config']);
    },
  );
}
