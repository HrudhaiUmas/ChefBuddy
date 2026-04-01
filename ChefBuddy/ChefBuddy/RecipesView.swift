// RecipesView.swift
// The core recipe management screen and its supporting types.
//
// Recipe            — Firestore-backed data model for a saved recipe including
//                     nutrition, cook history, and favourite state.
// NutritionInfo     — Embedded nutrition struct stored inside each Recipe doc.
// RecipesViewModel  — ObservableObject that owns the Firestore listener, drives
//                     AI recipe generation, handles reviews, cooked-state tracking,
//                     nutrition backfill for older recipes, and suggestion loading.
// RecipesView       — The main grid UI: fresh recipes on top, cooked below,
//                     AI suggestion carousel, filter pills, and generate sheet.
// RecipeReviewView  — Post-cook review flow: liked tags, improvement prompt,
//                     optional AI recipe revision, and cooked-count update.
// NutritionBreakdownCard — Reusable macro display used in detail and review views.

import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import Combine
import UIKit
import PhotosUI


// Embeds as a sub-document inside each Recipe. Stored separately from the
// top-level calories field so the detail view can show a full macro breakdown.
struct NutritionInfo: Codable, Equatable {
    var calories: String
    var carbs: String
    var protein: String
    var fat: String
    var saturatedFat: String
    var sugar: String
    var fiber: String
    var sodium: String

    // Sentinel value used when a recipe was saved before nutrition backfill ran.
    // Lets the UI safely check if nutrition data exists without optional unwrapping.
    static var empty: NutritionInfo {
        NutritionInfo(calories: "", carbs: "", protein: "", fat: "",
                      saturatedFat: "", sugar: "", fiber: "", sodium: "")
    }
}

// The core data model stored in Firestore at users/{uid}/recipes/{id}.
// @DocumentID auto-populates id from the Firestore doc key so we never
// manually manage the primary key.
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

    // Computed from cookedCount so the UI never gets out of sync with the
// actual cook history — there's no separate boolean that could drift.
var hasBeenCooked: Bool { cookedCount > 0 }
}

enum GroceryStore: String, CaseIterable, Codable, Identifiable {
    case safeway = "Safeway"
    case walmart = "Walmart"
    case costco = "Costco"
    case traderJoes = "Trader Joe's"

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .safeway: return "🛒"
        case .walmart: return "🏬"
        case .costco: return "📦"
        case .traderJoes: return "🥕"
        }
    }
}

struct GroceryStoreProduct: Codable, Equatable, Identifiable {
    var name: String
    var brand: String
    var size: String
    var price: String
    var section: String
    var note: String

    var id: String {
        "\(name)|\(brand)|\(size)|\(price)"
    }
}

struct GroceryListItem: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var ingredientDisplay: String
    var normalizedIngredient: String
    var quantityHint: String
    var recipeId: String?
    var recipeTitle: String
    var recipeEmoji: String
    var isPurchased: Bool
    var createdAt: Date
    var matchesByStore: [String: [GroceryStoreProduct]]
}

private let ingredientStopWords: Set<String> = [
    "a", "an", "and", "or", "of", "to", "taste", "for", "with", "from", "optional",
    "cup", "cups", "tbsp", "tsp", "teaspoon", "teaspoons", "tablespoon", "tablespoons",
    "oz", "ounce", "ounces", "g", "kg", "ml", "l", "lb", "lbs", "pound", "pounds",
    "small", "medium", "large", "fresh", "dried", "minced", "diced", "chopped", "sliced",
    "shredded", "grated", "ground", "crushed", "extra", "virgin", "boneless", "skinless",
    "halved", "quartered", "rinsed", "washed", "peeled", "cubed", "thinly", "thickly",
    "pinch", "handful", "dash", "pack", "packet", "can", "cans", "jar", "jars"
]

