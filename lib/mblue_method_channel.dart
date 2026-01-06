import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mblue_platform_interface.dart';

/// An implementation of [MbluePlatform] that uses method channels.
class MethodChannelMblue extends MbluePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('mblue');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
