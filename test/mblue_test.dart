import 'package:flutter_test/flutter_test.dart';
import 'package:mblue/mblue.dart';
import 'package:mblue/mblue_platform_interface.dart';
import 'package:mblue/mblue_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockMbluePlatform
    with MockPlatformInterfaceMixin
    implements MbluePlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final MbluePlatform initialPlatform = MbluePlatform.instance;

  test('$MethodChannelMblue is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelMblue>());
  });

  test('getPlatformVersion', () async {
    Mblue mbluePlugin = Mblue();
    MockMbluePlatform fakePlatform = MockMbluePlatform();
    MbluePlatform.instance = fakePlatform;

    expect(await mbluePlugin.getPlatformVersion(), '42');
  });
}
