// MealPlan.swift
// Meal planning feature — lets users schedule recipes across a week.
// Persists plan data to Firestore so it survives app restarts and can
// later be used to auto-generate a grocery list from planned meals.

import SwiftUI
import FirebaseFirestore
import FirebaseAuth
import Combine
import PhotosUI

private extension Calendar {
    func weekdayName(for date: Date) -> String {
        let weekday = component(.weekday, from: date)
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[max(0, min(names.count - 1, weekday - 1))]
    }
}

struct PlannedMealRecipe: Codable, Equatable {
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

    init(recipe: Recipe) {
        self.title = recipe.title
        self.emoji = recipe.emoji
        self.description = recipe.description
        self.ingredients = recipe.ingredients
        self.steps = recipe.steps
        self.cookTime = recipe.cookTime
        self.servings = recipe.servings
        self.difficulty = recipe.difficulty
        self.tags = recipe.tags
        self.calories = recipe.calories
        self.nutrition = recipe.nutrition
    }

    func asRecipe(id: String? = nil) -> Recipe {
        var recipe = Recipe(
            title: title,
            emoji: emoji,
            description: description,
            ingredients: ingredients,
            steps: steps,
            cookTime: cookTime,
            servings: servings,
            difficulty: difficulty,
            tags: tags,
            calories: calories,
            nutrition: nutrition,
            createdAt: Date()
        )
        recipe.id = id
        return recipe
    }
}

struct MealPlanSlot: Identifiable, Codable {
    var id: String?
    var day: String
    var mealType: String
    var recipeId: String?
    var recipeTitle: String?
    var plannedRecipe: PlannedMealRecipe?
    var status: MealPlanSlotStatus? = nil
    var completedAt: Date? = nil
    var consumedNutritionSnapshot: NutritionInfo? = nil
    var sourceType: MealPlanSourceType? = nil

    var displayTitle: String {
        let snapshotTitle = plannedRecipe?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let topLevelTitle = recipeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !snapshotTitle.isEmpty ? snapshotTitle : topLevelTitle
    }

    var hasRecipeContent: Bool {
        plannedRecipe != nil
    }

    var resolvedStatus: MealPlanSlotStatus {
        status ?? .planned
    }

    var isCompleted: Bool {
        resolvedStatus == .cooked || resolvedStatus == .logged
    }
}

private struct MealPlanGenerationSlot: Codable {
    let day: String
    let mealType: String
    let recipe: RecipeSuggestion
}

private func nutritionNumericValue(from raw: String) -> Double {
    let pattern = #"[-+]?\d*\.?\d+"#
    guard let range = raw.range(of: pattern, options: .regularExpression) else { return 0 }
    return Double(raw[range]) ?? 0
}

private func formatNutritionValue(_ value: Double, suffix: String) -> String {
    if value == 0 { return "0\(suffix)" }
    if value.rounded() == value {
        return "\(Int(value))\(suffix)"
    }
    return "\(String(format: "%.1f", value))\(suffix)"
}

struct DayNutritionSummary {
    let calories: String
    let carbs: String
    let protein: String
    let fat: String
    let sodium: String
}

struct DayNutritionRealitySummary {
    let planned: DayNutritionSummary
    let consumed: DayNutritionSummary
    let deltaCalories: String
}

struct MealLogDraft {
    var mode: MealLogInputMode = .quick
    var mealType: String = "Dinner"
    var title: String = ""
    var notes: String = ""
    var calories: String = ""
    var carbs: String = ""
    var protein: String = ""
    var fat: String = ""
    var sodium: String = ""
    var isEstimated: Bool = true
    var confidence: String? = nil
    var ingredients: [String] = [""]
    var steps: [String] = [""]
    var autoPolishWithAI: Bool = true
}

struct CustomMealRecipeDraft {
    var mealType: String = "Dinner"
    var title: String = ""
    var emoji: String = "🍽️"
    var description: String = ""
    var prepMinutes: Int = 25
    var servingsCount: Int = 2
    var difficulty: String = "Easy"
    var tagsText: String = "Custom"
    var calories: Int = 400
    var carbs: Int = 40
    var protein: Int = 25
    var fat: Int = 15
    var sodium: Int = 500
    var ingredients: [String] = [""]
    var steps: [String] = [""]
    var autoPolishWithAI: Bool = true
}

struct MealPlanGenerationSession: Equatable {
    enum Kind: Equatable {
        case weekly
        case day(day: String, mealTypes: [String])
    }

    let id = UUID()
    let kind: Kind
}


class MealPlanViewModel: ObservableObject {
    static let shared = MealPlanViewModel()

    @Published var weeklySlots: [MealPlanSlot] = []
    @Published var mealLogEvents: [MealLogEvent] = []
    @Published var isGenerating = false
    @Published var activeGeneration: MealPlanGenerationSession? = nil

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var mealLogListener: ListenerRegistration?
    private var generationTask: Task<Void, Never>? = nil

