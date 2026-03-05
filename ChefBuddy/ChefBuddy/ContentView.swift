//
//  ContentView.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/1/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var authVM = AuthViewModel()

    var body: some View {
        Group {
            if authVM.userSession != nil {
                // If they are logged in, figure out where they go:
                if authVM.isFetchingProfile {
                    ZStack {
                        Color(.systemBackground).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.5)
                            Text("Loading your kitchen...").foregroundStyle(.secondary)
                        }
                    }
                } else if authVM.currentUserProfile == nil {
                    // Logged in, but NO preferences saved yet -> Show Setup
                    InitialPreferencesView()
                        .environmentObject(authVM)
                } else {
                    // Logged in AND preferences exist -> Show App
                    HomeView()
                        .environmentObject(authVM)
                }
            } else {
                // Not logged in -> Always show Onboarding
                OnboardingFlowView()
                    .environmentObject(authVM)
            }
        }
        // Smooth transitions between routing states
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: authVM.userSession != nil)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: authVM.isFetchingProfile)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: authVM.currentUserProfile != nil)
    }
}

// Dedicated wrapper for the login screen when users are logged out
struct StandaloneAuthView: View {
    @EnvironmentObject var authVM: AuthViewModel
    var body: some View {
        AuthView(onAuthSuccess: {
            // Do nothing here.
            // The AuthViewModel updates `userSession`, which automatically kicks the user to HomeView
        })
    }
}

struct MainAppPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("ChefBuddyLogo").resizable().scaledToFit().frame(width: 120, height: 120)
            Text("ChefBuddy").font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Home placeholder").foregroundStyle(.secondary)
            
            // Temporary button to let you test onboarding again
            Button("Reset Onboarding") {
                UserDefaults.standard.set(false, forKey: "hasOnboarded")
            }.buttonStyle(.borderedProminent).tint(.orange).padding(.top, 20)
        }.padding()
    }
}
