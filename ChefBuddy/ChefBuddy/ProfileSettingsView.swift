//
//  ProfileSettingsView.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/5/26.
//

import SwiftUI
import Combine
import FirebaseAuth

// MARK: - Shared State Model & Form Logic
class ProfileFormState: ObservableObject {
    @Published var chefLevel: String = "🍳 Beginner"
    @Published var dietTags: Set<String> = []
    @Published var allergies: Set<String> = []
    @Published var macroTags: Set<String> = []
    
    // Sliders use Doubles for UI, converted to Strings for DB
    @Published var age: Double = 25.0
    @Published var heightInches: Double = 67.0 // 5'7" default for now
    @Published var weight: Double = 150.0
    @Published var sex: String = "Male"
    
    @Published var targetGoal: String = "⚖️ Maintain"
    @Published var activityLevel: String = "🛋️ Sedentary"
    
    @Published var appliances: Set<String> = []
    @Published var cookTime: String = "⏱️ 15-30 mins"
    
    @Published var cuisines: Set<String> = []
    @Published var customCuisineInput: String = ""
    
    @Published var spiceTolerance: String = "🌶️ Medium"
    
    // Ingredients to Avoid logic
    @Published var dislikesList: Set<String> = []
    @Published var customDislikeInput: String = ""
    
    // Custom allergy + appliance inputs
    @Published var customAllergyInput: String = ""
    @Published var customApplianceInput: String = ""
    
    @Published var servingSize: String = "👤 1 Person"
    @Published var budget: String = "💵 $$ (Standard)"
    
    func load(from profile: DBUser?) {
        guard let profile = profile else { return }
        chefLevel = profile.chefLevel
        dietTags = Set(profile.dietTags)
        allergies = Set(profile.allergies)
        macroTags = Set(profile.macroTags)
        
        age = Double(profile.age) ?? 25.0
        heightInches = Double(profile.height) ?? 67.0
        weight = Double(profile.weight) ?? 150.0
        sex = profile.sex.isEmpty ? "Male" : profile.sex
        targetGoal = profile.targetGoal.isEmpty ? "⚖️ Maintain" : profile.targetGoal
        activityLevel = profile.activityLevel.isEmpty ? "🛋️ Sedentary" : profile.activityLevel
        
        appliances = Set(profile.appliances)
        cookTime = profile.cookTime.isEmpty ? "⏱️ 15-30 mins" : profile.cookTime
        
        cuisines = Set(profile.cuisines)
        spiceTolerance = profile.spiceTolerance.isEmpty ? "🌶️ Medium" : profile.spiceTolerance
        
        // Convert comma string to Set
        dislikesList = Set(
            profile.dislikes
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        
        servingSize = profile.servingSize.isEmpty ? "👤 1 Person" : profile.servingSize
        budget = profile.budget.isEmpty ? "💵 $$ (Standard)" : profile.budget
    }
}

// MARK: - View 1: First-Time Setup
struct InitialPreferencesView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @StateObject private var formState = ProfileFormState()
    @State private var isSaving = false
    
    var displayName: String {
        if let name = authVM.userSession?.displayName, !name.isEmpty {
            return String(name.split(separator: " ").first ?? "")
        } else if let email = authVM.userSession?.email {
            return String(email.split(separator: "@").first ?? "Chef")
        }
        return "Chef"
    }

