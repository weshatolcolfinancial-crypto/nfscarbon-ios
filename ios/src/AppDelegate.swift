//
//  AppDelegate.swift
//  NFSCarbon
//
//  Application entry and window initialization for Need for Speed: Carbon iOS.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Prevent display dimming during gameplay
        UIApplication.shared.isIdleTimerDisabled = true

        let window = UIWindow(frame: UIScreen.main.bounds)
        let gameVC = GameViewController()
        window.rootViewController = gameVC
        window.makeKeyAndVisible()
        self.window = window

        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        NFSCLogger.shared.info("APP", "applicationWillResignActive received.")
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        NFSCLogger.shared.info("APP", "applicationDidEnterBackground received.")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        NFSCLogger.shared.info("APP", "applicationWillEnterForeground received.")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        NFSCLogger.shared.info("APP", "applicationDidBecomeActive received.")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        NFSCLogger.shared.info("APP", "applicationWillTerminate received.")
    }
}
