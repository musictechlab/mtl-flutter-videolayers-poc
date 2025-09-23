import UIKit
import Flutter

@main
class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    GeneratedPluginRegistrant.register(with: self)

    // Mixed player
    if let registrar = self.registrar(forPlugin: "mtl.mixedplayer") {
      let factory = MTLMixedFactory(binaryMessenger: registrar.messenger())
      registrar.register(factory, withId: "mtl.mixedplayer")
    }

    // AirPlay route picker  ✅ (TU BYŁ BŁĄD)
    if let registrar = self.registrar(forPlugin: "mtl.airplay.routepicker") {
      let airplayFactory = AirPlayRoutePickerFactory(messenger: registrar.messenger())
      registrar.register(airplayFactory, withId: "mtl.airplay.routepicker")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}