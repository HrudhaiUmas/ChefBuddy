//
//  AIViewModel.swift
//  ChefBuddy
//
//  Created by nrml on 3/5/26.
//

import Combine
import FirebaseFirestore
import FirebaseAILogic
import SwiftUI

struct RecipeSuggestion: Identifiable, Codable, Equatable {
    let id = UUID()
    let title: String
    let emoji: String
    let description: String
    let prepTime: String
    let servings: String
    let difficulty: String
    let calories: String
    let tags: [String]
    let ingredients: [String]
    let steps: [String]
    let matchReason: String

    enum CodingKeys: String, CodingKey {
        case title
        case emoji
        case description
        case prepTime
        case servings
        case difficulty
        case calories
        case tags
        case ingredients
        case steps
        case matchReason
    }
}

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

class CookingAssistant: ObservableObject {
    private let db = Firestore.firestore()

    @Published var model: GenerativeModel?
    @Published var isModelReady = false
    @Published var suggestions: [RecipeSuggestion] = []

    /// Waits up to 10s for the model to be ready, then throws if it still isn't
    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(10)

        while !isModelReady {
            if Date() > deadline {
                throw CookingAssistantError.modelNotReady
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

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

    func fetchRecipeSuggestions() async {
        guard let model = model else { return }

        let prompt = """
        Generate 3 fully detailed recipe suggestions based on my profile.

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
        - tags must be a JSON array of strings
        - ingredients must be a JSON array of strings
        - steps must be a JSON array of strings
        - emoji must be a single relevant food emoji
        - make all 3 recipe titles different from each other
        """

        do {
            let response = try await model.generateContent(prompt)

            print("MODEL READY:", model != nil)
            print("AI RESPONSE:", response.text ?? "nil")

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

    func fetchOneMoreRecipeSuggestion(excludingTitles: [String]) async throws {
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

        let prompt = """
        Generate exactly 1 fully detailed recipe suggestion based on my profile.

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
          "tags": ["Healthy", "Quick", "High Protein"],
          "ingredients": ["ingredient 1", "ingredient 2", "ingredient 3"],
          "steps": ["step one", "step two", "step three"],
          "matchReason": "Why it fits the user"
        }

        Rules:
        - Do not include markdown
        - Do not include backticks
        - Do not include explanations
        - tags must be a JSON array of strings
        - ingredients must be a JSON array of strings
        - steps must be a JSON array of strings
        - emoji must be a single relevant food emoji
        - title must not match or be too similar to any excluded title
        """

        let response = try await model.generateContent(prompt)

        print("ONE MORE SUGGESTION RESPONSE:", response.text ?? "nil")

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
                systemInstruction: ModelContent(role: "system", parts: [TextPart(systemPrompt)])
            )

            await MainActor.run {
                self.model = newModel
                self.isModelReady = true
            }
        } catch {
            print("ChefBuddy setup error: \(error.localizedDescription)")
        }
    }

    func getHelp(question: String) async throws -> String {
        guard let model = model else {
            throw CookingAssistantError.modelNotReady
        }

        let response = try await model.generateContent(question)
        return response.text ?? "Hmm, I couldn't come up with anything. Try rephrasing!"
    }

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

    func scanFridgeIngredients(image: UIImage) async throws -> [String] {
        guard let model else {
            throw CookingAssistantError.modelNotReady
        }

        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw CookingAssistantError.imageProcessingFailed
        }

        let imagePart = InlineDataPart(data: imageData, mimeType: "image/jpeg")

        let prompt = """
        Look at this fridge image and identify food ingredients.

        Return ONLY a JSON array of ingredient names.

        Example:
        ["eggs", "milk", "spinach", "cheese"]
        """

        let response = try await model.generateContent(imagePart, prompt)

        guard let text = response.text else { return [] }

        let cleaned = text
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return [] }

        return try JSONDecoder().decode([String].self, from: data)
    }

    func generateRecipesFromIngredients(_ ingredients: [String]) async {
        guard let model else { return }

        let ingredientList = ingredients.joined(separator: ", ")

        let prompt = """
        Create 3 fully detailed recipes using ONLY these ingredients:

        \(ingredientList)

        You may add basic pantry staples (salt, pepper, oil, water).

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
            "tags": ["Healthy", "Quick"],
            "ingredients": ["ingredient 1", "ingredient 2", "ingredient 3"],
            "steps": ["step one", "step two", "step three"],
            "matchReason": "Why this recipe works with the ingredients"
          }
        ]

        Rules:
        - Do not include markdown
        - Do not include backticks
        - Do not include explanations
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
            print("Recipe generation failed:", error)
        }
    }
}
