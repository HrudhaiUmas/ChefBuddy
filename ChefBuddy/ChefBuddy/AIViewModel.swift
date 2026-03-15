// AIViewModel.swift
// Defines CookingAssistant — the central AI brain of ChefBuddy.
// Owns the Gemini model instance and exposes every AI operation the app uses:
// recipe suggestions, pantry scanning, live cooking help, and fridge image analysis.
// All AI calls go through this single class so model setup and error handling stay in one place.

import Combine
import FirebaseFirestore
import FirebaseAILogic
import SwiftUI

// A single AI-generated recipe card shown in the suggestion carousel.
// Identifiable so SwiftUI lists can diff them; Equatable so we can deduplicate.
struct RecipeSuggestion: Identifiable, Codable, Equatable {
    let id = UUID()
    let title: String
    let emoji: String
    let description: String
    let prepTime: String
    let servings: String
    let difficulty: String
    let calories: String
    let carbs: String
    let protein: String
    let fat: String
    let saturatedFat: String
    let sugar: String
    let fiber: String
    let sodium: String
    let tags: [String]
    let ingredients: [String]
    let steps: [String]
    let matchReason: String

    // Explicit keys let us rename Swift properties without breaking the JSON contract.
enum CodingKeys: String, CodingKey {
        case title
        case emoji
        case description
        case prepTime
        case servings
        case difficulty
        case calories
        case carbs
        case protein
        case fat
        case saturatedFat
        case sugar
        case fiber
        case sodium
        case tags
        case ingredients
        case steps
        case matchReason
    }

    init(
        title: String,
        emoji: String,
        description: String,
        prepTime: String,
        servings: String,
        difficulty: String,
        calories: String,
        carbs: String,
        protein: String,
        fat: String,
        saturatedFat: String,
        sugar: String,
        fiber: String,
        sodium: String,
        tags: [String],
        ingredients: [String],
        steps: [String],
        matchReason: String
    ) {
        self.title = title
        self.emoji = emoji
        self.description = description
        self.prepTime = prepTime
        self.servings = servings
        self.difficulty = difficulty
        self.calories = calories
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.saturatedFat = saturatedFat
        self.sugar = sugar
        self.fiber = fiber
        self.sodium = sodium
        self.tags = tags
        self.ingredients = ingredients
        self.steps = steps
        self.matchReason = matchReason
    }

    // Custom decoder because the AI sometimes returns numbers or booleans instead
    // of strings. decodeFlexibleString handles all those edge cases gracefully.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.title = container.decodeFlexibleString(forKey: .title)
        self.emoji = container.decodeFlexibleString(forKey: .emoji, defaultValue: "🍽️")
        self.description = container.decodeFlexibleString(forKey: .description)
        self.prepTime = container.decodeFlexibleString(forKey: .prepTime, defaultValue: "20 mins")
        self.servings = container.decodeFlexibleString(forKey: .servings, defaultValue: "1 person")
        self.difficulty = container.decodeFlexibleString(forKey: .difficulty, defaultValue: "Intermediate")
        self.calories = container.decodeFlexibleString(forKey: .calories, defaultValue: "0 kcal")
        self.carbs = container.decodeFlexibleString(forKey: .carbs, defaultValue: "0g")
        self.protein = container.decodeFlexibleString(forKey: .protein, defaultValue: "0g")
        self.fat = container.decodeFlexibleString(forKey: .fat, defaultValue: "0g")
        self.saturatedFat = container.decodeFlexibleString(forKey: .saturatedFat, defaultValue: "0g")
        self.sugar = container.decodeFlexibleString(forKey: .sugar, defaultValue: "0g")
        self.fiber = container.decodeFlexibleString(forKey: .fiber, defaultValue: "0g")
        self.sodium = container.decodeFlexibleString(forKey: .sodium, defaultValue: "0mg")
        let parsedTags = container.decodeFlexibleStringArray(forKey: .tags)
        self.tags = parsedTags.isEmpty ? ["Fusion"] : parsedTags
        self.ingredients = container.decodeFlexibleStringArray(forKey: .ingredients)
        self.steps = container.decodeFlexibleStringArray(forKey: .steps)
        self.matchReason = container.decodeFlexibleString(forKey: .matchReason)
    }

    // Convenience computed property so callers get a NutritionInfo without
    // having to manually assemble it from the individual macro fields.
    var nutrition: NutritionInfo {
        NutritionInfo(
            calories: calories,
            carbs: carbs,
            protein: protein,
            fat: fat,
            saturatedFat: saturatedFat,
            sugar: sugar,
            fiber: fiber,
            sodium: sodium
        )
    }
}