    var body: some View {
        ZStack {
            ProfileBackground()
            PreferencesFormContent(
                formState: formState,
                title: "One last step, \(displayName)!",
                subtitle: "Personalize your experience so ChefBuddy knows exactly what to suggest."
            )
            
            VStack {
                Spacer()
                Button(action: finishSetup) {
                    HStack {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Text("Complete Setup")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(
                        LinearGradient(
                            colors: [.orange, .green.opacity(0.9)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                    .shadow(color: .orange.opacity(0.3), radius: 10, y: 5)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .disabled(isSaving)
            }
        }
    }
    
    private func finishSetup() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isSaving = true
        authVM.saveUserPreferences(
            level: formState.chefLevel,
            diets: formState.dietTags,
            allergy: formState.allergies,
            macros: formState.macroTags,
            age: String(format: "%.0f", formState.age),
            height: String(format: "%.0f", formState.heightInches),
            weight: String(format: "%.0f", formState.weight),
            sex: formState.sex,
            targetGoal: formState.targetGoal,
            activity: formState.activityLevel,
            appliances: formState.appliances,
            cookTime: formState.cookTime,
            mealPrep: false,
            cuisines: formState.cuisines,
            spice: formState.spiceTolerance,
            dislikes: formState.dislikesList.joined(separator: ", "),
            servings: formState.servingSize,
            budget: formState.budget
        )
    }
}

// MARK: - View 2: Edit Preferences (From Home)
struct ProfileSettingsView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @Environment(\.dismiss) var dismiss
    @StateObject private var formState = ProfileFormState()
    @State private var isSaving = false

    var body: some View {
        ZStack {
            ProfileBackground()
            PreferencesFormContent(
                formState: formState,
                title: "Your Kitchen Profile",
                subtitle: "Tweak your preferences for better AI suggestions."
            )
            
            VStack {
                Spacer()
                Button(action: saveChanges) {
                    HStack {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Text("Save Changes")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(
                        LinearGradient(
                            colors: [.orange, .green.opacity(0.9)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                    .shadow(color: .orange.opacity(0.3), radius: 10, y: 5)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .disabled(isSaving)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "arrow.left.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.primary.opacity(0.8), .ultraThinMaterial)
                }
            }
        }
        .onAppear {
            formState.load(from: authVM.currentUserProfile)
        }
    }
    
    private func saveChanges() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isSaving = true
        authVM.updateUserPreferences(
            level: formState.chefLevel,
            diets: formState.dietTags,
            allergy: formState.allergies,
            macros: formState.macroTags,
            age: String(format: "%.0f", formState.age),
            height: String(format: "%.0f", formState.heightInches),
            weight: String(format: "%.0f", formState.weight),
            sex: formState.sex,
            targetGoal: formState.targetGoal,
            activity: formState.activityLevel,
            appliances: formState.appliances,
            cookTime: formState.cookTime,
            mealPrep: false,
            cuisines: formState.cuisines,
            spice: formState.spiceTolerance,
            dislikes: formState.dislikesList.joined(separator: ", "),
            servings: formState.servingSize,
            budget: formState.budget
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isSaving = false
            dismiss()
        }
    }
}

// MARK: - Core Form Content
private struct PreferencesFormContent: View {
    @ObservedObject var formState: ProfileFormState
    let title: String
    let subtitle: String
    
    @State private var activeSheet: ActiveSheet? = nil
    @State private var showSections: [Bool] = Array(repeating: false, count: 12)
    
    var bmi: Double {
        let h = formState.heightInches
        let w = formState.weight
        return h > 0 ? (w / (h * h)) * 703 : 0
    }
    
    var bmiCategory: String {
        if bmi < 18.5 { return "Underweight" }
        else if bmi < 25 { return "Normal" }
        else if bmi < 30 { return "Overweight" }
        else { return "Obese" }
    }
    
    var bmiColor: Color {
        if bmi < 18.5 { return .blue }
        else if bmi < 25 { return .green }
        else if bmi < 30 { return .orange }
        else { return .red }
    }
    
    // Mifflin-St Jeor estimate using sex, age, height, and weight
    var estimatedCalories: Int {
        let weightKg = formState.weight * 0.453592
        let heightCm = formState.heightInches * 2.54
        let age = formState.age
        
        let bmr: Double
        
        if formState.sex == "Male" {
            bmr = (10 * weightKg) + (6.25 * heightCm) - (5 * age) + 5
        } else {
            bmr = (10 * weightKg) + (6.25 * heightCm) - (5 * age) - 161
        }
        
        let activityMultiplier: Double
        
        switch formState.activityLevel {
        case "🛋️ Sedentary":
            activityMultiplier = 1.2
        case "🚶 Lightly Active":
            activityMultiplier = 1.375
        case "🏃 Active":
            activityMultiplier = 1.55
        case "🏋️ Athlete":
            activityMultiplier = 1.725
        default:
            activityMultiplier = 1.2
        }
        
        var calories = bmr * activityMultiplier
        
        switch formState.targetGoal {
        case "📉 Weight Loss":
            calories -= 400
        case "💪 Muscle Gain":
            calories += 250
        default:
            break
        }
        
        let clamped = max(1200, min(calories, 4500))
        return Int(clamped.rounded())
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                
                // Header Animation
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        ProfileSequentialIconView()
                            .scaleEffect(0.6)
                            .frame(height: 100)
                        Spacer()
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                        Text(subtitle)
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.top, 20)
                
                // SECTION 1: Core Basics
                AnimatedSection(isVisible: showSections[0]) {
                    VStack(alignment: .leading, spacing: 28) {
                        ProfileSectionHeader(title: "The Basics", icon: "person.text.rectangle")
                        
                        ProfileSinglePreference(
                            title: "Experience Level",
                            options: levelsList,
                            selected: $formState.chefLevel
                        ) {
                            activeSheet = .level
                        }
                        
                        ProfileMultiPreference(
                            title: "Dietary Preferences",
                            options: dietsList,
                            selected: $formState.dietTags
                        ) {
                            activeSheet = .diet
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            ProfileMultiPreference(
                                title: "Avoid (Allergies)",
                                options: allergiesList,
                                selected: $formState.allergies
                            ) {
                                activeSheet = .allergy
                            }
                            
                            let customAllergies = formState.allergies.filter { !allergiesList.contains($0) }.sorted()
                            if !customAllergies.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        Spacer().frame(width: 12)
                                        ForEach(customAllergies, id: \.self) { item in
                                            Button {
                                                withAnimation {
                                                    _ = formState.allergies.remove(item)
                                                }
                                            } label: {
                                                HStack(spacing: 6) {
                                                    Text(item)
                                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.system(size: 14))
                                                        .foregroundStyle(.white.opacity(0.8))
                                                }
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 10)
                                                .background(Color.red)
                                                .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        Spacer().frame(width: 12)
                                    }
                                }
                            }
                            
                            HStack(spacing: 12) {
                                ProfileTextField(
                                    placeholder: "Add a custom allergy...",
                                    text: $formState.customAllergyInput
                                )
                                
                                Button(action: {
                                    let input = formState.customAllergyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !input.isEmpty {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        let newItem = "🚫 " + input
                                        withAnimation {
                                            _ = formState.allergies.insert(newItem)
                                        }
                                        formState.customAllergyInput = ""
                                    }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(formState.customAllergyInput.isEmpty ? Color.gray.opacity(0.3) : Color.red)
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                        
                        ProfileMultiPreference(
                            title: "Macro Goals",
                            options: macrosList,
                            selected: $formState.macroTags
                        ) {
                            activeSheet = .macro
                        }
                    }
                }
                
                // SECTION 2: Physical Metrics & BMI
                AnimatedSection(isVisible: showSections[1]) {
                    VStack(alignment: .leading, spacing: 28) {
                        ProfileSectionHeader(title: "Body & Goals", icon: "figure.walk")
                        
                        VStack(spacing: 32) {
                            ProfileSlider(
                                title: "Age",
                                value: $formState.age,
                                range: 10...100,
                                format: "%.0f yrs"
                            ) {
                                activeSheet = .physical
                            }
                            
                            ProfileHeightSlider(
                                title: "Height",
                                inches: $formState.heightInches
                            ) {
                                activeSheet = .physical
                            }
                            
                            ProfileSlider(
                                title: "Weight",
                                value: $formState.weight,
                                range: 50...400,
                                format: "%.0f lbs"
                            ) {
                                activeSheet = .physical
                            }
                            
                            ProfileSinglePreference(
                                title: "Sex",
                                options: sexList,
                                selected: $formState.sex
                            ) {
                                activeSheet = .sex
                            }
                            
                            // Calculated BMI Card
                            HStack {
                                Text("Calculated BMI")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f", bmi))
                                    .font(.system(size: 18, weight: .heavy, design: .monospaced))
                                Text(bmiCategory)
                                    .font(.system(size: 14, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(bmiColor.opacity(0.15))
                                    .foregroundStyle(bmiColor)
                                    .clipShape(Capsule())
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            )
                            
                            // Estimated calories card
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Text("Recommended Daily Calories")
                                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                                .foregroundStyle(.secondary)
                                            
                                            Button(action: {
                                                activeSheet = .calories
                                            }) {
                                                Image(systemName: "info.circle.fill")
                                                    .foregroundStyle(Color.primary.opacity(0.4))
                                            }
                                        }
                                        
                                        Text("\(estimatedCalories) cal/day")
                                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                                            .foregroundStyle(.orange)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "flame.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.orange)
                                        .padding(14)
                                        .background(Color.orange.opacity(0.12))
                                        .clipShape(Circle())
                                }
                                
                                Text("This is a general recommendation based on your sex, age, height, weight, target goal, and activity level.")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.primary)
                                
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.yellow)
                                        .padding(.top, 2)
                                    
                                    Text("App recommendation only — please check with a registered dietitian or healthcare professional for personalized nutrition advice.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(3)
                                }
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            )
                        }
                        .padding(.horizontal, 24)
                        
                        ProfileSinglePreference(
                            title: "Target Goal",
                            options: goalsList,
                            selected: $formState.targetGoal
                        ) {
                            activeSheet = .goal
                        }
                        
                        ProfileSinglePreference(
                            title: "Activity Level",
                            options: activityList,
                            selected: $formState.activityLevel
                        ) {
                            activeSheet = .activity
                        }
                    }
                }
                
                // SECTION 3: Kitchen & Time
                AnimatedSection(isVisible: showSections[2]) {
                    VStack(alignment: .leading, spacing: 28) {
                        ProfileSectionHeader(title: "Kitchen & Time", icon: "timer")
                        
                        VStack(alignment: .leading, spacing: 12) {
                            ProfileMultiPreference(
                                title: "Appliances You Own",
                                options: appliancesList,
                                selected: $formState.appliances
                            ) {
                                activeSheet = .appliances
                            }
                            
                            let customAppliances = formState.appliances.filter { !appliancesList.contains($0) }.sorted()
                            if !customAppliances.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        Spacer().frame(width: 12)
                                        ForEach(customAppliances, id: \.self) { item in
                                            Button {
                                                withAnimation {
                                                    _ = formState.appliances.remove(item)
                                                }
                                            } label: {
                                                HStack(spacing: 6) {
                                                    Text(item)
                                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.system(size: 14))
                                                        .foregroundStyle(.white.opacity(0.8))
                                                }
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 10)
                                                .background(Color.green)
                                                .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        Spacer().frame(width: 12)
                                    }
                                }
                            }
                            
                            HStack(spacing: 12) {
                                ProfileTextField(
                                    placeholder: "Add a custom appliance...",
                                    text: $formState.customApplianceInput
                                )
                                
                                Button(action: {
                                    let input = formState.customApplianceInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !input.isEmpty {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        let newItem = "🔧 " + input
                                        withAnimation {
                                            _ = formState.appliances.insert(newItem)
                                        }
                                        formState.customApplianceInput = ""
                                    }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(formState.customApplianceInput.isEmpty ? Color.gray.opacity(0.3) : Color.green)
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                        
                        ProfileSinglePreference(
                            title: "Typical Cook Time",
                            options: cookTimesList,
                            selected: $formState.cookTime
                        ) {
                            activeSheet = .cookTime
                        }
                    }
                }
                
                // SECTION 4: Taste & Household
                AnimatedSection(isVisible: showSections[3]) {
                    VStack(alignment: .leading, spacing: 28) {
                        ProfileSectionHeader(title: "Taste & Household", icon: "fork.knife")
                        
                        // Cuisines Selection & Custom Entry
                        VStack(alignment: .leading, spacing: 12) {
                            ProfileMultiPreference(
                                title: "Favorite Cuisines",
                                options: cuisinesList,
                                selected: $formState.cuisines
                            ) {
                                activeSheet = .cuisines
                            }
                            
                            let customCuisines = formState.cuisines.filter { !cuisinesList.contains($0) }.sorted()
                            if !customCuisines.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        Spacer().frame(width: 12)
                                        ForEach(customCuisines, id: \.self) { item in
                                            Button {
                                                withAnimation {
                                                    _ = formState.cuisines.remove(item)
                                                }
                                            } label: {
                                                HStack(spacing: 6) {
                                                    Text(item)
                                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.system(size: 14))
                                                        .foregroundStyle(.white.opacity(0.8))
                                                }
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 10)
                                                .background(Color.green)
                                                .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        Spacer().frame(width: 12)
                                    }
                                }
                            }
                            
                            HStack(spacing: 12) {
                                ProfileTextField(
                                    placeholder: "Add a custom cuisine...",
                                    text: $formState.customCuisineInput
                                )
                                Button(action: {
                                    let input = formState.customCuisineInput.trimmingCharacters(in: .whitespaces)
                                    if !input.isEmpty {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        let newItem = "🍽️ " + input
                                        withAnimation {
                                            _ = formState.cuisines.insert(newItem)
                                        }
                                        formState.customCuisineInput = ""
                                    }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(formState.customCuisineInput.isEmpty ? Color.gray.opacity(0.3) : Color.green)
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                        
                        ProfileSinglePreference(
                            title: "Spice Tolerance",
                            options: spiceList,
                            selected: $formState.spiceTolerance
                        ) {
                            activeSheet = .spice
                        }
                        
                        // Ingredients to Avoid Custom Entry
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Ingredients to Avoid")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                Button(action: { activeSheet = .dislikes }) {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundStyle(Color.primary.opacity(0.4))
                                }
                            }
                            .padding(.horizontal, 24)
                            
                            if !formState.dislikesList.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        Spacer().frame(width: 12)
                                        ForEach(Array(formState.dislikesList).sorted(), id: \.self) { item in
                                            Button {
                                                withAnimation {
                                                    _ = formState.dislikesList.remove(item)
                                                }
                                            } label: {
                                                HStack(spacing: 6) {
                                                    Text(item)
                                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.system(size: 14))
                                                        .foregroundStyle(.white.opacity(0.8))
                                                }
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 10)
                                                .background(Color.red)
                                                .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        Spacer().frame(width: 12)
                                    }
                                }
                            }
                            
                            HStack(spacing: 12) {
                                ProfileTextField(
                                    placeholder: "e.g. Cilantro, Olives...",
                                    text: $formState.customDislikeInput
                                )
                                Button(action: {
                                    let input = formState.customDislikeInput.trimmingCharacters(in: .whitespaces)
                                    if !input.isEmpty {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        withAnimation {
                                            _ = formState.dislikesList.insert(input)
                                        }
                                        formState.customDislikeInput = ""
                                    }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 38))
                                        .foregroundStyle(formState.customDislikeInput.isEmpty ? Color.gray.opacity(0.3) : Color.red)
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                        
                        ProfileSinglePreference(
                            title: "Typical Serving Size",
                            options: servingsList,
                            selected: $formState.servingSize
                        ) {
                            activeSheet = .serving
                        }
                        
                        ProfileSinglePreference(
                            title: "Budget",
                            options: budgetList,
                            selected: $formState.budget
                        ) {
                            activeSheet = .budget
                        }
                    }
                }
                
                Spacer(minLength: 160)
            }
        }
        .onAppear {
            for i in 0..<showSections.count {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(i) * 0.15)) {
                    showSections[i] = true
                }
            }
        }
        .sheet(item: $activeSheet) { sheetType in
            SheetRouter(sheetType: sheetType)
        }
    }
}

