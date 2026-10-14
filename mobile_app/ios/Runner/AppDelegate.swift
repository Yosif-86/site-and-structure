import Flutter
import StoreKit
import UIKit

/// Native screen security for iPhone:
///  - ScreenShield puts the whole app inside a secure text field's layer, so
///    screenshots, recordings and mirroring show black instead of the app
///    (the same technique as the common Flutter protection plugins; not an
///    official switch, so Dart checks it is active and logs if not).
///  - While the screen is recorded or mirrored a black cover also hides the
///    app (official UIScreen.isCaptured), and Dart pauses video playback.
///  - Screenshot / recording events are still forwarded to Dart for the
///    admin's security report.
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
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "enableShield":
        // Returns whether the secure layer is really in place (self-check).
        DispatchQueue.main.async { result(ScreenShield.enable()) }
      case "shieldActive":
        DispatchQueue.main.async { result(ScreenShield.isActive) }
      default:
        // setSecure etc.: Android only, nothing to do here.
        result(nil)
      }
    }

    // App Store country of the signed-in Apple ID ("USA" etc.): the app
    // shows the outside-checkout button only for the US storefront.
    let storefront = FlutterMethodChannel(
      name: "site_and_structure/storefront", binaryMessenger: messenger)
    storefront.setMethodCallHandler { call, result in
      guard call.method == "countryCode" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(SKPaymentQueue.default().storefront?.countryCode)
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
    ScreenShield.setCaptureCover(isCaptured)
    if isCaptured {
      channel?.invokeMethod("onCapture", arguments: ["type": "recording"])
    }
  }
}

/// Hides the app from screenshots and screen recordings on iPhone.
enum ScreenShield {
  private static var field: UITextField?
  private static weak var secureLayer: CALayer?
  private static weak var window: UIWindow?
  private static var cover: UIView?

  static var isActive: Bool {
    guard let w = window, let s = secureLayer else { return false }
    return w.layer.superlayer === s
  }

  private static func keyWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      if let ws = scene as? UIWindowScene,
         let w = ws.windows.first(where: { $0.isKeyWindow }) ?? ws.windows.first {
        return w
      }
    }
    return nil
  }

  /// Moves the window's layer into the secure text field's content layer:
  /// iOS leaves that layer out of every capture. Safe to call again.
  static func enable() -> Bool {
    if isActive { return true }
    // The window layer must sit under a parent layer, or moving it into the
    // field (which lives inside it) would make a layer cycle.
    guard let w = keyWindow(), w.layer.superlayer != nil else { return false }
    window = w
    let f = UITextField()
    f.isSecureTextEntry = true
    f.isUserInteractionEnabled = false
    f.backgroundColor = .clear
    w.addSubview(f)
    f.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    w.layer.superlayer?.addSublayer(f.layer)
    // The secure content layer is the text field's canvas sublayer; its
    // position in the list changed in iOS 17, so look for it by name first.
    let subs = f.layer.sublayers ?? []
    let canvas = subs.first(where: {
      String(describing: type(of: $0)).contains("Canvas")
        || String(describing: $0.delegate.map { type(of: $0) }).contains("Canvas")
    })
    let target: CALayer?
    if let c = canvas {
      target = c
    } else if #available(iOS 17.0, *) {
      target = subs.last
    } else {
      target = subs.first
    }
    guard let t = target else { return false }
    t.addSublayer(w.layer)
    field = f
    secureLayer = t
    setCaptureCover(UIScreen.main.isCaptured)
    return isActive
  }

  /// Black cover while the screen is recorded or mirrored.
  static func setCaptureCover(_ on: Bool) {
    guard let w = window ?? keyWindow() else { return }
    if on {
      if cover == nil {
        let v = UIView(frame: w.bounds)
        v.backgroundColor = .black
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let label = UILabel()
        label.text = "أوقف تسجيل الشاشة لمتابعة استخدام التطبيق"
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
          label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
          label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
          label.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 24),
        ])
        cover = v
      }
      if let v = cover, v.superview == nil {
        v.frame = w.bounds
        w.addSubview(v)
      }
    } else {
      cover?.removeFromSuperview()
    }
  }
}
