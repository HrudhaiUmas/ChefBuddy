// MealPlan.swift
// Meal planning feature — lets users schedule recipes across a week.
// Persists plan data to Firestore so it survives app restarts and can
// later be used to auto-generate a grocery list from planned meals.

import SwiftUI
import FirebaseFirestore
import FirebaseAuth
import Combine

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

    var displayTitle: String {
        let snapshotTitle = plannedRecipe?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let topLevelTitle = recipeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !snapshotTitle.isEmpty ? snapshotTitle : topLevelTitle
    }

    var hasRecipeContent: Bool {
        plannedRecipe != nil
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
    @Published var isGenerating = false
    @Published var activeGeneration: MealPlanGenerationSession? = nil

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
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

    }

    func addToPlan(recipe: Recipe, day: String, mealType: String, userId: String) {
        let slotId = "\(day)-\(mealType)"
        let ref = db.collection("users").document(userId).collection("mealPlan").document(slotId)

        let slot = MealPlanSlot(
            id: slotId,
            day: day,
            mealType: mealType,
            recipeId: recipe.id ?? "",
            recipeTitle: recipe.title,
            plannedRecipe: PlannedMealRecipe(recipe: recipe)
        )

        do {
            var payload = try Firestore.Encoder().encode(slot)
            payload["updatedAt"] = FieldValue.serverTimestamp()

            ref.setData(payload, merge: true) { error in
                if error == nil {
                    DispatchQueue.main.async {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
            plannedRecipe: PlannedMealRecipe(recipe: recipe)
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
                    plannedRecipe: PlannedMealRecipe(recipe: recipe)
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
                    plannedRecipe: PlannedMealRecipe(recipe: recipe)
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

    @State private var selectedDay = "Monday"
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

    private let days = [
        "Monday", "Tuesday", "Wednesday",
        "Thursday", "Friday", "Saturday", "Sunday"
    ]

    private let mealTypes = ["Breakfast", "Lunch", "Dinner"]

    private var filledSlotsCount: Int {
        vm.weeklySlots.filter { !$0.displayTitle.isEmpty }.count
    }

    private var selectedDayFilledCount: Int {
        mealTypes.compactMap { slotFor(type: $0) }.filter { !$0.displayTitle.isEmpty }.count
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
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Weekly Meal Plan")
                                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                                Text("\(filledSlotsCount)/21 slots planned")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(selectedDayFilledCount)/3 today")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.16))
                                .clipShape(Capsule())
                        }

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
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : -12)

                    DayNutritionSummaryCard(day: selectedDay, summary: selectedDayNutritionSummary)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : -8)

                    VStack(spacing: 12) {
                        ForEach(mealTypes, id: \.self) { type in
                            MealSlotRow(
                                type: type,
                                slot: slotFor(type: type),
                                onTap: { handleSlotTap(type: type) },
                                onRemove: { removeSlot(type: type) }
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
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("Meal Plan")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            pulseHero = true
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(0.05)) {
                hasAppeared = true
            }

            if let uid = authVM.userSession?.uid {
                vm.startListening(userId: uid)
                recipesVM.startListening(userId: uid)
            }
        }
        .sheet(item: $selectedRecipeForDetail) { recipe in
            RecipeDetailView(
                recipe: recipe,
                assistant: assistant,
                pantryIngredients: [],
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
                userId: authVM.userSession?.uid ?? ""
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
    }
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
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct MealSlotRow: View {
    let type: String
    let slot: MealPlanSlot?
    let onTap: () -> Void
    var onRemove: (() -> Void)? = nil

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