func normalizedIngredientKey(from raw: String) -> String {
    let lowered = raw.lowercased()
    let stripped = lowered.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
    let pieces = stripped
        .split(separator: " ")
        .map(String.init)
        .filter { token in
            guard token.count > 1 else { return false }
            guard ingredientStopWords.contains(token) == false else { return false }
            return Int(token) == nil
        }

    if pieces.isEmpty {
        return stripped.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return pieces.prefix(3).joined(separator: " ")
}

func quantityHint(from ingredientLine: String) -> String {
    let trimmed = ingredientLine.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = trimmed.split(separator: " ")
    guard !components.isEmpty else { return "" }
    if components.count == 1 { return "" }

    let first = String(components[0]).lowercased()
    let second = String(components[1]).lowercased()
    let looksNumeric = first.range(of: #"^\d+([./]\d+)?$"#, options: .regularExpression) != nil
    let fraction = ["1/2", "1/3", "1/4", "2/3", "3/4", "¼", "½", "¾"].contains(first)
    let unitLike = ["cup", "cups", "tbsp", "tsp", "oz", "g", "kg", "ml", "l", "lb", "lbs", "clove", "cloves", "can", "cans"]
        .contains(second)

    if looksNumeric || fraction {
        return components.prefix(2).joined(separator: " ")
    }
    if unitLike {
        return String(components[0])
    }
    return ""
}

func displayIngredientText(from raw: String) -> String {
    raw
        .replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func ingredientTokenSet(_ raw: String) -> Set<String> {
    let normalized = normalizedIngredientKey(from: raw)
    return Set(normalized.split(separator: " ").map(String.init))
}

func pantryContainsIngredient(_ ingredient: String, pantryIngredients: [String]) -> Bool {
    let key = normalizedIngredientKey(from: ingredient)
    guard !key.isEmpty else { return true }
    let keyTokens = ingredientTokenSet(key)

    for pantryItem in pantryIngredients {
        let pantryKey = normalizedIngredientKey(from: pantryItem)
        guard !pantryKey.isEmpty else { continue }

        if pantryKey == key || pantryKey.contains(key) || key.contains(pantryKey) {
            return true
        }

        let pantryTokens = ingredientTokenSet(pantryKey)
        let overlap = keyTokens.intersection(pantryTokens).count
        if overlap >= 2 || (overlap == 1 && (keyTokens.count == 1 || pantryTokens.count == 1)) {
            return true
        }
    }

    return false
}

func missingIngredients(from ingredients: [String], pantryIngredients: [String]) -> [String] {
    ingredients.filter { pantryContainsIngredient($0, pantryIngredients: pantryIngredients) == false }
}

func sanitizedDocumentId(_ raw: String) -> String {
    let lowered = raw.lowercased()
    let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? UUID().uuidString : trimmed
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

func primaryCuisineTag(for tags: [String], title: String, description: String) -> String {
    detectedCuisineTag(title: title, description: description, tags: tags)
}

func prepMinutes(from raw: String) -> Int? {
    let lowered = raw.lowercased()
    let numbers = lowered
        .components(separatedBy: CharacterSet.decimalDigits.inverted)
        .compactMap { Int($0) }

    guard let first = numbers.first else { return nil }

    if lowered.contains("hour") || lowered.contains("hr") {
        let minutes = numbers.dropFirst().first ?? 0
        return (first * 60) + minutes
    }

    return first
}

func calorieNumber(from raw: String) -> Int? {
    raw
        .components(separatedBy: CharacterSet.decimalDigits.inverted)
        .compactMap { Int($0) }
        .first
}

func pantryOverlapRatio(ingredients: [String], pantryIngredients: [String]) -> Double {
    guard !ingredients.isEmpty, !pantryIngredients.isEmpty else { return 0 }

    let matches = ingredients.reduce(0) { partial, ingredient in
        partial + (pantryContainsIngredient(ingredient, pantryIngredients: pantryIngredients) ? 1 : 0)
    }

    return Double(matches) / Double(max(ingredients.count, 1))
}

extension CookingAssistant {
    func fetchStoreMatches(
        ingredients: [String],
        store: GroceryStore,
        budgetPreference: String
    ) async throws -> [String: [GroceryStoreProduct]] {
        let uniqueIngredients = Array(Set(ingredients
            .map { normalizedIngredientKey(from: $0) }
            .filter { !$0.isEmpty }))
            .sorted()

        guard !uniqueIngredients.isEmpty else { return [:] }

        let prompt = """
        I need grocery product matches for \(store.rawValue).

        Budget preference: \(budgetPreference)
        Ingredients to match: \(uniqueIngredients.joined(separator: ", "))

        Return ONLY valid JSON in this exact shape:
        {
          "items": [
            {
              "ingredient": "tofu",
              "products": [
                {
                  "name": "Firm Tofu",
                  "brand": "Nasoya",
                  "size": "14 oz",
                  "price": "$2.99",
                  "section": "Produce",
                  "note": "Best value for stir-fry"
                }
              ]
            }
          ]
        }

        Rules:
        - Do not include markdown or backticks
        - 2 to 3 products per ingredient
        - price must be a string like $3.49
        - products must be realistic for \(store.rawValue)
        - prioritize options aligned with the budget preference
        """

        let response = try await getHelp(question: prompt)
        guard let jsonString = Self.extractJSONObject(from: response),
              let data = jsonString.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["items"] as? [[String: Any]] else {
            return [:]
        }

        var output: [String: [GroceryStoreProduct]] = [:]

        for row in rows {
            let ingredient = (row["ingredient"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedIngredientKey(from: ingredient)
            guard !key.isEmpty else { continue }

            let productsRaw = row["products"] as? [[String: Any]] ?? []
            let products: [GroceryStoreProduct] = productsRaw.compactMap { product in
                let name = (product["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return GroceryStoreProduct(
                    name: name,
                    brand: (product["brand"] as? String ?? "Store Brand").trimmingCharacters(in: .whitespacesAndNewlines),
                    size: (product["size"] as? String ?? "Standard").trimmingCharacters(in: .whitespacesAndNewlines),
                    price: (product["price"] as? String ?? "—").trimmingCharacters(in: .whitespacesAndNewlines),
                    section: (product["section"] as? String ?? "Grocery").trimmingCharacters(in: .whitespacesAndNewlines),
                    note: (product["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            if !products.isEmpty {
                output[key] = products
            }
        }

        return output
    }

}


// Central controller for all recipe operations: Firestore CRUD, AI generation,
// suggestion loading, review saving, and nutrition backfill.
// Owned by RecipesView and kept alive as long as that view is on screen.
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

    // Opens a real-time Firestore snapshot listener so the recipe grid updates
    // the moment any recipe is added, changed, or deleted — no manual refresh needed.
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

    // Removes the snapshot listener when the view disappears to avoid holding
    // an open connection and triggering spurious updates in the background.
    func stopListening() {
        listener?.remove()
        listener = nil
    }

    // Generates recipes one-by-one until the user has 3, sequentially.
    // Uses a wait-cycle loop so each generation finishes before the next starts,
    // preventing the race condition where parallel requests duplicate recipes.
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

    // Increments cookedCount and sets lastCookedAt both locally (for immediate
    // UI response) and in Firestore (for persistence). Updating locally first
    // means the green tint appears instantly without waiting for a round trip.
    func markAsCooked(_ recipe: Recipe, userId: String) {
        guard let id = recipe.id, !userId.isEmpty else { return }
        let newCount = recipe.cookedCount + 1
        let now = Date()

        if let idx = recipes.firstIndex(where: { $0.id == id }) {
            recipes[idx].cookedCount = newCount
            recipes[idx].lastCookedAt = now
        }
        db.collection("users").document(userId).collection("recipes").document(id)
            .updateData(["cookedCount": newCount, "lastCookedAt": now])

        Task {
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .recipeCooked,
                eventKey: "recipe_cooked_\(id)_\(newCount)",
                metadata: [
                    "recipeId": id,
                    "title": recipe.title
                ]
            )
        }
    }

    // Replaces the entire recipe document so revised recipes (from the review
    // flow AI rewrite) overwrite the old version atomically.
    func updateRecipeAfterReview(_ updatedRecipe: Recipe, userId: String) {
        guard let id = updatedRecipe.id, !userId.isEmpty else { return }

        if let idx = recipes.firstIndex(where: { $0.id == id }) {
            recipes[idx] = updatedRecipe
        }
        guard let encoded = try? Firestore.Encoder().encode(updatedRecipe) else { return }
        db.collection("users").document(userId).collection("recipes").document(id).setData(encoded)
    }

    // Writes a review to the reviews sub-collection at recipes/{id}/reviews.
    // Kept as a sub-collection (not an array field) so it scales without
    // hitting Firestore's 1 MB document limit.
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

    func saveSuggestedRecipe(_ recipe: Recipe, userId: String, openAfterSave: Bool = true) {
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
                    if openAfterSave {
                        self.justGeneratedRecipe = savedRecipe
                    }
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
                var recipe = try await assistant.generateRecipe(from: prompt)

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

private enum DiscoveryFeedbackAction: String {
    case saved
    case skipped
}

private struct DiscoveryBehaviorSnapshot: Equatable {
    var favoriteCuisines: [String] = []
    var skippedCuisines: [String] = []
    var averagePrepMinutes: Int? = nil
    var averageCalories: Int? = nil
    var pantryUsageRate: Double = 0
    var savedCount: Int = 0
    var cookedCount: Int = 0

    static let empty = DiscoveryBehaviorSnapshot()

    var dominantCuisine: String? {
        favoriteCuisines.first
    }

    var highlightPills: [String] {
        var items: [String] = []

        if let dominantCuisine {
            items.append("Usually \(dominantCuisine)")
        }

        if let averagePrepMinutes {
            items.append("\(averagePrepMinutes) min sweet spot")
        }

        if let averageCalories {
            items.append("Around \(averageCalories) kcal")
        }

        if pantryUsageRate >= 0.55 {
            items.append("Pantry-first")
        } else if pantryUsageRate >= 0.25 {
            items.append("Some pantry pull")
        }

        if items.isEmpty {
            items.append("Learns as you swipe")
        }

        return Array(items.prefix(4))
    }
}

private struct DiscoveryPersonalizationContext {
    let summary: String
    let snapshot: DiscoveryBehaviorSnapshot
}

private final class RecipeDiscoveryStore: ObservableObject {
    static let shared = RecipeDiscoveryStore()

    @Published var chefBuddyPickSuggestions: [RecipeSuggestion] = []
    @Published var swipeDiscoveryDeck: [RecipeSuggestion] = []
    @Published var swipeDiscoverySeenTitles: Set<String> = []
    @Published var isLoadingChefBuddyPicks = false
    @Published var isLoadingSwipeDiscoveryDeck = false
    @Published var isToppingUpSwipeDiscoveryDeck = false
    @Published var discoverySnapshot: DiscoveryBehaviorSnapshot = .empty

    private init() {}
}


struct RecipesView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant
    var savedRecipes: [Recipe] = []
    var onOpenLiveCookingPicker: () -> Void = {}
    @StateObject private var vm = RecipesViewModel()
    @StateObject private var discoveryStore = RecipeDiscoveryStore.shared

    @State private var selectedRecipe: Recipe? = nil
    @State private var selectedSuggestionRecipe: Recipe? = nil
    @State private var showGenerateSheet = false
    @State private var showCustomRecipeSheet = false
    @State private var showAllRecipesScreen = false
    @State private var recipeToReview: Recipe? = nil
    @State private var liveHelpRecipe: Recipe? = nil
    @State private var pantryIngredients: [String] = []
    @State private var pantryListener: ListenerRegistration? = nil
    @State private var pantrySpaces: [SimplePantrySpace] = []
    @State private var selectedPantryId: String? = nil
    @State private var showGroceryList = false
    @State private var isGeneratingFromPantry = false
    @State private var pantrySuggestionsById: [String: [RecipeSuggestion]] = [:]
    @State private var pantryIngredientSignatures: [String: String] = [:]
    @State private var selectedPantrySuggestionRecipe: Recipe? = nil
    @State private var infoSheet: RecipesInfoSheet? = nil
    @State private var showSwipeDiscovery = false

    private var userId: String { authVM.userSession?.uid ?? "" }
    private var budgetPreference: String {
        authVM.currentUserProfile?.budget ?? "💵 $$ (Standard)"
    }

    private var chefBuddyPickSuggestions: [RecipeSuggestion] {
        get { discoveryStore.chefBuddyPickSuggestions }
        nonmutating set { discoveryStore.chefBuddyPickSuggestions = newValue }
    }

    private var swipeDiscoveryDeck: [RecipeSuggestion] {
        get { discoveryStore.swipeDiscoveryDeck }
        nonmutating set { discoveryStore.swipeDiscoveryDeck = newValue }
    }

    private var isLoadingChefBuddyPicks: Bool {
        get { discoveryStore.isLoadingChefBuddyPicks }
        nonmutating set { discoveryStore.isLoadingChefBuddyPicks = newValue }
    }

    private var isLoadingSwipeDiscoveryDeck: Bool {
        get { discoveryStore.isLoadingSwipeDiscoveryDeck }
        nonmutating set { discoveryStore.isLoadingSwipeDiscoveryDeck = newValue }
    }

    private var isToppingUpSwipeDiscoveryDeck: Bool {
        get { discoveryStore.isToppingUpSwipeDiscoveryDeck }
        nonmutating set { discoveryStore.isToppingUpSwipeDiscoveryDeck = newValue }
    }

    private var discoverySnapshot: DiscoveryBehaviorSnapshot {
        get { discoveryStore.discoverySnapshot }
        nonmutating set { discoveryStore.discoverySnapshot = newValue }
    }

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

    private func feedbackSuggestion(from recipe: Recipe) -> RecipeSuggestion {
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
            matchReason: ""
        )
    }

    private var chefBuddyPicks: [RecipeSuggestion] {
        Array(chefBuddyPickSuggestions.prefix(3))
    }

    private var currentPantry: SimplePantrySpace? {
        pantrySpaces.first(where: { $0.id == selectedPantryId })
    }

    private var currentPantrySuggestions: [RecipeSuggestion] {
        pantrySuggestionsById[selectedPantryId ?? ""] ?? []
    }

    private func startPantryListener() {
        guard !userId.isEmpty else { return }

        pantryListener?.remove()
        pantryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .addSnapshotListener { snap, _ in
                guard let docs = snap?.documents else { return }

                var spaces: [SimplePantrySpace] = []
                var signatures: [String: String] = [:]
                var changedPantryIds: Set<String> = []
                for doc in docs {
                    let data = doc.data()
                    let name = data["name"] as? String ?? "Pantry"
                    let emoji = data["emoji"] as? String ?? "🥑"
                    let colorTheme = data["colorTheme"] as? String ?? "Orange"
                    let virtualPantry = data["virtualPantry"] as? [String: [String]] ?? [:]
                    let flattenedIngredients = virtualPantry.values.flatMap { $0 }
                    let signature = flattenedIngredients
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .sorted()
                        .joined(separator: "|")
                    signatures[doc.documentID] = signature
                    if let previous = pantryIngredientSignatures[doc.documentID], previous != signature {
                        changedPantryIds.insert(doc.documentID)
                    }
                    spaces.append(
                        SimplePantrySpace(
                            id: doc.documentID,
                            name: name,
                            emoji: emoji,
                            ingredients: flattenedIngredients,
                            colorTheme: colorTheme
                        )
                    )
                }

                DispatchQueue.main.async {
                    pantrySpaces = spaces.sorted { $0.name < $1.name }
                    pantryIngredientSignatures = signatures

                    for pantryId in changedPantryIds {
                        pantrySuggestionsById.removeValue(forKey: pantryId)
                    }

                    let preferredPantryId = authVM.currentUserProfile?.activePantryId
                    if let selectedPantryId,
                       pantrySpaces.contains(where: { $0.id == selectedPantryId }) == false {
                        self.selectedPantryId = nil
                    }

                    if self.selectedPantryId == nil,
                       let preferredPantryId,
                       pantrySpaces.contains(where: { $0.id == preferredPantryId }) {
                        self.selectedPantryId = preferredPantryId
                    } else if self.selectedPantryId == nil {
                        self.selectedPantryId = pantrySpaces.first?.id
                    }

                    pantryIngredients = pantrySpaces.first(where: { $0.id == self.selectedPantryId })?.ingredients ?? []

                    if let selectedPantry = pantrySpaces.first(where: { $0.id == self.selectedPantryId }),
                       !selectedPantry.ingredients.isEmpty,
                       pantrySuggestionsById[selectedPantry.id] == nil,
                       !isGeneratingFromPantry {
                        generateFromSelectedPantry(selectedPantry)
                    }
                }
            }
    }

    private func stopPantryListener() {
        pantryListener?.remove()
        pantryListener = nil
    }

    private func generateFromSelectedPantry(_ pantry: SimplePantrySpace) {
        guard !pantry.ingredients.isEmpty else { return }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            isGeneratingFromPantry = true
        }

        Task {
            do {
                let generated = try await assistant.generatePantryRecipes(ingredients: pantry.ingredients)
                await MainActor.run {
                    pantrySuggestionsById[pantry.id] = generated
                    if selectedPantryId == pantry.id {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            isGeneratingFromPantry = false
                        }
                    } else {
                        isGeneratingFromPantry = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        isGeneratingFromPantry = false
                    }
                }
            }
        }
    }

    private func removeAndReplacePantrySuggestion(_ recipe: Recipe, pantry: SimplePantrySpace) {
        let normalizedTitle = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var currentSuggestions = pantrySuggestionsById[pantry.id] ?? []
        currentSuggestions.removeAll {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
        }
        pantrySuggestionsById[pantry.id] = currentSuggestions

        Task {
            do {
                let excludingTitles = currentSuggestions.map(\.title)
                let replacement = try await assistant.generateSinglePantryRecipe(
                    ingredients: pantry.ingredients,
                    excludingTitles: excludingTitles
                )

                await MainActor.run {
                    var refreshedSuggestions = pantrySuggestionsById[pantry.id] ?? currentSuggestions
                    refreshedSuggestions.append(replacement)
                    pantrySuggestionsById[pantry.id] = refreshedSuggestions
                }
            } catch {
                print("Failed to fetch replacement pantry recipe: \(error)")
            }
        }
    }

    private func pantrySuggestion(from recipe: Recipe, previous: RecipeSuggestion) -> RecipeSuggestion {
        let normalizedTags = recipe.tags.isEmpty
            ? [detectedCuisineTag(title: recipe.title, description: recipe.description, tags: recipe.tags)]
            : recipe.tags

        return RecipeSuggestion(
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
            tags: normalizedTags,
            ingredients: recipe.ingredients,
            steps: recipe.steps,
            matchReason: previous.matchReason
        )
    }

    private func addMissingIngredientsToGroceryList(recipe: Recipe, missing: [String]) {
        guard !userId.isEmpty else { return }
        let trimmedMissing = missing
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedMissing.isEmpty else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let collection = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("groceryList")
            .document("active")
            .collection("items")

        let group = DispatchGroup()
        let writeLock = NSLock()
        var hasSuccessfulWrite = false

        for ingredient in trimmedMissing {
            let normalized = normalizedIngredientKey(from: ingredient)
            guard !normalized.isEmpty else { continue }

            let recipeIdentifier = recipe.id ?? recipe.title
            let docId = sanitizedDocumentId("\(recipeIdentifier)-\(normalized)")
            let payload = GroceryListItem(
                id: nil,
                ingredientDisplay: ingredient,
                normalizedIngredient: normalized,
                quantityHint: quantityHint(from: ingredient),
                recipeId: recipe.id,
                recipeTitle: recipe.title,
                recipeEmoji: recipe.emoji,
                isPurchased: false,
                createdAt: Date(),
                matchesByStore: [:]
            )

            group.enter()
            do {
                try collection.document(docId).setData(from: payload, merge: true) { error in
                    if error == nil {
                        writeLock.lock()
                        hasSuccessfulWrite = true
                        writeLock.unlock()
                    }
                    group.leave()
                }
            } catch {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if hasSuccessfulWrite {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private func normalizedSuggestionTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func discoveryExclusionTitles(
        includeChefBuddyPicks: Bool,
        includeSwipeDeck: Bool,
        additional: [String] = []
    ) -> [String] {
        var titles = vm.recipes.map(\.title)
        titles.append(contentsOf: additional)

        if includeChefBuddyPicks {
            titles.append(contentsOf: chefBuddyPickSuggestions.map(\.title))
        }

        if includeSwipeDeck {
            titles.append(contentsOf: swipeDiscoveryDeck.map(\.title))
            titles.append(contentsOf: discoveryStore.swipeDiscoverySeenTitles)
        }

        var seen: Set<String> = []
        return titles.filter { title in
            let normalized = normalizedSuggestionTitle(title)
            guard !normalized.isEmpty else { return false }
            return seen.insert(normalized).inserted
        }
    }

    private func requestPersonalizedSuggestions(
        count: Int,
        excludingTitles: [String]
    ) async -> [RecipeSuggestion] {
        do {
            try await assistant.waitUntilReady()
            let context = await loadDiscoveryPersonalizationContext()
            await MainActor.run {
                discoverySnapshot = context.snapshot
            }

            return try await assistant.generateRecipeSuggestions(
                personalizationSummary: context.summary,
                count: count,
                excludingTitles: excludingTitles
            )
        } catch {
            print("Personalized suggestion fetch failed: \(error)")
            return []
        }
    }

    private func markSwipeDiscoveryTitlesSeen(_ suggestions: [RecipeSuggestion]) {
        for suggestion in suggestions {
            discoveryStore.swipeDiscoverySeenTitles.insert(normalizedSuggestionTitle(suggestion.title))
        }
    }

    private func loadChefBuddyPicks(force: Bool = false) async {
        guard !isLoadingChefBuddyPicks else { return }
        if !force, !chefBuddyPicks.isEmpty { return }

        await MainActor.run {
            isLoadingChefBuddyPicks = true
            if force {
                chefBuddyPickSuggestions = []
            }
        }

        let generated = await requestPersonalizedSuggestions(
            count: 3,
            excludingTitles: await MainActor.run {
                discoveryExclusionTitles(includeChefBuddyPicks: false, includeSwipeDeck: true)
            }
        )

        await MainActor.run {
            chefBuddyPickSuggestions = Array(generated.prefix(3))
            isLoadingChefBuddyPicks = false
        }
    }

    private func topUpChefBuddyPicksIfNeeded() async {
        let currentCount = await MainActor.run { chefBuddyPickSuggestions.count }
        guard currentCount < 3 else { return }
        guard !isLoadingChefBuddyPicks else { return }

        await MainActor.run { isLoadingChefBuddyPicks = true }

        let needed = max(1, 3 - currentCount)
        let generated = await requestPersonalizedSuggestions(
            count: needed,
            excludingTitles: await MainActor.run {
                discoveryExclusionTitles(includeChefBuddyPicks: true, includeSwipeDeck: true)
            }
        )

        await MainActor.run {
            let existingTitles = Set(chefBuddyPickSuggestions.map { normalizedSuggestionTitle($0.title) })
            let filtered = generated.filter { !existingTitles.contains(normalizedSuggestionTitle($0.title)) }
            chefBuddyPickSuggestions.append(contentsOf: filtered)
            chefBuddyPickSuggestions = Array(chefBuddyPickSuggestions.prefix(3))
            isLoadingChefBuddyPicks = false
        }
    }

    private func loadSwipeDiscoveryDeck(force: Bool = false) async {
        let currentCount = await MainActor.run { swipeDiscoveryDeck.count }
        guard force || currentCount < 10 else { return }
        guard !isLoadingSwipeDiscoveryDeck else { return }

        await MainActor.run {
            isLoadingSwipeDiscoveryDeck = true
            if force {
                swipeDiscoveryDeck = []
                discoveryStore.swipeDiscoverySeenTitles = []
            }
        }

        let needed = force ? 10 : max(1, 10 - currentCount)
        let generated = await requestPersonalizedSuggestions(
            count: needed,
            excludingTitles: await MainActor.run {
                discoveryExclusionTitles(includeChefBuddyPicks: true, includeSwipeDeck: true)
            }
        )

        await MainActor.run {
            if force {
                swipeDiscoveryDeck = generated
            } else {
                let existingTitles = Set(swipeDiscoveryDeck.map { normalizedSuggestionTitle($0.title) })
                let filtered = generated.filter { !existingTitles.contains(normalizedSuggestionTitle($0.title)) }
                swipeDiscoveryDeck.append(contentsOf: filtered)
            }
            markSwipeDiscoveryTitlesSeen(swipeDiscoveryDeck)
            isLoadingSwipeDiscoveryDeck = false
        }
    }

    private func topUpSwipeDiscoveryDeckIfNeeded() async {
        let currentCount = await MainActor.run { swipeDiscoveryDeck.count }
        guard currentCount < 10 else { return }
        guard !isToppingUpSwipeDiscoveryDeck else { return }

        await MainActor.run { isToppingUpSwipeDiscoveryDeck = true }

        let generated = await requestPersonalizedSuggestions(
            count: max(1, 10 - currentCount),
            excludingTitles: await MainActor.run {
                discoveryExclusionTitles(includeChefBuddyPicks: true, includeSwipeDeck: true)
            }
        )

        await MainActor.run {
            let existingTitles = Set(swipeDiscoveryDeck.map { normalizedSuggestionTitle($0.title) })
            let filtered = generated.filter { !existingTitles.contains(normalizedSuggestionTitle($0.title)) }
            swipeDiscoveryDeck.append(contentsOf: filtered)
            markSwipeDiscoveryTitlesSeen(filtered)
            isToppingUpSwipeDiscoveryDeck = false
        }
    }

    private func loadDiscoveryPersonalizationContext() async -> DiscoveryPersonalizationContext {
        guard !userId.isEmpty else {
            return DiscoveryPersonalizationContext(summary: "", snapshot: .empty)
        }

        let recipes = await MainActor.run { vm.recipes }
        let currentPantryIngredients = await MainActor.run { pantryIngredients }
        let profile = await MainActor.run { authVM.currentUserProfile }

        let cookedRecipes = recipes.filter { $0.hasBeenCooked }
        let allBehaviorRecipes = cookedRecipes.isEmpty ? recipes : cookedRecipes + recipes

        var cuisineWeights: [String: Int] = [:]
        var prepValues: [Int] = []
        var calorieValues: [Int] = []
        var pantryOverlapValues: [Double] = []

        for recipe in allBehaviorRecipes {
            let cuisine = primaryCuisineTag(for: recipe.tags, title: recipe.title, description: recipe.description)
            cuisineWeights[cuisine, default: 0] += max(1, recipe.cookedCount + (recipe.isFavorite ? 1 : 0))

            if let minutes = prepMinutes(from: recipe.cookTime) {
                prepValues.append(minutes)
            }

            if let calories = calorieNumber(from: recipe.calories) {
                calorieValues.append(calories)
            }

            pantryOverlapValues.append(
                pantryOverlapRatio(ingredients: recipe.ingredients, pantryIngredients: currentPantryIngredients)
            )
        }

        let db = Firestore.firestore()
        var skippedCuisines: [String: Int] = [:]
        var skippedTitles: [String] = []

        do {
            let feedbackDocuments = try await db.collection("users")
                .document(userId)
                .collection("discoveryFeedback")
                .order(by: "createdAt", descending: true)
                .limit(to: 40)
                .getDocuments()

            for document in feedbackDocuments.documents {
                let data = document.data()
                guard let action = data["action"] as? String, action == DiscoveryFeedbackAction.skipped.rawValue else {
                    continue
                }

                let cuisine = (data["cuisine"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !cuisine.isEmpty {
                    skippedCuisines[cuisine, default: 0] += 1
                }

                let title = (data["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    skippedTitles.append(title)
                }
            }
        } catch {
            print("Failed to load discovery feedback: \(error)")
        }

        let sortedFavoriteCuisines = cuisineWeights
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        let sortedSkippedCuisines = skippedCuisines
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        let averagePrep = prepValues.isEmpty ? nil : Int((Double(prepValues.reduce(0, +)) / Double(prepValues.count)).rounded())
        let averageCalories = calorieValues.isEmpty ? nil : Int((Double(calorieValues.reduce(0, +)) / Double(calorieValues.count)).rounded())
        let pantryUsageRate = pantryOverlapValues.isEmpty ? 0 : pantryOverlapValues.reduce(0, +) / Double(pantryOverlapValues.count)
        let reviewSummary = await loadReviewFeedbackSummary()

        var summaryParts: [String] = []

        if let profile, !profile.cuisines.isEmpty {
            summaryParts.append("Profile cuisine interests: \(profile.cuisines.prefix(5).joined(separator: ", ")).")
        }

        if !sortedFavoriteCuisines.isEmpty {
            summaryParts.append("Recent saved/cooked cuisines lean toward: \(sortedFavoriteCuisines.prefix(3).joined(separator: ", ")).")
        }

        if !sortedSkippedCuisines.isEmpty {
            summaryParts.append("Recently skipped cuisines or vibes: \(sortedSkippedCuisines.prefix(3).joined(separator: ", ")).")
        }

        if !skippedTitles.isEmpty {
            summaryParts.append("Recently passed on titles similar to: \(Array(skippedTitles.prefix(4)).joined(separator: ", ")).")
        }

        if let averagePrep {
            summaryParts.append("Comfort prep window is around \(averagePrep) minutes.")
        }

        if let averageCalories {
            summaryParts.append("Typical calorie style is around \(averageCalories) kcal per serving.")
        }

        if pantryUsageRate > 0 {
            let usageLabel: String
            switch pantryUsageRate {
            case 0.55...:
                usageLabel = "high"
            case 0.25...:
                usageLabel = "moderate"
            default:
                usageLabel = "light"
            }
            summaryParts.append("Pantry usage rate is \(usageLabel), based on overlap between cooked/saved recipes and the active pantry.")
        }

        if !reviewSummary.isEmpty {
            summaryParts.append(reviewSummary)
        }

        summaryParts.append("Use their habits as guidance, but avoid making every suggestion the same cuisine. Keep the deck balanced between comfort-zone picks and fresh cuisines that still fit their time, calorie style, budget, and restrictions.")

        let snapshot = DiscoveryBehaviorSnapshot(
            favoriteCuisines: Array(sortedFavoriteCuisines.prefix(3)),
            skippedCuisines: Array(sortedSkippedCuisines.prefix(3)),
            averagePrepMinutes: averagePrep,
            averageCalories: averageCalories,
            pantryUsageRate: pantryUsageRate,
            savedCount: recipes.count,
            cookedCount: cookedRecipes.count
        )

        return DiscoveryPersonalizationContext(
            summary: summaryParts.joined(separator: " "),
            snapshot: snapshot
        )
    }


    private func loadReviewFeedbackSummary() async -> String {
        guard !userId.isEmpty else { return "" }
        let db = Firestore.firestore()
        var improvements: [String] = []
        var liked: [String] = []

        do {

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

    private func trackDiscoveryFeedback(_ suggestion: RecipeSuggestion, action: DiscoveryFeedbackAction) async {
        guard !userId.isEmpty else { return }

        let db = Firestore.firestore()
        let cuisine = primaryCuisineTag(for: suggestion.tags, title: suggestion.title, description: suggestion.description)

        var payload: [String: Any] = [
            "title": suggestion.title,
            "emoji": suggestion.emoji,
            "action": action.rawValue,
            "cuisine": cuisine,
            "tags": suggestion.tags,
            "source": "chefbuddy_swipe",
            "createdAt": Date()
        ]

        if let prep = prepMinutes(from: suggestion.prepTime) {
            payload["prepMinutes"] = prep
        }

        if let calories = calorieNumber(from: suggestion.calories) {
            payload["calories"] = calories
        }

        do {
            _ = try await db.collection("users")
                .document(userId)
                .collection("discoveryFeedback")
                .addDocument(data: payload)
        } catch {
            print("Failed to track discovery feedback: \(error)")
        }
    }

    private func refreshDiscoverySnapshot() async {
        let context = await loadDiscoveryPersonalizationContext()
        await MainActor.run {
            discoverySnapshot = context.snapshot
        }
    }

    private func saveChefBuddyPick(_ suggestion: RecipeSuggestion) {
        let recipe = recipeFromSuggestion(suggestion)
        vm.saveSuggestedRecipe(recipe, userId: userId)
        removeSuggestionFromChefBuddyPicks(recipe)

        Task {
            await trackDiscoveryFeedback(suggestion, action: .saved)
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .swipeSave,
                metadata: [
                    "title": suggestion.title,
                    "source": "chefbuddy_pick"
                ]
            )
            await refreshDiscoverySnapshot()
            await topUpChefBuddyPicksIfNeeded()
        }
    }

    private func dislikeChefBuddyPick(_ recipe: Recipe) {
        let suggestion = feedbackSuggestion(from: recipe)
        removeSuggestionFromChefBuddyPicks(recipe)

        Task {
            await trackDiscoveryFeedback(suggestion, action: .skipped)
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .swipeSkip,
                metadata: [
                    "title": suggestion.title,
                    "source": "chefbuddy_pick"
                ]
            )
            await refreshDiscoverySnapshot()
            await topUpChefBuddyPicksIfNeeded()
        }
    }

    private func removeSuggestionFromChefBuddyPicks(_ recipe: Recipe) {
        let normalizedTitle = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        chefBuddyPickSuggestions.removeAll {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
        }
        selectedSuggestionRecipe = nil
    }

    private func saveSuggestionFromDiscovery(_ suggestion: RecipeSuggestion) {
        let recipe = recipeFromSuggestion(suggestion)
        vm.saveSuggestedRecipe(recipe, userId: userId, openAfterSave: false)
        removeSuggestionFromSwipeDeck(suggestion)

        Task {
            await trackDiscoveryFeedback(suggestion, action: .saved)
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .swipeSave,
                metadata: [
                    "title": suggestion.title,
                    "source": "swipe_discovery"
                ]
            )
            await refreshDiscoverySnapshot()
            await topUpSwipeDiscoveryDeckIfNeeded()
        }
    }

    private func skipSuggestionFromDiscovery(_ suggestion: RecipeSuggestion) {
        removeSuggestionFromSwipeDeck(suggestion)

        Task {
            await trackDiscoveryFeedback(suggestion, action: .skipped)
            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .swipeSkip,
                metadata: [
                    "title": suggestion.title,
                    "source": "swipe_discovery"
                ]
            )
            await refreshDiscoverySnapshot()
            await topUpSwipeDiscoveryDeckIfNeeded()
        }
    }

    private func removeSuggestionFromSwipeDeck(_ suggestion: RecipeSuggestion) {
        let normalizedTitle = normalizedSuggestionTitle(suggestion.title)
        swipeDiscoveryDeck.removeAll {
            normalizedSuggestionTitle($0.title) == normalizedTitle
        }
    }

    private func openSwipeDiscovery() {
        showSwipeDiscovery = true

        Task {
            if swipeDiscoveryDeck.isEmpty {
                await loadSwipeDiscoveryDeck(force: true)
            } else {
                await refreshDiscoverySnapshot()
                await topUpSwipeDiscoveryDeckIfNeeded()
            }
        }
    }

    private func openGroceryListSheetSafely() {
        if selectedRecipe != nil {
            selectedRecipe = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                showGroceryList = true
            }
            return
        }

        if selectedSuggestionRecipe != nil {
            selectedSuggestionRecipe = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                showGroceryList = true
            }
            return
        }

        if showAllRecipesScreen {
            showAllRecipesScreen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                showGroceryList = true
            }
            return
        }

        showGroceryList = true
    }

    var body: some View {
        contentView

            .onAppear {
                vm.startListening(userId: userId)
                startPantryListener()
            }
            .onDisappear {
                vm.stopListening()
                stopPantryListener()
            }
            .task {
                await withTaskGroup(of: Void.self) { group in
                    if chefBuddyPickSuggestions.isEmpty {
                        group.addTask { await loadChefBuddyPicks(force: true) }
                    }
                    if swipeDiscoveryDeck.isEmpty {
                        group.addTask { await loadSwipeDiscoveryDeck(force: true) }
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
        .onChange(of: selectedPantryId) { pantryId in
            pantryIngredients = pantrySpaces.first(where: { $0.id == pantryId })?.ingredients ?? []
            authVM.updateActivePantrySelection(pantryId)
            if let pantry = pantrySpaces.first(where: { $0.id == pantryId }),
               !pantry.ingredients.isEmpty,
               pantrySuggestionsById[pantry.id] == nil,
               !isGeneratingFromPantry {
                generateFromSelectedPantry(pantry)
            }
        }
        .onChange(of: authVM.currentUserProfile?.activePantryId) { pantryId in
            guard pantryId != selectedPantryId else { return }
            if let pantryId,
               pantrySpaces.contains(where: { $0.id == pantryId }) {
                selectedPantryId = pantryId
            } else if pantryId == nil, selectedPantryId != nil {
                selectedPantryId = pantrySpaces.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .discoveryFeedbackDidReset)) { _ in
            Task {
                await MainActor.run {
                    discoveryStore.swipeDiscoverySeenTitles.removeAll()
                    swipeDiscoveryDeck.removeAll()
                    chefBuddyPickSuggestions.removeAll()
                    discoverySnapshot = .empty
                }
                await refreshDiscoverySnapshot()
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await loadChefBuddyPicks(force: true) }
                    group.addTask { await loadSwipeDiscoveryDeck(force: true) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activePantrySelectionDidChange)) { note in
            let pantryId = note.userInfo?["pantryId"] as? String
            guard pantryId != selectedPantryId else { return }
            if let pantryId,
               pantrySpaces.contains(where: { $0.id == pantryId }) {
                selectedPantryId = pantryId
            } else if pantryId == nil {
                selectedPantryId = pantrySpaces.first?.id
            }
        }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateRecipeSheet(vm: vm, assistant: assistant, userId: userId)
                .presentationDetents([.fraction(0.6)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCustomRecipeSheet) {
            RecipesCustomRecipeSheet(
                assistant: assistant,
                onSave: { recipe in
                    vm.saveSuggestedRecipe(recipe, userId: userId, openAfterSave: false)
                }
            )
        }
        .sheet(item: $selectedRecipe) { recipe in
            RecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                pantrySpaces: pantrySpaces,
                selectedPantryId: selectedPantryId,
                onFavorite: {
                    toggleFavoriteEverywhere(recipe)
                },
                onDelete: {
                    vm.deleteRecipe(recipe, userId: userId)
                    selectedRecipe = nil
                },
                userId: userId,
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
                },
                onAddMissingToGrocery: { targetRecipe, missing in
                    addMissingIngredientsToGroceryList(recipe: targetRecipe, missing: missing)
                },
                onOpenGroceryList: {
                    openGroceryListSheetSafely()
                },
                onSelectPantry: { pantryId in
                    selectedPantryId = pantryId
                }
            )
        }
        .sheet(item: $selectedSuggestionRecipe) { recipe in
            SuggestedRecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                onSave: {
                    let suggestion = feedbackSuggestion(from: recipe)
                    vm.saveSuggestedRecipe(recipe, userId: userId)
                    removeSuggestionFromChefBuddyPicks(recipe)
                    Task {
                        await trackDiscoveryFeedback(suggestion, action: .saved)
                        await refreshDiscoverySnapshot()
                        await topUpChefBuddyPicksIfNeeded()
                    }
                    },
                onDislike: {
                    dislikeChefBuddyPick(recipe)
                },
                onRecipeUpdated: { updated in
                    let normalizedTitle = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let idx = chefBuddyPickSuggestions.firstIndex(where: {
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
                    }) {
                        chefBuddyPickSuggestions[idx] = suggestionFromRecipe(updated, previous: chefBuddyPickSuggestions[idx])
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
        .sheet(item: $selectedPantrySuggestionRecipe) { recipe in
            SuggestedRecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                onSave: {
                    vm.saveSuggestedRecipe(recipe, userId: userId)
                    if let pantry = currentPantry {
                        removeAndReplacePantrySuggestion(recipe, pantry: pantry)
                    }
                    selectedPantrySuggestionRecipe = nil
                },
                onDislike: {
                    if let pantry = currentPantry {
                        removeAndReplacePantrySuggestion(recipe, pantry: pantry)
                    }
                    selectedPantrySuggestionRecipe = nil
                },
                onRecipeUpdated: { updated in
                    guard let pantry = currentPantry else { return }
                    var suggestions = pantrySuggestionsById[pantry.id] ?? []
                    let normalizedTitle = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if let idx = suggestions.firstIndex(where: {
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle
                    }) {
                        suggestions[idx] = pantrySuggestion(from: updated, previous: suggestions[idx])
                        pantrySuggestionsById[pantry.id] = suggestions
                        selectedPantrySuggestionRecipe = updated
                    }
                },
                onLiveHelp: {
                    selectedPantrySuggestionRecipe = nil
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
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                onAddMissingToGrocery: { recipe, missing in
                    addMissingIngredientsToGroceryList(recipe: recipe, missing: missing)
                },
                onOpenGroceryList: {
                    openGroceryListSheetSafely()
                }
            )
        }
        .sheet(isPresented: $showGroceryList) {
            NavigationStack {
                GroceryListView(
                    userId: userId,
                    assistant: assistant,
                    budgetPreference: budgetPreference
                )
            }
        }
        .sheet(item: $infoSheet) { item in
            InfoMessageSheet(title: item.title, message: item.message)
        }
        .fullScreenCover(isPresented: $showSwipeDiscovery) {
            SwipeDiscoveryScreen(
                suggestions: swipeDiscoveryDeck,
                behaviorSnapshot: discoverySnapshot,
                isLoadingInitial: isLoadingSwipeDiscoveryDeck && swipeDiscoveryDeck.isEmpty,
                isLoadingMore: isToppingUpSwipeDiscoveryDeck,
                onDismiss: { showSwipeDiscovery = false },
                onRefresh: {
                    Task { await loadSwipeDiscoveryDeck(force: true) }
                },
                onSave: { suggestion in
                    saveSuggestionFromDiscovery(suggestion)
                },
                onSkip: { suggestion in
                    skipSuggestionFromDiscovery(suggestion)
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
                    if cooked.cookedCount == updatedRecipe.cookedCount {

                        cooked.cookedCount = max(updatedRecipe.cookedCount, recipe.cookedCount + 1)
                    }
                    cooked.lastCookedAt = Date()
                    vm.updateRecipeAfterReview(cooked, userId: userId)
                    if let recipeId = cooked.id {
                        vm.saveReview(recipeId: recipeId, liked: Array(liked), likedNote: likedNote, improvement: improvement, userId: userId)
                        Task {
                            await GrowthEngine.shared.logActivity(
                                userId: userId,
                                type: .recipeCooked,
                                eventKey: "recipe_cooked_review_\(recipeId)_\(cooked.cookedCount)",
                                metadata: [
                                    "recipeId": recipeId,
                                    "title": cooked.title,
                                    "source": "review"
                                ]
                            )
                        }
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
    private func errorBanner(_ err: String) -> some View {
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
        }
    }
    private var contentView: some View {
        ZStack {
            ChefBuddyBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    headerView
                    pantryDiscoverySection
                    suggestionsSection
                    spotlightSection
                    filterBar
                    recipesGridSection
                }
                .padding(.bottom, 136)
            }

            if let err = vm.errorMessage {
                errorBanner(err)
            }
        }
    }
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(vm.filters, id: \.self) { filter in
                        Button {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()

                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                vm.selectedFilter = filter
                            }
                        } label: {
                            Text(filter)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(vm.selectedFilter == filter ? .white : .primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    vm.selectedFilter == filter
                                    ? AnyView(
                                        LinearGradient(
                                            colors: [.orange, .green.opacity(0.85)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    : AnyView(Color.primary.opacity(0.07))
                                )
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var headerView: some View {
        AnimatedScreenHeader(
            eyebrow: "Recipes",
            title: "Cook something worth saving",
            subtitle: "\(vm.recipes.count) saved recipes, plus smarter ideas based on your pantry and preferences.",
            systemImage: "book.closed.fill",
            accent: .orange
        )
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }

    private var pantryDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("From Your Pantry")
                            .font(.system(size: 20, weight: .bold, design: .rounded))

                        SectionInfoButton {
                            infoSheet = RecipesInfoSheet(
                                title: "From Your Pantry",
                                message: "These ideas are generated from the ingredients in your currently active pantry, so they should feel more grounded in what you actually have on hand."
                            )
                        }
                    }

                    Text(
                        currentPantry == nil
                        ? "Pick a pantry in the Pantry tab to unlock ingredient-aware recipe ideas."
                        : "Ideas generated from what’s currently stocked in \(currentPantry?.name ?? "your pantry")."
                    )
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if pantrySpaces.count > 1 {
                    Menu {
                        ForEach(pantrySpaces) { pantry in
                            Button {
                                selectedPantryId = pantry.id
                            } label: {
                                HStack {
                                    Text("\(pantry.emoji) \(pantry.name)")
                                    if pantry.id == selectedPantryId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(currentPantry.map { "\($0.emoji) \($0.name)" } ?? "Select Pantry")
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 20)

            if pantrySpaces.isEmpty {
                DiscoveryMessageCard(
                    title: "No pantry linked yet",
                    subtitle: "Open Pantry to create a space and add ingredients before asking ChefBuddy for pantry-based recipe ideas.",
                    icon: "basket"
                )
                .padding(.horizontal, 16)
            } else if currentPantry?.ingredients.isEmpty ?? true {
                DiscoveryMessageCard(
                    title: "\(currentPantry?.name ?? "This pantry") is still empty",
                    subtitle: "Scan a shelf or add ingredients manually in Pantry, then come back here for smarter pantry-first ideas.",
                    icon: "camera.viewfinder"
                )
                .padding(.horizontal, 16)
            } else if isGeneratingFromPantry && currentPantrySuggestions.isEmpty {
                PantryRecipeLoadingView()
                    .padding(.horizontal, 16)
            } else if !currentPantrySuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(currentPantrySuggestions) { suggestion in
                            PantryRecipeCard(recipe: suggestion) {
                                selectedPantrySuggestionRecipe = recipeFromSuggestion(suggestion)
                            }
                        }

                        if isGeneratingFromPantry {
                            PantryCardLoadingView()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            } else if let pantry = currentPantry {
                Button(action: { generateFromSelectedPantry(pantry) }) {
                    Label("Generate ideas from \(pantry.name)", systemImage: "sparkles")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ChefBuddy Picks")
                    .font(.system(size: 20, weight: .bold, design: .rounded))

                SectionInfoButton {
                    infoSheet = RecipesInfoSheet(
                        title: "ChefBuddy Picks",
                        message: "These are broader AI recipe ideas tuned to your preferences and cooking behavior, while Swipe Discovery gives you a dedicated place to train ChefBuddy more directly."
                    )
                }

                Spacer()
            }
            .padding(.horizontal, 20)

            if isLoadingChefBuddyPicks && chefBuddyPicks.isEmpty {
                SuggestionsLoadingSection()
            } else if !chefBuddyPicks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(chefBuddyPicks) { suggestion in
                            let suggestionRecipe = recipeFromSuggestion(suggestion)

                            RecipeCard(
                                recipe: suggestionRecipe,
                                onTap: { selectedSuggestionRecipe = suggestionRecipe },
                                onFavorite: { },
                                showFavorite: false
                            )
                            .frame(width: 180)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                DiscoveryMessageCard(
                    title: "No fresh picks yet",
                    subtitle: "ChefBuddy is refreshing picks automatically in the background. Swipe Discovery is ready while it updates.",
                    icon: "sparkles"
                )
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 10)
    }

    private var spotlightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create & Discover")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)

            VStack(spacing: 12) {
                FeaturedRecipeActionCard(
                    title: "Generate Any Recipe",
                    subtitle: "Describe a craving, dish, or cuisine and ChefBuddy will build a full recipe from scratch.",
                    icon: "wand.and.stars",
                    tint: [.orange, .green.opacity(0.85)],
                    statusText: vm.isGenerating ? "ChefBuddy is cooking" : "Main creation flow",
                    footnote: vm.isGenerating ? "Your recipe is building right now." : "Best for specific cravings, dishes, and weeknight what-ifs.",
                    actionLabel: vm.isGenerating ? "Generating..." : "Create Recipe",
                    isLoading: vm.isGenerating,
                    loadingStep: vm.elapsedSeconds
                ) {
                    showGenerateSheet = true
                }

                HStack(spacing: 12) {
                    SupportingRecipeActionCard(
                        title: "Swipe Discovery",
                        subtitle: "Teach ChefBuddy your taste fast.",
                        icon: "rectangle.stack.badge.person.crop",
                        tint: [.orange, .green.opacity(0.84)],
                        badgeText: isLoadingSwipeDiscoveryDeck && swipeDiscoveryDeck.isEmpty ? "Building deck" : "\(max(swipeDiscoveryDeck.count, 10)) ready",
                        helperText: discoverySnapshot.highlightPills.prefix(2).joined(separator: " • "),
                        isLoading: isLoadingSwipeDiscoveryDeck && swipeDiscoveryDeck.isEmpty,
                        loadingStep: vm.elapsedSeconds
                    ) {
                        openSwipeDiscovery()
                    }

                    SupportingRecipeActionCard(
                        title: "Create Custom Recipe",
                        subtitle: "Turn your own idea into a saved card.",
                        icon: "square.and.pencil",
                        tint: [Color(red: 0.39, green: 0.43, blue: 0.96), Color(red: 0.23, green: 0.68, blue: 0.90)],
                        badgeText: "Recipe Studio",
                        helperText: "Great for family recipes and meal-prep staples."
                    ) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showCustomRecipeSheet = true
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var recipesGridSection: some View {
        Group {
            if vm.filteredRecipes.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    RecipesEmptyState(filter: vm.selectedFilter) {
                        showGenerateSheet = true
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {

                    HStack {
                        Text("Your Recipes")
                            .font(.system(size: 20, weight: .bold, design: .rounded))

                        SectionInfoButton {
                            infoSheet = RecipesInfoSheet(
                                title: "Your Recipes",
                                message: "This is your saved recipe library. Filters here only affect recipes you’ve saved, not the AI discovery sections above."
                            )
                        }

                        Spacer()

                        if vm.filteredRecipes.count > 4 {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showAllRecipesScreen = true
                            } label: {
                                Text("See More")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)

                    VStack(alignment: .leading, spacing: 18) {
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
        }
    }
}


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


struct RecipeCard: View {
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
                            .foregroundStyle(Color.primary.opacity(0.92))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.14))
                            .overlay(
                                Capsule()
                                    .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                            )
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

struct RecipeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

private struct FeaturedRecipeActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: [Color]
    let statusText: String
    let footnote: String
    let actionLabel: String
    var isLoading: Bool = false
    var loadingStep: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tint.first?.opacity(0.22) ?? .orange.opacity(0.22), tint.last?.opacity(0.18) ?? .green.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 58, height: 58)

                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(tint.first ?? .orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Main Action")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(tint.first ?? .orange)
                        Text(title)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint.first ?? .orange)
                    }

                    Text(statusText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(tint.first ?? .orange)

                    if isLoading {
                        RecipeBouncingDotsView(step: loadingStep, color: tint.first ?? .orange)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.06), in: Capsule())

                Text(footnote)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(actionLabel)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: tint,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.05), tint.last?.opacity(0.10) ?? Color.green.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading && title == "Generate Any Recipe")
    }
}

private struct SupportingRecipeActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: [Color]
    let badgeText: String
    let helperText: String
    var isLoading: Bool = false
    var loadingStep: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tint.first?.opacity(0.22) ?? .orange.opacity(0.22), tint.last?.opacity(0.18) ?? .green.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 46, height: 46)

                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(tint.first ?? .orange)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(tint.first ?? .orange)
                        }

                        Text(badgeText)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(tint.first ?? .orange)

                        if isLoading {
                            RecipeBouncingDotsView(step: loadingStep, color: tint.first ?? .orange)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Text(helperText.isEmpty ? "Open" : helperText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint.first ?? .orange)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 192, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.04), tint.last?.opacity(0.10) ?? Color.green.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct GenerateRecipeSpotlightCard: View {
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

private struct RecipesInfoSheet: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct SectionInfoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
    }
}

private struct InfoMessageSheet: View {
    let title: String
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))

                    Text(message)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)

                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Section Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.fraction(0.34)])
        .presentationDragIndicator(.visible)
    }
}


private struct SuggestionsLoadingSection: View {
    @State private var scanAnimationStep: Int = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

private struct DiscoveryMessageCard: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct SwipeDiscoveryEntryCard: View {
    let pills: [String]
    let readyCount: Int
    let isLoading: Bool
    let onTap: () -> Void

    private var statusLabel: String {
        if isLoading && readyCount == 0 {
            return "Building your swipe deck"
        }
        return "Open Swipe Discovery"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Swipe Discovery")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Train ChefBuddy with quick save-or-skip decisions and keep the discovery feed learning from your cooking style.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineSpacing(3)
                    }

                    Spacer(minLength: 12)

                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 48, height: 48)

                        Image(systemName: "rectangle.stack.badge.person.crop")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                if !pills.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(pills.prefix(3)), id: \.self) { pill in
                            Text(pill)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.14), in: Capsule())
                        }
                    }
                }

                HStack {
                    HStack(spacing: 8) {
                        if isLoading && readyCount == 0 {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }

                        Text(statusLabel)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.96), in: Capsule())

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.94))
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
            }
            .padding(20)
            .background(
                LinearGradient(
                    colors: [Color.orange.opacity(0.96), Color.green.opacity(0.84)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .orange.opacity(0.18), radius: 14, y: 8)
        }
        .buttonStyle(.plain)
    }
}

private enum SwipeDeckFeedbackKind: Equatable {
    case saved
    case skipped

    var icon: String {
        switch self {
        case .saved:
            return "heart.fill"
        case .skipped:
            return "xmark"
        }
    }

    var title: String {
        switch self {
        case .saved:
            return "That’s a match"
        case .skipped:
            return "Passed for now"
        }
    }

    var subtitle: String {
        switch self {
        case .saved:
            return "Saved to your recipe list."
        case .skipped:
            return "ChefBuddy will steer away from this vibe."
        }
    }

    var accent: Color {
        switch self {
        case .saved:
            return .green
        case .skipped:
            return .red
        }
    }
}

private struct SwipeDiscoveryLoadingSection: View {
    @State private var animationStep = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.24), Color.green.opacity(0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 62, height: 62)

                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 1.2)
                        .frame(width: 74, height: 74)
                        .scaleEffect(animationStep.isMultiple(of: 2) ? 0.98 : 1.04)

                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Building your discovery deck")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))

                    Text("ChefBuddy is mixing comfort picks with a few fresh cuisines so the stack feels personal without getting repetitive.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        loadingStatusPill(text: "Fresh mix", color: .orange)
                        loadingStatusPill(text: "Taste-aware", color: .green)
                        loadingStatusPill(text: "Fast refill", color: .blue)
                    }
                }
            }

            VStack(spacing: 12) {
                loadingPreviewCard(height: 74, widthInset: 88, tilt: -7, opacity: 0.08)
                loadingPreviewCard(height: 90, widthInset: 46, tilt: 5, opacity: 0.10)
                loadingPrimaryPreview(step: animationStep)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 6)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
                animationStep += 1
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func loadingStatusPill(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color.opacity(0.95))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05), in: Capsule())
    }

    private func loadingPreviewCard(height: CGFloat, widthInset: CGFloat, tilt: Double, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(.horizontal, widthInset)
            .rotationEffect(.degrees(tilt))
    }

    private func loadingPrimaryPreview(step: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 48, height: 48)

                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1.2)
                        .frame(width: 62, height: 62)
                        .scaleEffect(step.isMultiple(of: 2) ? 1.0 : 1.05)

                    Text("🍽️")
                        .font(.system(size: 26))
                        .scaleEffect(step.isMultiple(of: 2) ? 1.0 : 1.08)
                        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: step)
                }

                    VStack(alignment: .leading, spacing: 6) {
                    Text("Your next plate is almost ready")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("The deck stays loaded while you browse, so once this stack lands you can keep swiping without waiting.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                loadingMetric(title: "20 mins", accent: .orange)
                loadingMetric(title: "410 kcal", accent: .yellow)
                loadingMetric(title: "Easy", accent: .green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 138)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.11, blue: 0.13))

                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.88), Color(red: 0.48, green: 0.76, blue: 0.36)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 34)
    }

    private func loadingMetric(title: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent.opacity(0.95))
                .frame(width: 8, height: 8)

            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.16), in: Capsule())
    }
}

