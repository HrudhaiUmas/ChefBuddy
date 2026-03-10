//
//  RecipesView.swift
//  ChefBuddy
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import Combine

// MARK: - Model

struct NutritionInfo: Codable, Equatable {
    var calories: String   // total kcal (mirrors Recipe.calories for convenience)
    var carbs: String      // e.g. "42g"
    var protein: String    // e.g. "35g"
    var fat: String        // e.g. "12g"
    var saturatedFat: String // e.g. "4g"
    var sugar: String      // e.g. "8g"
    var fiber: String      // e.g. "5g"
    var sodium: String     // e.g. "620mg"

    static var empty: NutritionInfo {
        NutritionInfo(calories: "", carbs: "", protein: "", fat: "",
                      saturatedFat: "", sugar: "", fiber: "", sodium: "")
    }
}

struct Recipe: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var title: String
    var emoji: String
    var description: String
    var ingredients: [String]
    var steps: [String]
    var cookTime: String
    var servings: String
    var difficulty: String
    var tags: [String]
    var calories: String
    var nutrition: NutritionInfo
    var createdAt: Date
    var isFavorite: Bool
    // Cooking history
    var cookedCount: Int
    var lastCookedAt: Date?

    init(
        title: String,
        emoji: String = "🍽️",
        description: String,
        ingredients: [String],
        steps: [String],
        cookTime: String,
        servings: String,
        difficulty: String,
        tags: [String] = [],
        calories: String = "",
        nutrition: NutritionInfo = .empty,
        createdAt: Date = Date(),
        isFavorite: Bool = false,
        cookedCount: Int = 0,
        lastCookedAt: Date? = nil
    ) {
        self.title = title
        self.emoji = emoji
        self.description = description
        self.ingredients = ingredients
        self.steps = steps
        self.cookTime = cookTime
        self.servings = servings
        self.difficulty = difficulty
        self.tags = tags
        self.calories = calories
        self.nutrition = nutrition
        self.createdAt = createdAt
        self.isFavorite = isFavorite
        self.cookedCount = cookedCount
        self.lastCookedAt = lastCookedAt
    }

    var hasBeenCooked: Bool { cookedCount > 0 }
}

func detectedCuisineTag(title: String, description: String, tags: [String]) -> String {
    let knownCuisines = [
        "Italian", "Mexican", "Indian", "Chinese", "Japanese", "Thai",
        "Mediterranean", "Korean", "Vietnamese", "Greek", "American",
        "French", "Spanish", "Middle Eastern"
    ]

    for cuisine in knownCuisines {
        if tags.contains(where: { $0.localizedCaseInsensitiveContains(cuisine) }) {
            return cuisine
        }
    }

    let text = "\(title) \(description)".lowercased()
    let keywordMap: [(String, [String])] = [
        ("Italian", ["pasta", "risotto", "marinara", "alfredo"]),
        ("Mexican", ["taco", "burrito", "enchilada", "salsa"]),
        ("Indian", ["curry", "masala", "paneer", "dal", "tikka"]),
        ("Chinese", ["stir-fry", "fried rice", "noodle", "wok"]),
        ("Japanese", ["teriyaki", "ramen", "miso", "sushi"]),
        ("Thai", ["pad thai", "thai", "lemongrass"]),
        ("Mediterranean", ["mediterranean", "hummus", "tzatziki"]),
        ("Korean", ["kimchi", "gochujang", "bulgogi"]),
        ("Vietnamese", ["pho", "banh mi"]),
        ("Greek", ["gyro", "feta", "greek"]),
        ("Middle Eastern", ["falafel", "shawarma", "tahini"])
    ]

    for (cuisine, keywords) in keywordMap where keywords.contains(where: { text.contains($0) }) {
        return cuisine
    }

    return "Fusion"
}

// MARK: - ViewModel