// MARK: - UI Components & Data Lists

private let levelsList = ["🍳 Beginner", "👨‍🍳 Intermediate", "🔪 Advanced", "🌟 Masterchef"]
private let dietsList = ["🥗 Vegetarian", "🌿 Vegan", "🐟 Pescatarian", "🥩 Keto", "🍖 Paleo", "☪️ Halal", "✡️ Kosher"]
private let allergiesList = ["🥜 Peanuts", "🌳 Tree Nuts", "🥛 Dairy", "🥚 Eggs", "🦐 Shellfish", "🫘 Soy", "🌾 Gluten"]
private let macrosList = ["⚖️ Balanced", "💪 High Protein", "🔥 Low Calorie", "🍞 Low Carb"]
private let sexList = ["Male", "Female"]
private let goalsList = ["📉 Weight Loss", "⚖️ Maintain", "💪 Muscle Gain"]
private let activityList = ["🛋️ Sedentary", "🚶 Lightly Active", "🏃 Active", "🏋️ Athlete"]
private let appliancesList = ["♨️ Stove", "🍳 Oven", "🍚 Rice Cooker", "🌪️ Air Fryer", "🍲 Slow Cooker", "🥤 Blender", "🔪 Food Processor", "⏲️ Microwave", "🥘 Cast Iron"]
private let cookTimesList = ["⚡ < 15 mins", "⏱️ 15-30 mins", "⏳ 30-60 mins", "🕰️ 1 hr+"]
private let cuisinesList = ["🇮🇹 Italian", "🇲🇽 Mexican", "🇨🇳 Asian", "🇮🇳 Indian", "🇬🇷 Mediterranean", "🇺🇸 American"]
private let spiceList = ["🌿 Mild", "🌶️ Medium", "🔥 Spicy", "🌋 Extra Spicy"]
private let servingsList = ["👤 1 Person", "👥 2 People", "👨‍👩‍👧‍👦 3-4 People", "🏠 5+ People"]
private let budgetList = ["🪙 $ (Budget)", "💵 $$ (Standard)", "💰 $$$ (Gourmet)"]

