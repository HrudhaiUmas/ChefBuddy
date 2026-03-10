//
//  ContentView.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/1/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var authVM = AuthViewModel()
    @State private var showHallucinationWarning = true

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
        .sheet(isPresented: $showHallucinationWarning) {
            AIWarningSheet(onDismiss: { showHallucinationWarning = false })
                .presentationDetents([.fraction(0.55)])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
        }
    }
}

// MARK: - AI Hallucination Warning Sheet

private struct AIWarningSheet: View {
    let onDismiss: () -> Void
    @State private var understood = false

    var body: some View {
        VStack(spacing: 0) {
            // Header gradient bar
            LinearGradient(
                colors: [.orange, .green.opacity(0.85)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 5)

            VStack(spacing: 24) {
                // Icon + title
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Text("⚠️")
                            .font(.system(size: 36))
                    }

                    Text("AI-Generated Content")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))

                    Text("Please read before cooking")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                // Warning points
                VStack(alignment: .leading, spacing: 2) {
                    WarningRow(icon: "brain.head.profile", color: .orange,
                               text: "Recipes are AI-generated and may contain errors.")
                    WarningRow(icon: "allergens", color: .red,
                               text: "Verify for allergens and dietary restrictions.")
                    WarningRow(icon: "flame", color: .orange,
                               text: "Cook times, temperatures and quantities may be inaccurate.")
                    WarningRow(icon: "cross.case", color: .green,
                               text: "Consult a professional if you have specific health needs.")
                }
                .padding(.horizontal, 4)

                // Confirm + dismiss
                Button(action: onDismiss) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                        Text("I Understand — Let's Cook!")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        LinearGradient(
                            colors: [.orange, .green.opacity(0.85)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                    .shadow(color: .orange.opacity(0.3), radius: 8, y: 4)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
        }
        .background(Color(.systemBackground))
    }
}

private struct WarningRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
                .padding(.top, 1)

            Text(text)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