// Extension that makes JSON decoding resilient to the AI returning numbers,
// booleans, or nested dicts where strings are expected. Without this the app
// would crash whenever Gemini slightly deviates from the requested format.
private extension KeyedDecodingContainer {
    // Tries String first, then falls back to Int, Double, Bool, and dict lookups.
    // Returns defaultValue if nothing works so the recipe still renders.
    func decodeFlexibleString(forKey key: K, defaultValue: String = "") -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let intValue = try? decode(Int.self, forKey: key) {
            return String(intValue)
        }

        if let doubleValue = try? decode(Double.self, forKey: key) {
            if doubleValue.rounded() == doubleValue {
                return String(Int(doubleValue))
            }
            return String(doubleValue)
        }

        if let boolValue = try? decode(Bool.self, forKey: key) {
            return boolValue ? "true" : "false"
        }

        if let dictValue = try? decode([String: String].self, forKey: key) {
            let preferredKeys = ["text", "value", "name", "title", "label", "description"]
            for preferredKey in preferredKeys {
                if let value = dictValue[preferredKey], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if let firstNonEmpty = dictValue.values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return firstNonEmpty.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return defaultValue
    }

    // Handles arrays that may arrive as comma-separated strings or as arrays
    // of dicts (Gemini occasionally wraps items in {"text": "..."} objects).
    func decodeFlexibleStringArray(forKey key: K) -> [String] {
        if let value = try? decode([String].self, forKey: key) {
            return value
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        if let value = try? decode(String.self, forKey: key) {
            let split = value
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !split.isEmpty {
                return split
            }

            let single = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return single.isEmpty ? [] : [single]
        }

        if let value = try? decode([[String: String]].self, forKey: key) {
            return value.compactMap { dictionary in
                let preferredKeys = ["text", "value", "name", "title", "ingredient", "step", "description", "item"]
                for preferredKey in preferredKeys {
                    if let found = dictionary[preferredKey] {
                        let trimmed = found.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed
                        }
                    }
                }

                if let firstNonEmpty = dictionary.values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    return firstNonEmpty.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                return nil
            }
        }

        if let value = try? decode([[String: AnyDecodable]].self, forKey: key) {
            return value.compactMap { dictionary in
                let preferredKeys = ["text", "value", "name", "title", "ingredient", "step", "description", "item"]
                for preferredKey in preferredKeys {
                    if let found = dictionary[preferredKey]?.stringValue {
                        let trimmed = found.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed
                        }
                    }
                }

                if let firstNonEmpty = dictionary.values.compactMap({ $0.stringValue }).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    return firstNonEmpty.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                return nil
            }
        }

        return []
    }
}

// Type-erased Decodable used when we need to peek inside heterogeneous JSON
// arrays or dicts before committing to a concrete Swift type.
struct AnyDecodable: Decodable {
    let value: Any