private struct AnimatedSection<Content: View>: View {
    var isVisible: Bool
    @ViewBuilder var content: () -> Content
    
    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .opacity(isVisible ? 1.0 : 0.0)
        .offset(y: isVisible ? 0 : 30)
    }
}

private struct ProfileBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Circle()
                .fill(Color.orange.opacity(0.12))
                .blur(radius: 80)
                .offset(x: -150, y: -300)
            Circle()
                .fill(Color.green.opacity(0.1))
                .blur(radius: 80)
                .offset(x: 150, y: 300)
        }
    }
}

private struct ProfileSectionHeader: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack {
                Divider()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }
}

private struct ProfileTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    
    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(keyboardType)
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }
}

private struct ProfileSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    let onInfoTap: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                Button(action: onInfoTap) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.primary.opacity(0.4))
                }
                Spacer()
                Text(String(format: format, value))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            Slider(value: $value, in: range, step: 1.0).tint(.orange)
        }
    }
}

private struct ProfileHeightSlider: View {
    let title: String
    @Binding var inches: Double
    let onInfoTap: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                Button(action: onInfoTap) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.primary.opacity(0.4))
                }
                Spacer()
                Text("\(Int(inches) / 12) ft  \(Int(inches) % 12) in")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green)
            }
            Slider(value: $inches, in: 48...84, step: 1.0).tint(.green)
        }
    }
}

