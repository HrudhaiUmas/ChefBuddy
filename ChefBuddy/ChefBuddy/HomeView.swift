//
//  HomeView.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/5/26.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseAILogic

struct SimplePantrySpace: Identifiable, Equatable {
    let id: String
    let name: String
    let emoji: String
    let ingredients: [String]
    let colorTheme: String
}

struct HomeView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @StateObject private var assistant = CookingAssistant()

    @State private var showDropdown = false
    @State private var showSettings = false
    @State private var appearAnimation = false
    @State private var showRecipePicker = false
    @State private var showVirtualPantry = false
    @State private var selectedLiveRecipe: Recipe? = nil
    @State private var showLiveCooking = false

    @State private var savedRecipes: [Recipe] = []
    @State private var dailyPrompt = "What are we cooking today? 🍳"

    @State private var isPantryEmpty = true
    @State private var availablePantries: [SimplePantrySpace] = []
    @State private var selectedPantryId: String? = nil
    @State private var isGeneratingFromPantry = false
    @State private var generatedPantryRecipes: [RecipeSuggestion]? = nil
    @State private var selectedGeneratedPantryRecipe: Recipe? = nil

    var displayName: String {
        if let name = authVM.userSession?.displayName, !name.isEmpty {
            return String(name.split(separator: " ").first ?? "")
        } else if let email = authVM.userSession?.email {
            return String(email.split(separator: "@").first ?? "Chef")
        }
        return "Chef"
    }

    var timeBasedGreeting: String {
        let date = Date()
        let hour = Calendar.current.component(.hour, from: date)
        let minute = Calendar.current.component(.minute, from: date)

        switch (hour, minute) {
        case (0...2, _), (3, 0...30):
            return [
                "Midnight munchies, \(displayName)? 🦉",
                "Late night cravings, \(displayName)? 🌙",
                "Fueling the midnight oil, \(displayName)? 🍜"
            ].randomElement() ?? "Late night snack, \(displayName)?"
        case (3...11, _):
            return [
                "Rise and shine, Chef \(displayName)! 🍳",
                "Let's get this bread, \(displayName). 🍞",
                "Time to fuel up for the day, \(displayName). ☕️"
            ].randomElement() ?? "Good morning, \(displayName)!"
        case (12...16, _):
            return [
                "Lunchtime cravings, \(displayName)? 🌮",
                "Midday fuel, \(displayName)? 🥗",
                "Let’s cook up a midday masterpiece, \(displayName). 🧑‍🍳"
            ].randomElement() ?? "Good afternoon, \(displayName)!"
        default:
            return [
                "What's on the dinner menu, \(displayName)? 🥘",
                "Time to unwind and dine, \(displayName). 🍽️",
                "Let's cook up something cozy tonight, \(displayName). 🍲"
            ].randomElement() ?? "Good evening, \(displayName)!"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .blur(radius: 70)
                        .offset(x: -120, y: -250)

                    Circle()
                        .fill(Color.green.opacity(0.1))
                        .blur(radius: 70)
                        .offset(x: 120, y: 250)
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {

                        VStack(alignment: .leading, spacing: 4) {
                            Text(timeBasedGreeting)
                                .font(.system(size: 34, weight: .bold, design: .rounded))

                            Text(dailyPrompt)
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 60)
                        .padding(.horizontal, 24)
                        .offset(y: appearAnimation ? 0 : 15)
                        .opacity(appearAnimation ? 1.0 : 0)

                        Button(action: { showVirtualPantry = true }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    if isPantryEmpty {
                                        Text("Crickets in the Kitchen? 🦗")
                                            .font(.headline)

                                        Text("A virtual pantry lets you track ingredients to craft recipes with what you have. Scan your fridge to stock up!")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    } else {
                                        Text("View Virtual Pantry")
                                            .font(.headline)

                                        Text("Craft recipes with what you have. Check your available ingredients or add more to your virtual shelves.")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                }

                                Spacer()

                                Image(systemName: isPantryEmpty ? "camera.viewfinder" : "basket.fill")
                                    .font(.title)
                                    .foregroundStyle(.orange)
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .offset(y: appearAnimation ? 0 : 15)
                        .opacity(appearAnimation ? 1.0 : 0)

                        VStack(alignment: .leading, spacing: 16) {
                            RecipesView(assistant: assistant)
                                .environmentObject(authVM)
                        }
                        .offset(y: appearAnimation ? 0 : 20)
                        .opacity(appearAnimation ? 1.0 : 0)

                        pantryAISection
                            .offset(y: appearAnimation ? 0 : 20)
                            .opacity(appearAnimation ? 1.0 : 0)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Assistance & Tools")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .padding(.horizontal, 24)

                            Button(action: { showRecipePicker = true }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Live Cooking Help")
                                            .font(.headline)

                                        Text("Pick a recipe — AI guides you step by step.")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }

                                    Spacer()

                                    Image(systemName: "video.fill")
                                        .font(.title)
                                        .foregroundStyle(.green)
                                }
                                .padding()
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24)
                                        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 24)

                            HStack(spacing: 12) {
                                ToolButton(icon: "calendar", title: "Meal Plan", color: .green)
                                ToolButton(icon: "cart.fill", title: "Grocery List", color: .orange)
                            }
                            .padding(.horizontal, 24)
                        }
                        .offset(y: appearAnimation ? 0 : 25)
                        .opacity(appearAnimation ? 1.0 : 0)

                        Spacer(minLength: 100)
                    }
                }

                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        showDropdown.toggle()
                    }
                }) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .green],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .padding(4)
                        .background(Circle().fill(.ultraThinMaterial))
                        .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                if showDropdown {
                    DropdownOverlay(
                        showDropdown: $showDropdown,
                        showSettings: $showSettings,
                        showRecipePicker: $showRecipePicker,
                        authVM: authVM
                    )
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                            removal: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity)
                        )
                    )
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                ProfileSettingsView().environmentObject(authVM)
            }
            .navigationDestination(isPresented: $showVirtualPantry) {
                VirtualPantryView(assistant: assistant)
                    .environmentObject(authVM)
            }
            .sheet(isPresented: $showRecipePicker) {
                RecipePickerSheet(recipes: savedRecipes) { recipe in
                    selectedLiveRecipe = recipe
                    showLiveCooking = true
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showLiveCooking) {
                if let recipe = selectedLiveRecipe,
                   let uid = authVM.userSession?.uid {
                    LiveCookingView(recipe: recipe, assistant: assistant, userId: uid)
                }
            }
            .sheet(item: $selectedGeneratedPantryRecipe) { recipe in
                SuggestedRecipeDetailView(
                    recipe: recipe,
                    onSave: {
                        saveGeneratedPantryRecipe(recipe)

                        if let pantry = availablePantries.first(where: { $0.id == selectedPantryId }) {
                            removeAndReplaceSavedPantryRecipe(recipe, pantry: pantry)
                        }

                        selectedGeneratedPantryRecipe = nil
                    }
                )
            }
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                    appearAnimation = true
                }

                setupDynamicPrompts()

                if let uid = authVM.userSession?.uid {
                    Task {
                        await assistant.setupAssistant(userId: uid)
                    }

                    let userDocRef = Firestore.firestore().collection("users").document(uid)

                    userDocRef.collection("recipes")
                        .order(by: "createdAt", descending: true)
                        .addSnapshotListener { snap, _ in
                            guard let docs = snap?.documents else { return }
                            savedRecipes = docs.compactMap { try? $0.data(as: Recipe.self) }
                        }

                    userDocRef.collection("pantrySpaces")
                        .addSnapshotListener { snap, _ in
                            guard let docs = snap?.documents else { return }

                            var newPantries: [SimplePantrySpace] = []
                            var allEmpty = true

                            for doc in docs {
                                let data = doc.data()
                                let name = data["name"] as? String ?? "Pantry"
                                let emoji = data["emoji"] as? String ?? "🥑"
                                let color = data["colorTheme"] as? String ?? "Orange"
                                let pantryDict = data["virtualPantry"] as? [String: [String]] ?? [:]

                                let allIngredients = pantryDict.values.flatMap { $0 }
                                if !allIngredients.isEmpty {
                                    allEmpty = false
                                }

                                newPantries.append(
                                    SimplePantrySpace(
                                        id: doc.documentID,
                                        name: name,
                                        emoji: emoji,
                                        ingredients: allIngredients,
                                        colorTheme: color
                                    )
                                )
                            }

                            self.availablePantries = newPantries.sorted { $0.name < $1.name }
                            self.isPantryEmpty = allEmpty

                            if selectedPantryId == nil, let first = self.availablePantries.first {
                                selectedPantryId = first.id
                            }
                        }
                }
            }
        }
    }

    private var pantryAISection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pantry Suggestions")
                    .font(.system(size: 20, weight: .bold, design: .rounded))

                Spacer()

                if availablePantries.count > 1 {
                    Menu {
                        ForEach(availablePantries) { space in
                            Button {
                                withAnimation(.spring()) {
                                    selectedPantryId = space.id
                                    generatedPantryRecipes = nil
                                }
                            } label: {
                                HStack {
                                    Text("\(space.emoji) \(space.name)")
                                    if selectedPantryId == space.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        if let selected = availablePantries.first(where: { $0.id == selectedPantryId }) {
                            HStack(spacing: 4) {
                                Text("\(selected.emoji) \(selected.name)")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)

                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08))
                            .foregroundStyle(.primary)
                            .clipShape(Capsule())
                        }
                    }
                } else if let single = availablePantries.first {
                    HStack(spacing: 4) {
                        Text(single.emoji)
                        Text(single.name)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)

            if availablePantries.isEmpty {
                Text("Set up your virtual pantry to unlock AI recipes based on what you own.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            } else if let currentPantry = availablePantries.first(where: { $0.id == selectedPantryId }) {
                if currentPantry.ingredients.isEmpty {
                    Text("\(currentPantry.name) is empty. Add ingredients to get tailored suggestions.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                } else {
                    if isGeneratingFromPantry {
                        PantryRecipeLoadingView()
                            .padding(.horizontal, 24)
                    } else if let recipes = generatedPantryRecipes {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(recipes) { recipe in
                                    PantryRecipeCard(recipe: recipe) {
                                        var adapted = Recipe(
                                            title: recipe.title,
                                            emoji: recipe.emoji,
                                            description: recipe.description,
                                            ingredients: recipe.ingredients,
                                            steps: recipe.steps,
                                            cookTime: recipe.prepTime,
                                            servings: recipe.servings,
                                            difficulty: recipe.difficulty,
                                            tags: recipe.tags,
                                            calories: recipe.calories,
                                            nutrition: recipe.nutrition,
                                            createdAt: Date()
                                        )

                                        adapted.id = UUID().uuidString
                                        selectedGeneratedPantryRecipe = adapted
                                    }
                                }

                                if recipes.count < 3 {
                                    PantryCardLoadingView()
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    } else {
                        Button(action: {
                            generateFromSelectedPantry(ingredients: currentPantry.ingredients)
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Craft a Meal")
                                        .font(.headline)

                                    Text("You have \(currentPantry.ingredients.count) ingredients. Tap to let ChefBuddy build recipes using them.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }

                                Spacer()

                                ZStack {
                                    Circle()
                                        .fill(Color.orange.opacity(0.15))
                                        .frame(width: 44, height: 44)

                                    Image(systemName: "sparkles")
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                    }
                }
            }
        }
    }

    private func saveGeneratedPantryRecipe(_ recipe: Recipe) {
        guard let uid = authVM.userSession?.uid else { return }

        do {
            let encoded = try Firestore.Encoder().encode(recipe)

            Firestore.firestore()
                .collection("users")
                .document(uid)
                .collection("recipes")
                .addDocument(data: encoded)

            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            print("Error saving pantry generated recipe: \(error)")
        }
    }

    private func removeAndReplaceSavedPantryRecipe(_ recipe: Recipe, pantry: SimplePantrySpace) {
        withAnimation(.spring()) {
            generatedPantryRecipes?.removeAll(where: { $0.title == recipe.title })
        }

        Task {
            do {
                guard let model = assistant.model else { return }

                let existingTitles = generatedPantryRecipes?.map { $0.title } ?? []

                let ingredientList = pantry.ingredients.map { item -> String in
                    let parts = item.split(separator: " ", maxSplits: 1)
                    return parts.count == 2 ? String(parts[1]) : item
                }
                .joined(separator: ", ")

                let prompt = """
                Create exactly 1 fully detailed recipe using ONLY the following ingredients from my pantry:
                \(ingredientList)

                The recipe title MUST be different from all of these existing titles:
                \(existingTitles.joined(separator: ", "))

                Return ONLY a valid JSON object (not an array) matching this exact format:
                {
                  "title": "Recipe name",
                  "emoji": "🥗",
                  "description": "...",
                  "prepTime": "...",
                  "servings": "...",
                  "difficulty": "...",
                  "calories": "...",
                  "carbs": "...",
                  "protein": "...",
                  "fat": "...",
                  "saturatedFat": "...",
                  "sugar": "...",
                  "fiber": "...",
                  "sodium": "...",
                  "tags": [],
                  "ingredients": [],
                  "steps": [],
                  "matchReason": "..."
                }

                Rules:
                - ingredients must be a JSON array of plain strings only
                - steps must be a JSON array of plain strings only
                - tags must be a JSON array of plain strings only
                - do not return dictionaries inside ingredients or steps
                - do not include markdown
                - do not include backticks
                """

                let response = try await model.generateContent(prompt)
                let rawText = response.text ?? ""

                var jsonString = rawText
                    .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if let start = jsonString.firstIndex(of: "{"),
                   let end = jsonString.lastIndex(of: "}") {
                    jsonString = String(jsonString[start...end])
                }

                guard let data = jsonString.data(using: .utf8) else { return }
                let newRecipe = try JSONDecoder().decode(RecipeSuggestion.self, from: data)

                await MainActor.run {
                    withAnimation(.spring()) {
                        self.generatedPantryRecipes?.append(newRecipe)
                    }
                }
            } catch {
                print("Failed to fetch replacement recipe: \(error)")
            }
        }
    }

    private func generateFromSelectedPantry(ingredients: [String]) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        withAnimation(.spring()) {
            isGeneratingFromPantry = true
        }

        Task {
            do {
                let generated = try await assistant.generatePantryRecipes(ingredients: ingredients)

                await MainActor.run {
                    withAnimation(.spring()) {
                        self.generatedPantryRecipes = generated
                        self.isGeneratingFromPantry = false
                    }
                }
            } catch {
                print("Failed to generate: \(error)")

                await MainActor.run {
                    withAnimation {
                        isGeneratingFromPantry = false
                    }
                }
            }
        }
    }

    private func setupDynamicPrompts() {
        let prompts = [
            "Ready to whip up something tasty? 🍳",
            "What's on the menu today? 🌮",
            "Time to make some magic in the kitchen! ✨",
            "Let's cook up a storm! 🌪️",
            "Hungry for something new? 🤤",
            "Grab your apron, it's cooking time! 👨‍🍳"
        ]

        dailyPrompt = prompts.randomElement() ?? prompts[0]
    }
}

// MARK: - Subviews

struct PantryRecipeLoadingView: View {
    @State private var scanAnimationStep: Int = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.18), Color.pink.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)

                Text("🍳")
                    .font(.system(size: 28))
                    .scaleEffect(scanAnimationStep % 2 == 0 ? 1.0 : 1.08)
                    .animation(.spring(response: 0.35, dampingFraction: 0.65), value: scanAnimationStep)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("ChefBuddy is cooking...")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Text("Crafting recipes from your pantry...")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 5) {
                    Text("Generating")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HomeBouncingDotsView(step: scanAnimationStep, color: .orange)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.orange.opacity(0.16), lineWidth: 1)
        )
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                scanAnimationStep += 1
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
}

struct PantryCardLoadingView: View {
    @State private var scanAnimationStep: Int = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [Color.orange.opacity(0.18), Color.green.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Text("🍳")
                    .font(.system(size: 40))
                    .scaleEffect(scanAnimationStep % 2 == 0 ? 1.0 : 1.08)
                    .animation(.spring(response: 0.35, dampingFraction: 0.65), value: scanAnimationStep)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("ChefBuddy is cooking...")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text("Crafting recipes from your pantry...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text("Generating")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)

                    HomeBouncingDotsView(step: scanAnimationStep, color: .orange)
                }
            }
            .padding(12)
        }
        .frame(width: 200)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                scanAnimationStep += 1
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
}