private struct SwipeDiscoveryScreen: View {
    let suggestions: [RecipeSuggestion]
    let behaviorSnapshot: DiscoveryBehaviorSnapshot
    let isLoadingInitial: Bool
    let isLoadingMore: Bool
    let onDismiss: () -> Void
    let onRefresh: () -> Void
    let onSave: (RecipeSuggestion) -> Void
    let onSkip: (RecipeSuggestion) -> Void

    @State private var showInfo = false
    @State private var animateHeader = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ChefBuddyBackground()

                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(action: { showInfo = true }) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                        Text("Swipe Discovery")
                                .font(.system(size: 34, weight: .heavy, design: .rounded))
                                .foregroundStyle(.primary)

                            Image(systemName: "sparkles")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.orange)
                                .offset(y: animateHeader ? -2 : 2)
                        }

                        Text("Save what feels worth cooking, skip what doesn’t, and let ChefBuddy keep discovery fresh without becoming repetitive.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            ForEach(Array(behaviorSnapshot.highlightPills.prefix(4)), id: \.self) { pill in
                                Text(pill)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                            }
                        }
                    }

                    if suggestions.isEmpty {
                        if isLoadingInitial || isLoadingMore {
                            SwipeDiscoveryLoadingSection()
                                .padding(.top, 38)
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                DiscoveryMessageCard(
                                    title: "The deck is catching its breath",
                                    subtitle: "ChefBuddy can line up a fresh swipe stack right away, with a mix of familiar favorites and a few new cuisines.",
                                    icon: "wand.and.stars"
                                )

                                Button(action: onRefresh) {
                                    Label("Keep Swiping", systemImage: "arrow.clockwise")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 15)
                                        .background(
                                            LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 4)
                            .padding(.top, 28)
                        }
                    } else {
                        if isLoadingMore {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.orange)

                                Text("ChefBuddy is already sliding the next plate into your stack.")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                        }

                        SwipeDiscoveryDeckView(
                            suggestions: suggestions,
                            behaviorSnapshot: behaviorSnapshot,
                            isLoadingMore: isLoadingMore,
                            cardHeight: min(max(geometry.size.height * 0.34, 286), 352),
                            onSave: onSave,
                            onSkip: onSkip
                        )
                        .padding(.top, max(160, geometry.size.height * 0.18))
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 30)
            }
        }
        .sheet(isPresented: $showInfo) {
            InfoMessageSheet(
                title: "Swipe Discovery",
                message: "Swipe right to save, left to skip, and tap any card to flip it for the full recipe. ChefBuddy learns from what you save, cook, and skip, while still mixing in fresh cuisines so discovery stays interesting."
            )
        }
        .onAppear {
            if suggestions.isEmpty {
                onRefresh()
            }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                animateHeader = true
            }
        }
    }
}

