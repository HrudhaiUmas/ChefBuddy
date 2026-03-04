//
//  ChefBuddyOnboarding.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/1/26.
//

import SwiftUI
import Combine

// MARK: - Onboarding Flow

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case scanIngredients
    case aiAssistant
    case preferences
    case account
}

struct OnboardingFlowView: View {
    @Binding var hasOnboarded: Bool
    @State private var step: OnboardingStep = .welcome
    
    @State private var dietTags: Set<String> = []
    @State private var allergies: Set<String> = []
    @State private var macroTags: Set<String> = []
    @State private var chefLevel: String = "🍳 Beginner"

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
                        title: "Your Al Sous-Chef",
                        subtitle: "Get step-by-step guidance and ask questions in real-time while you cook."
                    )
                    .tag(OnboardingStep.aiAssistant)
                    
                    PreferencesStep(
                        dietTags: $dietTags,
                        allergies: $allergies,
                        macroTags: $macroTags,
                        chefLevel: $chefLevel
                    )
                    .tag(OnboardingStep.preferences)
                    
                    AccountStep(onFinish: { hasOnboarded = true })
                        .tag(OnboardingStep.account)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: step)
                
                BottomDock(
                    step: step,
                    onBack: goBack,
                    onNext: goNext,
                    onFinish: { hasOnboarded = true }
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

// MARK: - Animation Components

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

// MARK: - Slides

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
                Text("Your Al-Powered Kitchen Companion.\nTurn ingredients into masterpieces.")
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

private struct PreferencesStep: View {
    @Binding var dietTags: Set<String>
    @Binding var allergies: Set<String>
    @Binding var macroTags: Set<String>
    @Binding var chefLevel: String

    private enum ActiveSheet: String, Identifiable {
        case level, diet, allergy, macro
        var id: String { self.rawValue }
    }
    
    @State private var activeSheet: ActiveSheet? = nil

    private let levels = ["🍳 Beginner", "👨‍🍳 Intermediate", "🔪 Advanced", "🌟 Masterchef"]
    private let diets = ["🥗 Vegetarian", "🌿 Vegan", "🐟 Pescatarian", "🥩 Keto", "🍖 Paleo", "☪️ Halal", "✡️ Kosher"]
    private let allergiesList = ["🥜 Peanuts", "🌳 Tree Nuts", "🥛 Dairy", "🥚 Eggs", "🦐 Shellfish", "🫘 Soy", "🌾 Gluten"]
    private let macros = ["⚖️ Balanced", "💪 High Protein", "🔥 Low Calorie", "🍞 Low Carb"]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Spacer()
                    SequentialIconView(icons: ["slider.horizontal.3", "heart.circle.fill", "checkmark.circle.fill"]).scaleEffect(0.6).frame(height: 100)
                    Spacer()
                }
                .padding(.top, 30)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Personalize it").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("We'll tailor every recipe to your lifestyle.").font(.system(size: 17)).foregroundStyle(.secondary)
                    Text("You can change these in your profile later.").font(.system(size: 14, weight: .medium)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 24)

                SinglePreferenceSection(title: "Experience Level", options: levels, selected: $chefLevel) {
                    activeSheet = .level
                }
                
                PreferenceSection(title: "Dietary Preferences", options: diets, selected: $dietTags) {
                    activeSheet = .diet
                }
                
                PreferenceSection(title: "Avoid (Allergies)", options: allergiesList, selected: $allergies) {
                    activeSheet = .allergy
                }
                
                PreferenceSection(title: "Macro Goals", options: macros, selected: $macroTags) {
                    activeSheet = .macro
                }
                
                Spacer(minLength: 120)
            }
        }
        .sheet(item: $activeSheet) { sheetType in
            switch sheetType {
            case .level:
                LevelInfoSheet()
                    .presentationDetents([.fraction(0.45)])
                    .presentationDragIndicator(.visible)
            case .diet:
                SimpleInfoSheet(title: "Dietary Preferences", message: "Select the diets that match your lifestyle. We will automatically filter out any recipe suggestions that don't fit these rules.")
                    .presentationDetents([.fraction(0.3)])
                    .presentationDragIndicator(.visible)
            case .allergy:
                SimpleInfoSheet(title: "Allergies", message: "Select ingredients you want to completely avoid. Your safety is our priority, and ChefBuddy will never suggest meals containing these items.")
                    .presentationDetents([.fraction(0.3)])
                    .presentationDragIndicator(.visible)
            case .macro:
                MacroInfoSheet()
                    .presentationDetents([.fraction(0.5)])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct AccountStep: View {
    let onFinish: () -> Void
    @State private var showFeatures = false
    @State private var isFloating = false
    @State private var shimmerOffset: CGFloat = -1.0
    @State private var showAuthSheet = false
    
    let features = [
        ("camera.viewfinder", "Smart Ingredient Scanning"),
        ("sparkles", "Personalized Al Recipes"),
        ("bubble.left.and.bubble.right.fill", "Real-time Cooking Assistant"),
        ("slider.horizontal.3", "Recipe Adjustment & Detail"),
        ("cart.fill", "Auto-Generated Grocery Lists")
    ]
    
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
                    Text("ChefBuddy Passport").font(.headline.bold())
                    Spacer()
                    Image(systemName: "star.fill").foregroundStyle(.orange)
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        HStack(spacing: 14) {
                            Image(systemName: feature.0).font(.caption.bold()).foregroundStyle(.green).frame(width: 26, height: 26).background(Color.green.opacity(0.15)).clipShape(Circle())
                            Text(feature.1).font(.system(size: 15, weight: .semibold, design: .rounded))
                        }
                        .opacity(showFeatures ? 1 : 0)
                        .offset(x: showFeatures ? 0 : -20)
                        .animation(.spring().delay(Double(index) * 0.1), value: showFeatures)
                    }
                }
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                LinearGradient(colors: [.clear, .white.opacity(0.4), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .offset(x: shimmerOffset * 300)
                    .mask(RoundedRectangle(cornerRadius: 24, style: .continuous))
            )
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
            showFeatures = true
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                isFloating = true
            }
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false).delay(1.5)) {
                shimmerOffset = 1.5
            }
        }
        .sheet(isPresented: $showAuthSheet) {
            AuthView(onAuthSuccess: {
                showAuthSheet = false
                onFinish()
            })
            .presentationDetents([.fraction(0.85), .large])
        }
    }
}

