import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    
    // Đăng ký native view factory
    if let registrar = self.registrar(forPlugin: "Runner") {
        let factory = NativeCameraViewFactory(messenger: registrar.messenger())
        registrar.register(factory, withId: "NativeCameraView") // ID này quan trọng
    }
    
    GeneratedPluginRegistrant.register(with: self)
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}