private struct SwipeDiscoveryDeckView: View {
    let suggestions: [RecipeSuggestion]
    let behaviorSnapshot: DiscoveryBehaviorSnapshot
    let isLoadingMore: Bool
    let cardHeight: CGFloat
    let onSave: (RecipeSuggestion) -> Void
    let onSkip: (RecipeSuggestion) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var exitOffset: CGSize = .zero
    @State private var flippedCardTitle: String? = nil
    @State private var feedbackKind: SwipeDeckFeedbackKind? = nil

    private var topSuggestions: [RecipeSuggestion] {
        Array(suggestions.prefix(3))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .top) {
                ForEach(Array(topSuggestions.enumerated().reversed()), id: \.element.id) { index, suggestion in
                    let isTopCard = index == 0
                    let isFlipped = flippedCardTitle == normalizedTitle(for: suggestion)

                    DiscoverySwipeCard(
                        suggestion: suggestion,
                        behaviorSnapshot: behaviorSnapshot,
                        dragOffset: isTopCard ? activeOffset : .zero,
                        isTopCard: isTopCard,
                        isFlipped: isFlipped
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .onTapGesture {
                        guard isTopCard else { return }
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            flippedCardTitle = isFlipped ? nil : normalizedTitle(for: suggestion)
                        }
                    }
                    .simultaneousGesture(
                        isTopCard ? dragGesture(for: suggestion) : nil
                    )
                    .scaleEffect(1 - (CGFloat(index) * 0.05))
                    .offset(
                        x: isTopCard ? activeOffset.width : 0,
                        y: CGFloat(index) * 14 + (isTopCard ? max(-8, min(8, activeOffset.height * 0.04)) : 0)
                    )
                    .rotationEffect(isTopCard ? .degrees(Double(activeOffset.width / 24)) : .zero)
                    .shadow(color: Color.black.opacity(index == 0 ? 0.2 : 0.08), radius: 18, y: 12)
                }

                if let feedbackKind {
                    SwipeDeckFeedbackBanner(kind: feedbackKind)
                        .padding(.top, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            HStack(spacing: 14) {
                deckActionButton(icon: "xmark", accent: .red.opacity(0.92)) {
                    if let top = suggestions.first {
                        completeSwipe(for: top, direction: .left)
                    }
                }

                Text(isLoadingMore ? "Another pick is already on the way." : "Tap the card to flip • swipe left or right")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.20), in: Capsule())

                deckActionButton(icon: "heart.fill", accent: .green.opacity(0.95)) {
                    if let top = suggestions.first {
                        completeSwipe(for: top, direction: .right)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .frame(height: cardHeight)
        .onChange(of: suggestions.first?.title) { _ in
            exitOffset = .zero
            dragOffset = .zero
        }
    }

    private var activeOffset: CGSize {
        if exitOffset != .zero {
            return exitOffset
        }
        return dragOffset
    }

    private enum SwipeDirection {
        case left
        case right
    }

    private func normalizedTitle(for suggestion: RecipeSuggestion) -> String {
        suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func dragGesture(for suggestion: RecipeSuggestion) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                let projectedWidth = value.predictedEndTranslation.width
                let finalWidth = value.translation.width + (projectedWidth * 0.18)

                if finalWidth > 110 {
                    completeSwipe(for: suggestion, direction: .right)
                } else if finalWidth < -110 {
                    completeSwipe(for: suggestion, direction: .left)
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func completeSwipe(for suggestion: RecipeSuggestion, direction: SwipeDirection) {
        let targetX = direction == .right ? UIScreen.main.bounds.width : -UIScreen.main.bounds.width

        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.84, blendDuration: 0.12)) {
            exitOffset = CGSize(width: targetX, height: 8)
        }

        switch direction {
        case .left:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                feedbackKind = .skipped
            }
        case .right:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                feedbackKind = .saved
            }
        }

        flippedCardTitle = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            switch direction {
            case .left:
                onSkip(suggestion)
            case .right:
                onSave(suggestion)
            }

            exitOffset = .zero
            dragOffset = .zero
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.22)) {
                feedbackKind = nil
            }
        }
    }

    private func deckActionButton(icon: String, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(accent, in: Circle())
                .shadow(color: accent.opacity(0.32), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct DiscoverySwipeCard: View {
    let suggestion: RecipeSuggestion
    let behaviorSnapshot: DiscoveryBehaviorSnapshot
    let dragOffset: CGSize
    let isTopCard: Bool
    let isFlipped: Bool

    @State private var animateOrb = false

    private var cuisine: String {
        primaryCuisineTag(for: suggestion.tags, title: suggestion.title, description: suggestion.description)
    }

    private var discoveryModeLabel: String {
        if behaviorSnapshot.favoriteCuisines.contains(cuisine) {
            return "Comfort Pick"
        }
        if let dominant = behaviorSnapshot.dominantCuisine, dominant != cuisine {
            return "Fresh Lane"
        }
        return "ChefBuddy Pick"
    }

    private var shortHook: String {
        compactText(from: suggestion.description, maxLength: 62, fallback: "A quick plate tuned to your vibe.")
    }

    private var fullHook: String {
        compactText(from: suggestion.description, maxLength: 240, fallback: "ChefBuddy built this recipe to fit your current cooking style.")
    }

    private var visibleTags: [String] {
        Array(
            suggestion.tags
                .filter { $0.caseInsensitiveCompare(cuisine) != .orderedSame }
                .prefix(2)
        )
    }

    private var swipeLabel: String? {
        if dragOffset.width > 30 {
            return "SAVE"
        }
        if dragOffset.width < -30 {
            return "SKIP"
        }
        return nil
    }

    private var swipeColor: Color {
        dragOffset.width >= 0 ? .green : .red
    }

    private var compactServings: String {
        let raw = suggestion.servings.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "1 srv" }

        if let number = raw.split(separator: " ").first, Int(number) != nil {
            let numeric = String(number)
            let suffix = "srv"
            return "\(numeric) \(suffix)"
        }

        if raw.localizedCaseInsensitiveContains("person") {
            return raw.replacingOccurrences(of: "person", with: "serving", options: .caseInsensitive)
                .replacingOccurrences(of: "people", with: "servings", options: .caseInsensitive)
        }

        return raw
    }

    private var flavorNotes: [(icon: String, label: String)] {
        let source = "\(suggestion.description) \(suggestion.matchReason) \(suggestion.tags.joined(separator: " "))".lowercased()
        var notes: [(String, String)] = []

        func append(_ icon: String, _ label: String, ifAny keywords: [String]) {
            guard notes.count < 3 else { return }
            guard keywords.contains(where: { source.contains($0) }) else { return }
            guard notes.contains(where: { $0.1 == label }) == false else { return }
            notes.append((icon, label))
        }

        append("sun.max.fill", "Bright", ifAny: ["lime", "lemon", "zesty", "fresh", "citrus", "herb"])
        append("flame.fill", "Spiced", ifAny: ["spicy", "heat", "chili", "curry", "pepper"])
        append("drop.fill", "Creamy", ifAny: ["creamy", "yogurt", "coconut", "buttery"])
        append("fork.knife", "Savory", ifAny: ["savory", "umami", "garlic", "toasted"])
        append("heart.fill", "Comforting", ifAny: ["comfort", "cozy", "hearty", "warm"])
        append("leaf.fill", "Fresh", ifAny: ["greens", "fresh", "crisp", "salad", "garden"])
        append("sparkles", "Balanced", ifAny: ["balanced", "high protein", "healthy", "light"])

        while notes.count < 3 {
            let fallbacks: [(String, String)] = [("fork.knife", "Savory"), ("sparkles", "Balanced"), ("heart.fill", "Comforting")]
            if let next = fallbacks.first(where: { fallback in notes.contains(where: { $0.1 == fallback.1 }) == false }) {
                notes.append(next)
            } else {
                break
            }
        }

        return Array(notes.prefix(3))
    }

    private var frontGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.35, green: 0.21, blue: 0.11),
                Color(red: 0.57, green: 0.48, blue: 0.20),
                Color(red: 0.28, green: 0.52, blue: 0.23)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            frontFace
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))

            backFace
                .opacity(isFlipped ? 1 : 0)
                .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.12))

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(frontGradient)
                    .opacity(0.96)

                Circle()
                    .fill(Color.orange.opacity(0.28))
                    .frame(width: 220, height: 220)
                    .blur(radius: 55)
                    .offset(x: -92, y: -118)

                Circle()
                    .fill(Color.green.opacity(0.32))
                    .frame(width: 240, height: 240)
                    .blur(radius: 60)
                    .offset(x: 118, y: 134)

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.18), .clear, Color.black.opacity(0.24)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(Color.white.opacity(isTopCard ? 0.14 : 0.08), lineWidth: 1)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(Color.white.opacity(isTopCard ? 0.12 : 0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .animation(.spring(response: 0.46, dampingFraction: 0.84), value: isFlipped)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                animateOrb = true
            }
        }
    }

    private var frontFace: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(discoveryModeLabel)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.12), in: Capsule())

                        if let swipeLabel {
                            Text(swipeLabel)
                                .font(.system(size: 12, weight: .black, design: .rounded))
                                .foregroundStyle(swipeColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.94), in: Capsule())
                        }
                    }

                    Text(suggestion.title)
                        .font(.system(size: 29, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.82)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(shortHook)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 96, height: 96)
                        .scaleEffect(animateOrb ? 1.04 : 0.96)

                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.white.opacity(0.0), .white.opacity(0.55), .white.opacity(0.0)],
                                center: .center
                            ),
                            lineWidth: 2.2
                        )
                        .frame(width: 92, height: 92)
                        .rotationEffect(.degrees(animateOrb ? 360 : 0))

                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1.2)
                        .frame(width: 78, height: 78)

                    Text(suggestion.emoji)
                        .font(.system(size: 46))

                    Circle()
                        .fill(Color.orange.opacity(0.9))
                        .frame(width: 8, height: 8)
                        .offset(x: 34, y: -28)
                        .opacity(animateOrb ? 0.9 : 0.45)

                    Circle()
                        .fill(Color.green.opacity(0.9))
                        .frame(width: 10, height: 10)
                        .offset(x: -32, y: 26)
                        .opacity(animateOrb ? 0.42 : 0.92)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                DiscoveryIconStatTile(icon: "globe.americas.fill", title: cuisine)
                DiscoveryIconStatTile(icon: "clock.fill", title: suggestion.prepTime)
                DiscoveryIconStatTile(icon: "flame.fill", title: suggestion.calories)
                DiscoveryIconStatTile(icon: "sparkles", title: suggestion.difficulty)
            }

            HStack(spacing: 10) {
                ForEach(visibleTags, id: \.self) { tag in
                    DiscoveryTraitPill(title: tag)
                }
            }

            HStack(spacing: 10) {
                DiscoveryMiniMetric(icon: "bolt.heart.fill", title: suggestion.protein, subtitle: "Protein", accent: .green)
                DiscoveryMiniMetric(icon: "chart.bar.fill", title: suggestion.carbs, subtitle: "Carbs", accent: .orange)
                DiscoveryMiniMetric(icon: "drop.fill", title: suggestion.fat, subtitle: "Fat", accent: .pink)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .padding(.bottom, 74)
    }

    private var backFace: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(suggestion.title)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(fullHook)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 6) {
                            DiscoveryStatPill(icon: "clock.fill", label: suggestion.prepTime)
                            DiscoveryStatPill(icon: "person.2.fill", label: compactServings)
                        }

                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.10))
                                .frame(width: 58, height: 58)

                            Text(suggestion.emoji)
                                .font(.system(size: 30))
                        }
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    DiscoveryNutritionTile(title: "Calories", value: suggestion.calories, accent: .orange)
                    DiscoveryNutritionTile(title: "Protein", value: suggestion.protein, accent: .green)
                    DiscoveryNutritionTile(title: "Carbs", value: suggestion.carbs, accent: .blue)
                    DiscoveryNutritionTile(title: "Fat", value: suggestion.fat, accent: .pink)
                }

                DiscoveryBackSection(title: "Tastes like", icon: "sparkles") {
                    HStack(spacing: 10) {
                        ForEach(Array(flavorNotes.enumerated()), id: \.offset) { _, note in
                            HStack(spacing: 7) {
                                Image(systemName: note.icon)
                                    .font(.system(size: 11, weight: .bold))
                                Text(note.label)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }

                if !suggestion.matchReason.isEmpty {
                    DiscoveryBackSection(title: "Why it fits", icon: "sparkles") {
                        Text(suggestion.matchReason)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                DiscoveryBackSection(title: "Ingredients", icon: "carrot.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(suggestion.ingredients.enumerated()), id: \.offset) { _, ingredient in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .padding(.top, 6)

                                Text(ingredient)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                DiscoveryBackSection(title: "Steps", icon: "list.number") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(suggestion.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .black, design: .rounded))
                                    .foregroundStyle(.orange)
                                    .frame(width: 24, height: 24)
                                    .background(Color.white.opacity(0.95), in: Circle())

                                Text(step)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 74)
        }
    }

    private func compactText(from raw: String, maxLength: Int, fallback: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return fallback }
        guard cleaned.count > maxLength else { return cleaned }

        let prefix = String(cleaned.prefix(maxLength))
        if let split = prefix.lastIndex(of: " ") {
            return String(prefix[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func frontHintPill(icon: String, label: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.10), in: Capsule())
    }
}

private struct SwipeDeckFeedbackBanner: View {
    let kind: SwipeDeckFeedbackKind

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(kind.accent, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                Text(kind.subtitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 28)
    }
}

private struct DiscoveryIconStatTile: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.black.opacity(0.18), in: Circle())

            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct DiscoveryMiniMetric: View {
    let icon: String
    let title: String
    let subtitle: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent.opacity(0.94))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.white)
                    )

                Text(subtitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))
            }

            Text(title)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct DiscoveryBackSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                Text(title)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }

            content
        }
        .padding(16)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct DiscoveryNutritionTile: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent.opacity(0.9))
                    .frame(width: 10, height: 10)

                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }

            Text(value)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Capsule()
                .fill(accent.opacity(0.9))
                .frame(width: 42, height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct DiscoveryStatPill: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .allowsTightening(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct DiscoveryTraitPill: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.16), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
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

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "circle")
                            .font(.system(size: 9, weight: .bold))
                        Text("AI Suggestion")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.14))
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                    )
                    .clipShape(Capsule())
                }
                .frame(height: 16)

                Text("ChefBuddy is cooking...")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(height: 54, alignment: .topLeading)

                Text("Making your next recipe idea")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(height: 20, alignment: .leading)

                Text("Detailed steps and nutrition are on the way.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(height: 18, alignment: .leading)

                HStack(spacing: 4) {
                    Text("Generating")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(Capsule())

                    Spacer(minLength: 0)

                    RecipeBouncingDotsView(step: scanAnimationStep, color: .orange)
                }
                .frame(height: 22)
            }
            .padding(12)
        }
        .frame(width: 180, height: 288)
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


