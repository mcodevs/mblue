
import 'mblue_platform_interface.dart';

class Mblue {
  Future<String?> getPlatformVersion() {
    return MbluePlatform.instance.getPlatformVersion();
  }
}