private struct ProfileSinglePreference: View {
    let title: String
    let options: [String]
    @Binding var selected: String
    var onInfoTap: (() -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
                if let onInfoTap = onInfoTap {
                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.primary.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 24)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Spacer().frame(width: 12)
                    ForEach(options, id: \.self) { option in
                        let isSelected = selected == option
                        Button {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selected = option
                            }
                        } label: {
                            Text(option)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(isSelected ? .white : .primary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .background(isSelected ? Color.orange : Color(.systemGray6))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer().frame(width: 12)
                }
            }
        }
        .padding(.bottom, 12)
    }
}

private struct ProfileMultiPreference: View {
    let title: String
    let options: [String]
    @Binding var selected: Set<String>
    var onInfoTap: (() -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
                if let onInfoTap = onInfoTap {
                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.primary.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 24)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Spacer().frame(width: 12)
                    ForEach(options, id: \.self) { option in
                        let isSelected = selected.contains(option)
                        Button {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                if isSelected {
                                    _ = selected.remove(option)
                                } else {
                                    _ = selected.insert(option)
                                }
                            }
                        } label: {
                            Text(option)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(isSelected ? .white : .primary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .background(isSelected ? Color.green : Color(.systemGray6))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer().frame(width: 12)
                }
            }
        }
        .padding(.bottom, 12)
    }
}

