import UIKit
import Flutter

@main
class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "mtl.mixedplayer") {
      let factory = MTLMixedFactory(binaryMessenger: registrar.messenger())
      registrar.register(factory, withId: "mtl.mixedplayer")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}