    func startListening(userId: String) {

        guard !userId.isEmpty else { return }
        listener?.remove()

        listener = db.collection("users")
            .document(userId)
            .collection("mealPlan")
            .addSnapshotListener { snapshot, _ in

                guard let documents = snapshot?.documents else { return }

                DispatchQueue.main.async {
                    self.weeklySlots = documents.compactMap {
                        try? $0.data(as: MealPlanSlot.self)
                    }
                }
            }

        mealLogListener?.remove()
        mealLogListener = db.collection("users")
            .document(userId)
            .collection("mealLogEvents")
            .order(by: "consumedAt", descending: true)
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }
                DispatchQueue.main.async {
                    self.mealLogEvents = documents.compactMap { try? $0.data(as: MealLogEvent.self) }
                }
            }

    }

    func addToPlan(recipe: Recipe, day: String, mealType: String, userId: String) {
        let slotId = "\(day)-\(mealType)"
        let ref = db.collection("users").document(userId).collection("mealPlan").document(slotId)
        let source: MealPlanSourceType = recipe.id == nil ? .custom : .saved

        let slot = MealPlanSlot(
            id: slotId,
            day: day,
            mealType: mealType,
            recipeId: recipe.id ?? "",
            recipeTitle: recipe.title,
            plannedRecipe: PlannedMealRecipe(recipe: recipe),
            status: .planned,
            completedAt: nil,
            consumedNutritionSnapshot: nil,
            sourceType: source
        )

        do {
            var payload = try Firestore.Encoder().encode(slot)
            payload["updatedAt"] = FieldValue.serverTimestamp()

            ref.setData(payload, merge: true) { error in
                if error == nil {
                    DispatchQueue.main.async {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    Task {
                        await GrowthEngine.shared.logActivity(
                            userId: userId,
                            type: .planAdd,
                            eventKey: "plan_add_\(slotId)",
                            metadata: [
                                "day": day,
                                "mealType": mealType,
                                "title": recipe.title
                            ]
                        )
                    }
                } else {
                    print("Error adding to plan: \(error?.localizedDescription ?? "Unknown error")")
                }
            }
        } catch {
            print("Error encoding meal plan slot: \(error.localizedDescription)")
        }
    }

    func removeFromPlan(day: String, mealType: String, userId: String) {
        let slotId = "\(day)-\(mealType)"
        let ref = db.collection("users")
            .document(userId)
            .collection("mealPlan")
            .document(slotId)

        ref.delete() { error in
            if error == nil {
                DispatchQueue.main.async {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } else {
                print("Error removing from plan: \(error?.localizedDescription ?? "Unknown error")")
            }
        }
    }

    deinit {
        listener?.remove()
        mealLogListener?.remove()
    }

    func startWeeklyPlanGeneration(
        assistant: CookingAssistant,
        userId: String
    ) {
        guard !userId.isEmpty else { return }

        let session = MealPlanGenerationSession(kind: .weekly)
        generationTask?.cancel()

        Task { @MainActor in
            activeGeneration = session
            isGenerating = true
        }

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.generateWeeklyPlan(assistant: assistant, userId: userId)
            await MainActor.run {
                if self.activeGeneration?.id == session.id {
                    self.activeGeneration = nil
                }
                self.generationTask = nil
            }
        }
    }

    func startDayCustomization(
        day: String,
        mealTypes: [String],
        prompt: String,
        assistant: CookingAssistant,
        userId: String
    ) {
        guard !userId.isEmpty, !day.isEmpty, !mealTypes.isEmpty else { return }

        let session = MealPlanGenerationSession(kind: .day(day: day, mealTypes: mealTypes))
        generationTask?.cancel()

        Task { @MainActor in
            activeGeneration = session
            isGenerating = true
        }

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.customizeDayPlan(
                day: day,
                mealTypes: mealTypes,
                prompt: prompt,
                assistant: assistant,
                userId: userId
            )
            await MainActor.run {
                if self.activeGeneration?.id == session.id {
                    self.activeGeneration = nil
                }
                self.generationTask = nil
            }
        }
    }

    func updatePlannedRecipe(_ recipe: Recipe, for slot: MealPlanSlot, userId: String) {
        guard let slotId = slot.id else { return }

        let updated = MealPlanSlot(
            id: slotId,
            day: slot.day,
            mealType: slot.mealType,
            recipeId: slot.recipeId,
            recipeTitle: recipe.title,
            plannedRecipe: PlannedMealRecipe(recipe: recipe),
            status: slot.status ?? .planned,
            completedAt: slot.completedAt,
            consumedNutritionSnapshot: slot.consumedNutritionSnapshot,
            sourceType: slot.sourceType ?? .saved
        )

        do {
            var payload = try Firestore.Encoder().encode(updated)
            payload["updatedAt"] = FieldValue.serverTimestamp()

            db.collection("users")
                .document(userId)
                .collection("mealPlan")
                .document(slotId)
                .setData(payload, merge: true)
        } catch {
            print("Error updating planned recipe snapshot: \(error.localizedDescription)")
        }
    }

    func updateSlotStatus(
        _ slot: MealPlanSlot,
        status: MealPlanSlotStatus,
        userId: String,
        consumedNutritionSnapshot: NutritionInfo? = nil
    ) {
        guard !userId.isEmpty, let slotId = slot.id else { return }

        var updated = slot
        updated.status = status
        updated.completedAt = (status == .cooked || status == .logged) ? Date() : nil
        if let consumedNutritionSnapshot {
            updated.consumedNutritionSnapshot = consumedNutritionSnapshot
        }

        do {
            var payload = try Firestore.Encoder().encode(updated)
            payload["updatedAt"] = FieldValue.serverTimestamp()
            db.collection("users")
                .document(userId)
                .collection("mealPlan")
                .document(slotId)
                .setData(payload, merge: true)
        } catch {
            print("Failed to update meal slot status: \(error.localizedDescription)")
        }

        if status == .cooked || status == .logged {
            Task {
                await GrowthEngine.shared.logActivity(
                    userId: userId,
                    type: .planComplete,
                    eventKey: "plan_complete_\(slotId)_\(status.rawValue)",
                    metadata: [
                        "day": slot.day,
                        "mealType": slot.mealType,
                        "status": status.rawValue
                    ]
                )

                if status == .cooked {
                    await GrowthEngine.shared.logActivity(
                        userId: userId,
                        type: .recipeCooked,
                        eventKey: "recipe_cooked_plan_\(slotId)",
                        metadata: [
                            "day": slot.day,
                            "mealType": slot.mealType,
                            "title": slot.displayTitle
                        ]
                    )
                }
            }
        }
    }

    func addMealLogEvent(
        day: String,
        mealType: String,
        title: String,
        notes: String,
        mode: MealLogInputMode,
        calories: String,
        nutrition: NutritionInfo,
        isEstimated: Bool,
        confidence: String?,
        ingredients: [String],
        steps: [String],
        userId: String
    ) async {
        guard !userId.isEmpty else { return }

        let logId = UUID().uuidString
        let event = MealLogEvent(
            id: logId,
            day: day,
            mealType: mealType,
            title: title,
            notes: notes,
            inputMode: mode.rawValue,
            calories: calories,
            carbs: nutrition.carbs,
            protein: nutrition.protein,
            fat: nutrition.fat,
            sodium: nutrition.sodium,
            consumedAt: Date(),
            createdAt: Date(),
            isEstimated: isEstimated,
            confidence: confidence,
            ingredients: ingredients.isEmpty ? nil : ingredients,
            steps: steps.isEmpty ? nil : steps
        )

        do {
            let encoded = try Firestore.Encoder().encode(event)
            try await db.collection("users")
                .document(userId)
                .collection("mealLogEvents")
                .document(logId)
                .setData(encoded, merge: false)

            await GrowthEngine.shared.logActivity(
                userId: userId,
                type: .mealLogged,
                eventKey: "meal_logged_\(logId)",
                metadata: [
                    "day": day,
                    "mealType": mealType,
                    "mode": mode.rawValue
                ]
            )
        } catch {
            print("Failed to store meal log event: \(error.localizedDescription)")
        }
    }

    private func consumedHistorySummary(userId: String) async -> String {
        guard !userId.isEmpty else { return "" }

        do {
            let snap = try await db.collection("users")
                .document(userId)
                .collection("mealLogEvents")
                .order(by: "consumedAt", descending: true)
                .limit(to: 40)
                .getDocuments()

            let logs = snap.documents.compactMap { try? $0.data(as: MealLogEvent.self) }
            guard !logs.isEmpty else { return "" }

            let titles = logs.map(\.title).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let calorieValues = logs.map { nutritionNumericValue(from: $0.calories) }.filter { $0 > 0 }
            let avgCalories = calorieValues.isEmpty ? nil : Int((calorieValues.reduce(0, +) / Double(calorieValues.count)).rounded())
            let frequentModes = Dictionary(grouping: logs, by: \.inputMode)
                .mapValues(\.count)
                .sorted { $0.value > $1.value }
                .prefix(2)
                .map(\.key)

            var parts: [String] = []
            if !titles.isEmpty {
                parts.append("Recently eaten meals include: \(Array(titles.prefix(5)).joined(separator: ", ")).")
            }
            if let avgCalories {
                parts.append("Logged intake style averages around \(avgCalories) kcal.")
            }
            if !frequentModes.isEmpty {
                parts.append("Most logs are captured through: \(frequentModes.joined(separator: ", ")).")
            }
            parts.append("Use this consumption history to keep suggestions realistic, not just theoretical.")
            return parts.joined(separator: " ")
        } catch {
            print("Failed to load consumed history summary: \(error.localizedDescription)")
            return ""
        }
    }


    func generateWeeklyPlan(
        assistant: CookingAssistant,
        userId: String
    ) async {

        guard !userId.isEmpty else { return }
        await MainActor.run {
            isGenerating = true
        }

        do {


            let userDoc = try await db.collection("users")
                .document(userId)
                .getDocument()

            let data = userDoc.data() ?? [:]

            let diets = (data["dietTags"] as? [String])?.joined(separator: ", ") ?? ""
            let allergies = (data["allergies"] as? [String])?.joined(separator: ", ") ?? ""
            let macros = (data["macroTags"] as? [String])?.joined(separator: ", ") ?? ""
            let cuisines = (data["cuisines"] as? [String])?.joined(separator: ", ") ?? ""
            let spice = data["spiceTolerance"] as? String ?? "Medium"
            let cookTime = data["cookTime"] as? String ?? "30 mins"
            let budget = data["budget"] as? String ?? "Standard"
            let servings = data["servingSize"] as? String ?? "2"
            let dislikes = data["dislikes"] as? String ?? ""
            let dailyCalorieTarget = data["dailyCalorieTarget"] as? Int

            var context = ""

            if !diets.isEmpty { context += "Diet: \(diets). " }
            if !allergies.isEmpty { context += "Avoid allergies: \(allergies). " }
            if !macros.isEmpty { context += "Macro goal: \(macros). " }
            if !cuisines.isEmpty { context += "Preferred cuisines: \(cuisines). " }
            if !dislikes.isEmpty { context += "Avoid ingredients: \(dislikes). " }

            context += "Spice tolerance: \(spice). "
            context += "Cook time preference: \(cookTime). "
            context += "Budget: \(budget). "
            context += "Serving size: \(servings)."
            if let dailyCalorieTarget {
                context += " Target about \(dailyCalorieTarget) calories across the full day."
            }
            let consumedHistory = await consumedHistorySummary(userId: userId)
            if !consumedHistory.isEmpty {
                context += " \(consumedHistory)"
            }


            let existingSnap = try await db.collection("users")
                .document(userId)
                .collection("mealPlan")
                .getDocuments()

            let currentPlan = existingSnap.documents.compactMap { try? $0.data(as: MealPlanSlot.self) }

            var emptySlotsDescription = ""
            for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] {
                for meal in ["Breakfast", "Lunch", "Dinner"] {
                    if !currentPlan.contains(where: { $0.day == day && $0.mealType == meal && !$0.displayTitle.isEmpty }) {
                        emptySlotsDescription += "- \(day): \(meal)\n"
                    }
                }
            }

            let prompt = """
            Generate meals ONLY for the following empty slots:
            \(emptySlotsDescription)

            Do not provide suggestions for slots already filled.
            User preferences: \(context)

            Return ONLY valid JSON in this exact format:
            [
              {
                "day": "Monday",
                "mealType": "Breakfast",
                "recipe": {
                  "title": "Spinach Egg Tacos",
                  "emoji": "🌮",
                  "description": "A fast, savory breakfast taco with fluffy eggs and sauteed spinach.",
                  "prepTime": "15 mins",
                  "servings": "2 people",
                  "difficulty": "Easy",
                  "calories": "410 kcal",
                  "carbs": "26g",
                  "protein": "24g",
                  "fat": "21g",
                  "saturatedFat": "6g",
                  "sugar": "3g",
                  "fiber": "4g",
                  "sodium": "540mg",
                  "tags": ["Mexican", "High Protein", "Quick"],
                  "ingredients": ["4 eggs", "1 cup spinach"],
                  "steps": ["Crack the eggs into a bowl and whisk until smooth before heating the pan.", "Cook until the eggs are softly set, 2 to 3 minutes, then remove from the heat immediately."],
                  "matchReason": "Why it fits the user."
                }
              }
            ]

            Rules:
            - Output JSON only. No markdown, no commentary, and no code fences.
            - Generate entries for every empty slot only.
            - Every recipe must be fully cookable with 4 to 7 detailed steps.
            - ingredients must include exact quantities and units.
            - steps must include prep work, timing ranges, heat guidance, and doneness or texture cues.
            - Include nutrition strings for calories, carbs, protein, fat, saturatedFat, sugar, fiber, and sodium.
            - Keep recipes realistic for the stated cook time, budget, preferences, and skill level.
            - Include at least one cuisine tag in each recipe tags array.
            """


            try await assistant.waitUntilReady()

            let response = try await assistant.getHelp(question: prompt)

            guard let json = CookingAssistant.extractJSONArray(from: response),
                  let data = json.data(using: .utf8) else { return }

            let generated = try JSONDecoder().decode([MealPlanGenerationSlot].self, from: data)

            let batch = db.batch()

            let collection = db.collection("users")
                .document(userId)
                .collection("mealPlan")

            for generatedSlot in generated {
                let slotId = "\(generatedSlot.day)-\(generatedSlot.mealType)"
                let doc = collection.document(slotId)
                let recipe = generatedSlot.recipe.asRecipe()
                let slot = MealPlanSlot(
                    id: slotId,
                    day: generatedSlot.day,
                    mealType: generatedSlot.mealType,
                    recipeId: nil,
                    recipeTitle: recipe.title,
                    plannedRecipe: PlannedMealRecipe(recipe: recipe),
                    status: .planned,
                    completedAt: nil,
                    consumedNutritionSnapshot: nil,
                    sourceType: .ai
                )
                var payload = try Firestore.Encoder().encode(slot)
                payload["updatedAt"] = FieldValue.serverTimestamp()
                batch.setData(payload, forDocument: doc, merge: true)
            }

            try await batch.commit()

            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isGenerating = false
            }

        } catch {

            print("Weekly plan error:", error)

            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                isGenerating = false
            }
        }
    }

    func customizeDayPlan(
        day: String,
        mealTypes: [String],
        prompt: String,
        assistant: CookingAssistant,
        userId: String
    ) async {
        guard !userId.isEmpty, !day.isEmpty, !mealTypes.isEmpty else { return }

        await MainActor.run {
            isGenerating = true
        }

        do {
            let userDoc = try await db.collection("users").document(userId).getDocument()
            let data = userDoc.data() ?? [:]

            let diets = (data["dietTags"] as? [String])?.joined(separator: ", ") ?? ""
            let allergies = (data["allergies"] as? [String])?.joined(separator: ", ") ?? ""
            let macros = (data["macroTags"] as? [String])?.joined(separator: ", ") ?? ""
            let cuisines = (data["cuisines"] as? [String])?.joined(separator: ", ") ?? ""
            let spice = data["spiceTolerance"] as? String ?? "Medium"
            let cookTime = data["cookTime"] as? String ?? "30 mins"
            let budget = data["budget"] as? String ?? "Standard"
            let servings = data["servingSize"] as? String ?? "2"
            let dislikes = data["dislikes"] as? String ?? ""
            let dailyCalorieTarget = data["dailyCalorieTarget"] as? Int

            var context = ""
            if !diets.isEmpty { context += "Diet: \(diets). " }
            if !allergies.isEmpty { context += "Avoid allergies: \(allergies). " }
            if !macros.isEmpty { context += "Macro goal: \(macros). " }
            if !cuisines.isEmpty { context += "Preferred cuisines: \(cuisines). " }
            if !dislikes.isEmpty { context += "Avoid ingredients: \(dislikes). " }
            context += "Spice tolerance: \(spice). "
            context += "Cook time preference: \(cookTime). "
            context += "Budget: \(budget). "
            context += "Serving size: \(servings). "
            if let dailyCalorieTarget {
                context += "Keep the full day close to \(dailyCalorieTarget) calories total. "
            }
            let consumedHistory = await consumedHistorySummary(userId: userId)
            if !consumedHistory.isEmpty {
                context += consumedHistory + " "
            }

            let targetedMeals = mealTypes.joined(separator: ", ")
            let customizationPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No extra theme request. Make the day balanced and appealing."
                : prompt.trimmingCharacters(in: .whitespacesAndNewlines)

            let request = """
            Regenerate only these meals for \(day): \(targetedMeals).

            User preferences: \(context)
            Extra customization request: \(customizationPrompt)

            Return ONLY valid JSON in this exact format:
            [
              {
                "day": "\(day)",
                "mealType": "Lunch",
                "recipe": {
                  "title": "Recipe name",
                  "emoji": "🍝",
                  "description": "Short enticing description",
                  "prepTime": "25 mins",
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
                  "tags": ["Italian", "Balanced"],
                  "ingredients": ["1 tbsp olive oil", "200g chicken breast"],
                  "steps": ["Prep...", "Cook..."],
                  "matchReason": "Why it fits the day."
                }
              }
            ]

            Rules:
            - Output JSON only with no markdown or code fences.
            - Generate entries for exactly these meal types and no others: \(targetedMeals).
            - Keep the selected day coherent with the customization request.
            - Balance the selected meals so the full day tracks close to the calorie target when provided.
            - Each recipe must be fully cookable with 4 to 7 detailed steps.
            - ingredients must include exact quantities and units.
            - steps must include prep work, timing ranges, heat guidance, and doneness or texture cues.
            - Include nutrition strings for calories, carbs, protein, fat, saturatedFat, sugar, fiber, and sodium.
            - Include at least one cuisine tag in each recipe tags array.
            """

            try await assistant.waitUntilReady()
            let response = try await assistant.getHelp(question: request)

            guard let json = CookingAssistant.extractJSONArray(from: response),
                  let responseData = json.data(using: .utf8) else {
                throw NSError(domain: "MealPlan", code: 1)
            }

            let generated = try JSONDecoder().decode([MealPlanGenerationSlot].self, from: responseData)
            let batch = db.batch()
            let collection = db.collection("users").document(userId).collection("mealPlan")

            for generatedSlot in generated where mealTypes.contains(generatedSlot.mealType) {
                let slotId = "\(generatedSlot.day)-\(generatedSlot.mealType)"
                let recipe = generatedSlot.recipe.asRecipe()
                let slot = MealPlanSlot(
                    id: slotId,
                    day: generatedSlot.day,
                    mealType: generatedSlot.mealType,
                    recipeId: nil,
                    recipeTitle: recipe.title,
                    plannedRecipe: PlannedMealRecipe(recipe: recipe),
                    status: .planned,
                    completedAt: nil,
                    consumedNutritionSnapshot: nil,
                    sourceType: .ai
                )
                var payload = try Firestore.Encoder().encode(slot)
                payload["updatedAt"] = FieldValue.serverTimestamp()
                batch.setData(payload, forDocument: collection.document(slotId), merge: true)
            }

            try await batch.commit()

            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isGenerating = false
            }
        } catch {
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                isGenerating = false
            }
        }
    }
}