class RecipesViewModel: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var isGenerating = false
    @Published var errorMessage: String? = nil
    @Published var selectedFilter = "All"
    @Published var justGeneratedRecipe: Recipe? = nil
    @Published var elapsedSeconds: Int = 0

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var timerTask: Task<Void, Never>? = nil

    let filters = ["All", "❤️ Saved", "✅ Cooked", "⚡ Quick", "💪 Protein", "🥗 Healthy"]

    var filteredRecipes: [Recipe] {
        switch selectedFilter {
        case "❤️ Saved":
            return recipes.filter { $0.isFavorite }
        case "✅ Cooked":
            return recipes.filter { $0.hasBeenCooked }
        case "⚡ Quick":
            return recipes.filter {
                $0.cookTime.contains("15") || $0.cookTime.lowercased().contains("quick")
            }
        case "💪 Protein":
            return recipes.filter {
                $0.tags.contains(where: { $0.lowercased().contains("protein") })
            }
        case "🥗 Healthy":
            return recipes.filter {
                $0.tags.contains(where: {
                    $0.lowercased().contains("healthy") || $0.lowercased().contains("low cal")
                })
            }
        default:
            return recipes
        }
    }

    var previewRecipes: [Recipe] {
        Array(filteredRecipes.prefix(4))
    }

    func startListening(userId: String) {
        guard !userId.isEmpty else { return }

        listener?.remove()
        listener = db.collection("users")
            .document(userId)
            .collection("recipes")
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { [weak self] snap, _ in
                guard let docs = snap?.documents else { return }

                DispatchQueue.main.async {
                    self?.recipes = docs.compactMap { try? $0.data(as: Recipe.self) }
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    func autoGenerateIfNeeded(assistant: CookingAssistant, userId: String) {
        guard recipes.count < 3, !isGenerating, !userId.isEmpty else { return }

        db.collection("users").document(userId).getDocument { [weak self] snap, _ in
            guard let self = self else { return }

            let data = snap?.data() ?? [:]

            let diets = (data["dietTags"] as? [String])?.joined(separator: ", ") ?? ""
            let allergies = (data["allergies"] as? [String])?.joined(separator: ", ") ?? ""
            let macros = (data["macroTags"] as? [String])?.joined(separator: ", ") ?? ""
            let spice = data["spiceTolerance"] as? String ?? "Medium"
            let cookTime = data["cookTime"] as? String ?? "30 mins"
            let budget = data["budget"] as? String ?? "Standard"
            let servings = data["servingSize"] as? String ?? "1 Person"
            let cuisines = (data["cuisines"] as? [String])?.joined(separator: ", ") ?? ""
            let appliances = (data["appliances"] as? [String])?.joined(separator: ", ") ?? "basic kitchen tools"
            let goal = data["targetGoal"] as? String ?? "Maintain"
            let dislikes = data["dislikes"] as? String ?? ""

            var ctx = ""
            if !diets.isEmpty { ctx += "Diet: \(diets). " }
            if !allergies.isEmpty { ctx += "Allergies to avoid: \(allergies). " }
            if !macros.isEmpty { ctx += "Macro goal: \(macros). " }
            if !cuisines.isEmpty { ctx += "Preferred cuisines: \(cuisines). " }
            if !dislikes.isEmpty { ctx += "Ingredients to avoid: \(dislikes). " }

            ctx += "Spice tolerance: \(spice). Cook time: \(cookTime). Budget: \(budget). Serving size: \(servings). Goal: \(goal). Available appliances: \(appliances)."

            let starterPrompts = [
                "A delicious \(cookTime) dinner that fits these preferences — \(ctx)",
                "A nutritious breakfast or lunch using these preferences — \(ctx)",
                "A crowd-pleasing meal that matches these tastes — \(ctx)"
            ]

            let prompt = starterPrompts[min(self.recipes.count, starterPrompts.count - 1)]

            DispatchQueue.main.async {
                self.generateAndSave(prompt: prompt, assistant: assistant, userId: userId)
            }
        }
    }

    func toggleFavorite(_ recipe: Recipe, userId: String) {
        guard let id = recipe.id, !userId.isEmpty else { return }
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return }

        let newValue = !recipes[index].isFavorite

        recipes[index].isFavorite = newValue

        db.collection("users")
            .document(userId)
            .collection("recipes")
            .document(id)
            .updateData(["isFavorite": newValue]) { [weak self] error in
                if let error = error {
                    DispatchQueue.main.async {
                        guard let self = self,
                              let rollbackIndex = self.recipes.firstIndex(where: { $0.id == id }) else { return }

                        self.recipes[rollbackIndex].isFavorite.toggle()
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
    }

    func deleteRecipe(_ recipe: Recipe, userId: String) {
        guard let id = recipe.id, !userId.isEmpty else { return }

        db.collection("users")
            .document(userId)
            .collection("recipes")
            .document(id)
            .delete()
    }

    func markAsCooked(_ recipe: Recipe, userId: String) {
        guard let id = recipe.id, !userId.isEmpty else { return }
        let newCount = recipe.cookedCount + 1
        let now = Date()
        // Update local array immediately so UI reacts without waiting for Firestore
        if let idx = recipes.firstIndex(where: { $0.id == id }) {
            recipes[idx].cookedCount = newCount
            recipes[idx].lastCookedAt = now
        }
        db.collection("users").document(userId).collection("recipes").document(id)
            .updateData(["cookedCount": newCount, "lastCookedAt": now])
    }

    func updateRecipeAfterReview(_ updatedRecipe: Recipe, userId: String) {
        guard let id = updatedRecipe.id, !userId.isEmpty else { return }
        // Ensure cookedCount is reflected in local array too
        if let idx = recipes.firstIndex(where: { $0.id == id }) {
            recipes[idx] = updatedRecipe
        }
        guard let encoded = try? Firestore.Encoder().encode(updatedRecipe) else { return }
        db.collection("users").document(userId).collection("recipes").document(id).setData(encoded)
    }

    func saveReview(recipeId: String, liked: [String], likedNote: String, improvement: String, userId: String) {
        guard !userId.isEmpty else { return }
        let data: [String: Any] = [
            "likedTags": liked,
            "likedNote": likedNote,
            "improvement": improvement,
            "createdAt": Date()
        ]
        db.collection("users").document(userId).collection("recipes").document(recipeId)
            .collection("reviews").addDocument(data: data)
    }

    func saveSuggestedRecipe(_ recipe: Recipe, userId: String) {
        guard !userId.isEmpty else { return }

        Task {
            do {
                let encoded = try Firestore.Encoder().encode(recipe)
                let ref = try await db.collection("users")
                    .document(userId)
                    .collection("recipes")
                    .addDocument(data: encoded)

                var savedRecipe = recipe
                savedRecipe.id = ref.documentID

                await MainActor.run {
                    self.justGeneratedRecipe = savedRecipe
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    print("Save suggested recipe error: \(error)")
                }
            }
        }
    }

    func generateAndSave(prompt: String, assistant: CookingAssistant, userId: String) {
        guard !userId.isEmpty else { return }

        isGenerating = true
        elapsedSeconds = 0
        errorMessage = nil
        justGeneratedRecipe = nil

        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self.elapsedSeconds += 1
                }
            }
        }

        Task {
            do {
                try await assistant.waitUntilReady()

                let fullPrompt = """
                Generate a recipe based on: \(prompt)

                Respond ONLY in this exact format, no extra text:
                Title: [recipe name]
                Emoji: [single relevant emoji]
                Description: [one sentence about the dish]
                Cook Time: [e.g. 25 mins]
                Servings: [e.g. 2 people]
                Difficulty: [Easy / Medium / Hard]
                Calories: [e.g. 420 kcal]
                Carbs: [e.g. 42g]
                Protein: [e.g. 35g]
                Fat: [e.g. 12g]
                Saturated Fat: [e.g. 4g]
                Sugar: [e.g. 8g]
                Fiber: [e.g. 5g]
                Sodium: [e.g. 620mg]
                Tags: [comma-separated, e.g. High Protein, Healthy, Quick]

                Ingredients:
                - [ingredient 1]
                - [ingredient 2]

                Instructions:
                1. [step one]
                2. [step two]

                Rules for quality:
                - ingredients must include concrete amounts/units (e.g., "1 tbsp olive oil", "200g tofu")
                - instructions must be detailed, precise, and beginner-friendly
                - include prep details where relevant (washing, peeling, dicing, preheating, marinating)
                - include doneness cues and timing checkpoints (e.g., "cook until translucent, 3-4 mins")
                - never skip important food safety or preparation steps
                - include at least one cuisine tag in Tags
                """

                let raw = try await assistant.getHelp(question: fullPrompt)

                var recipe = RecipesViewModel.parseRecipe(from: raw)

                let encoded = try Firestore.Encoder().encode(recipe)
                let ref = try await db.collection("users")
                    .document(userId)
                    .collection("recipes")
                    .addDocument(data: encoded)

                recipe.id = ref.documentID

                await MainActor.run {
                    self.timerTask?.cancel()
                    self.isGenerating = false
                    self.justGeneratedRecipe = recipe
                }
            } catch {
                await MainActor.run {
                    self.timerTask?.cancel()
                    self.isGenerating = false
                    self.errorMessage = error.localizedDescription
                    print("Generation error: \(error)")
                }
            }
        }
    }

    static func parseRecipe(from text: String) -> Recipe {
        var title = "New Recipe"
        var emoji = "🍽️"
        var description = ""
        var ingredients: [String] = []
        var steps: [String] = []
        var cookTime = "30 mins"
        var servings = "2 people"
        var difficulty = "Medium"
        var tags: [String] = []
        var calories = ""
        var carbs = ""
        var protein = ""
        var fat = ""
        var saturatedFat = ""
        var sugar = ""
        var fiber = ""
        var sodium = ""
        var section = ""

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let low = line.lowercased()

            if low.hasPrefix("title:") {
                title = after("Title:", in: line)
            } else if low.hasPrefix("emoji:") {
                emoji = after("Emoji:", in: line)
            } else if low.hasPrefix("description:") {
                description = after("Description:", in: line)
            } else if low.hasPrefix("cook time:") {
                cookTime = after("Cook Time:", in: line)
            } else if low.hasPrefix("servings:") {
                servings = after("Servings:", in: line)
            } else if low.hasPrefix("difficulty:") {
                difficulty = after("Difficulty:", in: line)
            } else if low.hasPrefix("calories:") {
                calories = after("Calories:", in: line)
            } else if low.hasPrefix("carbs:") || low.hasPrefix("carbohydrates:") {
                carbs = after(low.hasPrefix("carbs:") ? "Carbs:" : "Carbohydrates:", in: line)
            } else if low.hasPrefix("protein:") {
                protein = after("Protein:", in: line)
            } else if low.hasPrefix("saturated fat:") {
                saturatedFat = after("Saturated Fat:", in: line)
            } else if low.hasPrefix("fat:") {
                fat = after("Fat:", in: line)
            } else if low.hasPrefix("sugar:") {
                sugar = after("Sugar:", in: line)
            } else if low.hasPrefix("fiber:") || low.hasPrefix("fibre:") {
                fiber = after(low.hasPrefix("fiber:") ? "Fiber:" : "Fibre:", in: line)
            } else if low.hasPrefix("sodium:") {
                sodium = after("Sodium:", in: line)
            } else if low.hasPrefix("tags:") {
                tags = after("Tags:", in: line)
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if low.contains("ingredient") {
                section = "ingredients"
            } else if low.contains("instruction") || low.contains("direction") {
                section = "steps"
            } else if line.hasPrefix("-") || line.hasPrefix("•") {
                let item = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty {
                    if section == "steps" {
                        steps.append(item)
                    } else {
                        ingredients.append(item)
                    }
                }
            } else if let first = line.first, first.isNumber, line.count > 2 {
                let secondIdx = line.index(line.startIndex, offsetBy: 1)
                if line[secondIdx] == "." {
                    let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !item.isEmpty && section == "steps" {
                        steps.append(item)
                    }
                }
            }
        }

        if description.isEmpty {
            description = "A delicious recipe generated just for you by ChefBuddy."
        }

        let nutrition = NutritionInfo(
            calories: calories,
            carbs: carbs,
            protein: protein,
            fat: fat,
            saturatedFat: saturatedFat,
            sugar: sugar,
            fiber: fiber,
            sodium: sodium
        )

        let normalizedTags = tags.isEmpty ? [detectedCuisineTag(title: title, description: description, tags: tags)] : tags

        return Recipe(
            title: title,
            emoji: emoji,
            description: description,
            ingredients: ingredients,
            steps: steps,
            cookTime: cookTime,
            servings: servings,
            difficulty: difficulty,
            tags: normalizedTags,
            calories: calories,
            nutrition: nutrition
        )
    }

    private static func after(_ prefix: String, in line: String) -> String {
        guard let r = line.range(of: prefix, options: .caseInsensitive) else { return line }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Main View

struct RecipesView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant
    @StateObject private var vm = RecipesViewModel()

    @State private var selectedRecipe: Recipe? = nil
    @State private var selectedSuggestionRecipe: Recipe? = nil
    @State private var showGenerateSheet = false
    @State private var showAllRecipesScreen = false
    @State private var appeared = false
    @State private var recipeToReview: Recipe? = nil
    @State private var isLoadingInitialSuggestions = false
    @State private var isLoadingMoreSuggestion = false
    @State private var liveHelpRecipe: Recipe? = nil

    private var userId: String { authVM.userSession?.uid ?? "" }

    private func timeString(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private func recipeFromSuggestion(_ suggestion: RecipeSuggestion) -> Recipe {
        let normalizedTags = suggestion.tags.isEmpty
            ? [detectedCuisineTag(title: suggestion.title, description: suggestion.description, tags: suggestion.tags)]
            : suggestion.tags

        return Recipe(
            title: suggestion.title,
            emoji: suggestion.emoji,
            description: suggestion.description,
            ingredients: suggestion.ingredients,
            steps: suggestion.steps,
            cookTime: suggestion.prepTime,
            servings: suggestion.servings,
            difficulty: suggestion.difficulty,
            tags: normalizedTags,
            calories: suggestion.calories,
            nutrition: suggestion.nutrition
        )
    }

    private func suggestionFromRecipe(_ recipe: Recipe, previous: RecipeSuggestion) -> RecipeSuggestion {
        RecipeSuggestion(
            title: recipe.title,
            emoji: recipe.emoji,
            description: recipe.description,
            prepTime: recipe.cookTime,
            servings: recipe.servings,
            difficulty: recipe.difficulty,
            calories: recipe.calories,
            carbs: recipe.nutrition.carbs,
            protein: recipe.nutrition.protein,
            fat: recipe.nutrition.fat,
            saturatedFat: recipe.nutrition.saturatedFat,
            sugar: recipe.nutrition.sugar,
            fiber: recipe.nutrition.fiber,
            sodium: recipe.nutrition.sodium,
            tags: recipe.tags,
            ingredients: recipe.ingredients,
            steps: recipe.steps,
            matchReason: previous.matchReason
        )
    }

    private var unsavedSuggestions: [RecipeSuggestion] {
        assistant.suggestions
    }

    private func loadInitialSuggestions() async {
        guard !isLoadingInitialSuggestions else { return }
        await MainActor.run { isLoadingInitialSuggestions = true }
        do {
            try await assistant.waitUntilReady()
            // Load any past review feedback so suggestions are personalised
            let feedback = await loadReviewFeedbackSummary()
            await assistant.fetchRecipeSuggestions(reviewFeedback: feedback)
        } catch {
            print("Initial suggestion fetch failed: \(error)")
        }
        await MainActor.run { isLoadingInitialSuggestions = false }
    }

    private func loadOneMoreSuggestion() async {
        guard !isLoadingMoreSuggestion else { return }
        await MainActor.run { isLoadingMoreSuggestion = true }
        do {
            try await assistant.waitUntilReady()
            let feedback = await loadReviewFeedbackSummary()
            try await assistant.fetchOneMoreRecipeSuggestion(
                excludingTitles: vm.recipes.map { $0.title } + assistant.suggestions.map { $0.title },
                reviewFeedback: feedback
            )
        } catch {
            print("Load one more suggestion failed: \(error)")
        }
        await MainActor.run { isLoadingMoreSuggestion = false }
    }

    /// Reads the last 10 reviews across all saved recipes and returns a summary string
    /// the AI can use to avoid repeating things users didn't like.
    private func loadReviewFeedbackSummary() async -> String {
        guard !userId.isEmpty else { return "" }
        let db = Firestore.firestore()
        var improvements: [String] = []
        var liked: [String] = []

        do {
            // Fetch all recipe IDs
            let recipeDocs = try await db.collection("users").document(userId)
                .collection("recipes").getDocuments()

            for recipeDoc in recipeDocs.documents {
                let reviews = try await db.collection("users").document(userId)
                    .collection("recipes").document(recipeDoc.documentID)
                    .collection("reviews")
                    .order(by: "createdAt", descending: true)
                    .limit(to: 3)
                    .getDocuments()

                for review in reviews.documents {
                    let data = review.data()
                    if let imp = data["improvement"] as? String, !imp.trimmingCharacters(in: .whitespaces).isEmpty {
                        improvements.append(imp)
                    }
                    if let tags = data["likedTags"] as? [String] {
                        liked.append(contentsOf: tags)
                    }
                    if let note = data["likedNote"] as? String, !note.trimmingCharacters(in: .whitespaces).isEmpty {
                        liked.append(note)
                    }
                }
            }
        } catch {
            print("Failed to load review feedback: \(error)")
        }

        var summary = ""
        if !liked.isEmpty {
            let topLiked = Array(Set(liked)).prefix(6).joined(separator: ", ")
            summary += "User has previously enjoyed: \(topLiked). "
        }
        if !improvements.isEmpty {
            let topImprovements = improvements.prefix(5).joined(separator: "; ")
            summary += "User has asked for improvements like: \(topImprovements). Avoid repeating these issues."
        }
        return summary
    }

    private func toggleFavoriteEverywhere(_ recipe: Recipe) {
        vm.toggleFavorite(recipe, userId: userId)

        if selectedRecipe?.id == recipe.id {
            selectedRecipe?.isFavorite.toggle()
        }
    }

    private func dislikeSuggestion(_ recipe: Recipe) {
        let normalizedTitle = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        assistant.suggestions.removeAll {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
        }
        selectedSuggestionRecipe = nil

        Task {
            await loadOneMoreSuggestion()
        }
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            Circle()
                .fill(Color.orange.opacity(0.10))
                .blur(radius: 80)
                .offset(x: -160, y: -320)
                .ignoresSafeArea()

            Circle()
                .fill(Color.green.opacity(0.08))
                .blur(radius: 80)
                .offset(x: 160, y: 320)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Recipes")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))

                        Text("\(vm.recipes.count) recipe\(vm.recipes.count == 1 ? "" : "s") saved")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Spacer().frame(width: 16)

                        ForEach(vm.filters, id: \.self) { filter in
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()

                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    vm.selectedFilter = filter
                                }
                            }) {
                                Text(filter)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(vm.selectedFilter == filter ? .white : .primary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .background(
                                        vm.selectedFilter == filter
                                        ? AnyView(
                                            LinearGradient(
                                                colors: [.orange, .green.opacity(0.85)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        : AnyView(Color(.systemGray6))
                                    )
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer().frame(width: 16)
                    }
                    .padding(.vertical, 4)
                }
                .opacity(appeared ? 1 : 0)

                if vm.filteredRecipes.isEmpty && vm.selectedFilter != "All" {
                    RecipesEmptyState(filter: vm.selectedFilter) {
                        showGenerateSheet = true
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            if isLoadingInitialSuggestions && unsavedSuggestions.isEmpty {
                                SuggestionsLoadingSection()
                                    .padding(.top, 10)
                            } else if !unsavedSuggestions.isEmpty || isLoadingMoreSuggestion {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text("AI Suggestions")
                                            .font(.system(size: 20, weight: .bold, design: .rounded))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 20)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 14) {
                                            ForEach(unsavedSuggestions) { suggestion in
                                                let suggestionRecipe = recipeFromSuggestion(suggestion)
                                                RecipeCard(
                                                    recipe: suggestionRecipe,
                                                    onTap: { selectedSuggestionRecipe = suggestionRecipe },
                                                    onFavorite: { },
                                                    showFavorite: false
                                                )
                                                .frame(width: 180)
                                            }
                                            if isLoadingMoreSuggestion {
                                                SuggestionCookingCard()
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                }
                                .padding(.top, 10)
                            }

                            if vm.selectedFilter == "All" {
                                GenerateRecipeSpotlightCard(
                                    onTap: { showGenerateSheet = true },
                                    isGenerating: vm.isGenerating,
                                    step: vm.elapsedSeconds
                                )
                                    .padding(.horizontal, 16)
                            }

                            if vm.filteredRecipes.isEmpty && vm.selectedFilter == "All" {
                                RecipesEmptyState(filter: vm.selectedFilter) {
                                    showGenerateSheet = true
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 20)
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text("Your Recipes")
                                            .font(.system(size: 20, weight: .bold, design: .rounded))

                                        Spacer()

                                        if vm.filteredRecipes.count > 4 {
                                            Button(action: {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                showAllRecipesScreen = true
                                            }) {
                                                Text("See More")
                                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                    .foregroundStyle(.orange)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 20)

                                    LazyVGrid(
                                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                                        spacing: 14
                                    ) {
                                        ForEach(vm.previewRecipes) { recipe in
                                            RecipeCard(
                                                recipe: recipe,
                                                onTap: { selectedRecipe = recipe },
                                                onFavorite: { toggleFavoriteEverywhere(recipe) },
                                                isCooked: recipe.hasBeenCooked
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                        .padding(.bottom, 40)
                    }
                }
            }

            if let err = vm.errorMessage {
                VStack {
                    Spacer()

                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.white)

                        Text(err)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Spacer()

                        Button(action: { vm.errorMessage = nil }) {
                            Image(systemName: "xmark")
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(Color.red.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .red.opacity(0.3), radius: 10, y: 4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.4), value: vm.errorMessage)
            }

        }
        .onAppear {
            vm.startListening(userId: userId)

            withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
        }
        .onDisappear {
            vm.stopListening()
        }
        .task {
            if assistant.suggestions.isEmpty {
                await loadInitialSuggestions()
            }
        }
        .onChange(of: vm.recipes) { recipes in
            if recipes.count < 3 && !vm.isGenerating && assistant.isModelReady {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    vm.autoGenerateIfNeeded(assistant: assistant, userId: userId)
                }
            }
        }
        .onChange(of: assistant.isModelReady) { ready in
            if ready && vm.recipes.count < 3 && !vm.isGenerating {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    vm.autoGenerateIfNeeded(assistant: assistant, userId: userId)
                }
            }
        }
        .onChange(of: vm.justGeneratedRecipe) { recipe in
            if recipe != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    selectedRecipe = recipe
                    vm.justGeneratedRecipe = nil
                }
            }
        }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateRecipeSheet(vm: vm, assistant: assistant, userId: userId)
                .presentationDetents([.fraction(0.6)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedRecipe) { recipe in
            RecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                onFavorite: {
                    toggleFavoriteEverywhere(recipe)
                },
                onDelete: {
                    vm.deleteRecipe(recipe, userId: userId)
                    selectedRecipe = nil
                },
                onRecipeUpdated: { updated in
                    vm.updateRecipeAfterReview(updated, userId: userId)
                    selectedRecipe = updated
                },
                onMarkCooked: {
                    selectedRecipe = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        recipeToReview = recipe
                    }
                },
                onLiveHelp: {
                    selectedRecipe = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        liveHelpRecipe = recipe
                    }
                }
            )
        }
        .sheet(item: $selectedSuggestionRecipe) { recipe in
            SuggestedRecipeDetailView(
                    recipe: recipe,
                    assistant: assistant,
                    onSave: {
                        vm.saveSuggestedRecipe(recipe, userId: userId)
                        dislikeSuggestion(recipe)
                    },
                onDislike: {
                    dislikeSuggestion(recipe)
                },
                onRecipeUpdated: { updated in
                    let normalizedTitle = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let idx = assistant.suggestions.firstIndex(where: {
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
                    }) {
                        assistant.suggestions[idx] = suggestionFromRecipe(updated, previous: assistant.suggestions[idx])
                        selectedSuggestionRecipe = updated
                    }
                },
                onLiveHelp: {
                    selectedSuggestionRecipe = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        liveHelpRecipe = recipe
                    }
                }
            )
        }
        .sheet(isPresented: $showAllRecipesScreen) {
            AllRecipesView(
                vm: vm,
                userId: userId,
                assistant: assistant
            )
        }
        .sheet(item: $recipeToReview) { recipe in
            RecipeReviewView(
                recipe: recipe,
                assistant: assistant,
                userId: userId,
                onComplete: { updatedRecipe, liked, likedNote, improvement in
                    // Build a fully-cooked copy so a single setData is the source of truth
                    var cooked = updatedRecipe
                    if cooked.cookedCount == updatedRecipe.cookedCount {
                        // cookedCount not yet incremented (Keep Original path) — bump it now
                        cooked.cookedCount = max(updatedRecipe.cookedCount, recipe.cookedCount + 1)
                    }
                    cooked.lastCookedAt = Date()
                    vm.updateRecipeAfterReview(cooked, userId: userId)
                    if let recipeId = cooked.id {
                        vm.saveReview(recipeId: recipeId, liked: Array(liked), likedNote: likedNote, improvement: improvement, userId: userId)
                    }
                    recipeToReview = nil
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $liveHelpRecipe) { recipe in
            LiveCookingView(recipe: recipe, assistant: assistant, userId: userId)
        }
    }
}

// MARK: - Helper Views

struct RecipeBouncingDotsView: View {
    let step: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index <= (step % 3) ? color : color.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .offset(y: index == (step % 3) ? -2 : 0)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
    }
}

