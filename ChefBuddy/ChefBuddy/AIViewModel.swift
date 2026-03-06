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

class CookingAssistant: ObservableObject {
    private let db = Firestore.firestore()

    @Published var model: GenerativeModel?
    @Published var isModelReady = false

    func setupAssistant(userId: String) async {
        do {
            let snapshot = try await db.collection("users").document(userId).getDocument()
            let data = snapshot.data() ?? [:]

            let level      = data["chefLevel"]      as? String ?? "Beginner"
            let diets      = (data["dietTags"]      as? [String])?.joined(separator: ", ") ?? "none"
            let allergies  = (data["allergies"]     as? [String])?.joined(separator: ", ") ?? "none"
            let appliances = (data["appliances"]    as? [String])?.joined(separator: ", ") ?? "basic kitchen tools"
            let macros     = (data["macroTags"]     as? [String])?.joined(separator: ", ") ?? "balanced"
            let dislikes   = data["dislikes"]       as? String ?? "none"
            let spice      = data["spiceTolerance"] as? String ?? "Medium"
            let cookTime   = data["cookTime"]       as? String ?? "30 mins"
            let budget     = data["budget"]         as? String ?? "Standard"
            let servings   = data["servingSize"]    as? String ?? "1 Person"

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
                modelName: "gemini-2.0-flash-preview",
                systemInstruction: ModelContent(parts: [TextPart(systemPrompt)])
            )

            await MainActor.run {
                self.model = newModel
                self.isModelReady = true
            }

        } catch {
            print("ChefBuddy setup error: \(error.localizedDescription)")
        }
    }

    // Text-only chat
    func getHelp(question: String) async throws -> String {
        guard let model = model else { return "Chef is still getting ready..." }
        let response = try await model.generateContent(question)
        return response.text ?? "Hmm, I couldn't come up with anything. Try rephrasing!"
    }

    // Live camera frame + question — image first, then text (Firebase SDK convention)
    func getLiveHelp(image: UIImage, question: String) async throws -> String {
        guard let model = model else { return "Chef is still getting ready..." }
        let response = try await model.generateContent(image, question)
        return response.text ?? "I'm not sure — could you show me the ingredients again?"
    }
}
