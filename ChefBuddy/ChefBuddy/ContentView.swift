// ContentView.swift
// The root routing view. Reads AuthViewModel state and decides which screen to show:
// onboarding (not logged in), a loading spinner (fetching profile), preference setup
// (logged in but no profile yet), or the main HomeView (fully set up).
// Also presents the AI hallucination warning sheet on every cold launch so users
// understand the limits of AI-generated recipes before they start cooking.

import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var authVM = AuthViewModel()
    @StateObject private var notificationManager = NotificationManager.shared
    @State private var showHallucinationWarning = true

    var body: some View {
        Group {
            if authVM.userSession != nil {

                // Show a spinner while Firestore loads the profile. Skipping this state
                // would cause a brief flash of the setup screen for returning users.
                if authVM.isFetchingProfile {
                    ZStack {
                        Color(.systemBackground).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.5)
                            Text("Loading your kitchen...").foregroundStyle(.secondary)
                        }
                    }
                // Profile is nil — user is logged in but hasn't completed setup yet.
                } else if authVM.currentUserProfile == nil {

                    InitialPreferencesView()
                        .environmentObject(authVM)
                        .environmentObject(notificationManager)
                } else if (authVM.currentUserProfile?.didCompleteNotificationOnboarding ?? false) == false {
                    NotificationPermissionView()
                        .environmentObject(authVM)
                        .environmentObject(notificationManager)
                } else {

                    MainTabShellView()
                        .environmentObject(authVM)
                        .environmentObject(notificationManager)
                }
            } else {

                OnboardingFlowView()
                    .environmentObject(authVM)
                    .environmentObject(notificationManager)
            }
        }

        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: authVM.userSession != nil)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: authVM.isFetchingProfile)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: authVM.currentUserProfile != nil)
        // Shown on every cold launch to remind users that AI recipes may contain
// errors. interactiveDismissDisabled prevents swiping it away without
// explicitly tapping "I Understand".
        .sheet(isPresented: $showHallucinationWarning) {
            AIWarningSheet(onDismiss: { showHallucinationWarning = false })
                .presentationDetents([.fraction(0.80)])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
        }
        .task(id: authVM.currentUserProfile?.id) {
            if let profile = authVM.currentUserProfile,
               let uid = authVM.userSession?.uid {
                await notificationManager.rescheduleNotificationsIfPossible(profile: profile, userId: uid)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                notificationManager.clearBadgeCount()
            }
        }
    }
}


// The warning sheet itself. Uses a dark glassmorphism card with animated
// gradient glows. The dismiss button is disabled until the user ticks the
// acknowledgement checkbox, ensuring they actually read the warnings.
private struct AIWarningSheet: View {
    let onDismiss: () -> Void

    @State private var understood = false
    @State private var animateGlow = false
    @State private var showContent = false

    var body: some View {
        ZStack(alignment: .bottom) {

            Color.black.opacity(0.35)
                .ignoresSafeArea()


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


// A single warning item — icon badge on the left, title text on the right.
// Reused four times in the warning sheet for consistent spacing and style.
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


struct StandaloneAuthView: View {
    @EnvironmentObject var authVM: AuthViewModel
    var body: some View {
        AuthView(onAuthSuccess: {


        })
    }
}

struct MainAppPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("ChefBuddyLogo").resizable().scaledToFit().frame(width: 120, height: 120)
            Text("ChefBuddy").font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Home placeholder").foregroundStyle(.secondary)


            Button("Reset Onboarding") {
                UserDefaults.standard.set(false, forKey: "hasOnboarded")
            }.buttonStyle(.borderedProminent).tint(.orange).padding(.top, 20)
        }.padding()
    }
}