// MARK: - Recipe Card

private struct RecipeCard: View {
    let recipe: Recipe
    let onTap: () -> Void
    let onFavorite: () -> Void
    var isCooked: Bool = false
    var showFavorite: Bool = true

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

    private var cookedHistoryText: String? {
        guard recipe.hasBeenCooked else { return nil }
        let dateText = recipe.lastCookedAt.map { Self.lastCookedFormatter.string(from: $0) } ?? "unknown"
        return "Cooked \(recipe.cookedCount)x • Last: \(dateText)"
    }

    private var addedHistoryText: String {
        "Added \(Self.createdAtFormatter.string(from: recipe.createdAt))"
    }

    private var cuisineTag: String {
        detectedCuisineTag(title: recipe.title, description: recipe.description, tags: recipe.tags)
    }

    private static let lastCookedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let createdAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        }) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(
                        colors: [Color.orange.opacity(0.12), Color.green.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    Text(recipe.emoji)
                        .font(.system(size: 52))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: -2)

                    if showFavorite {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onFavorite()
                        }) {
                            Image(systemName: recipe.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(recipe.isFavorite ? .red : .secondary)
                                .padding(7)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if isCooked {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Previously Cooked")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.85))
                            .clipShape(Capsule())
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "circle")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Not Cooked")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white.opacity(0.86))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 16)

                    Text(recipe.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 54, alignment: .topLeading)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(recipe.cookTime)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(recipe.difficulty)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(difficultyColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(difficultyColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .foregroundStyle(.secondary)
                    .frame(height: 20)

                    Text(recipe.calories.isEmpty ? "— kcal per serving" : "\(recipe.calories) per serving")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .frame(height: 18, alignment: .leading)

                    HStack {
                        Text(cuisineTag)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)

                    Text(cookedHistoryText ?? addedHistoryText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 12, alignment: .topLeading)
                }
                .padding(12)
            }
            .frame(height: 288)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isCooked ? Color.green.opacity(0.28) : Color.primary.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(RecipeCardButtonStyle())
    }
}

