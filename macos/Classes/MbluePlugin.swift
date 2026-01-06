import Cocoa
import FlutterMacOS

final class MblueEventStreamHandler: NSObject, FlutterStreamHandler {
  private(set) var eventSink: FlutterEventSink?
  var onListenCallback: (() -> Void)?
  var onCancelCallback: (() -> Void)?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    onListenCallback?()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    onCancelCallback?()
    return nil
  }

  func send(_ event: Any) {
    eventSink?(event)
  }
}

public class MbluePlugin: NSObject, FlutterPlugin {
  private let bluetoothManager = BluetoothManager()

  private let scanStreamHandler = MblueEventStreamHandler()
  private let connectionStreamHandler = MblueEventStreamHandler()

  override init() {
    super.init()

    bluetoothManager.onScanEvent = { [weak self] event in
      self?.scanStreamHandler.send(event)
    }
    bluetoothManager.onConnectionEvent = { [weak self] event in
      self?.connectionStreamHandler.send(event)
    }

    scanStreamHandler.onListenCallback = { [weak self] in
      guard let self = self else { return }
      self.scanStreamHandler.send([
        "event": "scanState",
        "isScanning": self.bluetoothManager.isScanning,
        "reason": "initial"
      ])
    }

    connectionStreamHandler.onListenCallback = { [weak self] in
      guard let self = self else { return }
      self.connectionStreamHandler.send([
        "event": "adapterState",
        "state": self.bluetoothManager.adapterStateString
      ])
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(name: "mblue", binaryMessenger: registrar.messenger)

    let scanEventChannel = FlutterEventChannel(name: "mblue/scan", binaryMessenger: registrar.messenger)
    let connectionEventChannel = FlutterEventChannel(
      name: "mblue/connection",
      binaryMessenger: registrar.messenger
    )

    let instance = MbluePlugin()
    registrar.addMethodCallDelegate(instance, channel: methodChannel)

    scanEventChannel.setStreamHandler(instance.scanStreamHandler)
    connectionEventChannel.setStreamHandler(instance.connectionStreamHandler)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)

    case "startScan":
      let args = call.arguments as? [String: Any]
      let timeoutMs = args?["timeoutMs"] as? Int
      if let err = bluetoothManager.startScan(timeoutMs: timeoutMs) {
        result(FlutterError(code: err.code, message: err.message, details: nil))
      } else {
        result(nil)
      }

    case "stopScan":
      bluetoothManager.stopScan()
      result(nil)

    case "connect":
      guard
        let args = call.arguments as? [String: Any],
        let deviceId = args["deviceId"] as? String
      else {
        result(FlutterError(code: "invalid_args", message: "Missing deviceId", details: nil))
        return
      }
      if let err = bluetoothManager.connect(deviceId: deviceId) {
        result(FlutterError(code: err.code, message: err.message, details: nil))
      } else {
        result(nil)
      }

    case "disconnect":
      guard
        let args = call.arguments as? [String: Any],
        let deviceId = args["deviceId"] as? String
      else {
        result(FlutterError(code: "invalid_args", message: "Missing deviceId", details: nil))
        return
      }
      if let err = bluetoothManager.disconnect(deviceId: deviceId) {
        result(FlutterError(code: err.code, message: err.message, details: nil))
      } else {
        result(nil)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
