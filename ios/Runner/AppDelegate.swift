import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var shareChannel: FlutterMethodChannel?
  private var pendingSharedURL: URL?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSharedURLNotification(_:)),
      name: .pcdropSharedURL,
      object: nil
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    shareChannel = FlutterMethodChannel(
      name: "pcdrop/share",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    if let pendingSharedURL {
      shareChannel?.invokeMethod("sharedFile", arguments: pendingSharedURL.path)
      self.pendingSharedURL = nil
    }
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    publishSharedURL(url)
    return true
  }

  @objc private func handleSharedURLNotification(_ notification: Notification) {
    if let url = notification.object as? URL {
      publishSharedURL(url)
    }
  }

  private func publishSharedURL(_ url: URL) {
    guard url.isFileURL else { return }
    if let shareChannel {
      shareChannel.invokeMethod("sharedFile", arguments: url.path)
    } else {
      pendingSharedURL = url
    }
  }
}

extension Notification.Name {
  static let pcdropSharedURL = Notification.Name("pcdrop.sharedURL")
}
