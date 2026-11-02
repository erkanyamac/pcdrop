import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      NotificationCenter.default.post(
        name: .pcdropSharedURL,
        object: context.url
      )
    }
  }
}