private struct RecipeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

private struct GenerateRecipeSpotlightCard: View {
    let onTap: () -> Void
    var isGenerating: Bool = false
    var step: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.95), .green.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Generate Any Recipe")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Describe any dish, cuisine, or craving and ChefBuddy will build it.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            if isGenerating {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)

                    Text("ChefBuddy is cooking")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    RecipeBouncingDotsView(step: step, color: .white)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.horizontal, 14)
                .background(
                    LinearGradient(
                        colors: [.orange, .green.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
            } else {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onTap()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14, weight: .bold))
                        Text("Create Recipe")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        LinearGradient(
                            colors: [.orange, .green.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }
}

// MARK: - Suggestions Loading UI

private struct SuggestionsLoadingSection: View {
    @State private var scanAnimationStep: Int = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI Suggestions")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 20)

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
                    
                    Text("Generating recipe ideas for you...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 5) {
                        Text("Generating")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        RecipeBouncingDotsView(step: scanAnimationStep, color: .orange)
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
            .padding(.horizontal, 16)
        }
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

private struct SuggestionCookingCard: View {
    @State private var scanAnimationStep: Int = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [Color.orange.opacity(0.18), Color.green.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
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
                
                Text("Making your next recipe idea")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                
                HStack(spacing: 4) {
                    Text("Generating")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    
                    RecipeBouncingDotsView(step: scanAnimationStep, color: .orange)
                }
            }
            .padding(12)
        }
        .frame(width: 180)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.05), lineWidth: 1))
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