private struct ProfileSequentialIconView: View {
    let icons = ["slider.horizontal.3", "heart.circle.fill", "flame.fill"]
    @State private var currentIndex = 0
    @State private var isAnimating = false
    let timer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.orange.opacity(0.15), .green.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 180, height: 180)
                .scaleEffect(isAnimating ? 1.0 : 0.8)
            
            Image(systemName: icons[currentIndex])
                .font(.system(size: 70, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .green],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .scaleEffect(isAnimating ? 1.0 : 0.5)
                .opacity(isAnimating ? 1.0 : 0.0)
                .id(currentIndex)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) {
                isAnimating = true
            }
        }
        .onReceive(timer) { _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isAnimating = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    currentIndex = (currentIndex + 1) % icons.count
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) {
                        isAnimating = true
                    }
                }
            }
        }
    }
}

// MARK: - Detailed Info Sheets

private enum ActiveSheet: String, Identifiable {
    case level
    case diet
    case allergy
    case macro
    case physical
    case sex
    case calories
    case goal
    case activity
    case appliances
    case cookTime
    case cuisines
    case spice
    case dislikes
    case serving
    case budget
    
    var id: String { self.rawValue }
}

private struct SheetRouter: View {
    let sheetType: ActiveSheet
    
    var body: some View {
        switch sheetType {
        case .level:
            ProfileDetailedInfoSheet(title: "Chef Levels", subtitle: "Tell us your comfort level in the kitchen.", items: [
                ("🍳", "Beginner", "You need step-by-step help, clear instructions, and simple recipes."),
                ("👨‍🍳", "Intermediate", "Comfortable with basics and looking to expand your skills."),
                ("🔪", "Advanced", "Confident cook who handles complex techniques and timing."),
                ("🌟", "Masterchef", "An expert looking for culinary challenges and inspiration.")
            ])
            .presentationDetents([.fraction(0.55)])
            
        case .diet:
            ProfileDetailedInfoSheet(title: "Dietary Preferences", subtitle: "We filter out recipes that don't fit these rules.", items: [
                ("🥗", "Vegetarian", "No meat or poultry."),
                ("🌿", "Vegan", "No animal products whatsoever."),
                ("🐟", "Pescatarian", "Vegetarian plus seafood."),
                ("🥩", "Keto", "High fat, very low carb."),
                ("🍖", "Paleo", "Whole foods, no grains/dairy."),
                ("☪️", "Halal", "Prepared according to Islamic law."),
                ("✡️", "Kosher", "Prepared according to Jewish dietary laws.")
            ])
            .presentationDetents([.fraction(0.7)])
            
        case .allergy:
            ProfileDetailedInfoSheet(title: "Allergies", subtitle: "ChefBuddy will strictly exclude these ingredients.", items: [
                ("🥜", "Peanuts", "Avoids all peanut products."),
                ("🌳", "Tree Nuts", "Almonds, walnuts, pecans, etc."),
                ("🥛", "Dairy", "Milk, cheese, butter, yogurt."),
                ("🥚", "Eggs", "All egg products."),
                ("🦐", "Shellfish", "Shrimp, crab, lobster, etc."),
                ("🫘", "Soy", "Tofu, soy sauce, edamame."),
                ("🌾", "Gluten", "Wheat, barley, rye.")
            ])
            .presentationDetents([.fraction(0.7)])
            
        case .macro:
            ProfileDetailedInfoSheet(title: "Macro Goals", subtitle: "AI prioritizes recipes that fit your needs.", items: [
                ("⚖️", "Balanced", "A well-rounded ratio of proteins, fats, and carbs."),
                ("💪", "High Protein", "Prioritizes muscle growth and recovery."),
                ("🔥", "Low Calorie", "Focuses on meals for weight management."),
                ("🍞", "Low Carb", "Minimizes carbohydrates for specialized diets.")
            ])
            .presentationDetents([.fraction(0.55)])
            
        case .physical:
            ProfileSimpleInfoSheet(
                title: "Body Metrics",
                message: "We use your age, height, weight, sex, target goal, and activity level to estimate your daily calorie needs. BMI is shown as a simple weight-to-height ratio, and calorie needs are estimated separately using the Mifflin-St Jeor equation plus an activity multiplier."
            )
            .presentationDetents([.fraction(0.42)])
            
        case .sex:
            ProfileSimpleInfoSheet(
                title: "Sex",
                message: "Sex is included because the calorie estimate uses the Mifflin-St Jeor equation, which uses slightly different constants for male and female metabolism estimates."
            )
            .presentationDetents([.fraction(0.32)])
            
        case .calories:
            ProfileSimpleInfoSheet(
                title: "How Calories Are Calculated",
                message: "ChefBuddy first converts your weight from pounds to kilograms and your height from inches to centimeters. Then it estimates your BMR using the Mifflin-St Jeor equation: for Male, BMR = (10 × kg) + (6.25 × cm) − (5 × age) + 5. For Female, BMR = (10 × kg) + (6.25 × cm) − (5 × age) − 161. Then we multiply that BMR by your activity level: Sedentary = 1.2, Lightly Active = 1.375, Active = 1.55, Athlete = 1.725. Finally, we adjust for your goal: Weight Loss subtracts 400 calories, Maintain keeps it the same, and Muscle Gain adds 250 calories. This is only a general app estimate, not medical advice."
            )
            .presentationDetents([.fraction(0.62)])
            
        case .goal:
            ProfileDetailedInfoSheet(title: "Target Goal", subtitle: "Adjusts meal portions accordingly.", items: [
                ("📉", "Weight Loss", "Caloric deficit for shedding pounds."),
                ("⚖️", "Maintain", "Maintenance calories to stay exactly where you are."),
                ("💪", "Muscle Gain", "Caloric surplus focused on protein intake.")
            ])
            .presentationDetents([.fraction(0.45)])
            
        case .activity:
            ProfileDetailedInfoSheet(title: "Activity Level", subtitle: "Helps calculate daily energy expenditure.", items: [
                ("🛋️", "Sedentary", "Little to no exercise, desk job."),
                ("🚶", "Lightly Active", "Light exercise/sports 1-3 days a week."),
                ("🏃", "Active", "Moderate exercise/sports 3-5 days a week."),
                ("🏋️", "Athlete", "Hard exercise/sports 6-7 days a week.")
            ])
            .presentationDetents([.fraction(0.55)])
            
        case .appliances:
            ProfileDetailedInfoSheet(title: "Appliances", subtitle: "We'll only suggest meals you can actually cook.", items: [
                ("♨️", "Stove", "Standard stovetop cooking."),
                ("🍳", "Oven", "Baking and roasting."),
                ("🍚", "Rice Cooker", "Automated rice and grain cooking."),
                ("🌪️", "Air Fryer", "High-heat convection cooking."),
                ("🍲", "Slow Cooker", "Low-temperature, long-duration cooking."),
                ("🥤", "Blender", "Smoothies and purees."),
                ("🔪", "Food Processor", "Chopping and mixing dense ingredients."),
                ("⏲️", "Microwave", "Quick reheating and steaming."),
                ("🥘", "Cast Iron", "High-heat searing and stovetop-to-oven.")
            ])
            .presentationDetents([.fraction(0.85)])
            
        case .cookTime:
            ProfileDetailedInfoSheet(title: "Cook Time", subtitle: "How long do you want to spend?", items: [
                ("⚡", "< 15 mins", "Lightning fast, minimal prep."),
                ("⏱️", "15-30 mins", "Standard weeknight dinner."),
                ("⏳", "30-60 mins", "A bit more involved, great for weekends."),
                ("🕰️", "1 hr+", "Slow roasting, braising, or complex meals.")
            ])
            .presentationDetents([.fraction(0.55)])
            
        case .cuisines:
            ProfileSimpleInfoSheet(
                title: "Cuisines",
                message: "Select your favorite flavors, or add your own custom cuisines using the text box. We'll tailor recipe styles to match your cravings."
            )
            .presentationDetents([.fraction(0.35)])
            
        case .spice:
            ProfileDetailedInfoSheet(title: "Spice Tolerance", subtitle: "How much heat can you handle?", items: [
                ("🌿", "Mild", "No heat, focus on herbs and aromatics."),
                ("🌶️", "Medium", "A little kick, family-friendly."),
                ("🔥", "Spicy", "Noticeable burn, jalapeño level."),
                ("🌋", "Extra Spicy", "Bring on the habaneros and ghost peppers.")
            ])
            .presentationDetents([.fraction(0.55)])
            
        case .dislikes:
            ProfileSimpleInfoSheet(
                title: "Ingredients to Avoid",
                message: "Not an allergy, just a preference. If you hate cilantro or mushrooms, put them here and you won't see them in recipes."
            )
            .presentationDetents([.fraction(0.35)])
            
        case .serving:
            ProfileDetailedInfoSheet(title: "Serving Size", subtitle: "Auto-scales ingredient measurements.", items: [
                ("👤", "1 Person", "Single portions, minimal leftovers."),
                ("👥", "2 People", "Perfect for couples."),
                ("👨‍👩‍👧‍👦", "3-4 People", "Standard family dinners."),
                ("🏠", "5+ People", "Large batches and gatherings.")
            ])
            .presentationDetents([.fraction(0.55)])
            
        case .budget:
            ProfileDetailedInfoSheet(title: "Budget", subtitle: "Controls the cost of suggested ingredients.", items: [
                ("🪙", "$ (Budget)", "Affordable staples: beans, rice, chicken thighs."),
                ("💵", "$$ (Standard)", "Everyday grocery items."),
                ("💰", "$$$ (Gourmet)", "Premium cuts, saffron, fresh seafood.")
            ])
            .presentationDetents([.fraction(0.45)])
        }
    }
}

private struct ProfileDetailedInfoSheet: View {
    let title: String
    let subtitle: String?
    let items: [(String, String, String)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(items, id: \.1) { item in
                        HStack(alignment: .top, spacing: 16) {
                            Text(item.0).font(.title)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.1).font(.headline.bold())
                                Text(item.2)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(24)
        .padding(.top, 16)
        .presentationDragIndicator(.visible)
    }
}

private struct ProfileSimpleInfoSheet: View {
    let title: String
    let message: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
            }
            
            Text(message)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
            
            Spacer()
        }
        .padding(24)
        .padding(.top, 16)
        .presentationDragIndicator(.visible)
    }
}
