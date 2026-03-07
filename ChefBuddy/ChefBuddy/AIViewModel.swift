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

enum CookingAssistantError: LocalizedError {
    case modelNotReady
    case imageProcessingFailed

    var errorDescription: String? {
        switch self {
        case .modelNotReady:        return "ChefBuddy is still loading. Please wait a moment and try again."
        case .imageProcessingFailed: return "Couldn't process the image. Please try again."
        }
    }
}

class CookingAssistant: ObservableObject {
    private let db = Firestore.firestore()

    @Published var model: GenerativeModel?
    @Published var isModelReady = false

    /// Waits up to 10s for the model to be ready, then throws if it still isn't
    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(10)
        while !isModelReady {
            if Date() > deadline { throw CookingAssistantError.modelNotReady }
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2s poll
        }
    }

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

            // systemInstruction uses ModelContent with TextPart (Part protocol, not enum)
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

    // Text-only chat — throws if model isn't ready so callers can handle it properly
    func getHelp(question: String) async throws -> String {
        guard let model = model else {
            throw CookingAssistantError.modelNotReady
        }
        let response = try await model.generateContent(question)
        return response.text ?? "Hmm, I couldn't come up with anything. Try rephrasing!"
    }

    // Live camera frame + question
    // InlineDataPart is the correct type (ModelContent.Part enum was removed in Firebase SDK 12.x)
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
}
