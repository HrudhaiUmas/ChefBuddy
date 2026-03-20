// OnboardingFlowView.swift
// First-run experience shown to users who are not yet logged in.
// A four-step TabView walks users through the app's key features before
// landing on the account creation step. Keeping onboarding separate from
// auth means the flow can be updated without touching authentication logic.

import SwiftUI
import Combine

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case scanIngredients
    case aiAssistant
    case account
}

struct OnboardingFlowView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        ZStack {
            BrandBackground()

            VStack(spacing: 0) {
                TopNavigation(step: step)

                TabView(selection: $step) {
                    WelcomeStep()
                        .tag(OnboardingStep.welcome)

                    FeatureStep(
                        icons: ["camera.viewfinder", "refrigerator", "carrot.fill"],
                        title: "Cook with what you have",
                        subtitle: "Scan your pantry or enter ingredients manually to get instant, realistic meal ideas."
                    )
                    .tag(OnboardingStep.scanIngredients)

                    FeatureStep(
                        icons: ["frying.pan.fill", "sparkles", "bubble.left.and.bubble.right.fill"],
                        title: "Your AI Sous-Chef",
                        subtitle: "Get step-by-step guidance and ask questions in real-time while you cook."
                    )
                    .tag(OnboardingStep.aiAssistant)

                    AccountStep()
                        .environmentObject(authVM)
                        .tag(OnboardingStep.account)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: step)

                BottomDock(
                    step: step,
                    onBack: goBack,
                    onNext: goNext
                )
            }
        }
    }

    private func goNext() {
        if let next = OnboardingStep(rawValue: step.rawValue + 1) {
            withAnimation { step = next }
        }
    }

    private func goBack() {
        if let prev = OnboardingStep(rawValue: step.rawValue - 1) {
            withAnimation { step = prev }
        }
    }
}


private struct SequentialIconView: View {
    let icons: [String]
    @State private var currentIndex = 0
    @State private var isAnimating = false

    let timer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.orange.opacity(0.15), .green.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 180, height: 180)
                .scaleEffect(isAnimating ? 1.0 : 0.8)

            Image(systemName: icons[currentIndex])
                .font(.system(size: 70, weight: .light))
                .foregroundStyle(LinearGradient(colors: [.orange, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                .scaleEffect(isAnimating ? 1.0 : 0.5)
                .opacity(isAnimating ? 1.0 : 0.0)
                .id(currentIndex)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) { isAnimating = true }
        }
        .onReceive(timer) { _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isAnimating = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    currentIndex = (currentIndex + 1) % icons.count
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) { isAnimating = true }
                }
            }
        }
    }
}


private struct WelcomeStep: View {
    @State private var isAnimating = false
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 240, height: 240)
                    .scaleEffect(isAnimating ? 1.05 : 0.95)
                    .animation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true), value: isAnimating)

                Image("ChefBuddyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .offset(y: 10)
                    .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
            }
            .onAppear { isAnimating = true }

            VStack(spacing: 12) {
                Text("ChefBuddy")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                Text("Your AI-Powered Kitchen Companion.\nTurn ingredients into masterpieces.")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
    }
}

private struct FeatureStep: View {
    let icons: [String]
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            SequentialIconView(icons: icons)
            VStack(spacing: 16) {
                Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                Text(subtitle).font(.system(size: 17, weight: .regular)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            Spacer()
        }
    }
}

private struct AccountStep: View {
    @EnvironmentObject var authVM: AuthViewModel

    @State private var isFloating = false
    @State private var showAuthSheet = false
    @State private var carouselIndex = 0

    let features = [
        ("camera.viewfinder", "Smart Ingredient Scanning", "Scan a fridge or shelf and sort ingredients into the right spots fast."),
        ("sparkles", "Personalized AI Recipes", "Get detailed meals with nutrition, timing cues, and clearer instructions."),
        ("bubble.left.and.bubble.right.fill", "Real-time Cooking Assistant", "Ask follow-up questions while you cook and keep the recipe moving."),
        ("calendar", "Weekly Meal Plans", "Turn your week into actionable meals with recipe details attached to each day."),
        ("cart.fill", "Auto-Generated Grocery Lists", "Catch what you’re missing before the store run and stay organized.")
    ]

    private let carouselTimer = Timer.publish(every: 4.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(Color.green.opacity(0.15)).frame(width: 160, height: 160).blur(radius: 20)

                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.system(size: 18))
                    .offset(x: -70, y: isFloating ? -50 : -30).opacity(isFloating ? 0.9 : 0.3)