    var stringValue: String? {
        switch value {
        case let string as String:
            return string
        case let int as Int:
            return String(int)
        case let double as Double:
            if double.rounded() == double {
                return String(Int(double))
            }
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            self.value = string
            return
        }

        if let int = try? container.decode(Int.self) {
            self.value = int
            return
        }

        if let double = try? container.decode(Double.self) {
            self.value = double
            return
        }

        if let bool = try? container.decode(Bool.self) {
            self.value = bool
            return
        }

        if let dictionary = try? container.decode([String: String].self) {
            self.value = dictionary
            return
        }

        if let array = try? container.decode([String].self) {
            self.value = array
            return
        }

        self.value = ""
    }
}

// Typed errors so the UI can show useful messages instead of raw system errors.
enum CookingAssistantError: LocalizedError {
    case modelNotReady
    case imageProcessingFailed

    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "ChefBuddy is still loading. Please wait a moment and try again."
        case .imageProcessingFailed:
            return "Couldn't process the image. Please try again."
        }
    }
}

// The AI model wrapper. One instance lives in HomeView and is passed down
// so all child views share the same warmed-up model — avoids re-initialising
// Gemini every time a sheet opens.
class CookingAssistant: ObservableObject {
    private let db = Firestore.firestore()

    @Published var model: GenerativeModel?
    @Published var isModelReady = false
    @Published var suggestions: [RecipeSuggestion] = []

    // Polls isModelReady up to 10 seconds so callers can safely await the model
    // without hardcoding delays or risking a crash on a cold launch.
    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(10)

