//
//  ChefBuddyApp.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/1/26.
//

import SwiftUI
import FirebaseCore
import GoogleSignIn

// Create an AppDelegate to handle Firebase initialization
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Initializes Firebase when the app starts
        FirebaseApp.configure()
        
        return true
    }
}

@main
struct ChefBuddyApp: App {
    // Attach the AppDelegate to your SwiftUI App
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Listen for the Google Sign-In callback URL
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
