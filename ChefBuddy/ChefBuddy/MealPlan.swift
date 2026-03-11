import SwiftUI
import FirebaseFirestore
import FirebaseAuth
import Combine

// MARK: - Models

struct MealPlanSlot: Identifiable, Codable {
    var id: String?
    var day: String
    var mealType: String
    var recipeId: String?
    var recipeTitle: String?
}


// MARK: - ViewModel

class MealPlanViewModel: ObservableObject {

    @Published var weeklySlots: [MealPlanSlot] = []
    @Published var isGenerating = false

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

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
    @Published var showSuccessAlert = false

    func addToPlan(recipe: Recipe, day: String, mealType: String, userId: String) {
        let slotId = "\(day)-\(mealType)"
        let ref = db.collection("users").document(userId).collection("mealPlan").document(slotId)

        let payload: [String: Any] = [
            "id": slotId,
            "day": day,
            "mealType": mealType,
            "recipeId": recipe.id ?? "",
            "recipeTitle": recipe.title,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        ref.setData(payload, merge: true) { error in
            if error == nil {
                DispatchQueue.main.async {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.showSuccessAlert = true // This triggers your confirmation alert
                }
            } else {
                print("Error adding to plan: \(error?.localizedDescription ?? "Unknown error")")
            }
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


    // MARK: - Manual Add




    // MARK: - AI Plan Generator

    func generateWeeklyPlan(
        assistant: CookingAssistant,
        userId: String
    ) async {

        guard !userId.isEmpty else { return }
        await MainActor.run {
            isGenerating = true
        }

        do {

            // Fetch user preferences
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
            

            let existingSnap = try await db.collection("users")
                .document(userId)
                .collection("mealPlan")
                .getDocuments()

            let currentPlan = existingSnap.documents.compactMap { try? $0.data(as: MealPlanSlot.self) }

            var emptySlotsDescription = ""
            for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] {
                for meal in ["Breakfast", "Lunch", "Dinner"] {
                    if !currentPlan.contains(where: { $0.day == day && $0.mealType == meal }) {
                        emptySlotsDescription += "- \(day): \(meal)\n"
                    }
                }
            }

            let prompt = """
            Generate meals ONLY for the following empty slots:
            \(emptySlotsDescription)

            Do not provide suggestions for slots already filled.
            User preferences: \(context)

            Return ONLY valid JSON in this format:
            [
              {"day":"Monday","mealType":"Breakfast","recipeTitle":"Example"}
            ]
            
            Generate a 7-day meal plan including Breakfast, Lunch, and Dinner for ONLY empty slots.

            Do not skip any meals.

            User preferences:
            \(context)

            Choose meals primarily from these recipes when possible.

            Return ONLY valid JSON in this format:

            [
            {"day":"Monday","mealType":"Breakfast","recipeTitle":"Example"},
            {"day":"Monday","mealType":"Lunch","recipeTitle":"Example"},
            {"day":"Monday","mealType":"Dinner","recipeTitle":"Example"},

            {"day":"Tuesday","mealType":"Breakfast","recipeTitle":"Example"},
            {"day":"Tuesday","mealType":"Lunch","recipeTitle":"Example"},
            {"day":"Tuesday","mealType":"Dinner","recipeTitle":"Example"},

            {"day":"Wednesday","mealType":"Breakfast","recipeTitle":"Example"},
            {"day":"Wednesday","mealType":"Lunch","recipeTitle":"Example"},
            {"day":"Wednesday","mealType":"Dinner","recipeTitle":"Example"},

            {"day":"Thursday","mealType":"Breakfast","recipeTitle":"Example"},
            {"day":"Thursday","mealType":"Lunch","recipeTitle":"Example"},
            {"day":"Thursday","mealType":"Dinner","recipeTitle":"Example"},

            {"day":"Friday","mealType":"Breakfast","recipeTitle":"Example"},
            {"day":"Friday","mealType":"Lunch","recipeTitle":"Example"},
            {"day":"Friday","mealType":"Dinner","recipeTitle":"Example"},

            {"day":"Saturday","mealType":"Breakfast","recipeTitle":"Example"},
            {"day":"Saturday","mealType":"Lunch","recipeTitle":"Example"},
            {"day":"Saturday","mealType":"Dinner","recipeTitle":"Example"},

            {"day":"Sunday","mealType":"Breakfast","recipeTitle":"Example"},
            {"day":"Sunday","mealType":"Lunch","recipeTitle":"Example"},
            {"day":"Sunday","mealType":"Dinner","recipeTitle":"Example"}
            ]
            """


            try await assistant.waitUntilReady()

            let response = try await assistant.getHelp(question: prompt)

            guard let json = extractJSONArray(from: response),
                  let data = json.data(using: .utf8) else { return }

            var generated = try JSONDecoder().decode([MealPlanSlot].self, from: data)

            for i in generated.indices {
                generated[i].id = "\(generated[i].day)-\(generated[i].mealType)"
            }

            // Ensure IDs exist
            for i in generated.indices {
                generated[i].id = "\(generated[i].day)-\(generated[i].mealType)"
            }


            // Batch write
            let batch = db.batch()

            let collection = db.collection("users")
                .document(userId)
                .collection("mealPlan")

            for slot in generated {

                let doc = collection.document(slot.id ?? "\(slot.day)-\(slot.mealType)")

                let payload: [String: Any] = [
                    "id": slot.id ?? "\(slot.day)-\(slot.mealType)",
                    "day": slot.day,
                    "mealType": slot.mealType,
                    "recipeTitle": slot.recipeTitle ?? "New Recipe",
                    "updatedAt": FieldValue.serverTimestamp()
                ]

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


    // Extract JSON array safely

    private func extractJSONArray(from raw: String) -> String? {

        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]")
        else { return nil }

        return String(raw[start...end])
    }
}


// MARK: - Main View

struct WeeklyMealPlanView: View {

    @EnvironmentObject var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant

    @StateObject private var vm = MealPlanViewModel()
    @StateObject private var recipesVM = RecipesViewModel()

    @State private var selectedDay = "Monday"
    @State private var showRecipePicker = false
    @State private var selectedMealType: String?
    @State private var selectedRecipeForDetail: Recipe? = nil
    @State private var hasAppeared = false
    @State private var pulseHero = false

    private let days = [
        "Monday", "Tuesday", "Wednesday",
        "Thursday", "Friday", "Saturday", "Sunday"
    ]

    private let mealTypes = ["Breakfast", "Lunch", "Dinner"]

    private var filledSlotsCount: Int {
        vm.weeklySlots.filter { ($0.recipeTitle ?? "").isEmpty == false }.count
    }

    private var selectedDayFilledCount: Int {
        mealTypes.compactMap { slotFor(type: $0) }.filter { ($0.recipeTitle ?? "").isEmpty == false }.count
    }

    private func shortDay(_ day: String) -> String {
        String(day.prefix(3))
    }

    private func slotFor(type: String) -> MealPlanSlot? {
        vm.weeklySlots.first {
            $0.day == selectedDay && $0.mealType == type
        }
    }

    private func handleSlotTap(type: String) {
        if let slot = slotFor(type: type), let recipeId = slot.recipeId {
            if let foundRecipe = recipesVM.recipes.first(where: { $0.id == recipeId }) {
                selectedRecipeForDetail = foundRecipe
            } else {
                selectedMealType = type
                showRecipePicker = true
            }
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
        Task {
            if let uid = authVM.userSession?.uid {
                await vm.generateWeeklyPlan(assistant: assistant, userId: uid)
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
                        HStack(spacing: 8) {
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

                            if vm.isGenerating {
                                Spacer(minLength: 0)
                                Text("AI")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.20))
                                    .clipShape(Capsule())
                            }
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
        .alert("Added to Plan", isPresented: $vm.showSuccessAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Recipe added to your \(selectedDay) plan.")
        }
    }
}

// MARK: - UI Components

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

                        Text(slot?.recipeTitle ?? "Tap to add recipe")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(slot?.recipeTitle == nil ? .secondary : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if slot?.recipeTitle == nil {
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

            if slot?.recipeTitle != nil {
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
