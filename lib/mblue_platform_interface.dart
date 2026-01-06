import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'mblue_method_channel.dart';

abstract class MbluePlatform extends PlatformInterface {
  /// Constructs a MbluePlatform.
  MbluePlatform() : super(token: _token);

  static final Object _token = Object();

  static MbluePlatform _instance = MethodChannelMblue();

  /// The default instance of [MbluePlatform] to use.
  ///
  /// Defaults to [MethodChannelMblue].
  static MbluePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [MbluePlatform] when
  /// they register themselves.
  static set instance(MbluePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