// MARK: - All Recipes Screen

struct AllRecipesView: View {
    @ObservedObject var vm: RecipesViewModel
    let userId: String
    let assistant: CookingAssistant

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecipe: Recipe? = nil
    @State private var recipeToReview: Recipe? = nil
    @State private var liveHelpRecipe: Recipe? = nil
    @State private var searchText = ""
    @State private var selectedCuisine = "All Cuisines"
    @State private var selectedFocusFilter = "All"
    private let focusFilters = ["All", "Favorites", "Cooked"]

    private var titleText: String {
        vm.selectedFilter == "All" ? "All Recipes" : vm.selectedFilter
    }

    private var availableCuisines: [String] {
        let values = vm.filteredRecipes.map {
            detectedCuisineTag(title: $0.title, description: $0.description, tags: $0.tags)
        }
        return ["All Cuisines"] + Array(Set(values)).sorted()
    }

    private var displayedRecipes: [Recipe] {
        vm.filteredRecipes.filter { recipe in
            let matchesSearch: Bool = {
                let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if q.isEmpty { return true }
                let text = "\(recipe.title) \(recipe.description) \(recipe.tags.joined(separator: " "))".lowercased()
                return text.contains(q.lowercased())
            }()

            let matchesCuisine: Bool = {
                guard selectedCuisine != "All Cuisines" else { return true }
                return detectedCuisineTag(title: recipe.title, description: recipe.description, tags: recipe.tags) == selectedCuisine
            }()

            let matchesFocus: Bool = {
                switch selectedFocusFilter {
                case "Favorites":
                    return recipe.isFavorite
                case "Cooked":
                    return recipe.hasBeenCooked
                default:
                    return true
                }
            }()

            return matchesSearch && matchesCuisine && matchesFocus
        }
    }

