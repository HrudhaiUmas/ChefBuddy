//
//  ContentView.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/1/26.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("hasOnboarded") private var hasOnboarded: Bool = false

    var body: some View {
        Group {
            if hasOnboarded {
                MainAppPlaceholderView()
            } else {
                OnboardingFlowView(hasOnboarded: $hasOnboarded)
            }
        }
    }
}

struct MainAppPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("ChefBuddyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)

            Text("ChefBuddy")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Text("Home placeholder")
                .foregroundStyle(.secondary)
            
            // Temporary button to let you test onboarding again
            Button("Reset Onboarding") {
                UserDefaults.standard.set(false, forKey: "hasOnboarded")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.top, 20)
        }
        .padding()
    }
}