// MARK: - Shared UI

private struct SinglePreferenceSection: View {
    let title: String
    let options: [String]
    @Binding var selected: String
    var onInfoTap: (() -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                if let onInfoTap = onInfoTap {
                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.primary.opacity(0.4)) // 🛠️ Adjusted for clear visibility in light & dark mode
                            .font(.system(size: 18))
                    }
                }
            }.padding(.horizontal, 24)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Spacer().frame(width: 12)
                    ForEach(options, id: \.self) { option in
                        let isSelected = selected == option
                        Button {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            selected = option
                        } label: {
                            Text(option).font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(isSelected ? .white : .primary)
                                .padding(.horizontal, 20).padding(.vertical, 14)
                                .background(isSelected ? Color.orange : Color(.systemGray6))
                                .clipShape(Capsule())
                                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
                        }.buttonStyle(.plain)
                    }
                    Spacer().frame(width: 12)
                }
            }
        }
    }
}

private struct PreferenceSection: View {
    let title: String
    let options: [String]
    @Binding var selected: Set<String>
    var onInfoTap: (() -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                if let onInfoTap = onInfoTap {
                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.primary.opacity(0.4)) // 🛠️ Adjusted for clear visibility in light & dark mode
                            .font(.system(size: 18))
                    }
                }
            }.padding(.horizontal, 24)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Spacer().frame(width: 12)
                    ForEach(options, id: \.self) { option in
                        let isSelected = selected.contains(option)
                        Button {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            if isSelected { selected.remove(option) } else { selected.insert(option) }
                        } label: {
                            Text(option).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(isSelected ? .white : .primary).padding(.horizontal, 20).padding(.vertical, 14).background(isSelected ? Color.green : Color(.systemGray6)).clipShape(Capsule()).animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
                        }.buttonStyle(.plain)
                    }
                    Spacer().frame(width: 12)
                }
            }
        }
    }
}

// Sub-view for the Level Info Sheet
private struct LevelInfoSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Chef Levels")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .padding(.bottom, 4)
            
            VStack(alignment: .leading, spacing: 16) {
                LevelDescriptionRow(icon: "🍳", title: "Beginner", description: "You need step-by-step help, clear instructions, and simple recipes.")
                LevelDescriptionRow(icon: "👨‍🍳", title: "Intermediate", description: "You're comfortable with basics and looking to expand your skills.")
                LevelDescriptionRow(icon: "🔪", title: "Advanced", description: "You're a confident cook who can handle complex techniques and timing.")
                LevelDescriptionRow(icon: "🌟", title: "Masterchef", description: "You're an expert looking for culinary challenges and fresh inspiration.")
            }
            Spacer()
        }
        .padding(24)
        .padding(.top, 16)
    }
}

// Sub-view for the Macro Info Sheet
private struct MacroInfoSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Macro Goals")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .padding(.bottom, 4)
            
            VStack(alignment: .leading, spacing: 16) {
                LevelDescriptionRow(icon: "⚖️", title: "Balanced", description: "A well-rounded ratio of proteins, fats, and carbohydrates for general health.")
                LevelDescriptionRow(icon: "💪", title: "High Protein", description: "Prioritizes recipes rich in protein to support muscle growth and recovery.")
                LevelDescriptionRow(icon: "🔥", title: "Low Calorie", description: "Focuses on meals with a lower total caloric intake for weight management.")
                LevelDescriptionRow(icon: "🍞", title: "Low Carb", description: "Minimizes carbohydrates, often favored for ketogenic or low-carb diets.")
            }
            Spacer()
        }
        .padding(24)
        .padding(.top, 16)
    }
}

// Sub-view for the other simpler info sheets
private struct SimpleInfoSheet: View {
    let title: String
    let message: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            
            Text(message)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
            
            Spacer()
        }
        .padding(24)
        .padding(.top, 16)
    }
}

private struct LevelDescriptionRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(icon).font(.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline.bold())
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BottomDock: View {
    let step: OnboardingStep
    let onBack: () -> Void
    let onNext: () -> Void
    let onFinish: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        VStack {
            if step != .account {
                HStack(spacing: 16) {
                    if step != .welcome {
                        Button(action: onBack) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color.primary) // 🛠️ Solid primary for maximum contrast
                                .frame(width: 64, height: 64)
                                .background(.thickMaterial) // 🛠️ Upgraded to thickMaterial to separate from background
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                .shadow(color: .black.opacity(0.15), radius: 8, y: 4) // 🛠️ Slightly stronger shadow
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