struct WeeklyMealPlanView: View {

    @EnvironmentObject var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant

    @ObservedObject private var vm = MealPlanViewModel.shared
    @StateObject private var recipesVM = RecipesViewModel()

    @State private var selectedDay = Calendar.current.weekdayName(for: Date())
    @State private var showRecipePicker = false
    @State private var selectedMealType: String?
    @State private var selectedRecipeForDetail: Recipe? = nil
    @State private var selectedPlannedRecipeForDetail: Recipe? = nil
    @State private var selectedPlanSlotForDetail: MealPlanSlot? = nil
    @State private var hasAppeared = false
    @State private var pulseHero = false
    @State private var showDayAssistant = false
    @State private var dayAssistantPrompt = ""
    @State private var dayAssistantMealTypes: Set<String> = ["Breakfast", "Lunch", "Dinner"]
    @State private var showMealLogSheet = false
    @State private var pantrySpaces: [SimplePantrySpace] = []
    @State private var selectedPantryId: String? = nil
    @State private var pantryListener: ListenerRegistration? = nil
    @State private var aiCoachInsight: DailyCoachInsight? = nil
    @State private var aiCoachLoading = false
    @State private var aiCoachCache: [String: DailyCoachInsight] = [:]
    @State private var aiCoachTask: Task<Void, Never>? = nil

    private let days = [
        "Monday", "Tuesday", "Wednesday",
        "Thursday", "Friday", "Saturday", "Sunday"
    ]

    private let mealTypes = ["Breakfast", "Lunch", "Dinner"]

    private var currentWeekday: String {
        Calendar.current.weekdayName(for: Date())
    }

    private var filledSlotsCount: Int {
        vm.weeklySlots.filter { !$0.displayTitle.isEmpty }.count
    }

    private var selectedDayFilledCount: Int {
        mealTypes.compactMap { slotFor(type: $0) }.filter { !$0.displayTitle.isEmpty }.count
    }

    private var pantryIngredients: [String] {
        pantrySpaces.first(where: { $0.id == selectedPantryId })?.ingredients ?? []
    }

    private func shortDay(_ day: String) -> String {
        String(day.prefix(3))
    }

    private func slotFor(type: String) -> MealPlanSlot? {
        vm.weeklySlots.first {
            $0.day == selectedDay && $0.mealType == type
        }
    }

