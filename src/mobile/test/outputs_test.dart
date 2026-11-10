import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/outputs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sends identical RTCM bytes to file, TCP and Bluetooth', () async {
    final calls = <String, Object?>{};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(StreamOutputs.channel, (call) async {
      calls[call.method] = call.arguments;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(StreamOutputs.channel, null),
    );
    final outputs = StreamOutputs((message) => fail(message));
    addTearDown(outputs.close);
    await outputs.open(
      file: 'content://test/corrections',
      port: 0,
      bluetooth: '00:00:00:00:00:00',
    );
    final peer = await Socket.connect(
      InternetAddress.loopbackIPv4,
      outputs.tcpPort!,
    );
    addTearDown(peer.destroy);
    final received = peer.first;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final bytes = Uint8List.fromList([0xd3, 0, 2, 0xff, 0, 13, 10, 0]);
    await outputs.write(bytes);
    expect(await received.timeout(const Duration(seconds: 2)), bytes);
    expect(calls['writeFile'], bytes);
    expect(calls['writeBluetooth'], bytes);
    await outputs.close();
    expect(calls.keys, containsAll(['closeFile', 'closeBluetooth']));
  });
}
