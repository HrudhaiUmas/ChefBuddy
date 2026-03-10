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

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    func startListening(userId: String) {

        guard !userId.isEmpty else { return }

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
            }

        } catch {

            print("Weekly plan error:", error)

            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
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

    @State private var selectedDay = "Monday"
    @State private var showRecipePicker = false
    @State private var selectedMealType: String?
    @State private var selectedRecipeForDetail: Recipe? = nil
    @State private var recipeToOpen: Recipe? = nil
    @StateObject private var recipesVM = RecipesViewModel()

    let days = [
        "Monday","Tuesday","Wednesday",
        "Thursday","Friday","Saturday","Sunday"
    ]


    private func slotFor(type: String) -> MealPlanSlot? {

        vm.weeklySlots.first {
            $0.day == selectedDay && $0.mealType == type
        }
    }
    
    private func handleSlotTap(type: String) {
        if let slot = slotFor(type: type), let recipeId = slot.recipeId {
            if let foundRecipe = recipesVM.recipes.first(where: { $0.id == recipeId }) {
                self.selectedRecipeForDetail = foundRecipe
            } else {
                selectedMealType = type
                showRecipePicker = true
            }
        } else {
            // Slot is empty, show picker
            selectedMealType = type
            showRecipePicker = true
        }
    }


    func addManualRecipe(_ mealType: String) {

        guard let uid = authVM.userSession?.uid else { return }

        let recipe = Recipe(
            title: "Custom Meal",
            description: "",
            ingredients: [],
            steps: [],
            cookTime: "",
            servings: "",
            difficulty: ""
        )

        vm.addToPlan(
            recipe: recipe,
            day: selectedDay,
            mealType: mealType,
            userId: uid
        )
    }


    var body: some View {
        ZStack{
            ChefBuddyBackground()
            
            
            
            VStack(spacing: 20) {
                
                
                ScrollView(.horizontal, showsIndicators: false) {
                    
                    HStack(spacing: 12) {
                        
                        ForEach(days, id: \.self) { day in
                            
                            DayButton(day: day, isSelected: selectedDay == day)
                                .onTapGesture {
                                    withAnimation(.spring()) {
                                        selectedDay = day
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                }
                
                
                
                List {
                    
                    MealSlotRow(
                        type: "Breakfast",
                        slot: slotFor(type: "Breakfast"),
                        onTap: { handleSlotTap(type: "Breakfast") },
                        onRemove: {
                            if let uid = authVM.userSession?.uid {
                                vm.removeFromPlan(day: selectedDay, mealType: "Breakfast", userId: uid)
                            }
                        }
                    )
                    
                    MealSlotRow(
                        type: "Lunch",
                        slot: slotFor(type: "Lunch"),
                        onTap: { handleSlotTap(type: "Lunch") },
                        onRemove: {
                            if let uid = authVM.userSession?.uid {
                                vm.removeFromPlan(day: selectedDay, mealType: "Lunch", userId: uid)
                            }
                        }
                    )
                    
                    MealSlotRow(
                        type: "Dinner",
                        slot: slotFor(type: "Dinner"),
                        onTap: { handleSlotTap(type: "Dinner") },
                        onRemove: {
                            if let uid = authVM.userSession?.uid {
                                vm.removeFromPlan(day: selectedDay, mealType: "Dinner", userId: uid)
                            }
                        }
                    )
                }
                .listStyle(.plain)
                
                
                // AI Generator
                
                Button {
                    
                    Task {
                        
                        if let uid = authVM.userSession?.uid {
                            
                            await vm.generateWeeklyPlan(
                                assistant: assistant,
                                userId: uid
                            )
                        }
                    }
                    
                } label: {
                    
                    HStack {
                        
                        Image(systemName: "sparkles")
                        
                        Text("Generate Weekly Plan")
                            .fontWeight(.semibold)
                    }
                    
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            .navigationTitle("Meal Plan")
            
            .onAppear {
                
                if let uid = authVM.userSession?.uid {
                    vm.startListening(userId: uid)
                    
                    recipesVM.startListening(userId: uid)
                }
            }
            .sheet(item: $selectedRecipeForDetail) { recipe in
                RecipeDetailView(
                    recipe: recipe,
                    assistant: assistant,
                    pantryIngredients: [], // You can pass pantry ingredients here if available
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
                        
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Select a recipe for \(selectedDay) \(selectedMealType ?? "")")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 20)
                                
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
                            .padding(.top, 20)
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
        }
    }
}



// MARK: - UI Components

struct DayButton: View {

    let day: String
    let isSelected: Bool

    var body: some View {

        Text(day)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(isSelected ? Color.orange : Color(.systemGray6))
            .clipShape(Capsule())
    }
}


struct MealSlotRow: View {
    let type: String
    let slot: MealPlanSlot?
    let onTap: () -> Void
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack {
            Button(action: onTap) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(type)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        Text(slot?.recipeTitle ?? "Tap to add recipe...")
                            .font(.headline)
                            .foregroundStyle(slot?.recipeTitle == nil ? .tertiary : .primary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if slot?.recipeTitle != nil {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onRemove?()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red.opacity(0.7))
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            } else {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 8)
    }
}