    private var selectedDayNutritionSummary: DayNutritionSummary {
        let plannedRecipes = mealTypes
            .compactMap { slotFor(type: $0)?.plannedRecipe }

        let calories = plannedRecipes.reduce(0) { $0 + nutritionNumericValue(from: $1.calories) }
        let carbs = plannedRecipes.reduce(0) { $0 + nutritionNumericValue(from: $1.nutrition.carbs) }
        let protein = plannedRecipes.reduce(0) { $0 + nutritionNumericValue(from: $1.nutrition.protein) }
        let fat = plannedRecipes.reduce(0) { $0 + nutritionNumericValue(from: $1.nutrition.fat) }
        let sodium = plannedRecipes.reduce(0) { $0 + nutritionNumericValue(from: $1.nutrition.sodium) }

        return DayNutritionSummary(
            calories: formatNutritionValue(calories, suffix: " kcal"),
            carbs: formatNutritionValue(carbs, suffix: "g carbs"),
            protein: formatNutritionValue(protein, suffix: "g protein"),
            fat: formatNutritionValue(fat, suffix: "g fat"),
            sodium: formatNutritionValue(sodium, suffix: "mg sodium")
        )
    }

    private var selectedDayMealLogs: [MealLogEvent] {
        vm.mealLogEvents.filter { $0.day == selectedDay }
    }

    private var selectedDayCompletionCount: Int {
        mealTypes
            .compactMap { slotFor(type: $0) }
            .filter(\.isCompleted)
            .count
    }

    private var selectedDayConsumedSummary: DayNutritionSummary {
        var calories = 0.0
        var carbs = 0.0
        var protein = 0.0
        var fat = 0.0
        var sodium = 0.0

        for slot in mealTypes.compactMap({ slotFor(type: $0) }) where slot.isCompleted {
            if let consumed = slot.consumedNutritionSnapshot {
                calories += nutritionNumericValue(from: consumed.calories)
                carbs += nutritionNumericValue(from: consumed.carbs)
                protein += nutritionNumericValue(from: consumed.protein)
                fat += nutritionNumericValue(from: consumed.fat)
                sodium += nutritionNumericValue(from: consumed.sodium)
            } else if let planned = slot.plannedRecipe {
                calories += nutritionNumericValue(from: planned.calories)
                carbs += nutritionNumericValue(from: planned.nutrition.carbs)
                protein += nutritionNumericValue(from: planned.nutrition.protein)
                fat += nutritionNumericValue(from: planned.nutrition.fat)
                sodium += nutritionNumericValue(from: planned.nutrition.sodium)
            }
        }

        for log in selectedDayMealLogs {
            calories += nutritionNumericValue(from: log.calories)
            carbs += nutritionNumericValue(from: log.carbs)
            protein += nutritionNumericValue(from: log.protein)
            fat += nutritionNumericValue(from: log.fat)
            sodium += nutritionNumericValue(from: log.sodium)
        }

        return DayNutritionSummary(
            calories: formatNutritionValue(calories, suffix: " kcal"),
            carbs: formatNutritionValue(carbs, suffix: "g carbs"),
            protein: formatNutritionValue(protein, suffix: "g protein"),
            fat: formatNutritionValue(fat, suffix: "g fat"),
            sodium: formatNutritionValue(sodium, suffix: "mg sodium")
        )
    }

    private var selectedDayRealitySummary: DayNutritionRealitySummary {
        let planned = selectedDayNutritionSummary
        let consumed = selectedDayConsumedSummary
        let delta = nutritionNumericValue(from: consumed.calories) - nutritionNumericValue(from: planned.calories)
        let deltaPrefix = delta > 0 ? "+" : ""
        return DayNutritionRealitySummary(
            planned: planned,
            consumed: consumed,
            deltaCalories: "\(deltaPrefix)\(Int(delta.rounded())) kcal"
        )
    }

    private var fallbackDailyCoachInsight: DailyCoachInsight {
        let target = Double(authVM.currentUserProfile?.dailyCalorieTarget ?? 0)
        let consumedCalories = nutritionNumericValue(from: selectedDayConsumedSummary.calories)

        if selectedDayCompletionCount == 0 && selectedDayMealLogs.isEmpty {
            return DailyCoachInsight(
                focus: "Momentum",
                headline: "Get one meal on the board",
                nextAction: "Mark one planned meal cooked or log what you actually ate next.",
                benefit: "That gives ChefBuddy real data to tune tomorrow."
            )
        }

        if target > 0 {
            let difference = consumedCalories - target
            if difference > 180 {
                return DailyCoachInsight(
                    focus: "Balance",
                    headline: "Dinner can rebalance the day",
                    nextAction: "Aim for a lighter, higher-protein next meal to close the calorie gap.",
                    benefit: "A softer landing keeps the week easier to sustain."
                )
            }
            if difference < -180 {
                return DailyCoachInsight(
                    focus: "Recovery",
                    headline: "You may need a little more fuel",
                    nextAction: "Add a balanced snack so energy stays steadier tonight.",
                    benefit: "Closing the gap helps recovery and appetite control."
                )
            }
        }

        if selectedDayCompletionCount >= 3 {
            return DailyCoachInsight(
                focus: "Consistency",
                headline: "You landed the whole day",
                nextAction: "Keep tomorrow simple so this streak stays low-friction.",
                benefit: "Consistency is turning into a real habit loop."
            )
        }

        if selectedDayMealLogs.count >= 2 {
            return DailyCoachInsight(
                focus: "Feedback",
                headline: "Your logging signal is getting useful",
                nextAction: "Keep portions honest so tomorrow's plan can tune faster.",
                benefit: "Better feedback makes personalization smarter."
            )
        }

        return DailyCoachInsight(
            focus: "Consistency",
            headline: "One more meal strengthens the day",
            nextAction: "Finish one more planned slot to lock in stronger momentum.",
            benefit: "Small completions are what build the streak."
        )
    }

    private var coachContextSignature: String {
        let slotTitles = mealTypes.compactMap { slotFor(type: $0)?.displayTitle }.joined(separator: "|")
        let logTitles = selectedDayMealLogs.map(\.title).joined(separator: "|")
        let target = authVM.currentUserProfile?.dailyCalorieTarget ?? 0
        return [
            selectedDay,
            slotTitles,
            logTitles,
            selectedDayNutritionSummary.calories,
            selectedDayConsumedSummary.calories,
            selectedDayCompletionCount.description,
            selectedDayMealLogs.count.description,
            target.description
        ].joined(separator: "•")
    }

    private var displayedDailyCoachInsight: DailyCoachInsight {
        aiCoachInsight ?? fallbackDailyCoachInsight
    }

    private func handleSlotTap(type: String) {
        if let slot = slotFor(type: type) {
            if let recipeId = slot.recipeId,
               let foundRecipe = recipesVM.recipes.first(where: { $0.id == recipeId }) {
                selectedRecipeForDetail = foundRecipe
                return
            }

            if let plannedRecipe = slot.plannedRecipe {
                selectedPlanSlotForDetail = slot
                selectedPlannedRecipeForDetail = plannedRecipe.asRecipe(id: slot.recipeId ?? slot.id)
                return
            }

            selectedMealType = type
            showRecipePicker = true
        } else {
            selectedMealType = type
            showRecipePicker = true
        }
    }

    private func removeSlot(type: String) {
        guard let uid = authVM.userSession?.uid else { return }
        vm.removeFromPlan(day: selectedDay, mealType: type, userId: uid)
    }

    private func updateSlotStatus(type: String, status: MealPlanSlotStatus) {
        guard let uid = authVM.userSession?.uid,
              let slot = slotFor(type: type) else { return }
        vm.updateSlotStatus(slot, status: status, userId: uid)
    }

