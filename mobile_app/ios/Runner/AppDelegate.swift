import Flutter
import UIKit

/// Native replacement for the broken screen_protector plugin's iOS half.
/// iOS can't block a screenshot/recording (Apple doesn't allow that), only
/// detect one after the fact — forwards both events to Dart over a method
/// channel so the video screen can blank/pause playback in reaction.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let channelName = "site_and_structure/screen_security"
  private var channel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.pluginRegistry as! FlutterBinaryMessenger
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      // No iOS-specific setup call needed today (Android's setSecure is a no-op
      // here); this keeps the channel symmetric across platforms.
      result(nil)
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenshotTaken),
      name: UIApplication.userDidTakeScreenshotNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenCaptureChanged),
      name: UIScreen.capturedDidChangeNotification,
      object: nil
    )
  }

  @objc private func screenshotTaken() {
    channel?.invokeMethod("onCapture", arguments: ["type": "screenshot"])
  }

  @objc private func screenCaptureChanged() {
    let isCaptured = UIScreen.main.isCaptured
    if isCaptured {
      channel?.invokeMethod("onCapture", arguments: ["type": "recording"])
    }
  }
}