struct AllRecipesView: View {
    @ObservedObject var vm: RecipesViewModel
    let userId: String
    let assistant: CookingAssistant
    let pantryIngredients: [String]
    var onAddMissingToGrocery: ((Recipe, [String]) -> Void)? = nil
    var onOpenGroceryList: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecipe: Recipe? = nil
    @State private var recipeToReview: Recipe? = nil
    @State private var liveHelpRecipe: Recipe? = nil
    @State private var searchText = ""
    @State private var selectedCuisine = "All Cuisines"
    @State private var selectedFocusFilter = "All"
    @State private var showFilters = true
    @State private var hasAppeared = false
    private let focusFilters = ["All", "Favorites", "Cooked"]

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
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("All Recipes")
                                        .font(.system(size: 30, weight: .heavy, design: .rounded))

                                    Text("\(displayedRecipes.count) shown • \(vm.filteredRecipes.count) total")
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button(action: {
                                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                                        showFilters.toggle()
                                    }
                                }) {
                                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(.orange, .green)
                                        .padding(6)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                .buttonStyle(.plain)
                            }

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
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : -10)

                        if showFilters {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Focus")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if hasActiveFilters {
                                        Button("Reset All") {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                                                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                                    selectedFocusFilter = filter
                                                }
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
                                                        : AnyView(Color.primary.opacity(0.08))
                                                    )
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }

                                HStack {
                                    Text("Cuisine")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(availableCuisines, id: \.self) { cuisine in
                                            Button(action: {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                                    selectedCuisine = cuisine
                                                }
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
                                                        : AnyView(Color.primary.opacity(0.08))
                                                    )
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                            .padding(.horizontal, 16)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        }

                        if displayedRecipes.isEmpty {
                            VStack(spacing: 10) {
                                Text("No recipes match your filters")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                Text("Try clearing filters or searching with broader keywords.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
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
                                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                                }
                            }
                            .padding(.horizontal, 16)
                            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: displayedRecipes.map(\.id))
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.04)) {
                    hasAppeared = true
                }
            }
            .sheet(item: $selectedRecipe) { recipe in
                RecipeDetailView(
                    recipe: recipe,
                    assistant: assistant,
                    pantryIngredients: pantryIngredients,
                    onFavorite: { vm.toggleFavorite(recipe, userId: userId) },
                    onDelete: {
                        vm.deleteRecipe(recipe, userId: userId)
                        selectedRecipe = nil
                    },
                    userId: userId,
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
                    },
                    onAddMissingToGrocery: onAddMissingToGrocery,
                    onOpenGroceryList: onOpenGroceryList
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
                            Task {
                                await GrowthEngine.shared.logActivity(
                                    userId: userId,
                                    type: .recipeCooked,
                                    eventKey: "recipe_cooked_library_review_\(recipeId)_\(cooked.cookedCount)",
                                    metadata: [
                                        "recipeId": recipeId,
                                        "title": cooked.title,
                                        "source": "library_review"
                                    ]
                                )
                            }
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


private struct LibraryCustomRecipeDraft {
    var title: String = ""
    var emoji: String = "🍽️"
    var description: String = ""
    var difficulty: String = "Easy"
    var tagsText: String = "Custom"
    var prepMinutes: Int = 25
    var servings: Int = 2
    var calories: Int = 420
    var carbs: Int = 40
    var protein: Int = 25
    var fat: Int = 15
    var sodium: Int = 520
    var ingredients: [String] = [""]
    var steps: [String] = [""]
    var autoPolishWithAI: Bool = true
}

struct RecipesCustomRecipeSheet: View {
    @ObservedObject var assistant: CookingAssistant
    let onSave: (Recipe) -> Void

    @State private var draft = LibraryCustomRecipeDraft()
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedPhotoImage: UIImage? = nil
    @State private var isGeneratingWithAI = false
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    private var nutritionColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    private var canSave: Bool {
        let titleOk = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ingredientsOk = draft.ingredients.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let stepsOk = draft.steps.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return titleOk && ingredientsOk && stepsOk
    }

    private var canAIFill: Bool {
        let titleOk = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isGeneratingWithAI && (titleOk || selectedPhotoImage != nil)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        customRecipeHeader

                        customRecipeSectionCard(
                            title: "Reference Photo",
                            subtitle: "Optional, but useful when you want ChefBuddy to infer the dish from plating, ingredients, and portion size."
                        ) {
                            VStack(alignment: .leading, spacing: 14) {
                                if let selectedPhotoImage {
                                    ZStack(alignment: .bottomLeading) {
                                        Image(uiImage: selectedPhotoImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(height: 188)
                                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                                        LinearGradient(
                                            colors: [.black.opacity(0.62), .clear],
                                            startPoint: .bottom,
                                            endPoint: .center
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Image attached")
                                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                                .foregroundStyle(.white.opacity(0.88))
                                            Text("AI can inspect the dish and fill likely ingredients, nutrition, and prep flow.")
                                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                                .foregroundStyle(.white)
                                        }
                                        .padding(14)
                                    }
                                } else {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                        .frame(height: 160)
                                        .overlay {
                                            VStack(spacing: 10) {
                                                Image(systemName: "photo.on.rectangle.angled")
                                                    .font(.system(size: 26, weight: .semibold))
                                                    .foregroundStyle(.secondary)
                                                Text("Add a photo to help ChefBuddy infer the dish")
                                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                Text("Upload plated food, ingredients, or handwritten notes and ChefBuddy will build the draft around it.")
                                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                                    .foregroundStyle(.secondary)
                                                    .multilineTextAlignment(.center)
                                                    .padding(.horizontal, 18)
                                            }
                                        }
                                }

                                HStack(spacing: 10) {
                                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                        Label(selectedPhotoImage == nil ? "Upload Reference" : "Change Photo", systemImage: "photo.badge.plus")
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                            .foregroundStyle(.primary)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 11)
                                            .background(Color.primary.opacity(0.08), in: Capsule())
                                    }
                                    .buttonStyle(.plain)

                                    if selectedPhotoImage != nil {
                                        Button {
                                            selectedPhotoItem = nil
                                            selectedPhotoImage = nil
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 11)
                                                .background(Color.primary.opacity(0.05), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Spacer(minLength: 0)

                                    Button(action: aiFillFromTitleOrPhoto) {
                                        HStack(spacing: 8) {
                                            if isGeneratingWithAI {
                                                ProgressView()
                                                    .controlSize(.small)
                                                    .tint(.white)
                                            } else {
                                                Image(systemName: "sparkles.rectangle.stack.fill")
                                            }
                                            Text(isGeneratingWithAI ? "Filling..." : "AI Fill")
                                        }
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 15)
                                        .padding(.vertical, 11)
                                        .background(
                                            LinearGradient(colors: [.orange, .green.opacity(0.86)], startPoint: .leading, endPoint: .trailing),
                                            in: Capsule()
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!canAIFill)
                                    .opacity(canAIFill ? 1 : 0.62)
                                }

                                Text(canAIFill
                                     ? "ChefBuddy can infer the title, fill ingredients, tighten the cooking steps, and estimate nutrition from your current draft plus the image."
                                     : "Type a recipe title or upload a reference photo to unlock AI Fill.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        customRecipeSectionCard(
                            title: "Recipe Basics",
                            subtitle: "Give the dish a clean title and a short card description. ChefBuddy will refine the rest."
                        ) {
                            VStack(alignment: .leading, spacing: 14) {
                                labeledInput(title: "Title", prompt: "Example: Lemon Garlic Salmon Bowl") {
                                    TextField("", text: $draft.title, prompt: Text("Example: Lemon Garlic Salmon Bowl").foregroundStyle(.secondary))
                                        .textInputAutocapitalization(.words)
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 14)
                                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }

                                labeledInput(title: "Description", prompt: "A one-line summary for the recipe card") {
                                    TextField(
                                        "",
                                        text: $draft.description,
                                        prompt: Text("A one-line summary for the recipe card").foregroundStyle(.secondary),
                                        axis: .vertical
                                    )
                                    .lineLimit(2...4)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 14)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }

                                labeledInput(title: "Cuisine & Tags", prompt: "Indian, High Protein, Weeknight") {
                                    TextField("", text: $draft.tagsText, prompt: Text("Indian, High Protein, Weeknight").foregroundStyle(.secondary))
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 14)
                                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }

                        customRecipeSectionCard(
                            title: "Cooking Setup",
                            subtitle: "Control the runtime details that show up on the recipe card."
                        ) {
                            VStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    metricStepperCard(
                                        title: "Prep Time",
                                        systemImage: "clock.fill",
                                        valueText: "\(draft.prepMinutes) mins",
                                        onDecrement: { draft.prepMinutes = max(5, draft.prepMinutes - 5) },
                                        onIncrement: { draft.prepMinutes = min(240, draft.prepMinutes + 5) }
                                    )

                                    metricStepperCard(
                                        title: "Servings",
                                        systemImage: "person.2.fill",
                                        valueText: "\(draft.servings) people",
                                        onDecrement: { draft.servings = max(1, draft.servings - 1) },
                                        onIncrement: { draft.servings = min(12, draft.servings + 1) }
                                    )
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Difficulty")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 10) {
                                        difficultyButton(title: "Easy", color: .green)
                                        difficultyButton(title: "Medium", color: .orange)
                                        difficultyButton(title: "Hard", color: .red)
                                    }
                                }
                            }
                        }

                        customRecipeSectionCard(
                            title: "Nutrition Per Serving",
                            subtitle: "Enter the numbers you want saved on the recipe card. ChefBuddy can overwrite these when AI Fill is used."
                        ) {
                            VStack(spacing: 14) {
                                HStack(alignment: .top, spacing: 14) {
                                    recipeMacroBalanceCard

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Macro balance")
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                        macroProgressRow(title: "Protein", value: draft.protein, color: .green)
                                        macroProgressRow(title: "Carbs", value: draft.carbs, color: .blue)
                                        macroProgressRow(title: "Fat", value: draft.fat, color: .pink)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                LazyVGrid(columns: nutritionColumns, spacing: 12) {
                                    nutritionFieldCard(title: "Calories", unit: "kcal", value: $draft.calories, step: 10, maxValue: 3000, color: .orange)
                                    nutritionFieldCard(title: "Carbs", unit: "g", value: $draft.carbs, step: 1, maxValue: 600, color: .blue)
                                    nutritionFieldCard(title: "Protein", unit: "g", value: $draft.protein, step: 1, maxValue: 600, color: .green)
                                    nutritionFieldCard(title: "Fat", unit: "g", value: $draft.fat, step: 1, maxValue: 400, color: .pink)
                                    nutritionFieldCard(title: "Sodium", unit: "mg", value: $draft.sodium, step: 10, maxValue: 6000, color: .purple)
                                }
                            }
                        }

                        customRecipeSectionCard(
                            title: "Ingredients",
                            subtitle: "Add measured ingredients one by one so ChefBuddy can keep quantities clean."
                        ) {
                            editorRowsSection(
                                rows: $draft.ingredients,
                                placeholder: "1 cup diced onions",
                                multiline: false,
                                addLabel: "Add Ingredient"
                            )
                        }

                        customRecipeSectionCard(
                            title: "Method",
                            subtitle: "Write each step in order so live cooking can guide it clearly later."
                        ) {
                            editorRowsSection(
                                rows: $draft.steps,
                                placeholder: "Heat 1 tbsp oil over medium heat and sauté the onions until soft.",
                                multiline: true,
                                addLabel: "Add Step"
                            )
                        }

                        customRecipeSectionCard(
                            title: "Save Settings",
                            subtitle: "Before saving, ChefBuddy can normalize the language, add missing transitions, and clean up ingredient quantities."
                        ) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.orange.opacity(0.12))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.orange)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("AI polish before save")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                    Text(draft.autoPolishWithAI
                                         ? "Enabled — ChefBuddy will tighten the writing before it becomes a saved recipe card."
                                         : "Disabled — your exact draft will be saved as-is.")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 12)

                                Toggle("", isOn: $draft.autoPolishWithAI)
                                    .labelsHidden()
                            }
                            .padding(14)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        Button(action: saveRecipe) {
                            HStack(spacing: 10) {
                                if isSaving {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "tray.and.arrow.down.fill")
                                }
                                Text(isSaving ? "Saving..." : "Save Custom Recipe")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                LinearGradient(colors: [.orange, .green.opacity(0.86)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                            .shadow(color: .orange.opacity(0.18), radius: 18, y: 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSave || isSaving)
                        .opacity((canSave && !isSaving) ? 1 : 0.72)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle("Custom Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _ in
            Task { await loadSelectedPhoto() }
        }
    }

    private var customRecipeHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recipe Studio")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
            Text("Create a polished recipe card for your library. Use a title, a reference image, or both, and let ChefBuddy help shape the final version.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                headerPill(text: "Library-ready", systemImage: "square.stack.3d.up.fill")
                headerPill(text: "Image-aware AI", systemImage: "photo.badge.sparkles")
                headerPill(text: "Step-by-step", systemImage: "list.number")
            }
        }
        .padding(20)
        .background(.ultraThinMaterial.opacity(0.95), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func headerPill(text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func customRecipeSectionCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(18)
        .background(.ultraThinMaterial.opacity(0.95), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func labeledInput<Content: View>(
        title: String,
        prompt: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func metricStepperCard(
        title: String,
        systemImage: String,
        valueText: String,
        onDecrement: @escaping () -> Void,
        onIncrement: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            Text(valueText)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            HStack(spacing: 10) {
                stepperControl(systemImage: "minus", action: onDecrement)
                stepperControl(systemImage: "plus", action: onIncrement)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stepperControl(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func difficultyButton(title: String, color: Color) -> some View {
        let isSelected = draft.difficulty == title
        return Button {
            draft.difficulty = title
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                isSelected
                ? AnyShapeStyle(LinearGradient(colors: [.orange, .green.opacity(0.82)], startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(Color.primary.opacity(0.06))
            , in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var recipeMacroBalanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Macro focus")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 16)

                Circle()
                    .trim(from: 0, to: CGFloat(Double(draft.protein) / max(1, Double(draft.protein + draft.carbs + draft.fat))))
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Circle()
                    .trim(
                        from: CGFloat(Double(draft.protein) / max(1, Double(draft.protein + draft.carbs + draft.fat))),
                        to: CGFloat(Double(draft.protein + draft.carbs) / max(1, Double(draft.protein + draft.carbs + draft.fat)))
                    )
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Circle()
                    .trim(
                        from: CGFloat(Double(draft.protein + draft.carbs) / max(1, Double(draft.protein + draft.carbs + draft.fat))),
                        to: 1
                    )
                    .stroke(Color.pink, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 3) {
                    Text("\(draft.calories)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                    Text("kcal")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 126, height: 126)
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func macroProgressRow(title: String, value: Int, color: Color) -> some View {
        let maxValue = max(1.0, Double(draft.protein + draft.carbs + draft.fat))
        let progress = min(1.0, Double(value) / maxValue)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(value)g")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 8)
        }
    }

    private func nutritionFieldCard(
        title: String,
        unit: String,
        value: Binding<Int>,
        step: Int,
        maxValue: Int,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Text(unit)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            TextField(
                "",
                value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = max(0, min($0, maxValue)) }
                ),
                format: .number
            )
            .keyboardType(.numberPad)
            .font(.system(size: 24, weight: .heavy, design: .rounded))
            .foregroundStyle(color)

            HStack(spacing: 10) {
                stepperControl(systemImage: "minus", action: {
                    value.wrappedValue = max(0, value.wrappedValue - step)
                })
                stepperControl(systemImage: "plus", action: {
                    value.wrappedValue = min(maxValue, value.wrappedValue + step)
                })
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func editorRowsSection(
        rows: Binding<[String]>,
        placeholder: String,
        multiline: Bool,
        addLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                rows.wrappedValue.append("")
            } label: {
                Label(addLabel, systemImage: "plus")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)

            ForEach(Array(rows.wrappedValue.enumerated()), id: \.offset) { index, _ in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.08), in: Circle())

                    Group {
                        if multiline {
                            TextField(
                                "",
                                text: Binding(
                                    get: { rows.wrappedValue[index] },
                                    set: { rows.wrappedValue[index] = $0 }
                                ),
                                prompt: Text(placeholder).foregroundStyle(.secondary),
                                axis: .vertical
                            )
                            .lineLimit(2...5)
                        } else {
                            TextField(
                                "",
                                text: Binding(
                                    get: { rows.wrappedValue[index] },
                                    set: { rows.wrappedValue[index] = $0 }
                                ),
                                prompt: Text(placeholder).foregroundStyle(.secondary)
                            )
                        }
                    }
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        guard rows.wrappedValue.count > 1 else { return }
                        rows.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(rows.wrappedValue.count > 1 ? Color.primary : Color.secondary.opacity(0.4))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(rows.wrappedValue.count <= 1)
                }
            }
        }
    }

    private func aiFillFromTitleOrPhoto() {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPhoto = selectedPhotoImage != nil
        guard (!title.isEmpty || hasPhoto), !isGeneratingWithAI else { return }

        isGeneratingWithAI = true
        Task {
            do {
                let prompt = """
                Build a polished recipe draft from the user's title, existing notes, and optional image.
                If an image is provided, inspect it carefully and infer visible ingredients, likely cuisine, cooking method, plating style, and portion size.
                If no title is provided, infer a concise menu-style title from the image.
                Use realistic quantities, keep the description to one short sentence, and return 4 to 7 coherent cooking steps.
                Return ONLY valid JSON:
                {
                  "title": "recipe title",
                  "description": "short description",
                  "prepMinutes": 25,
                  "servings": 2,
                  "difficulty": "Easy|Medium|Hard",
                  "tags": ["Indian", "High Protein"],
                  "calories": 420,
                  "carbs": 40,
                  "protein": 26,
                  "fat": 14,
                  "sodium": 520,
                  "ingredients": ["1 cup ...", "..."],
                  "steps": ["Step 1...", "Step 2..."]
                }
                Existing title: \(title.isEmpty ? "none provided" : title)
                Existing description: \(draft.description)
                Existing tags: \(draft.tagsText)
                Existing ingredients: \(draft.ingredients.joined(separator: " | "))
                Existing steps: \(draft.steps.joined(separator: " | "))
                """

                let raw: String
                if let selectedPhotoImage {
                    raw = try await assistant.getLiveHelp(image: selectedPhotoImage, question: prompt)
                } else {
                    raw = try await assistant.getHelp(question: prompt)
                }

                guard let json = extractJSONObject(from: raw),
                      let data = json.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    await MainActor.run { isGeneratingWithAI = false }
                    return
                }

                await MainActor.run {
                    if let generatedTitle = object["title"] as? String,
                       !generatedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        draft.title = generatedTitle
                    }
                    draft.description = (object["description"] as? String) ?? draft.description
                    draft.prepMinutes = max(5, object["prepMinutes"] as? Int ?? draft.prepMinutes)
                    draft.servings = max(1, object["servings"] as? Int ?? draft.servings)
                    draft.difficulty = (object["difficulty"] as? String) ?? draft.difficulty
                    let filledTags = (object["tags"] as? [String]) ?? []
                    if !filledTags.isEmpty {
                        draft.tagsText = filledTags.joined(separator: ", ")
                    }
                    draft.calories = max(0, object["calories"] as? Int ?? draft.calories)
                    draft.carbs = max(0, object["carbs"] as? Int ?? draft.carbs)
                    draft.protein = max(0, object["protein"] as? Int ?? draft.protein)
                    draft.fat = max(0, object["fat"] as? Int ?? draft.fat)
                    draft.sodium = max(0, object["sodium"] as? Int ?? draft.sodium)
                    draft.emoji = defaultEmoji(from: filledTags, title: draft.title)
                    draft.ingredients = ((object["ingredients"] as? [String]) ?? draft.ingredients).isEmpty ? draft.ingredients : ((object["ingredients"] as? [String]) ?? draft.ingredients)
                    draft.steps = ((object["steps"] as? [String]) ?? draft.steps).isEmpty ? draft.steps : ((object["steps"] as? [String]) ?? draft.steps)
                    if draft.ingredients.isEmpty { draft.ingredients = [""] }
                    if draft.steps.isEmpty { draft.steps = [""] }
                    isGeneratingWithAI = false
                }
            } catch {
                await MainActor.run {
                    isGeneratingWithAI = false
                }
            }
        }
    }

    private func saveRecipe() {
        guard canSave, !isSaving else { return }
        isSaving = true
        Task {
            var polishedDraft = draft
            if draft.autoPolishWithAI {
                polishedDraft = await polishDraftWithAI(draft)
            }

            let tags = polishedDraft.tagsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let recipe = Recipe(
                title: polishedDraft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                emoji: polishedDraft.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || polishedDraft.emoji == "🍽️"
                    ? defaultEmoji(from: tags, title: polishedDraft.title)
                    : polishedDraft.emoji,
                description: polishedDraft.description.trimmingCharacters(in: .whitespacesAndNewlines),
                ingredients: polishedDraft.ingredients.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                steps: polishedDraft.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                cookTime: "\(polishedDraft.prepMinutes) mins",
                servings: "\(polishedDraft.servings) people",
                difficulty: polishedDraft.difficulty,
                tags: tags.isEmpty ? ["Custom"] : tags,
                calories: "\(polishedDraft.calories) kcal",
                nutrition: NutritionInfo(
                    calories: "\(polishedDraft.calories) kcal",
                    carbs: "\(polishedDraft.carbs)g",
                    protein: "\(polishedDraft.protein)g",
                    fat: "\(polishedDraft.fat)g",
                    saturatedFat: "",
                    sugar: "",
                    fiber: "",
                    sodium: "\(polishedDraft.sodium)mg"
                ),
                createdAt: Date()
            )

            await MainActor.run {
                onSave(recipe)
                isSaving = false
                dismiss()
            }
        }
    }

    private func polishDraftWithAI(_ source: LibraryCustomRecipeDraft) async -> LibraryCustomRecipeDraft {
        do {
            let prompt = """
            Polish this recipe so it follows recipe standards.
            Ensure every ingredient has quantity + unit where possible.
            Ensure steps are complete and no major missing transitions.
            Return ONLY JSON:
            {
              "description": "...",
              "ingredients": ["..."],
              "steps": ["..."]
            }
            Title: \(source.title)
            Ingredients: \(source.ingredients.joined(separator: " | "))
            Steps: \(source.steps.joined(separator: " | "))
            """
            let raw = try await assistant.getHelp(question: prompt)
            guard let json = extractJSONObject(from: raw),
                  let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return source
            }

            var updated = source
            if let description = object["description"] as? String, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.description = description
            }
            if let ingredients = object["ingredients"] as? [String], !ingredients.isEmpty {
                updated.ingredients = ingredients
            }
            if let steps = object["steps"] as? [String], !steps.isEmpty {
                updated.steps = steps
            }
            return updated
        } catch {
            return source
        }
    }

    private func defaultEmoji(from tags: [String]?, title: String) -> String {
        let source = (tags ?? []).joined(separator: " ").lowercased() + " " + title.lowercased()
        if source.contains("pasta") { return "🍝" }
        if source.contains("salad") { return "🥗" }
        if source.contains("soup") { return "🍲" }
        if source.contains("bowl") { return "🥣" }
        if source.contains("rice") { return "🍚" }
        if source.contains("chicken") { return "🍗" }
        if source.contains("indian") { return "🍛" }
        if source.contains("mexican") { return "🌮" }
        if source.contains("dessert") || source.contains("sweet") { return "🍰" }
        return "🍽️"
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhotoItem else { return }
        do {
            guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                selectedPhotoImage = image
            }
        } catch {
            print("Failed to load custom recipe photo: \(error.localizedDescription)")
        }
    }

    private func extractJSONObject(from text: String) -> String? {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("{"), source.hasSuffix("}") {
            return source
        }
        guard let start = source.firstIndex(of: "{"),
              let end = source.lastIndex(of: "}") else {
            return nil
        }
        return String(source[start...end])
    }
}

struct GenerateRecipeSheet: View {
    @ObservedObject var vm: RecipesViewModel
    let assistant: CookingAssistant
    let userId: String

    @State private var prompt = ""
    @State private var selectedQuick: String? = nil
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

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


struct RecipeDetailView: View {
    let recipe: Recipe
    @ObservedObject var assistant: CookingAssistant
    var pantryIngredients: [String] = []
    var pantrySpaces: [SimplePantrySpace] = []
    var selectedPantryId: String? = nil
    let onFavorite: () -> Void
    let onDelete: () -> Void
    let userId: String
    var onRecipeUpdated: ((Recipe) -> Void)? = nil
    var onMarkCooked: (() -> Void)? = nil
    var onLiveHelp: (() -> Void)? = nil
    var onAddMissingToGrocery: ((Recipe, [String]) -> Void)? = nil
    var onOpenGroceryList: (() -> Void)? = nil
    var onSelectPantry: ((String?) -> Void)? = nil


    @State private var activeTab = 0
    @State private var showDeleteConfirm = false
    @State private var showAssistantSheet = false
    @StateObject private var mealPlanVM = MealPlanViewModel()
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

    private func saveToPlan(day: String, type: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        mealPlanVM.addToPlan(recipe: recipe, day: day, mealType: type, userId: userId)
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

    private func dismissThenOpenGroceryListIfAvailable() {
        guard let onOpenGroceryList else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onOpenGroceryList()
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
                    HStack(alignment: .top, spacing: 10) {
                        Text(recipe.title)
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Menu {
                            ForEach(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], id: \.self) { day in
                                Menu(day) {
                                    Button("Breakfast") { saveToPlan(day: day, type: "Breakfast") }
                                    Button("Lunch") { saveToPlan(day: day, type: "Lunch") }
                                    Button("Dinner") { saveToPlan(day: day, type: "Dinner") }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "calendar.badge.plus")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Plan")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                LinearGradient(
                                    colors: [.blue.opacity(0.92), .cyan.opacity(0.86)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

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
                    IngredientsTab(
                        ingredients: recipe.ingredients,
                        pantryIngredients: pantryIngredients,
                        pantrySpaces: pantrySpaces,
                        selectedPantryId: selectedPantryId,
                        onAddAllMissing: { missing in
                            onAddMissingToGrocery?(recipe, missing)
                            dismissThenOpenGroceryListIfAvailable()
                        },
                        onOpenGroceryList: {
                            dismissThenOpenGroceryListIfAvailable()
                        },
                        onSelectPantry: onSelectPantry
                    )
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
    var pantryIngredients: [String] = []
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
                    IngredientsTab(
                        ingredients: recipe.ingredients,
                        pantryIngredients: pantryIngredients,
                        showsGroceryActions: false
                    )
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

private struct MissingIngredientPanel: View {
    let missingIngredients: [String]
    var pantrySpaces: [SimplePantrySpace] = []
    var selectedPantryId: String? = nil
    var onSelectPantry: ((String?) -> Void)? = nil
    var showsGroceryActions = true
    var onAddAll: (() -> Void)? = nil
    var onOpenList: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: missingIngredients.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(missingIngredients.isEmpty ? .green : .orange)

                Text(
                    missingIngredients.isEmpty
                    ? "Everything for this recipe is already in your pantry"
                    : "\(missingIngredients.count) ingredient\(missingIngredients.count == 1 ? "" : "s") missing from pantry"
                )
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            }

            if let onSelectPantry,
               let selectedPantry = pantrySpaces.first(where: { $0.id == selectedPantryId }) {
                Menu {
                    ForEach(pantrySpaces) { pantry in
                        Button {
                            onSelectPantry(pantry.id)
                        } label: {
                            HStack {
                                Text("\(pantry.emoji) \(pantry.name)")
                                if pantry.id == selectedPantryId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Checking")
                            .foregroundStyle(.secondary)
                        Text("\(selectedPantry.emoji) \(selectedPantry.name)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
                }
            }

            if !missingIngredients.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(missingIngredients, id: \.self) { ingredient in
                            Text(displayIngredientText(from: ingredient))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }

                if showsGroceryActions {
                    HStack(spacing: 8) {
                        if let onAddAll {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onAddAll()
                            }) {
                                Label("Add Missing to Grocery List", systemImage: "cart.badge.plus")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
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

                        if let onOpenList {
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                onOpenList()
                            }) {
                                Label("Open Grocery List", systemImage: "list.bullet.clipboard")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.primary.opacity(0.06))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke((missingIngredients.isEmpty ? Color.green : Color.orange).opacity(0.22), lineWidth: 1)
        )
    }
}

private struct IngredientsTab: View {
    let ingredients: [String]
    var pantryIngredients: [String] = []
    var pantrySpaces: [SimplePantrySpace] = []
    var selectedPantryId: String? = nil
    var showsGroceryActions = true
    var onAddAllMissing: (([String]) -> Void)? = nil
    var onOpenGroceryList: (() -> Void)? = nil
    var onSelectPantry: ((String?) -> Void)? = nil

    private var missingItems: [String] {
        missingIngredients(from: ingredients, pantryIngredients: pantryIngredients)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !pantryIngredients.isEmpty {
                MissingIngredientPanel(
                    missingIngredients: missingItems,
                    pantrySpaces: pantrySpaces,
                    selectedPantryId: selectedPantryId,
                    onSelectPantry: onSelectPantry,
                    showsGroceryActions: showsGroceryActions,
                    onAddAll: {
                        guard !missingItems.isEmpty else { return }
                        onAddAllMissing?(missingItems)
                    },
                    onOpenList: onOpenGroceryList
                )
            }

            ForEach(Array(ingredients.enumerated()), id: \.offset) { _, item in
                let hasIngredient = pantryContainsIngredient(item, pantryIngredients: pantryIngredients)
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: pantryIngredients.isEmpty ? "circle.fill" : (hasIngredient ? "checkmark.circle.fill" : "xmark.circle.fill"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(
                            pantryIngredients.isEmpty
                            ? Color.orange
                            : (hasIngredient ? Color.green : Color.orange)
                        )
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item)
                            .font(.system(size: 15, design: .rounded))
                            .lineSpacing(3)

                        if !pantryIngredients.isEmpty {
                            Text(hasIngredient ? "In pantry" : "Missing from pantry")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(hasIngredient ? .green : .orange)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 2)
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


// Reusable macro display card. Only renders if at least one macro field is
// populated, so it's safe to show on recipes that predate nutrition tracking.
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


private struct GroceryRecipeGroup: Identifiable {
    let id: String
    let recipeTitle: String
    let recipeEmoji: String
    let items: [GroceryListItem]

    var remainingCount: Int {
        items.filter { !$0.isPurchased }.count
    }
}

struct GroceryListView: View {
    let userId: String
    @ObservedObject var assistant: CookingAssistant
    let budgetPreference: String

    @EnvironmentObject var authVM: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [GroceryListItem] = []
    @State private var selectedStore: GroceryStore = .safeway
    @State private var searchText = ""
    @State private var isMatchingStoreProducts = false
    @State private var matchAnimationStep = 0
    @State private var matchTimer: Timer?
    @State private var listener: ListenerRegistration?
    @State private var expandedRecipeId: String? = nil
    @State private var heroPulse = false
    @State private var pantrySpaces: [SimplePantrySpace] = []
    @State private var selectedPantryId: String? = nil
    @State private var pantryListener: ListenerRegistration? = nil

    private var itemsCollection: CollectionReference {
        Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("groceryList")
            .document("active")
            .collection("items")
    }

    private var filteredItems: [GroceryListItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }

        return items.filter { item in
            let text = "\(item.recipeTitle) \(item.ingredientDisplay) \(item.normalizedIngredient)".lowercased()
            return text.contains(query)
        }
    }

    private var groupedItems: [GroceryRecipeGroup] {
        let grouped = Dictionary(grouping: filteredItems) { item in
            item.recipeId ?? item.recipeTitle.lowercased()
        }

        return grouped.compactMap { id, values in
            guard let first = values.first else { return nil }
            return GroceryRecipeGroup(
                id: id,
                recipeTitle: first.recipeTitle,
                recipeEmoji: first.recipeEmoji,
                items: values.sorted { $0.createdAt > $1.createdAt }
            )
        }
        .sorted { lhs, rhs in
            lhs.recipeTitle.localizedCaseInsensitiveCompare(rhs.recipeTitle) == .orderedAscending
        }
    }

    private var purchasedCount: Int {
        items.filter { $0.isPurchased }.count
    }

    private var totalCount: Int {
        items.count
    }

    private var recipeGroupCount: Int {
        groupedItems.count
    }

    private var completionRatio: Double {
        guard totalCount > 0 else { return 0 }
        return Double(purchasedCount) / Double(totalCount)
    }

    private var selectedPantry: SimplePantrySpace? {
        pantrySpaces.first(where: { $0.id == selectedPantryId })
    }

    private var itemStateSignature: String {
        items.map { ($0.id ?? "") + ($0.isPurchased ? "1" : "0") }.joined(separator: "|")
    }

    var body: some View {
        ZStack {
            backgroundLayer
            scrollContent
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear {
            startListening()
            startPantryListening()
            heroPulse = true
            Task { await matchStoreProducts(force: false) }
        }
        .onDisappear {
            listener?.remove()
            listener = nil
            pantryListener?.remove()
            pantryListener = nil
            stopMatchTimer()
        }
        .onChange(of: selectedStore) { _ in
            Task { await matchStoreProducts(force: false) }
        }
        .onChange(of: itemStateSignature) { _ in
            Task { await matchStoreProducts(force: false) }
        }
        .onChange(of: selectedPantryId) { pantryId in
            authVM.updateActivePantrySelection(pantryId)
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            ChefBuddyBackground()
            Circle()
                .fill(Color.orange.opacity(heroPulse ? 0.12 : 0.07))
                .blur(radius: 90)
                .offset(x: -170, y: -260)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: heroPulse)
            Circle()
                .fill(Color.green.opacity(heroPulse ? 0.11 : 0.06))
                .blur(radius: 90)
                .offset(x: 170, y: 320)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: heroPulse)
        }
    }

    private var scrollContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                headerMetricsCard
                searchBarCard
                storeControlsCard

                if isMatchingStoreProducts {
                    matchingBanner
                }

                groupedListContent
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
    }

    private var headerMetricsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Grocery List")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))

                    Text("Everything still missing from your recipes, organized into a cleaner shopping flow.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        groceryHeroPill(
                            title: selectedPantry.map { "\($0.emoji) \($0.name)" } ?? "Pantry syncing",
                            systemImage: "basket.fill",
                            tint: .green
                        )
                        groceryHeroPill(
                            title: selectedStore.rawValue,
                            systemImage: "cart.fill",
                            tint: .orange
                        )
                    }
                }

                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 8)
                        .frame(width: 78, height: 78)

                    Circle()
                        .trim(from: 0, to: completionRatio)
                        .stroke(
                            LinearGradient(
                                colors: [.orange, .green.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 78, height: 78)

                    VStack(spacing: 2) {
                        Text("\(purchasedCount)")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                        Text("picked up")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 12) {
                GroceryStatTile(icon: "fork.knife", value: "\(recipeGroupCount)", label: "Recipes", color: .blue)
                GroceryStatTile(icon: "cart.fill", value: "\(totalCount)", label: "Need", color: .orange)
                GroceryStatTile(icon: "checkmark.circle.fill", value: "\(purchasedCount)", label: "Picked Up", color: .green)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.05), Color.green.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var searchBarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search your list")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Search recipe or ingredient", text: $searchText)
                    .font(.system(size: 14, design: .rounded))

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var storeControlsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Store matching")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GroceryStore.allCases) { store in
                        let selected = selectedStore == store
                        Button(action: {
                            guard !selected else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                selectedStore = store
                            }
                        }) {
                            HStack(spacing: 6) {
                                Text(store.emoji)
                                Text(store.rawValue)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(selected ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selected
                                ? AnyView(
                                    LinearGradient(
                                        colors: [.orange, .green.opacity(0.85)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                : AnyView(Color.primary.opacity(0.08))
                            )
                            .clipShape(Capsule())
                            .scaleEffect(selected ? 1.02 : 1.0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("Pick where you are shopping and let ChefBuddy line up the closest product matches.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await matchStoreProducts(force: true) }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Match Products")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [.orange, .green.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isMatchingStoreProducts || filteredItems.isEmpty)

                Button(action: removePurchasedItems) {
                    Label("Remove Purchased", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(purchasedCount == 0)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var matchingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Matching products at \(selectedStore.rawValue)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("ChefBuddy is checking the best fit for your remaining ingredients.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            RecipeBouncingDotsView(step: matchAnimationStep, color: .orange)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func startPantryListening() {
        pantryListener?.remove()
        pantryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }

                let spaces = documents.map { document -> SimplePantrySpace in
                    let data = document.data()
                    let name = data["name"] as? String ?? "Pantry"
                    let emoji = data["emoji"] as? String ?? "🥑"
                    let colorTheme = data["colorTheme"] as? String ?? "Orange"
                    let ingredients = (data["virtualPantry"] as? [String: [String]] ?? [:]).values.flatMap { $0 }
                    return SimplePantrySpace(
                        id: document.documentID,
                        name: name,
                        emoji: emoji,
                        ingredients: ingredients,
                        colorTheme: colorTheme
                    )
                }
                .sorted { $0.name < $1.name }

                DispatchQueue.main.async {
                    pantrySpaces = spaces

                    if let selectedPantryId,
                       spaces.contains(where: { $0.id == selectedPantryId }) == false {
                        self.selectedPantryId = nil
                    }

                    if self.selectedPantryId == nil,
                       let preferredPantryId = authVM.currentUserProfile?.activePantryId,
                       spaces.contains(where: { $0.id == preferredPantryId }) {
                        self.selectedPantryId = preferredPantryId
                    } else if self.selectedPantryId == nil {
                        self.selectedPantryId = spaces.first?.id
                    }
                }
            }
    }

    @ViewBuilder
    private var groupedListContent: some View {
        if groupedItems.isEmpty {
            VStack(spacing: 8) {
                Text("🧺")
                    .font(.system(size: 44))
                Text("No grocery items yet")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("Add missing ingredients from any recipe to build a list here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: 12) {
                ForEach(groupedItems) { group in
                    groupCard(group)
                }
            }
        }
    }

    private func toggleGroupExpansion(_ group: GroceryRecipeGroup) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if expandedRecipeId == group.id {
                expandedRecipeId = nil
            } else {
                expandedRecipeId = group.id
            }
        }
    }

    private func groupCard(_ group: GroceryRecipeGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.18), .green.opacity(0.14)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)

                    Text(group.recipeEmoji)
                        .font(.system(size: 24))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(group.recipeTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s") • \(group.remainingCount) still to grab")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    Text(group.remainingCount == 0 ? "Ready" : "\(group.remainingCount) left")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(group.remainingCount == 0 ? .green : .orange)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background((group.remainingCount == 0 ? Color.green : Color.orange).opacity(0.14), in: Capsule())

                    Button(action: { toggleGroupExpansion(group) }) {
                        Image(systemName: expandedRecipeId == group.id ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button(role: .destructive) {
                    removeRecipeGroup(group)
                } label: {
                    Label("Remove Recipe", systemImage: "trash.fill")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
            }

            if expandedRecipeId == group.id {
                VStack(spacing: 8) {
                    ForEach(group.items) { item in
                        GroceryListItemRow(
                            item: item,
                            store: selectedStore,
                            isMatching: isMatchingStoreProducts,
                            onTogglePurchased: { togglePurchased(item) },
                            onFindMatch: {
                                Task {
                                    await matchStoreProducts(targetItems: [item], force: true)
                                }
                            }
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func startListening() {
        guard !userId.isEmpty else { return }

        listener?.remove()
        listener = itemsCollection
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { snap, _ in
                guard let docs = snap?.documents else { return }
                let decoded = docs.compactMap { try? $0.data(as: GroceryListItem.self) }

                DispatchQueue.main.async {
                    items = decoded
                }
            }
    }

    private func togglePurchased(_ item: GroceryListItem) {
        guard let id = item.id else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        itemsCollection.document(id).updateData(["isPurchased": !item.isPurchased])
    }

    private func removePurchasedItems() {
        let purchased = items.filter { $0.isPurchased }
        guard !purchased.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let batch = Firestore.firestore().batch()
        for item in purchased {
            guard let id = item.id else { continue }
            batch.deleteDocument(itemsCollection.document(id))
        }

        batch.commit { error in
            if error == nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func removeRecipeGroup(_ group: GroceryRecipeGroup) {
        guard !group.items.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let batch = Firestore.firestore().batch()
        for item in group.items {
            guard let id = item.id else { continue }
            batch.deleteDocument(itemsCollection.document(id))
        }

        batch.commit { error in
            if error == nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func startMatchTimer() {
        stopMatchTimer()
        matchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            matchAnimationStep += 1
        }
    }

    private func stopMatchTimer() {
        matchTimer?.invalidate()
        matchTimer = nil
        matchAnimationStep = 0
    }

    private func matchStoreProducts(targetItems: [GroceryListItem]? = nil, force: Bool) async {
        guard !isMatchingStoreProducts else { return }
        let source = targetItems ?? filteredItems
        let unresolved = source.filter { item in
            guard !item.isPurchased else { return false }
            if force { return true }
            return (item.matchesByStore[selectedStore.rawValue] ?? []).isEmpty
        }
        guard !unresolved.isEmpty else { return }

        await MainActor.run {
            isMatchingStoreProducts = true
            startMatchTimer()
        }

        do {
            try await assistant.waitUntilReady()

            let ingredients = unresolved.map { item in
                item.normalizedIngredient.isEmpty
                ? normalizedIngredientKey(from: item.ingredientDisplay)
                : item.normalizedIngredient
            }

            let matches = try await assistant.fetchStoreMatches(
                ingredients: ingredients,
                store: selectedStore,
                budgetPreference: budgetPreference
            )

            for item in unresolved {
                guard let id = item.id else { continue }
                let key = item.normalizedIngredient.isEmpty
                    ? normalizedIngredientKey(from: item.ingredientDisplay)
                    : item.normalizedIngredient
                guard let products = matches[key], !products.isEmpty else { continue }

                var updated = item
                var allMatches = updated.matchesByStore
                allMatches[selectedStore.rawValue] = products
                updated.matchesByStore = allMatches
                updated.id = nil
                try itemsCollection.document(id).setData(from: updated, merge: true)
            }

            await MainActor.run {
                isMatchingStoreProducts = false
                stopMatchTimer()
            }
        } catch {
            await MainActor.run {
                isMatchingStoreProducts = false
                stopMatchTimer()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func groceryHeroPill(title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct GroceryStatTile: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct GroceryListItemRow: View {
    let item: GroceryListItem
    let store: GroceryStore
    let isMatching: Bool
    let onTogglePurchased: () -> Void
    let onFindMatch: () -> Void

    private var selectedStoreMatches: [GroceryStoreProduct] {
        item.matchesByStore[store.rawValue] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: onTogglePurchased) {
                    Image(systemName: item.isPurchased ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(item.isPurchased ? .green : .secondary)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.ingredientDisplay)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(item.isPurchased ? .secondary : .primary)
                        .strikethrough(item.isPurchased, color: .secondary)
                    if !item.quantityHint.isEmpty {
                        Text(item.quantityHint)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }

                Spacer(minLength: 0)

                if item.isPurchased {
                    Text("Purchased")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.14))
                        .clipShape(Capsule())
                } else if selectedStoreMatches.isEmpty {
                    Button(action: onFindMatch) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text(isMatching ? "Matching..." : "Match")
                        }
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.14))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isMatching)
                } else {
                    Text("Matched")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.14))
                        .clipShape(Capsule())
                }
            }

            if !item.isPurchased, let best = selectedStoreMatches.first {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(best.name)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Spacer(minLength: 0)
                        Text(best.price)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                    Text("\(best.brand) • \(best.size) • \(best.section)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !best.note.isEmpty {
                        Text(best.note)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.blue.opacity(0.18), lineWidth: 1)
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(0.045))
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: item.isPurchased)
    }
}


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


                        NutritionBreakdownCard(nutrition: recipe.nutrition, calories: recipe.calories)


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


                        VStack(spacing: 12) {
                            if revisedRecipe == nil {

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