    private func generateWeeklyPlan() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if let uid = authVM.userSession?.uid {
            vm.startWeeklyPlanGeneration(assistant: assistant, userId: uid)
        }
    }

    private func customizeSelectedDay() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if let uid = authVM.userSession?.uid {
            vm.startDayCustomization(
                day: selectedDay,
                mealTypes: Array(dayAssistantMealTypes),
                prompt: dayAssistantPrompt,
                assistant: assistant,
                userId: uid
            )
            showDayAssistant = false
        }
    }

    private func saveMealLog(_ draft: MealLogDraft) {
        guard let uid = authVM.userSession?.uid else { return }

        let cleanIngredients = draft.ingredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanSteps = draft.steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let nutrition = NutritionInfo(
            calories: draft.calories,
            carbs: draft.carbs,
            protein: draft.protein,
            fat: draft.fat,
            saturatedFat: "",
            sugar: "",
            fiber: "",
            sodium: draft.sodium
        )

        Task {
            await vm.addMealLogEvent(
                day: selectedDay,
                mealType: draft.mealType,
                title: draft.title,
                notes: draft.notes,
                mode: draft.mode,
                calories: draft.calories,
                nutrition: nutrition,
                isEstimated: draft.isEstimated,
                confidence: draft.confidence,
                ingredients: cleanIngredients,
                steps: cleanSteps,
                userId: uid
            )

            if let slot = slotFor(type: draft.mealType) {
                vm.updateSlotStatus(slot, status: .logged, userId: uid, consumedNutritionSnapshot: nutrition)
            }
        }
    }

    var body: some View {
        ZStack {
            ChefBuddyBackground()
            Circle()
                .fill(Color.orange.opacity(pulseHero ? 0.16 : 0.08))
                .blur(radius: 90)
                .offset(x: -170, y: -250)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: pulseHero)
            Circle()
                .fill(Color.green.opacity(pulseHero ? 0.14 : 0.07))
                .blur(radius: 100)
                .offset(x: 180, y: 320)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: pulseHero)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    AnimatedScreenHeader(
                        eyebrow: "Meal Plan",
                        title: "Shape your week",
                        subtitle: "\(filledSlotsCount)/21 slots planned and \(selectedDayFilledCount)/3 filled for \(selectedDay).",
                        systemImage: "calendar",
                        accent: .orange,
                        badgeText: "\(selectedDayFilledCount)/3 today"
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -12)

                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Planner controls")
                                .font(.system(size: 18, weight: .bold, design: .rounded))

                            Spacer()

                            Button(action: {
                                dayAssistantMealTypes = Set(mealTypes)
                                dayAssistantPrompt = ""
                                showDayAssistant = true
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "wand.and.stars")
                                    Text("Customize \(selectedDay) with AI")
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                }
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                )
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(days, id: \.self) { day in
                                    DayButton(
                                        day: day,
                                        shortDay: shortDay(day),
                                        isSelected: selectedDay == day
                                    )
                                    .onTapGesture {
                                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                            selectedDay = day
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(18)
                    .background(.ultraThinMaterial.opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -10)

                    DayNutritionSummaryCard(day: selectedDay, summary: selectedDayNutritionSummary)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : -8)

                    DailyExecutionSummaryCard(
                        day: selectedDay,
                        completedCount: selectedDayCompletionCount,
                        loggedCount: selectedDayMealLogs.count,
                        onLogMeal: { showMealLogSheet = true }
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -7)

                    DayRealityComparisonCard(summary: selectedDayRealitySummary)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : -6)

                    DailyCoachCard(
                        insight: displayedDailyCoachInsight,
                        isLoading: aiCoachLoading,
                        isAI: aiCoachInsight != nil
                    )
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : -5)

                    VStack(spacing: 12) {
                        ForEach(mealTypes, id: \.self) { type in
                            MealSlotRow(
                                type: type,
                                slot: slotFor(type: type),
                                onTap: { handleSlotTap(type: type) },
                                onRemove: { removeSlot(type: type) },
                                onStatusSelect: { newStatus in
                                    updateSlotStatus(type: type, status: newStatus)
                                }
                            )
                        }
                    }
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -6)

                    Button(action: generateWeeklyPlan) {
                        HStack(spacing: 10) {
                            if vm.isGenerating {
                                ProgressView()
                                    .tint(.white)
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 14, weight: .bold))
                            }

                            Text(vm.isGenerating ? "Building Your Week..." : "Generate Weekly Plan")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: vm.isGenerating ? [.orange.opacity(0.95), .orange.opacity(0.85)] : [.orange, .green.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .orange.opacity(0.28), radius: 12, y: 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isGenerating)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -2)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 150)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            pulseHero = true
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.05)) {
                hasAppeared = true
            }
            selectedDay = currentWeekday

            if let uid = authVM.userSession?.uid {
                vm.startListening(userId: uid)
                recipesVM.startListening(userId: uid)
                startPantryListener(userId: uid)
            }
            requestAIDailyCoach()
        }
        .onDisappear {
            pantryListener?.remove()
            pantryListener = nil
            aiCoachTask?.cancel()
            aiCoachTask = nil
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
        .onChange(of: coachContextSignature) { _ in
            requestAIDailyCoach()
        }
        .sheet(item: $selectedRecipeForDetail) { recipe in
            RecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: pantryIngredients,
                pantrySpaces: pantrySpaces,
                selectedPantryId: selectedPantryId,
                onFavorite: {
                    if let uid = authVM.userSession?.uid {
                        recipesVM.toggleFavorite(recipe, userId: uid)
                    }
                },
                onDelete: {
                    if let uid = authVM.userSession?.uid {
                        recipesVM.deleteRecipe(recipe, userId: uid)
                        selectedRecipeForDetail = nil
                    }
                },
                userId: authVM.userSession?.uid ?? "",
                onSelectPantry: { pantryId in
                    selectedPantryId = pantryId
                    authVM.updateActivePantrySelection(pantryId)
                }
            )
        }
        .sheet(item: $selectedPlannedRecipeForDetail) { recipe in
            SuggestedRecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                onSave: {
                    guard let uid = authVM.userSession?.uid else { return }
                    recipesVM.saveSuggestedRecipe(recipe, userId: uid)
                    selectedPlannedRecipeForDetail = nil
                    selectedPlanSlotForDetail = nil
                },
                onDislike: nil,
                onRecipeUpdated: { updatedRecipe in
                    guard let uid = authVM.userSession?.uid,
                          let slot = selectedPlanSlotForDetail else { return }
                    vm.updatePlannedRecipe(updatedRecipe, for: slot, userId: uid)
                    selectedPlannedRecipeForDetail = updatedRecipe
                },
                onLiveHelp: nil
            )
        }
        .sheet(isPresented: $showRecipePicker) {
            NavigationStack {
                ZStack {
                    ChefBuddyBackground()

                    if recipesVM.recipes.isEmpty {
                        VStack(spacing: 10) {
                            Text("No saved recipes yet")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text("Create recipes first, then add them to your meal plan.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 28)
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Choose a recipe for \(selectedDay) \(selectedMealType ?? "")")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 8)

                                LazyVGrid(
                                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                                    spacing: 14
                                ) {
                                    ForEach(recipesVM.recipes) { recipe in
                                        RecipeCard(
                                            recipe: recipe,
                                            onTap: {
                                                if let mealType = selectedMealType,
                                                   let uid = authVM.userSession?.uid {
                                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                                    vm.addToPlan(
                                                        recipe: recipe,
                                                        day: selectedDay,
                                                        mealType: mealType,
                                                        userId: uid
                                                    )
                                                }
                                                showRecipePicker = false
                                            },
                                            onFavorite: {
                                                if let uid = authVM.userSession?.uid {
                                                    recipesVM.toggleFavorite(recipe, userId: uid)
                                                }
                                            },
                                            isCooked: recipe.hasBeenCooked
                                        )
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            .padding(.bottom, 16)
                        }
                    }
                }
                .navigationTitle("Choose Recipe")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { showRecipePicker = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showDayAssistant) {
            DayCustomizationSheet(
                day: selectedDay,
                mealTypes: mealTypes,
                selectedMealTypes: $dayAssistantMealTypes,
                prompt: $dayAssistantPrompt,
                isGenerating: vm.isGenerating,
                onGenerate: customizeSelectedDay
            )
        }
        .sheet(isPresented: $showMealLogSheet) {
            MealLogEntrySheet(
                day: selectedDay,
                defaultMealType: "Dinner",
                assistant: assistant,
                onSave: { draft in
                    saveMealLog(draft)
                }
            )
        }
    }

    private func startPantryListener(userId: String) {
        pantryListener?.remove()
        pantryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .addSnapshotListener { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                let spaces = docs.compactMap { document -> SimplePantrySpace? in
                    let data = document.data()
                    let name = data["name"] as? String ?? "Pantry"
                    let emoji = data["emoji"] as? String ?? "🥑"
                    let colorTheme = data["colorTheme"] as? String ?? "Orange"
                    let pantry = data["virtualPantry"] as? [String: [String]] ?? [:]
                    return SimplePantrySpace(
                        id: document.documentID,
                        name: name,
                        emoji: emoji,
                        ingredients: pantry.values.flatMap { $0 },
                        colorTheme: colorTheme
                    )
                }.sorted { $0.name < $1.name }

                DispatchQueue.main.async {
                    pantrySpaces = spaces
                    let preferred = authVM.currentUserProfile?.activePantryId
                    if selectedPantryId == nil,
                       let preferred,
                       spaces.contains(where: { $0.id == preferred }) {
                        selectedPantryId = preferred
                    } else if selectedPantryId == nil {
                        selectedPantryId = spaces.first?.id
                    } else if let selectedPantryId,
                                !spaces.contains(where: { $0.id == selectedPantryId }) {
                        self.selectedPantryId = spaces.first?.id
                    }
                }
            }
    }

    private func requestAIDailyCoach() {
        guard let userId = authVM.userSession?.uid, !userId.isEmpty else {
            aiCoachInsight = nil
            aiCoachLoading = false
            return
        }

        let cacheKey = "\(userId)|\(coachContextSignature)"
        if let cached = aiCoachCache[cacheKey] {
            aiCoachInsight = cached
            aiCoachLoading = false
            return
        }

        aiCoachTask?.cancel()
        aiCoachLoading = true

        let plannedRows = mealTypes.compactMap { type -> String? in
            guard let slot = slotFor(type: type), !slot.displayTitle.isEmpty else { return nil }
            return "\(type): \(slot.displayTitle)"
        }
        let logRows = selectedDayMealLogs.map { "\($0.mealType): \($0.title) (\($0.calories))" }
        let recentLogs = vm.mealLogEvents.prefix(7).map { "\($0.day) \($0.mealType): \($0.title) \($0.calories)" }
        let macroGoal = authVM.currentUserProfile?.macroTags.joined(separator: ", ") ?? "Balanced"
        let targetGoal = authVM.currentUserProfile?.targetGoal ?? "Maintain"
        let dailyCalorieTarget = authVM.currentUserProfile?.dailyCalorieTarget ?? 0
        let weeklyPlannedCount = vm.weeklySlots.filter { !$0.displayTitle.isEmpty }.count
        let weeklyCompletedCount = vm.weeklySlots.filter(\.isCompleted).count
        let weeklyAdherenceRate = weeklyPlannedCount == 0 ? 0 : Int((Double(weeklyCompletedCount) / Double(weeklyPlannedCount) * 100).rounded())
        let plannedCalories = nutritionNumericValue(from: selectedDayNutritionSummary.calories)
        let consumedCalories = nutritionNumericValue(from: selectedDayConsumedSummary.calories)
        let calorieDelta = consumedCalories - plannedCalories
        let plannedProtein = nutritionNumericValue(from: selectedDayNutritionSummary.protein)
        let consumedProtein = nutritionNumericValue(from: selectedDayConsumedSummary.protein)
        let proteinDelta = consumedProtein - plannedProtein
        let cuisineTags = vm.weeklySlots
            .compactMap { $0.plannedRecipe?.tags.first?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cuisineDiversity = Set(cuisineTags.map { $0.lowercased() }).count

        aiCoachTask = Task {
            do {
                try await assistant.waitUntilReady()

                let prompt = """
                You are ChefBuddy's nutrition and habit coach.
                Give a thoughtful, personalized daily coaching insight based on behavior patterns.
                Be specific, non-judgmental, and helpful.
                Sound like a sharp coach, not a calorie calculator.
                Keep every field concise and punchy.

                Return ONLY valid JSON:
                {
                  "focus": "Protein|Timing|Balance|Prep|Variety|Recovery|Consistency|Feedback|Momentum",
                  "headline": "max 8 words",
                  "nextAction": "one clear action, max 60 chars",
                  "benefit": "why this helps, max 42 chars"
                }

                Context:
                day: \(selectedDay)
                targetGoal: \(targetGoal)
                macroGoal: \(macroGoal)
                dailyCalorieTarget: \(dailyCalorieTarget)
                plannedTotals: calories=\(selectedDayNutritionSummary.calories), carbs=\(selectedDayNutritionSummary.carbs), protein=\(selectedDayNutritionSummary.protein), fat=\(selectedDayNutritionSummary.fat), sodium=\(selectedDayNutritionSummary.sodium)
                consumedTotals: calories=\(selectedDayConsumedSummary.calories), carbs=\(selectedDayConsumedSummary.carbs), protein=\(selectedDayConsumedSummary.protein), fat=\(selectedDayConsumedSummary.fat), sodium=\(selectedDayConsumedSummary.sodium)
                calorieDeltaToday: \(Int(calorieDelta.rounded())) kcal
                proteinDeltaToday: \(Int(proteinDelta.rounded())) g
                completion: \(selectedDayCompletionCount)/3 planned meals completed
                weeklyCompletion: \(weeklyCompletedCount)/\(weeklyPlannedCount) (\(weeklyAdherenceRate)%)
                cuisineDiversityThisWeek: \(cuisineDiversity)
                plannedMeals: \(plannedRows.joined(separator: " | "))
                loggedMeals: \(logRows.joined(separator: " | "))
                recentLogs: \(recentLogs.joined(separator: " | "))
                """

                let raw = try await assistant.getHelp(question: prompt)
                let aiInsight: DailyCoachInsight
                if let json = extractJSONObject(from: raw),
                   let data = json.data(using: .utf8),
                   let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let focus = (object["focus"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let headline = (object["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let nextAction = (object["nextAction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let benefit = (object["benefit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let candidate = DailyCoachInsight(
                        focus: focus.isEmpty ? fallbackDailyCoachInsight.focus : focus,
                        headline: headline.isEmpty ? fallbackDailyCoachInsight.headline : headline,
                        nextAction: nextAction.isEmpty ? fallbackDailyCoachInsight.nextAction : nextAction,
                        benefit: benefit.isEmpty ? fallbackDailyCoachInsight.benefit : benefit
                    )
                    aiInsight = candidate
                } else {
                    aiInsight = fallbackDailyCoachInsight
                }

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    aiCoachCache[cacheKey] = aiInsight
                    aiCoachInsight = aiInsight
                    aiCoachLoading = false
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    aiCoachInsight = nil
                    aiCoachLoading = false
                }
            }
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

private struct DailyCoachInsight: Equatable {
    var focus: String
    var headline: String
    var nextAction: String
    var benefit: String
}


struct DayButton: View {
    let day: String
    let shortDay: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(shortDay)
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Text(day.prefix(1))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .opacity(0.65)
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .frame(width: 42, height: 44)
        .background(
            Group {
                if isSelected {
                    LinearGradient(
                        colors: [.orange, .green.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                } else {
                    Color.primary.opacity(0.08)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(isSelected ? 0 : 0.07), lineWidth: 1)
        )
    }
}

private struct DayCustomizationSheet: View {
    let day: String
    let mealTypes: [String]
    @Binding var selectedMealTypes: Set<String>
    @Binding var prompt: String
    let isGenerating: Bool
    let onGenerate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Customize \(day)")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .padding(.top, 8)

                        Text("Tell ChefBuddy what you want for this day and choose which meals should be refreshed.")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Meals to refresh")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                ForEach(mealTypes, id: \.self) { mealType in
                                    let selected = selectedMealTypes.contains(mealType)
                                    Button {
                                        if selected {
                                            selectedMealTypes.remove(mealType)
                                        } else {
                                            selectedMealTypes.insert(mealType)
                                        }
                                    } label: {
                                        Text(mealType)
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                            .foregroundStyle(selected ? .white : .primary)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 10)
                                            .background(
                                                selected
                                                ? AnyView(LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                                                : AnyView(Color.primary.opacity(0.08))
                                            )
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(alignment: .leading, spacing: 12) {
                            Text("What kind of day are you craving?")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)

                            TextField("Indian lunch, pasta dinner, lighter breakfast...", text: $prompt, axis: .vertical)
                                .font(.system(size: 15, design: .rounded))
                                .lineLimit(4)
                                .padding(14)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Button(action: onGenerate) {
                            HStack(spacing: 10) {
                                if isGenerating {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "sparkles")
                                }

                                Text(isGenerating ? "Refreshing \(day)..." : "Regenerate This Day")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedMealTypes.isEmpty || isGenerating)
                        .opacity(selectedMealTypes.isEmpty ? 0.65 : 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
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
        }
    }
}

struct DayNutritionSummaryCard: View {
    let day: String
    let summary: DayNutritionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(day)'s Nutrition Snapshot")
                    .font(.system(size: 18, weight: .bold, design: .rounded))

                Text("Total intake from the meals planned for this day.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                NutritionChip(label: "Calories", value: summary.calories, color: .red)
                NutritionChip(label: "Carbs", value: summary.carbs, color: .orange)
            }

            HStack(spacing: 10) {
                NutritionChip(label: "Protein", value: summary.protein, color: .green)
                NutritionChip(label: "Fat", value: summary.fat, color: .blue)
            }

            NutritionChip(label: "Sodium", value: summary.sodium, color: .purple)
        }
        .padding(18)
        .background(.ultraThinMaterial.opacity(0.93), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct NutritionChip: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MealPlanNutritionWheel: View {
    let protein: Double
    let carbs: Double
    let fat: Double

    private var total: Double {
        max(1, protein + carbs + fat)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 14)

            Circle()
                .trim(from: 0, to: CGFloat(protein / total))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .trim(from: CGFloat(protein / total), to: CGFloat((protein + carbs) / total))
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .trim(from: CGFloat((protein + carbs) / total), to: 1)
                .stroke(Color.pink, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 2) {
                Text("\(Int((protein + carbs + fat).rounded()))g")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                Text("Macros")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DailyExecutionSummaryCard: View {
    let day: String
    let completedCount: Int
    let loggedCount: Int
    let onLogMeal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(day) execution")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("\(completedCount)/3 planned meals completed • \(loggedCount) extra logs")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Button(action: onLogMeal) {
                    Label("Log Off-App Meal", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial.opacity(0.93), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct DayRealityComparisonCard: View {
    let summary: DayNutritionRealitySummary

    var deltaColor: Color {
        if summary.deltaCalories.hasPrefix("+") {
            return .orange
        }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Planned vs consumed")
                .font(.system(size: 17, weight: .bold, design: .rounded))

            HStack(spacing: 10) {
                NutritionChip(label: "Planned", value: summary.planned.calories, color: .blue)
                NutritionChip(label: "Consumed", value: summary.consumed.calories, color: .green)
            }

            HStack {
                Label("Calorie delta", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(summary.deltaCalories)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(deltaColor)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial.opacity(0.93), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct DailyCoachCard: View {
    let insight: DailyCoachInsight
    var isLoading: Bool = false
    var isAI: Bool = false

    private var accent: Color {
        switch insight.focus.lowercased() {
        case "protein": return .green
        case "timing": return .orange
        case "balance": return .blue
        case "prep": return .purple
        case "variety": return .pink
        case "recovery": return .teal
        case "feedback": return .indigo
        case "consistency": return .orange
        default: return .orange
        }
    }

    private var iconName: String {
        switch insight.focus.lowercased() {
        case "protein": return "bolt.heart.fill"
        case "timing": return "clock.fill"
        case "balance": return "scale.3d"
        case "prep": return "list.bullet.clipboard.fill"
        case "variety": return "sparkles"
        case "recovery": return "leaf.fill"
        case "feedback": return "waveform.path.ecg"
        case "consistency": return "flame.fill"
        default: return "sparkles"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.16))
                        .frame(width: 40, height: 40)
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("AI Daily Coach")
                            .font(.system(size: 14, weight: .bold, design: .rounded))

                        Text(insight.focus)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(accent.opacity(0.12), in: Capsule())
                    }
                    Text(isLoading ? "Reading your day..." : insight.headline)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if isAI {
                    Text("AI")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.85), in: Capsule())
                }
            }

            if isLoading {
                Text("ChefBuddy is comparing your plan, completions, and what you actually ate.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    coachMiniPill(text: insight.benefit, systemImage: "sparkles", tint: accent)

                    Text(insight.nextAction)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.93), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func coachMiniPill(text: String, systemImage: String, tint: Color, fill: Color? = nil) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background((fill ?? tint.opacity(0.12)), in: Capsule())
    }
}

struct MealSlotRow: View {
    let type: String
    let slot: MealPlanSlot?
    let onTap: () -> Void
    var onRemove: (() -> Void)? = nil
    var onStatusSelect: ((MealPlanSlotStatus) -> Void)? = nil

    private var iconName: String {
        switch type {
        case "Breakfast": return "sunrise.fill"
        case "Lunch": return "sun.max.fill"
        default: return "moon.stars.fill"
        }
    }

    private var accent: Color {
        switch type {
        case "Breakfast": return .orange
        case "Lunch": return .green
        default: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.18))
                            .frame(width: 34, height: 34)
                        Image(systemName: iconName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(accent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(type)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)

                        Text(slot?.displayTitle.isEmpty == false ? slot?.displayTitle ?? "" : "Tap to add recipe")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle((slot?.displayTitle.isEmpty ?? true) ? .secondary : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if let plannedRecipe = slot?.plannedRecipe {
                            HStack(spacing: 8) {
                                Text(plannedRecipe.calories.isEmpty ? "Nutrition pending" : plannedRecipe.calories)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.red)

                                Text(plannedRecipe.description)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        if let status = slot?.status {
                            Text(status.title)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(status == .cooked || status == .logged ? .green : .secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    (status == .cooked || status == .logged ? Color.green : Color.primary)
                                        .opacity(0.12),
                                    in: Capsule()
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if slot?.displayTitle.isEmpty ?? true {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if !(slot?.displayTitle.isEmpty ?? true) {
                if onStatusSelect != nil {
                    Menu {
                        ForEach(MealPlanSlotStatus.allCases, id: \.rawValue) { status in
                            Button(status.title) {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                onStatusSelect?(status)
                            }
                        }
                    } label: {
                        Image(systemName: "checklist.checked")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(10)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onRemove?()
                }) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MealLogEntrySheet: View {
    let day: String
    let defaultMealType: String
    @ObservedObject var assistant: CookingAssistant
    let onSave: (MealLogDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = MealLogDraft()
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedPhotoImage: UIImage? = nil
    @State private var isEstimating = false
    @State private var isSaving = false

    private let mealTypeOptions = ["Breakfast", "Lunch", "Dinner", "Snack"]

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.calories.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Log what you actually ate")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .padding(.top, 8)

                        Text("Track off-plan meals with quick AI estimates or manual values so your plan learns from real intake.")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        Picker("Input", selection: $draft.mode) {
                            ForEach(MealLogInputMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Meal slot")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Picker("Meal slot", selection: $draft.mealType) {
                                ForEach(mealTypeOptions, id: \.self) { type in
                                    Text(type).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Meal name")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                            TextField("Paneer wrap, protein bowl, cereal + fruit...", text: $draft.title)
                                .textInputAutocapitalization(.words)
                                .padding(12)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Notes / portion")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                            TextField("Example: medium bowl, 1.5 cups", text: $draft.notes, axis: .vertical)
                                .lineLimit(2...4)
                                .padding(12)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        if draft.mode == .photo {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Photo")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)

                                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                    Label(selectedPhotoImage == nil ? "Choose meal photo" : "Change photo", systemImage: "photo")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)

                                if selectedPhotoImage != nil {
                                    Label("Photo selected", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.green)
                                }
                            }
                        }

                        if draft.mode != .manual {
                            Button(action: estimateWithAI) {
                                HStack(spacing: 10) {
                                    if isEstimating {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "sparkles")
                                    }
                                    Text(isEstimating ? "Estimating..." : "Estimate Nutrition")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isEstimating || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        nutritionFieldsSection

                        Button(action: save) {
                            HStack(spacing: 8) {
                                if isSaving {
                                    ProgressView()
                                        .tint(.white)
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                Text(isSaving ? "Saving..." : "Save Meal Log")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(colors: [.green.opacity(0.85), .teal.opacity(0.75)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSave || isSaving)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 26)
                }
            }
            .navigationTitle("\(day) meal log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            draft.mealType = defaultMealType
        }
        .onChange(of: selectedPhotoItem) { _ in
            Task { await loadSelectedPhoto() }
        }
        .onChange(of: draft.mode) { mode in
            if mode == .manual {
                draft.isEstimated = false
                draft.confidence = nil
            }
        }
    }

    private var nutritionFieldsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nutrition")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    nutritionField("kcal", text: $draft.calories, unit: "kcal", color: .orange)
                    nutritionField("Carbs", text: $draft.carbs, unit: "g", color: .blue)
                    nutritionField("Protein", text: $draft.protein, unit: "g", color: .green)
                    nutritionField("Fat", text: $draft.fat, unit: "g", color: .pink)
                    nutritionField("Sodium", text: $draft.sodium, unit: "mg", color: .purple)
                }
                .frame(maxWidth: .infinity)

                MealPlanNutritionWheel(
                    protein: nutritionNumericValue(from: draft.protein),
                    carbs: nutritionNumericValue(from: draft.carbs),
                    fat: nutritionNumericValue(from: draft.fat)
                )
                .frame(width: 108, height: 108)
            }

            if let confidence = draft.confidence, !confidence.isEmpty {
                Text("AI confidence: \(confidence)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func nutritionField(_ label: String, text: Binding<String>, unit: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            TextField("0", text: text)
                .keyboardType(.numbersAndPunctuation)
                .font(.system(size: 13, weight: .bold, design: .rounded))

            Text(unit)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func editableRowsSection(
        title: String,
        subtitle: String,
        rows: Binding<[String]>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    rows.wrappedValue.append("")
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(rows.wrappedValue.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 8) {
                    TextField(placeholder, text: Binding(
                        get: { rows.wrappedValue[index] },
                        set: { rows.wrappedValue[index] = $0 }
                    ))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        guard rows.wrappedValue.count > 1 else { return }
                        rows.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(rows.wrappedValue.count > 1 ? .red : .secondary.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func normalizeNutrition(_ value: String, unit: String) -> String {
        let numeric = nutritionNumericValue(from: value)
        guard numeric > 0 else { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if numeric.rounded() == numeric {
            if unit == "kcal" {
                return "\(Int(numeric)) kcal"
            }
            return "\(Int(numeric))\(unit)"
        }
        if unit == "kcal" {
            return "\(String(format: "%.1f", numeric)) kcal"
        }
        return "\(String(format: "%.1f", numeric))\(unit)"
    }

    private func save() {
        guard !isSaving, canSave else { return }
        isSaving = true
        Task {
            var finalDraft = draft
            finalDraft.calories = normalizeNutrition(finalDraft.calories, unit: "kcal")
            finalDraft.carbs = normalizeNutrition(finalDraft.carbs, unit: "g")
            finalDraft.protein = normalizeNutrition(finalDraft.protein, unit: "g")
            finalDraft.fat = normalizeNutrition(finalDraft.fat, unit: "g")
            finalDraft.sodium = normalizeNutrition(finalDraft.sodium, unit: "mg")
            finalDraft.ingredients = []
            finalDraft.steps = []
            await MainActor.run {
                onSave(finalDraft)
                isSaving = false
                dismiss()
            }
        }
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
            print("Failed to load selected meal log photo: \(error.localizedDescription)")
        }
    }

    private func estimateWithAI() {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        isEstimating = true
        Task {
            do {
                let prompt = """
                Estimate nutrition for this meal log.
                Return ONLY valid JSON:
                {
                  "calories": "420 kcal",
                  "carbs": "42g",
                  "protein": "30g",
                  "fat": "14g",
                  "sodium": "540mg",
                  "confidence": "high|medium|low"
                }

                Meal: \(title)
                Portion notes: \(draft.notes)
                """

                let responseText: String
                if draft.mode == .photo, let image = selectedPhotoImage {
                    responseText = try await assistant.getLiveHelp(image: image, question: prompt)
                } else {
                    responseText = try await assistant.getHelp(question: prompt)
                }

                guard let jsonObject = extractJSONObject(from: responseText),
                      let data = jsonObject.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    await MainActor.run { isEstimating = false }
                    return
                }

                await MainActor.run {
                    draft.calories = (object["calories"] as? String) ?? draft.calories
                    draft.carbs = (object["carbs"] as? String) ?? draft.carbs
                    draft.protein = (object["protein"] as? String) ?? draft.protein
                    draft.fat = (object["fat"] as? String) ?? draft.fat
                    draft.sodium = (object["sodium"] as? String) ?? draft.sodium
                    draft.confidence = (object["confidence"] as? String)?.capitalized
                    draft.isEstimated = true
                    isEstimating = false
                }
            } catch {
                await MainActor.run {
                    isEstimating = false
                }
            }
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

    private func polishDraftWithAI(_ source: MealLogDraft) async -> MealLogDraft {
        let cleanIngredients = source.ingredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanSteps = source.steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleanIngredients.isEmpty || !cleanSteps.isEmpty else {
            return source
        }

        do {
            let prompt = """
            Polish this meal log ingredient list and step list so they are clear and complete.
            Return ONLY JSON:
            {
              "ingredients": ["..."],
              "steps": ["..."]
            }
            Meal: \(source.title)
            Notes: \(source.notes)
            Ingredients: \(cleanIngredients.joined(separator: " | "))
            Steps: \(cleanSteps.joined(separator: " | "))
            """
            let raw = try await assistant.getHelp(question: prompt)
            guard let json = extractJSONObject(from: raw),
                  let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return source
            }

            var updated = source
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
}

private struct CustomMealRecipeSheet: View {
    let day: String
    let defaultMealType: String
    @ObservedObject var assistant: CookingAssistant
    let onSave: (CustomMealRecipeDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CustomMealRecipeDraft()
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedPhotoImage: UIImage? = nil
    @State private var isAIFilling = false
    @State private var isSaving = false

    private let mealTypeOptions = ["Breakfast", "Lunch", "Dinner"]

    private var canSave: Bool {
        let titleOk = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ingredientsOk = draft.ingredients.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let stepsOk = draft.steps.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return titleOk && ingredientsOk && stepsOk
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ChefBuddyBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Create custom recipe card")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .padding(.top, 8)

                        Text("Build your own recipe and drop it directly into \(day)’s plan.")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 12) {
                            Picker("Meal", selection: $draft.mealType) {
                                ForEach(mealTypeOptions, id: \.self) { type in
                                    Text(type).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)

                            HStack(spacing: 10) {
                                TextField("Emoji", text: $draft.emoji)
                                    .frame(width: 76)
                                    .padding(10)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                                TextField("Recipe title", text: $draft.title)
                                    .textInputAutocapitalization(.words)
                                    .padding(10)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            HStack(spacing: 10) {
                                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                    Label(selectedPhotoImage == nil ? "Add Photo" : "Change Photo", systemImage: "photo")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(Color.blue.opacity(0.84), in: Capsule())
                                }

                                Button(action: fillWithAI) {
                                    HStack(spacing: 8) {
                                        if isAIFilling {
                                            ProgressView()
                                                .tint(.white)
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "sparkles")
                                        }
                                        Text(isAIFilling ? "Filling..." : "AI Fill")
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                                        in: Capsule()
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isAIFilling || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            TextField("Short description", text: $draft.description, axis: .vertical)
                                .lineLimit(2...4)
                                .padding(10)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Recipe Filters")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 10) {
                                    filterMetricCard(
                                        icon: "clock.fill",
                                        label: "Prep",
                                        value: "\(draft.prepMinutes) mins"
                                    ) {
                                        Stepper("", value: $draft.prepMinutes, in: 5...240, step: 5)
                                            .labelsHidden()
                                    }

                                    filterMetricCard(
                                        icon: "person.2.fill",
                                        label: "Serves",
                                        value: "\(draft.servingsCount)"
                                    ) {
                                        Stepper("", value: $draft.servingsCount, in: 1...12)
                                            .labelsHidden()
                                    }
                                }

                                Picker("Difficulty", selection: $draft.difficulty) {
                                    Text("🟢 Easy").tag("Easy")
                                    Text("🟠 Medium").tag("Medium")
                                    Text("🔴 Hard").tag("Hard")
                                }
                                .pickerStyle(.segmented)

                                TextField("Tags (comma-separated)", text: $draft.tagsText)
                                    .padding(10)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Nutrition")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)

                                HStack(alignment: .top, spacing: 14) {
                                    VStack(spacing: 8) {
                                        nutritionStepperRow(title: "kcal", value: $draft.calories, step: 10, color: .orange)
                                        nutritionStepperRow(title: "Carbs", value: $draft.carbs, step: 1, color: .blue)
                                        nutritionStepperRow(title: "Protein", value: $draft.protein, step: 1, color: .green)
                                        nutritionStepperRow(title: "Fat", value: $draft.fat, step: 1, color: .pink)
                                        nutritionStepperRow(title: "Sodium", value: $draft.sodium, step: 10, color: .purple)
                                    }
                                    .frame(maxWidth: .infinity)

                                    MealPlanNutritionWheel(
                                        protein: Double(draft.protein),
                                        carbs: Double(draft.carbs),
                                        fat: Double(draft.fat)
                                    )
                                    .frame(width: 114, height: 114)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            editableRowsSection(
                                title: "Ingredients",
                                subtitle: "Add measured ingredients one by one.",
                                rows: $draft.ingredients,
                                placeholder: "1 cup diced onions"
                            )

                            editableRowsSection(
                                title: "Steps",
                                subtitle: "Build the process step by step.",
                                rows: $draft.steps,
                                placeholder: "Heat oil in a pan over medium heat."
                            )

                            Toggle(isOn: $draft.autoPolishWithAI) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("AI polish before save")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                    Text("ChefBuddy checks quantities and fills missing transitions.")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        Button(action: save) {
                            HStack(spacing: 8) {
                                if isSaving {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                Text(isSaving ? "Saving..." : "Save + Add to \(day)")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSave || isSaving)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
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
        .onAppear {
            draft.mealType = defaultMealType
        }
        .onChange(of: selectedPhotoItem) { _ in
            Task { await loadSelectedPhoto() }
        }
    }

    private func filterMetricCard<Control: View>(
        icon: String,
        label: String,
        value: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: 22, height: 22)
                .background(Color.orange.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }

            Spacer(minLength: 4)

            control()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func nutritionStepperRow(
        title: String,
        value: Binding<Int>,
        step: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Stepper(value: value, in: 0...3000, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        Task {
            var finalDraft = draft
            if draft.autoPolishWithAI {
                finalDraft = await polishDraftWithAI(draft)
            }
            await MainActor.run {
                onSave(finalDraft)
                isSaving = false
                dismiss()
            }
        }
    }

    private func fillWithAI() {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isAIFilling else { return }
        isAIFilling = true
        Task {
            do {
                let prompt = """
                Generate a full recipe draft from this title and optional image.
                Return ONLY JSON:
                {
                  "emoji": "🍲",
                  "description": "short description",
                  "prepMinutes": 25,
                  "servingsCount": 2,
                  "difficulty": "Easy|Medium|Hard",
                  "tagsText": "Indian, High Protein",
                  "calories": 420,
                  "carbs": 40,
                  "protein": 25,
                  "fat": 15,
                  "sodium": 520,
                  "ingredients": ["1 cup ...", "..."],
                  "steps": ["Step 1...", "Step 2..."]
                }
                Title: \(title)
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
                    await MainActor.run { isAIFilling = false }
                    return
                }

                await MainActor.run {
                    draft.emoji = (object["emoji"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? draft.emoji
                    draft.description = (object["description"] as? String) ?? draft.description
                    draft.prepMinutes = max(5, object["prepMinutes"] as? Int ?? draft.prepMinutes)
                    draft.servingsCount = max(1, object["servingsCount"] as? Int ?? draft.servingsCount)
                    draft.difficulty = (object["difficulty"] as? String) ?? draft.difficulty
                    draft.tagsText = (object["tagsText"] as? String) ?? draft.tagsText
                    draft.calories = max(0, object["calories"] as? Int ?? draft.calories)
                    draft.carbs = max(0, object["carbs"] as? Int ?? draft.carbs)
                    draft.protein = max(0, object["protein"] as? Int ?? draft.protein)
                    draft.fat = max(0, object["fat"] as? Int ?? draft.fat)
                    draft.sodium = max(0, object["sodium"] as? Int ?? draft.sodium)
                    if let ingredients = object["ingredients"] as? [String], !ingredients.isEmpty {
                        draft.ingredients = ingredients
                    }
                    if let steps = object["steps"] as? [String], !steps.isEmpty {
                        draft.steps = steps
                    }
                    if draft.ingredients.isEmpty { draft.ingredients = [""] }
                    if draft.steps.isEmpty { draft.steps = [""] }
                    isAIFilling = false
                }
            } catch {
                await MainActor.run {
                    isAIFilling = false
                }
            }
        }
    }

    private func polishDraftWithAI(_ source: CustomMealRecipeDraft) async -> CustomMealRecipeDraft {
        do {
            let prompt = """
            Polish this recipe so ingredients are properly quantified and steps are complete.
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

    private func editableRowsSection(
        title: String,
        subtitle: String,
        rows: Binding<[String]>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    rows.wrappedValue.append("")
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(rows.wrappedValue.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 8) {
                    TextField(placeholder, text: Binding(
                        get: { rows.wrappedValue[index] },
                        set: { rows.wrappedValue[index] = $0 }
                    ))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        guard rows.wrappedValue.count > 1 else { return }
                        rows.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(rows.wrappedValue.count > 1 ? .red : .secondary.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
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
}