                Image(systemName: "sparkle").foregroundStyle(.orange).font(.system(size: 24))
                    .offset(x: 70, y: isFloating ? 10 : 30).opacity(isFloating ? 0.4 : 1.0)

                Image("ChefBuddyLogo")
                    .resizable().scaledToFit().frame(width: 150, height: 150)
                    .scaleEffect(isFloating ? 1.05 : 0.95)
                    .offset(y: isFloating ? -8 : 8)
            }
            .padding(.top, 10)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("ChefBuddy Tasting Menu").font(.headline.bold())
                    Spacer()
                    Text("\(carouselIndex + 1)/\(features.count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(Capsule())
                }
                Divider()
                TabView(selection: $carouselIndex) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 12) {
                                Image(systemName: feature.0)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.green)
                                    .frame(width: 42, height: 42)
                                    .background(Color.green.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(feature.1)
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                    Text("ChefBuddy feature spotlight")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text(feature.2)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)

                            HStack(spacing: 8) {
                                Text("Ready to use")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.green.opacity(0.12))
                                    .clipShape(Capsule())

                                Text("Built for your kitchen")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.12))
                                    .clipShape(Capsule())
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.top, 6)
                        .tag(index)
                    }
                }
                .frame(height: 180)
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 8) {
                    ForEach(features.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == carouselIndex ? Color.orange : Color.primary.opacity(0.10))
                            .frame(width: index == carouselIndex ? 26 : 8, height: 8)
                            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: carouselIndex)
                    }
                }
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.6), lineWidth: 1))
            .shadow(color: Color.orange.opacity(isFloating ? 0.1 : 0.0), radius: 20, y: 10)
            .padding(.horizontal, 24)

            VStack(spacing: 12) {
                Text("Create your space").font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Join other chefs mastering their kitchens.").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            VStack(spacing: 15) {
                AuthButton(icon: "person.crop.circle.fill", title: "Sign Up / Log In", bg: .orange, fg: .white) {
                    showAuthSheet = true
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)

            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                isFloating = true
            }
        }
        .onReceive(carouselTimer) { _ in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                carouselIndex = (carouselIndex + 1) % features.count
            }
        }
        .sheet(isPresented: $showAuthSheet) {
            AuthView(onAuthSuccess: {
                UserDefaults.standard.set(true, forKey: "hasOnboarded")
                showAuthSheet = false
            })
            .presentationDetents([.fraction(0.85), .large])
        }
    }
}


private struct BottomDock: View {
    let step: OnboardingStep
    let onBack: () -> Void
    let onNext: () -> Void
    @State private var isPressed = false

    var body: some View {
        VStack {
            if step != .account {
                HStack(spacing: 16) {
                    if step != .welcome {
                        Button(action: onBack) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color.primary)
                                .frame(width: 64, height: 64)
                                .background(.thickMaterial)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        }
                    }

                    Button(action: onNext) {
                        HStack {
                            Text("Continue").font(.system(size: 18, weight: .bold, design: .rounded))
                            Spacer()
                            Image(systemName: "arrow.right").font(.system(size: 18, weight: .bold))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 28).frame(height: 64)
                        .background(LinearGradient(colors: [.orange, .green.opacity(0.9)], startPoint: .leading, endPoint: .trailing))
                        .clipShape(Capsule())
                        .shadow(color: .orange.opacity(0.3), radius: 10, y: 5)
                        .scaleEffect(isPressed ? 0.94 : 1.0)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .padding(.top, 20)
            }
        }
    }
}

private struct BrandBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Circle().fill(Color.orange.opacity(0.12)).blur(radius: 70).offset(x: -120, y: -250)
            Circle().fill(Color.green.opacity(0.1)).blur(radius: 70).offset(x: 120, y: 250)
        }
    }
}

private struct TopNavigation: View {
    let step: OnboardingStep
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<OnboardingStep.allCases.count, id: \.self) { index in
                Capsule().fill(index <= step.rawValue ? Color.orange : Color.gray.opacity(0.2)).frame(width: index == step.rawValue ? 30 : 10, height: 8).animation(.spring(), value: step)
            }
            Spacer()
        }.padding(.horizontal, 24).padding(.top, 20)
    }
}

private struct AuthButton: View {
    let icon: String
    let title: String
    let bg: Color
    let fg: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium))
                Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .foregroundStyle(fg).frame(maxWidth: .infinity).frame(height: 64).background(bg).clipShape(Capsule()).shadow(color: bg.opacity(0.3), radius: 10, y: 5)
        }
    }
}