        while !isModelReady {
            if Date() > deadline {
                throw CookingAssistantError.modelNotReady
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // Strips markdown fences and locates the first [...] block in the response.
    // Gemini sometimes wraps JSON in ```json blocks even when instructed not to.
    private func cleanJSONArrayString(from rawText: String?) -> String? {
        guard var jsonString = rawText else { return nil }

        jsonString = jsonString
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = jsonString.firstIndex(of: "[") {
            jsonString = String(jsonString[start...])
        }

        if let end = jsonString.lastIndex(of: "]") {
            jsonString = String(jsonString[...end])
        }

        return jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Same as cleanJSONArrayString but for single-object responses.
    private func cleanJSONObjectString(from rawText: String?) -> String? {
        guard var jsonString = rawText else { return nil }

        jsonString = jsonString
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = jsonString.firstIndex(of: "{") {
            jsonString = String(jsonString[start...])
        }

        if let end = jsonString.lastIndex(of: "}") {
            jsonString = String(jsonString[...end])
        }

        return jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Generates 3 personalised recipe suggestions and stores them in self.suggestions.
    // If the user has left reviews, their feedback is injected into the prompt so
    // future suggestions learn from what they liked or disliked.
    func fetchRecipeSuggestions(reviewFeedback: String = "") async {
        guard let model = model else { return }

        let feedbackSection = reviewFeedback.isEmpty ? "" : """


        Important — personalise based on this user feedback from past recipes:
        \(reviewFeedback)
        Use this to suggest recipes they will enjoy more and avoid patterns they disliked.
        """

        let prompt = """
        Generate 3 fully detailed recipe suggestions based on my profile.\(feedbackSection)

        Return ONLY valid JSON.

        Format exactly like this:

        [
          {
            "title": "Recipe name",
            "emoji": "🍝",
            "description": "Short description",
            "prepTime": "20 mins",
            "servings": "2 people",
            "difficulty": "Easy",
            "calories": "420 kcal",
            "carbs": "42g",
            "protein": "35g",
            "fat": "12g",
            "saturatedFat": "4g",
            "sugar": "8g",
            "fiber": "5g",
            "sodium": "620mg",
            "tags": ["Healthy", "Quick", "High Protein"],
            "ingredients": ["ingredient 1", "ingredient 2", "ingredient 3"],
            "steps": ["step one", "step two", "step three"],
            "matchReason": "Why it fits the user"
          }
        ]

        Rules:
        - Do not include markdown
        - Do not include backticks
        - Do not include explanations
        - tags must be a JSON array of strings and must include at least one cuisine tag
        - ingredients must be a JSON array of strings
        - steps must be a JSON array of strings
        - never return dictionaries inside ingredients or steps
        - ingredients must include concrete quantities and units
        - steps must be detailed and precise, including prep steps (wash/chop/preheat where relevant)
        - steps must include timing/doneness cues where relevant
        - emoji must be a single relevant food emoji
        - make all 3 recipe titles different from each other
        """

        do {
            let response = try await model.generateContent(prompt)

            guard let jsonString = cleanJSONArrayString(from: response.text) else { return }
            guard let data = jsonString.data(using: .utf8) else { return }

            let decoded = try JSONDecoder().decode([RecipeSuggestion].self, from: data)

            await MainActor.run {
                self.suggestions = decoded
            }
        } catch {
            print("Failed to generate suggestions: \(error)")
        }
    }

    // Appends one new suggestion to the carousel without duplicating existing ones.
    // Passing excludedTitles in the prompt prevents Gemini from regenerating a
    // recipe the user already sees.
    func fetchOneMoreRecipeSuggestion(excludingTitles: [String], reviewFeedback: String = "") async throws {
        guard let model = model else {
            throw CookingAssistantError.modelNotReady
        }

        let cleanedTitles = excludingTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let excludedTitlesText: String
        if cleanedTitles.isEmpty {
            excludedTitlesText = "None"
        } else {
            excludedTitlesText = cleanedTitles.joined(separator: ", ")
        }

        let feedbackSection = reviewFeedback.isEmpty ? "" : """


        Important — personalise based on this user feedback from past recipes:
        \(reviewFeedback)
        Use this to suggest a recipe they will enjoy more and avoid patterns they disliked.
        """

        let prompt = """
        Generate exactly 1 fully detailed recipe suggestion based on my profile.\(feedbackSection)

        The recipe title MUST be different from all of these existing titles:
        \(excludedTitlesText)

        Return ONLY valid JSON as a single object.

        Format exactly like this:

        {
          "title": "Recipe name",
          "emoji": "🍝",
          "description": "Short description",
          "prepTime": "20 mins",
          "servings": "2 people",
          "difficulty": "Easy",
          "calories": "420 kcal",
          "carbs": "42g",
          "protein": "35g",
          "fat": "12g",
          "saturatedFat": "4g",
          "sugar": "8g",
          "fiber": "5g",
          "sodium": "620mg",
          "tags": ["Healthy", "Quick", "High Protein"],
          "ingredients": ["ingredient 1", "ingredient 2", "ingredient 3"],
          "steps": ["step one", "step two", "step three"],
          "matchReason": "Why it fits the user"
        }

        Rules:
        - Do not include markdown
        - Do not include backticks
        - Do not include explanations
        - tags must be a JSON array of strings and must include at least one cuisine tag
        - ingredients must be a JSON array of strings
        - steps must be a JSON array of strings
        - never return dictionaries inside ingredients or steps
        - ingredients must include concrete quantities and units
        - steps must be detailed and precise, including prep steps (wash/chop/preheat where relevant)
        - steps must include timing/doneness cues where relevant
        - emoji must be a single relevant food emoji
        - title must not match or be too similar to any excluded title
        """

        let response = try await model.generateContent(prompt)

        guard let jsonString = cleanJSONObjectString(from: response.text) else { return }
        guard let data = jsonString.data(using: .utf8) else { return }

        let decoded = try JSONDecoder().decode(RecipeSuggestion.self, from: data)

        let normalizedExcluded = Set(
            cleanedTitles.map { $0.lowercased() }
        )

        let normalizedNewTitle = decoded.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        await MainActor.run {
            if !normalizedExcluded.contains(normalizedNewTitle) &&
                !self.suggestions.contains(where: {
                    $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedNewTitle
                }) {
                self.suggestions.append(decoded)
            }
        }
    }

    // Generates 3 recipes constrained to the ingredients the user has on hand.
    // Strips emoji prefixes from pantry item strings before sending to the model.
    func generatePantryRecipes(ingredients: [String]) async throws -> [RecipeSuggestion] {
        guard let model else {
            throw CookingAssistantError.modelNotReady
        }

        let cleanIngredients = ingredients.map { item -> String in
            let parts = item.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : item
        }

        let ingredientList = cleanIngredients.joined(separator: ", ")

        let prompt = """
        Create 3 fully detailed recipes using ONLY the following ingredients from my pantry:
        \(ingredientList)

        You may add basic kitchen staples (salt, pepper, olive oil, water, butter).
        CRITICAL: You MUST strictly adhere to my dietary preferences, allergies, and restrictions defined in your system instructions.

        Return ONLY valid JSON in this format:

        [
          {
            "title": "Recipe name",
            "emoji": "🥗",
            "description": "Short description",
            "prepTime": "20 mins",
            "servings": "2 people",
            "difficulty": "Easy",
            "calories": "350 kcal",
            "carbs": "42g",
            "protein": "35g",
            "fat": "12g",
            "saturatedFat": "4g",
            "sugar": "8g",
            "fiber": "5g",
            "sodium": "620mg",
            "tags": ["Healthy", "Quick"],
            "ingredients": ["ingredient 1", "ingredient 2"],
            "steps": ["step one", "step two"],
            "matchReason": "Why this recipe works with the ingredients"
          }
        ]

        Rules:
        - Do not include markdown or backticks
        - tags must be an array of strings only and must include at least one cuisine tag
        - ingredients must be an array of strings only
        - steps must be an array of strings only
        - never return objects inside ingredients or steps
        - ingredients must include concrete quantities and units
        - steps must be detailed and precise, including prep steps (wash/chop/preheat where relevant)
        - steps must include timing/doneness cues where relevant
        - make all 3 recipe titles different from each other
        """

        let response = try await model.generateContent(prompt)

        guard let jsonString = cleanJSONArrayString(from: response.text) else {
            throw URLError(.badServerResponse)
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw URLError(.cannotDecodeRawData)
        }

        return try JSONDecoder().decode([RecipeSuggestion].self, from: data)
    }

    // Fetches the user's full profile from Firestore and builds a system prompt
    // that pins Gemini's persona to their preferences. Called once on HomeView
    // appear — subsequent AI calls inherit the context without re-fetching.
    func setupAssistant(userId: String) async {
        do {
            let snapshot = try await db.collection("users").document(userId).getDocument()
            let data = snapshot.data() ?? [:]

            let level = data["chefLevel"] as? String ?? "Beginner"
            let diets = (data["dietTags"] as? [String])?.joined(separator: ", ") ?? "none"
            let allergies = (data["allergies"] as? [String])?.joined(separator: ", ") ?? "none"
            let appliances = (data["appliances"] as? [String])?.joined(separator: ", ") ?? "basic kitchen tools"
            let macros = (data["macroTags"] as? [String])?.joined(separator: ", ") ?? "balanced"
            let dislikes = data["dislikes"] as? String ?? "none"
            let spice = data["spiceTolerance"] as? String ?? "Medium"
            let cookTime = data["cookTime"] as? String ?? "30 mins"
            let budget = data["budget"] as? String ?? "Standard"
            let servings = data["servingSize"] as? String ?? "1 Person"

            let systemPrompt = """
            You are ChefBuddy, a friendly and professional sous-chef AI assistant.

            USER PROFILE:
            - Experience Level: \(level)
            - Dietary Preferences: \(diets)
            - STRICT Allergies (NEVER suggest these): \(allergies)
            - Ingredients to Avoid: \(dislikes)
            - Available Kitchen Appliances: \(appliances)
            - Macro Goals: \(macros)
            - Spice Tolerance: \(spice)
            - Preferred Cook Time: \(cookTime)
            - Budget: \(budget)
            - Serving Size: \(servings)

            ROLE:
            - Provide real-time, friendly cooking help tailored to the user's \(level) experience.
            - If the user shares an image, identify visible ingredients and suggest recipes accordingly.
            - Always respect allergies strictly — never include them even as optional suggestions.
            - Scale recipes to \(servings) and keep instructions appropriate for a \(level) cook.
            - Keep responses concise, encouraging, and practical.
            """

            let newModel = FirebaseAI.firebaseAI().generativeModel(
                modelName: "gemini-2.5-flash",
                systemInstruction: ModelContent(
                    role: "system",
                    parts: [TextPart(systemPrompt)]
                )
            )

            await MainActor.run {
                self.model = newModel
                self.isModelReady = true
            }
        } catch {
            print("ChefBuddy setup error: \(error.localizedDescription)")
        }
    }

    // General-purpose text question to the model. Used for typed chat questions
    // in LiveCookingView and for recipe generation prompts in RecipesViewModel.
    func getHelp(question: String) async throws -> String {
        guard let model = model else {
            throw CookingAssistantError.modelNotReady
        }

        let response = try await model.generateContent(question)
        return response.text ?? "Hmm, I couldn't come up with anything. Try rephrasing!"
    }

    // Multimodal call — sends both an image frame and a text prompt so Gemini
    // can see what the user is cooking and give step-specific visual guidance.
    func getLiveHelp(image: UIImage, question: String) async throws -> String {
        guard let model = model else {
            throw CookingAssistantError.modelNotReady
        }

        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw CookingAssistantError.imageProcessingFailed
        }

        let imagePart = InlineDataPart(data: imageData, mimeType: "image/jpeg")
        let response = try await model.generateContent(imagePart, question)
        return response.text ?? "I'm not sure — could you show me the ingredients again?"
    }

    func generateRecipesFromIngredients(_ ingredients: [String]) async {
        do {
            let decoded = try await generatePantryRecipes(ingredients: ingredients)

            await MainActor.run {
                self.suggestions = decoded
            }
        } catch {
            print("Recipe generation failed:", error)
        }
    }

    // Accepts one or more fridge/pantry photos and returns a categorised
    // ingredient dictionary. Sending all images in one request reduces latency
    // and gives the model full context of the fridge contents at once.
    func scanMultipleImages(images: [UIImage]) async throws -> [String: [String]] {
        guard let model else {
            throw CookingAssistantError.modelNotReady
        }

        var parts: [any Part] = []

        for image in images {
            if let imageData = image.jpegData(compressionQuality: 0.8) {
                parts.append(InlineDataPart(data: imageData, mimeType: "image/jpeg"))
            }
        }

        guard !parts.isEmpty else {
            throw CookingAssistantError.imageProcessingFailed
        }

        let prompt = """
        Look at these images of a fridge/pantry and identify all the raw food ingredients visible.
        Categorize them into exactly these categories: "Produce", "Protein", "Dairy", "Pantry", "Condiments", and "Other".
        Return ONLY a valid JSON object where keys are the categories and values are arrays of strings.
        Each string MUST start with a single highly relevant emoji, followed by a space, and then the ingredient name in lowercase.
        Do not duplicate ingredients.

        Example:
        {
          "Produce": ["🥬 spinach", "🍅 tomato"],
          "Protein": ["🍗 chicken", "🥚 eggs"],
          "Dairy": ["🥛 milk", "🧀 cheese"],
          "Pantry": ["🍚 rice", "🍝 pasta"],
          "Condiments": ["🥫 ketchup"],
          "Other": ["🧃 juice"]
        }
        """

        parts.append(TextPart(prompt))

        let content = ModelContent(role: "user", parts: parts)
        let response = try await model.generateContent([content])

        guard let text = response.text else { return [:] }

        let cleaned = text
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return [:] }
        return try JSONDecoder().decode([String: [String]].self, from: data)
    }
}