struct HomeBouncingDotsView: View {
    let step: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index <= (step % 3) ? color : Color.gray.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .offset(y: index == (step % 3) ? -2 : 0)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }
}

struct PantryRecipeCard: View {
    let recipe: RecipeSuggestion
    let onTap: () -> Void

    var difficultyColor: Color {
        switch recipe.difficulty.lowercased() {
        case "easy":
            return .green
        case "hard":
            return .red
        default:
            return .orange
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    LinearGradient(
                        colors: [Color.orange.opacity(0.12), Color.green.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    Text(recipe.emoji)
                        .font(.system(size: 52))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(recipe.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        RecipeMiniStatPill(
                            icon: "clock",
                            text: recipe.prepTime,
                            foreground: .orange,
                            background: Color.orange.opacity(0.12)
                        )

                        RecipeMiniStatPill(
                            icon: "person.2",
                            text: recipe.servings,
                            foreground: .blue,
                            background: Color.blue.opacity(0.12)
                        )
                    }

                    HStack(spacing: 8) {
                        RecipeMiniStatPill(
                            icon: "flame",
                            text: recipe.calories,
                            foreground: .red,
                            background: Color.red.opacity(0.12)
                        )

                        Text(recipe.difficulty)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(difficultyColor)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(difficultyColor.opacity(0.12))
                            .clipShape(Capsule())
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 0)
                    }

                    if !recipe.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(recipe.tags.prefix(3), id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.green)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color.green.opacity(0.12))
                                        .clipShape(Capsule())
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(width: 220)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

struct RecipeMiniStatPill: View {
    let icon: String
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))

            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(background)
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct ToolButton: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

struct DropdownOverlay: View {
    @Binding var showDropdown: Bool
    @Binding var showSettings: Bool
    @Binding var showRecipePicker: Bool
    let authVM: AuthViewModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        showDropdown = false
                    }
                }

            VStack(alignment: .leading, spacing: 12) {
                MenuRow(icon: "video.fill", title: "Live Help", color: .orange) {
                    showDropdown = false
                    showRecipePicker = true
                }

                Divider().padding(.horizontal, 16)

                MenuRow(icon: "slider.horizontal.3", title: "Profile") {
                    showDropdown = false
                    showSettings = true
                }

                Divider().padding(.horizontal, 16)

                MenuRow(icon: "arrow.right.square", title: "Log Out", color: .red) {
                    showDropdown = false
                    authVM.signOut()
                }
            }
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 15, y: 10)
            .frame(width: 200)
            .padding(.trailing, 24)
            .padding(.top, 60)
        }
    }
}

struct MenuRow: View {
    let icon: String
    let title: String
    var color: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 24)

                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))

                Spacer()
            }
            .foregroundStyle(color)
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
