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
                .presentationDetents([.fraction(0.80)])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
        }
    }
}

// MARK: - AI Hallucination Warning Sheet

private struct AIWarningSheet: View {
    let onDismiss: () -> Void

    @State private var understood = false
    @State private var animateGlow = false
    @State private var showContent = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dimmed background
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            // Floating glow behind sheet
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(animateGlow ? 0.16 : 0.08))
                    .frame(width: 220, height: 220)
                    .blur(radius: 40)
                    .offset(x: -90, y: 40)

                Circle()
                    .fill(Color.green.opacity(animateGlow ? 0.14 : 0.06))
                    .frame(width: 180, height: 180)
                    .blur(radius: 35)
                    .offset(x: 110, y: 120)
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: animateGlow)

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 44, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 16)

                VStack(spacing: 18) {
                    // Header
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.orange.opacity(0.22),
                                            Color.green.opacity(0.16)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 62, height: 62)
                                .shadow(color: .orange.opacity(0.18), radius: 12, y: 5)

                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.orange.opacity(0.8))
                                .offset(x: 18, y: -18)

                            Text("⚠️")
                                .font(.system(size: 28))
                        }

                        VStack(spacing: 4) {
                            Text("AI-Generated Content")
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .multilineTextAlignment(.center)

                            Text("Double-check important details before cooking")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    // Compact warning list
                    VStack(spacing: 10) {
                        CompactWarningRow(
                            icon: "brain.head.profile",
                            color: .orange,
                            title: "Recipes may contain mistakes"
                        )

                        CompactWarningRow(
                            icon: "allergens",
                            color: .red,
                            title: "Review allergens carefully"
                        )

                        CompactWarningRow(
                            icon: "flame.fill",
                            color: .orange,
                            title: "Cook times and measurements may be off"
                        )

                        CompactWarningRow(
                            icon: "cross.case.fill",
                            color: .green,
                            title: "Use professional advice for health needs"
                        )
                    }

                    // Acknowledgement row
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            understood.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(understood ? Color.green : Color.clear)
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(
                                                understood ? Color.green : Color.white.opacity(0.18),
                                                lineWidth: 1.5
                                            )
                                    )

                                if understood {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }

                            Text("I understand that I should verify important recipe details.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                                .multilineTextAlignment(.leading)

                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    // CTA button
                    Button(action: onDismiss) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 17, weight: .bold))

                            Text("I Understand")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            LinearGradient(
                                colors: understood
                                    ? [.orange, .green.opacity(0.9)]
                                    : [Color.white.opacity(0.12), Color.white.opacity(0.08)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(Capsule())
                        .shadow(
                            color: understood ? .orange.opacity(0.22) : .clear,
                            radius: 10,
                            y: 5
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!understood)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.14, green: 0.14, blue: 0.16),
                                Color(red: 0.10, green: 0.10, blue: 0.12)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .offset(y: showContent ? 0 : 40)
            .opacity(showContent ? 1 : 0)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: showContent)
        }
        .onAppear {
            animateGlow = true
            showContent = true
        }
    }
}

// MARK: - Compact Warning Row

private struct CompactWarningRow: View {
    let icon: String
    let color: Color
    let title: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color.opacity(0.16))
                    .frame(width: 42, height: 42)

                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
            }

            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
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