    private var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        selectedCuisine != "All Cuisines" ||
        selectedFocusFilter != "All"
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)

                            TextField("Search recipes, tags, cuisines...", text: $searchText)
                                .font(.system(size: 15, design: .rounded))

                            if !searchText.isEmpty {
                                Button(action: { searchText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                        )

                        HStack {
                            Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Text("\(displayedRecipes.count)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)

                            if hasActiveFilters {
                                Button("Reset") {
                                    searchText = ""
                                    selectedCuisine = "All Cuisines"
                                    selectedFocusFilter = "All"
                                }
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                                .buttonStyle(.plain)
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(focusFilters, id: \.self) { filter in
                                    Button(action: {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        selectedFocusFilter = filter
                                    }) {
                                        Text(filter)
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(selectedFocusFilter == filter ? .white : .primary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                selectedFocusFilter == filter
                                                ? AnyView(
                                                    LinearGradient(
                                                        colors: [.orange, .green.opacity(0.85)],
                                                        startPoint: .leading,
                                                        endPoint: .trailing
                                                    )
                                                )
                                                : AnyView(Color(.systemGray6))
                                            )
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 1)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(availableCuisines, id: \.self) { cuisine in
                                    Button(action: {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        selectedCuisine = cuisine
                                    }) {
                                        Text(cuisine)
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(selectedCuisine == cuisine ? .white : .primary)
                                            .lineLimit(1)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                selectedCuisine == cuisine
                                                ? AnyView(
                                                    LinearGradient(
                                                        colors: [.blue.opacity(0.85), .cyan.opacity(0.85)],
                                                        startPoint: .leading,
                                                        endPoint: .trailing
                                                    )
                                                )
                                                : AnyView(Color(.systemGray6))
                                            )
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 1)
                        }
                    }
                    .padding(.horizontal, 16)

                    if displayedRecipes.isEmpty {
                        VStack(spacing: 10) {
                            Text("No recipes match your filters")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                            Text("Try clearing filters or searching with broader keywords.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 14
                        ) {
                            ForEach(displayedRecipes) { recipe in
                                RecipeCard(
                                    recipe: recipe,
                                    onTap: { selectedRecipe = recipe },
                                    onFavorite: { vm.toggleFavorite(recipe, userId: userId) },
                                    isCooked: recipe.hasBeenCooked
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedRecipe) { recipe in
                RecipeDetailView(
                    recipe: recipe,
                    assistant: assistant,
                    onFavorite: { vm.toggleFavorite(recipe, userId: userId) },
                    onDelete: {
                        vm.deleteRecipe(recipe, userId: userId)
                        selectedRecipe = nil
                    },
                    onRecipeUpdated: { updated in
                        vm.updateRecipeAfterReview(updated, userId: userId)
                        selectedRecipe = updated
                    },
                    onMarkCooked: {
                        selectedRecipe = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            recipeToReview = recipe
                        }
                    },
                    onLiveHelp: {
                        selectedRecipe = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            liveHelpRecipe = recipe
                        }
                    }
                )
            }
            .sheet(item: $recipeToReview) { recipe in
                RecipeReviewView(
                    recipe: recipe,
                    assistant: assistant,
                    userId: userId,
                    onComplete: { updatedRecipe, liked, likedNote, improvement in
                        var cooked = updatedRecipe
                        cooked.cookedCount = max(updatedRecipe.cookedCount, recipe.cookedCount + 1)
                        cooked.lastCookedAt = Date()
                        vm.updateRecipeAfterReview(cooked, userId: userId)
                        if let recipeId = cooked.id {
                            vm.saveReview(recipeId: recipeId, liked: Array(liked), likedNote: likedNote, improvement: improvement, userId: userId)
                        }
                        recipeToReview = nil
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $liveHelpRecipe) { recipe in
                LiveCookingView(recipe: recipe, assistant: assistant, userId: userId)
            }
        }
    }
}

// MARK: - Generate Sheet

struct GenerateRecipeSheet: View {
    @ObservedObject var vm: RecipesViewModel
    let assistant: CookingAssistant
    let userId: String

    @State private var prompt = ""
    @State private var selectedQuick: String? = nil
    @FocusState private var focused: Bool
    @Environment(\.dismiss) var dismiss

    let quickPrompts = [
        "Something quick & healthy",
        "High protein dinner",
        "Use chicken & rice",
        "Vegetarian pasta",
        "30-min meal prep"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Generate a Recipe")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))

                    Text("Tell ChefBuddy what you're craving")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickPrompts, id: \.self) { quick in
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            prompt = quick
                            selectedQuick = quick
                        }) {
                            Text(quick)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(selectedQuick == quick ? .white : .primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    selectedQuick == quick
                                    ? AnyView(
                                        LinearGradient(
                                            colors: [.orange, .green.opacity(0.85)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    : AnyView(Color(.systemGray6))
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField("Or describe your own idea...", text: $prompt)
                .font(.system(size: 16, design: .rounded))
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .focused($focused)
                .onChange(of: prompt) { _ in
                    selectedQuick = nil
                }

            Button(action: {
                guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }

                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                focused = false
                vm.generateAndSave(prompt: prompt, assistant: assistant, userId: userId)
                dismiss()
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                    Text("Generate Recipe")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    prompt.trimmingCharacters(in: .whitespaces).isEmpty
                    ? AnyView(Color.gray.opacity(0.35))
                    : AnyView(
                        LinearGradient(
                            colors: [.orange, .green.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                )
                .clipShape(Capsule())
                .shadow(color: .orange.opacity(0.3), radius: 10, y: 4)
            }
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }
}

// MARK: - Detail View

struct RecipeDetailView: View {
    let recipe: Recipe
    @ObservedObject var assistant: CookingAssistant
    let onFavorite: () -> Void
    let onDelete: () -> Void
    var onRecipeUpdated: ((Recipe) -> Void)? = nil
    var onMarkCooked: (() -> Void)? = nil
    var onLiveHelp: (() -> Void)? = nil

    @State private var activeTab = 0
    @State private var showDeleteConfirm = false
    @State private var showAssistantSheet = false
    @Environment(\.dismiss) var dismiss

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

    private var cookedHistorySummary: String? {
        guard recipe.hasBeenCooked else { return nil }
        let dateText = recipe.lastCookedAt.map { Self.lastCookedFormatter.string(from: $0) } ?? "unknown"
        return "Cooked \(recipe.cookedCount)x • Last cooked \(dateText)"
    }

    private static let lastCookedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .top) {
                    LinearGradient(
                        colors: [Color.orange.opacity(0.18), Color.green.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 220)

                    Text(recipe.emoji)
                        .font(.system(size: 100))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)

                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                                .background(Circle().fill(.ultraThinMaterial))
                        }

                        Spacer()

                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onFavorite()
                        }) {
                            Image(systemName: recipe.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(recipe.isFavorite ? .red : .secondary)
                                .padding(10)
                                .background(Circle().fill(.ultraThinMaterial))
                        }

                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(10)
                                .background(Circle().fill(.ultraThinMaterial))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 56)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(recipe.title)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            StatBadge(icon: "clock", label: recipe.cookTime, color: .orange)
                            StatBadge(icon: "person.2", label: recipe.servings, color: .blue)
                            StatBadge(icon: "flame", label: recipe.calories.isEmpty ? "—" : recipe.calories, color: .red)

                            Text(recipe.difficulty)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(difficultyColor)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(difficultyColor.opacity(0.12))
                                .clipShape(Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Text(recipe.description)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)

                    if let cookedHistorySummary {
                        Label(cookedHistorySummary, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showAssistantSheet = true
                        }) {
                            Label("AI Assistant", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(
                                        colors: [.orange, .green.opacity(0.85)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        if let onLiveHelp {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    onLiveHelp()
                                }
                            }) {
                                Label("Live AI Help", systemImage: "video.fill")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        LinearGradient(
                                            colors: [.blue.opacity(0.9), .cyan.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let onMarkCooked {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                onMarkCooked()
                            }
                        }) {
                            Label("Mark as Cooked", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    LinearGradient(
                                        colors: [.green, .green.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }

                    if !recipe.tags.filter({ !$0.isEmpty }).isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recipe.tags.filter { !$0.isEmpty }, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.green.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                NutritionBreakdownCard(nutrition: recipe.nutrition, calories: recipe.calories)
                    .padding(.bottom, 8)


                HStack(spacing: 0) {
                    ForEach(["Ingredients", "Instructions"].indices, id: \.self) { i in
                        let label = ["Ingredients", "Instructions"][i]

                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.3)) {
                                activeTab = i
                            }
                        }) {
                            VStack(spacing: 6) {
                                Text(label)
                                    .font(.system(size: 15, weight: activeTab == i ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(activeTab == i ? .primary : .secondary)

                                Rectangle()
                                    .fill(activeTab == i ? Color.orange : Color.clear)
                                    .frame(height: 2)
                                    .clipShape(Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)

                Divider()
                    .padding(.horizontal, 24)

                if activeTab == 0 {
                    IngredientsTab(ingredients: recipe.ingredients)
                } else {
                    InstructionsTab(steps: recipe.steps)
                }

                Spacer(minLength: 40)
            }
        }
        .ignoresSafeArea(edges: .top)
        .confirmationDialog("Delete this recipe?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showAssistantSheet) {
            RecipeAssistantSheet(recipe: recipe, assistant: assistant, onApplyRecipe: onRecipeUpdated)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct SuggestedRecipeDetailView: View {
    let recipe: Recipe
    @ObservedObject var assistant: CookingAssistant
    let onSave: () -> Void
    var onDislike: (() -> Void)? = nil
    var onRecipeUpdated: ((Recipe) -> Void)? = nil
    var onLiveHelp: (() -> Void)? = nil

    @State private var activeTab = 0
    @State private var showAssistantSheet = false
    @Environment(\.dismiss) var dismiss

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
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .top) {
                    LinearGradient(
                        colors: [Color.orange.opacity(0.18), Color.green.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 220)

                    Text(recipe.emoji)
                        .font(.system(size: 100))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)

                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                                .background(Circle().fill(.ultraThinMaterial))
                        }

                        Spacer()

                        Button(action: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onSave()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                Text("Save")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(
                                    colors: [.orange, .green.opacity(0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 56)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(recipe.title)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            StatBadge(icon: "clock", label: recipe.cookTime, color: .orange)
                            StatBadge(icon: "person.2", label: recipe.servings, color: .blue)
                            StatBadge(icon: "flame", label: recipe.calories.isEmpty ? "—" : recipe.calories, color: .red)

                            Text(recipe.difficulty)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(difficultyColor)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(difficultyColor.opacity(0.12))
                                .clipShape(Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Text(recipe.description)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)

                    HStack(spacing: 10) {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showAssistantSheet = true
                        }) {
                            Label("AI Assistant", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(
                                        colors: [.orange, .green.opacity(0.85)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        if let onLiveHelp {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    onLiveHelp()
                                }
                            }) {
                                Label("Live AI Help", systemImage: "video.fill")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        LinearGradient(
                                            colors: [.blue.opacity(0.9), .cyan.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let onDislike {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onDislike()
                        }) {
                            Label("Not for me", systemImage: "hand.thumbsdown.fill")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(
                                        colors: [.red.opacity(0.9), .pink.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }

                    if !recipe.tags.filter({ !$0.isEmpty }).isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recipe.tags.filter { !$0.isEmpty }, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.green.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                NutritionBreakdownCard(nutrition: recipe.nutrition, calories: recipe.calories)
                    .padding(.bottom, 8)

                HStack(spacing: 0) {
                    ForEach(["Ingredients", "Instructions"].indices, id: \.self) { i in
                        let label = ["Ingredients", "Instructions"][i]

                        Button(action: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.3)) {
                                activeTab = i
                            }
                        }) {
                            VStack(spacing: 6) {
                                Text(label)
                                    .font(.system(size: 15, weight: activeTab == i ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(activeTab == i ? .primary : .secondary)

                                Rectangle()
                                    .fill(activeTab == i ? Color.orange : Color.clear)
                                    .frame(height: 2)
                                    .clipShape(Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)

                Divider()
                    .padding(.horizontal, 24)

                if activeTab == 0 {
                    IngredientsTab(ingredients: recipe.ingredients)
                } else {
                    InstructionsTab(steps: recipe.steps)
                }

                Spacer(minLength: 40)
            }
        }
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $showAssistantSheet) {
            RecipeAssistantSheet(recipe: recipe, assistant: assistant, onApplyRecipe: onRecipeUpdated)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct RecipeAssistantMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
}

private struct RecipeAssistantSheet: View {
    let recipe: Recipe
    @ObservedObject var assistant: CookingAssistant
    var onApplyRecipe: ((Recipe) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var isLoading = false
    @State private var workingRecipe: Recipe
    @State private var messages: [RecipeAssistantMessage] = [
        RecipeAssistantMessage(
            isUser: false,
            text: "Ask me what to change. I will update this recipe directly."
        )
    ]

    init(recipe: Recipe, assistant: CookingAssistant, onApplyRecipe: ((Recipe) -> Void)? = nil) {
        self.recipe = recipe
        self.assistant = assistant
        self.onApplyRecipe = onApplyRecipe
        _workingRecipe = State(initialValue: recipe)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                Circle().fill(Color.orange.opacity(0.10)).blur(radius: 80).offset(x: -160, y: -200).ignoresSafeArea()
                Circle().fill(Color.green.opacity(0.08)).blur(radius: 80).offset(x: 160, y: 300).ignoresSafeArea()

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recipe AI Assistant")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                        Text(workingRecipe.title)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if isLoading {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(.orange)
                                .controlSize(.large)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Applying recipe changes...")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                Text("Updating ingredients and detailed instructions")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.10), Color.green.opacity(0.08)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                    }

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(messages) { message in
                                HStack {
                                    if message.isUser { Spacer() }
                                    Text(message.text)
                                        .font(.system(size: 14))
                                        .foregroundStyle(message.isUser ? .white : .primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(
                                            message.isUser
                                            ? AnyView(LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                                            : AnyView(Color(.systemGray6))
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .frame(maxWidth: 320, alignment: message.isUser ? .trailing : .leading)
                                    if !message.isUser { Spacer() }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    HStack(spacing: 10) {
                        TextField("What should be improved?", text: $input, axis: .vertical)
                            .font(.system(size: 14))
                            .lineLimit(3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        Button(action: sendMessage) {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 42, height: 42)
                                    .background(
                                        LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 42, height: 42)
                                    .background(
                                        LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("Recipe Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func sendMessage() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLoading else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        input = ""
        messages.append(.init(isUser: true, text: trimmed))
        isLoading = true

        Task {
            do {
                try await assistant.waitUntilReady()
                let ingredientList = workingRecipe.ingredients.map { "- \($0)" }.joined(separator: "\n")
                let stepList = workingRecipe.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                let prompt = """
                You are revising this recipe according to the user's request.
                Return ONLY in this exact format, no extra commentary:
                Title: [recipe name]
                Emoji: [single relevant emoji]
                Description: [one sentence about the dish]
                Cook Time: [e.g. 25 mins]
                Servings: [e.g. 2 people]
                Difficulty: [Easy / Medium / Hard]
                Calories: [e.g. 420 kcal]
                Carbs: [e.g. 42g]
                Protein: [e.g. 35g]
                Fat: [e.g. 12g]
                Saturated Fat: [e.g. 4g]
                Sugar: [e.g. 8g]
                Fiber: [e.g. 5g]
                Sodium: [e.g. 620mg]
                Tags: [comma-separated]

                Ingredients:
                \(ingredientList)
                Instructions:
                \(stepList)

                User request: \(trimmed)

                Rules for quality:
                - include precise ingredient amounts/units
                - include prep details where relevant (washing, dicing, preheating, marinating)
                - include timing and doneness cues in instructions
                - keep instructions detailed and easy to follow
                - include at least one cuisine tag
                """
                let raw = try await assistant.getHelp(question: prompt)
                var revised = RecipesViewModel.parseRecipe(from: raw)

                revised.id = workingRecipe.id
                revised.createdAt = workingRecipe.createdAt
                revised.isFavorite = workingRecipe.isFavorite
                revised.cookedCount = workingRecipe.cookedCount
                revised.lastCookedAt = workingRecipe.lastCookedAt

                if revised.tags.isEmpty { revised.tags = workingRecipe.tags }
                if revised.calories.isEmpty { revised.calories = workingRecipe.calories }
                if revised.nutrition.carbs.isEmpty { revised.nutrition.carbs = workingRecipe.nutrition.carbs }
                if revised.nutrition.protein.isEmpty { revised.nutrition.protein = workingRecipe.nutrition.protein }
                if revised.nutrition.fat.isEmpty { revised.nutrition.fat = workingRecipe.nutrition.fat }
                if revised.nutrition.saturatedFat.isEmpty { revised.nutrition.saturatedFat = workingRecipe.nutrition.saturatedFat }
                if revised.nutrition.sugar.isEmpty { revised.nutrition.sugar = workingRecipe.nutrition.sugar }
                if revised.nutrition.fiber.isEmpty { revised.nutrition.fiber = workingRecipe.nutrition.fiber }
                if revised.nutrition.sodium.isEmpty { revised.nutrition.sodium = workingRecipe.nutrition.sodium }

                await MainActor.run {
                    workingRecipe = revised
                    onApplyRecipe?(revised)
                    messages.append(.init(isUser: false, text: "Applied update. The recipe card and details are now updated."))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    messages.append(.init(isUser: false, text: "I hit an error while generating help. Please try again."))
                    isLoading = false
                }
            }
        }
    }
}

private struct StatBadge: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)

            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .clipShape(Capsule())
    }
}

private struct IngredientsTab: View {
    let ingredients: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(ingredients.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 14) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)

                    Text(item)
                        .font(.system(size: 15, design: .rounded))
                        .lineSpacing(3)

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }
}

private struct InstructionsTab: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 14) {
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            LinearGradient(
                                colors: [.orange, .green.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Circle())

                    Text(step)
                        .font(.system(size: 15, design: .rounded))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if index < steps.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.05))
                        .frame(height: 1)
                        .padding(.leading, 42)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }
}

private struct RecipesEmptyState: View {
    let filter: String
    let onGenerate: () -> Void

    @State private var bounce = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("🍳")
                .font(.system(size: 80))
                .offset(y: bounce ? -10 : 0)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: bounce)
                .onAppear {
                    bounce = true
                }

            Text(filter == "All" ? "No recipes yet.\nGenerate your first one!" : "No \"\(filter)\" recipes yet.")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if filter == "All" {
                Button(action: onGenerate) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Generate a Recipe")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [.orange, .green.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                    .shadow(color: .orange.opacity(0.3), radius: 10, y: 4)
                }
            }

            Spacer()
        }
        .padding()
    }
}

// MARK: - Nutrition Breakdown Card

struct NutritionBreakdownCard: View {
    let nutrition: NutritionInfo
    let calories: String

    private var hasAnyData: Bool {
        !nutrition.carbs.isEmpty || !nutrition.protein.isEmpty ||
        !nutrition.fat.isEmpty || !nutrition.sugar.isEmpty ||
        !nutrition.fiber.isEmpty || !nutrition.sodium.isEmpty ||
        !calories.isEmpty
    }

    var body: some View {
        if hasAnyData {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.orange)
                    Text("Nutrition Per Serving")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }

                // Calories hero row
                if !calories.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(calories)
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(.orange)
                            Text("Total Calories")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 2)
                }

                // Macro grid
                let macros: [(String, String, Color)] = [
                    ("Carbs", nutrition.carbs, .blue),
                    ("Protein", nutrition.protein, .green),
                    ("Fat", nutrition.fat, .orange),
                    ("Sat. Fat", nutrition.saturatedFat, .red),
                    ("Sugar", nutrition.sugar, .pink),
                    ("Fiber", nutrition.fiber, .teal),
                    ("Sodium", nutrition.sodium, .purple),
                ]
                let filledMacros = macros.filter { !$0.1.isEmpty }

                if !filledMacros.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 10
                    ) {
                        ForEach(filledMacros, id: \.0) { name, value, color in
                            VStack(spacing: 4) {
                                Text(value)
                                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                                    .foregroundStyle(color)
                                Text(name)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(color.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .padding(16)
            .background(
                LinearGradient(
                    colors: [Color.orange.opacity(0.05), Color.green.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.15), lineWidth: 1))
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Recipe Review View

struct RecipeReviewView: View {
    let recipe: Recipe
    let assistant: CookingAssistant
    let userId: String
    let onComplete: (Recipe, Set<String>, String, String) -> Void

    @Environment(\.dismiss) var dismiss
    @State private var selectedLiked: Set<String> = []
    @State private var likedNote = ""
    @State private var improvementText = ""
    @State private var isRegenerating = false
    @State private var revisedRecipe: Recipe? = nil
    @State private var showConfirmation = false
    @State private var scanAnimationStep = 0
    @State private var timer: Timer?
    @FocusState private var focusedField: Bool

    let likedOptions = [
        "🔥 Flavour", "⏱️ Cook Time", "🥗 Ingredients",
        "📋 Instructions", "🍽️ Portion Size", "💰 Budget-Friendly",
        "😊 Easy to Make", "🌶️ Spice Level"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                Circle().fill(Color.orange.opacity(0.10)).blur(radius: 80).offset(x: -160, y: -200).ignoresSafeArea()
                Circle().fill(Color.green.opacity(0.08)).blur(radius: 80).offset(x: 160, y: 300).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {

                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 14) {
                                Text(recipe.emoji).font(.system(size: 52))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("How was it?")
                                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                                    Text(recipe.title)
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Text("Your feedback helps ChefBuddy improve this recipe just for you.")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .lineSpacing(4)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                        // Nutrition breakdown
                        NutritionBreakdownCard(nutrition: recipe.nutrition, calories: recipe.calories)

                        // What you liked chips
                        VStack(alignment: .leading, spacing: 14) {
                            Label("What did you love?", systemImage: "heart.fill")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 24)

                            LazyVGrid(
                                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                                spacing: 10
                            ) {
                                ForEach(likedOptions, id: \.self) { option in
                                    let selected = selectedLiked.contains(option)
                                    Button(action: {
                                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                        if selected { selectedLiked.remove(option) } else { selectedLiked.insert(option) }
                                    }) {
                                        Text(option)
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                            .foregroundStyle(selected ? .white : .primary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 10)
                                            .frame(maxWidth: .infinity)
                                            .background(
                                                selected
                                                ? AnyView(LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                                                : AnyView(Color(.systemGray6))
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 24)

                            TextField("Anything else you loved? (optional)", text: $likedNote, axis: .vertical)
                                .font(.system(size: 15, design: .rounded))
                                .padding(14)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .lineLimit(3)
                                .padding(.horizontal, 24)
                                .focused($focusedField)
                        }

                        // Improvements
                        VStack(alignment: .leading, spacing: 12) {
                            Label("What would you improve?", systemImage: "wand.and.stars")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 24)

                            Text("Be specific — e.g. \"less salt\", \"add more garlic\", \"simpler steps\", \"bigger portions\"")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 24)

                            TextField("Describe what you'd change...", text: $improvementText, axis: .vertical)
                                .font(.system(size: 15, design: .rounded))
                                .padding(14)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .lineLimit(5)
                                .padding(.horizontal, 24)
                                .focused($focusedField)
                        }

                        // AI Revision Preview
                        if let revised = revisedRecipe {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.orange)
                                    Text("ChefBuddy revised your recipe!")
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                }
                                .padding(.horizontal, 24)

                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 12) {
                                        Text(revised.emoji).font(.system(size: 40))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(revised.title)
                                                .font(.system(size: 18, weight: .heavy, design: .rounded))
                                            Text(revised.description)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }

                                    HStack(spacing: 10) {
                                        Label(revised.cookTime, systemImage: "clock")
                                        Label(revised.servings, systemImage: "person.2")
                                        Label(revised.calories.isEmpty ? "—" : revised.calories, systemImage: "flame")
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)

                                    Divider()

                                    NutritionBreakdownCard(nutrition: revised.nutrition, calories: revised.calories)
                                        .padding(.horizontal, -16)

                                    Divider()

                                    Text("Tap **Save & Update Recipe** below to replace your current recipe with this improved version.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(3)
                                }
                                .padding(16)
                                .background(
                                    LinearGradient(
                                        colors: [.orange.opacity(0.07), .green.opacity(0.06)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.2), lineWidth: 1))
                                .padding(.horizontal, 24)
                            }
                        }

                        // Action buttons
                        VStack(spacing: 12) {
                            if revisedRecipe == nil {
                                // Generate improvement
                                Button(action: generateRevision) {
                                    HStack(spacing: 10) {
                                        if isRegenerating {
                                            Text("🍳")
                                                .scaleEffect(scanAnimationStep % 2 == 0 ? 0.9 : 1.1)
                                                .animation(.spring(response: 0.35, dampingFraction: 0.65), value: scanAnimationStep)
                                            
                                            Text("ChefBuddy is revising...")
                                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                            
                                            RecipeBouncingDotsView(step: scanAnimationStep, color: .white)
                                        } else {
                                            Image(systemName: "sparkles")
                                            Text(
                                                improvementText.trimmingCharacters(in: .whitespaces).isEmpty
                                                ? "Save & Mark as Cooked"
                                                : "Revise Recipe with AI & Mark as Cooked"
                                            )
                                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                        }
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .background(
                                        LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(Capsule())
                                    .shadow(color: .orange.opacity(0.3), radius: 10, y: 4)
                                }
                                .disabled(isRegenerating)
                            } else {
                                // Save revised recipe
                                Button(action: {
                                    if let revised = revisedRecipe {
                                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                                        onComplete(revised, selectedLiked, likedNote, improvementText)
                                    }
                                }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("Save & Update Recipe")
                                            .font(.system(size: 17, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .background(
                                        LinearGradient(colors: [.green, .green.opacity(0.75)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .clipShape(Capsule())
                                    .shadow(color: .green.opacity(0.3), radius: 10, y: 4)
                                }

                                // Keep original, just mark cooked
                                Button(action: {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    var cooked = recipe
                                    cooked.cookedCount = recipe.cookedCount + 1
                                    cooked.lastCookedAt = Date()
                                    onComplete(cooked, selectedLiked, likedNote, improvementText)
                                }) {
                                    Text("Keep Original & Mark Cooked")
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 48)
                                        .background(Color(.systemGray6))
                                        .clipShape(Capsule())
                                }
                            }

                            // Skip without changes
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dismiss()
                            }) {
                                Text("Skip for Now")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Mark as Cooked")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func generateRevision() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let hasImprovements = !improvementText.trimmingCharacters(in: .whitespaces).isEmpty
        guard hasImprovements else {
            // No improvements — just mark as cooked with original
            var cooked = recipe
            cooked.cookedCount = recipe.cookedCount + 1
            cooked.lastCookedAt = Date()
            onComplete(cooked, selectedLiked, likedNote, "")
            return
        }

        isRegenerating = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            scanAnimationStep += 1
        }

        Task {
            do {
                try await assistant.waitUntilReady()

                let likedList = selectedLiked.isEmpty ? "everything overall" : selectedLiked.joined(separator: ", ")
                let originalIngredients = recipe.ingredients.map { "- \($0)" }.joined(separator: "\n")
                let originalSteps = recipe.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

                let prompt = """
                I cooked "\(recipe.title)" and want you to improve it based on my feedback.

                What I liked: \(likedList)
                \(likedNote.isEmpty ? "" : "Additional notes on what I liked: \(likedNote)")
                What I want improved: \(improvementText)

                Current recipe:
                Ingredients:
                \(originalIngredients)

                Instructions:
                \(originalSteps)

                Please revise the recipe incorporating my feedback. Keep what I liked, and specifically address my improvements.

                Respond ONLY in this exact format, no extra text:
                Title: [recipe name]
                Emoji: [single relevant emoji]
                Description: [one sentence about the dish]
                Cook Time: [e.g. 25 mins]
                Servings: [e.g. 2 people]
                Difficulty: [Easy / Medium / Hard]
                Calories: [e.g. 420 kcal]
                Carbs: [e.g. 42g]
                Protein: [e.g. 35g]
                Fat: [e.g. 12g]
                Saturated Fat: [e.g. 4g]
                Sugar: [e.g. 8g]
                Fiber: [e.g. 5g]
                Sodium: [e.g. 620mg]
                Tags: [comma-separated]

                Ingredients:
                - [ingredient 1]
                - [ingredient 2]

                Instructions:
                1. [step one]
                2. [step two]

                Rules for quality:
                - include precise ingredient amounts/units
                - include prep details where relevant (washing, dicing, preheating, marinating)
                - include timing and doneness cues in instructions
                - keep instructions detailed and easy to follow
                - include at least one cuisine tag
                """

                let raw = try await assistant.getHelp(question: prompt)
                var revised = RecipesViewModel.parseRecipe(from: raw)
                revised.id = recipe.id
                revised.createdAt = recipe.createdAt
                revised.isFavorite = recipe.isFavorite
                revised.cookedCount = recipe.cookedCount + 1
                revised.lastCookedAt = Date()

                await MainActor.run {
                    self.timer?.invalidate()
                    self.revisedRecipe = revised
                    self.isRegenerating = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    self.timer?.invalidate()
                    self.isRegenerating = false
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }
}
