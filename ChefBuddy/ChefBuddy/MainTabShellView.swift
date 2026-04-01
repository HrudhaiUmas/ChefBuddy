import SwiftUI
import FirebaseFirestore
import FirebaseAuth
import UIKit

enum AppTab: Hashable {
    case plan
    case pantry
    case home
    case recipes
    case profile
}

struct MainTabShellView: View {
    @EnvironmentObject private var authVM: AuthViewModel
    @StateObject private var assistant = CookingAssistant()
    @State private var selectedTab: AppTab = .home
    @State private var showGroceryList = false
    @State private var showRecipePicker = false
    @State private var selectedLiveRecipe: Recipe? = nil
    @State private var savedRecipes: [Recipe] = []
    @State private var recipesListener: ListenerRegistration? = nil

    private var userId: String? {
        authVM.userSession?.uid
    }

    private var budgetPreference: String {
        authVM.currentUserProfile?.budget ?? "💵 $$ (Standard)"
    }

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().isHidden = true
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                PlanTabRootView(assistant: assistant)
            }
            .tag(AppTab.plan)
            .tabItem {
                Label("Plan", systemImage: "calendar")
            }

            NavigationStack {
                PantryTabRootView(
                    assistant: assistant,
                    onOpenGrocery: { showGroceryList = true }
                )
            }
            .tag(AppTab.pantry)
            .tabItem {
                Label("Pantry", systemImage: "basket.fill")
            }

            NavigationStack {
                HomeDashboardView(
                    assistant: assistant,
                    savedRecipes: savedRecipes,
                    selectedTab: $selectedTab,
                    onOpenGrocery: { showGroceryList = true },
                    onOpenLiveCookingPicker: { showRecipePicker = true }
                )
            }
            .tag(AppTab.home)
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }

            NavigationStack {
                RecipesTabRootView(
                    assistant: assistant,
                    savedRecipes: savedRecipes,
                    onOpenLiveCookingPicker: { showRecipePicker = true }
                )
            }
            .tag(AppTab.recipes)
            .tabItem {
                Label("Recipes", systemImage: "book.closed.fill")
            }

            NavigationStack {
                ProfileTabRootView()
            }
            .tag(AppTab.profile)
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 86)
        }
        .overlay(alignment: .bottom) {
            FloatingShellTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
        }
        .tint(.orange)
        .task(id: userId) {
            guard let userId else {
                stopRecipesListener()
                savedRecipes = []
                return
            }

            await assistant.setupAssistant(userId: userId)
            startRecipesListener(userId: userId)
        }
        .onDisappear {
            stopRecipesListener()
        }
        .sheet(isPresented: $showGroceryList) {
            NavigationStack {
                if let userId {
                    GroceryListView(
                        userId: userId,
                        assistant: assistant,
                        budgetPreference: budgetPreference
                    )
                } else {
                    Text("Sign in to view your grocery list.")
                        .padding()
                }
            }
        }
        .sheet(isPresented: $showRecipePicker) {
            RecipePickerSheet(recipes: savedRecipes) { recipe in
                selectedLiveRecipe = recipe
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $selectedLiveRecipe) { recipe in
            if let userId {
                LiveCookingView(recipe: recipe, assistant: assistant, userId: userId)
            } else {
                Text("Sign in to use Live Cooking Help.")
            }
        }
    }

    private func startRecipesListener(userId: String) {
        recipesListener?.remove()
        recipesListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("recipes")
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }
                DispatchQueue.main.async {
                    savedRecipes = documents.compactMap { try? $0.data(as: Recipe.self) }
                }
            }
    }

    private func stopRecipesListener() {
        recipesListener?.remove()
        recipesListener = nil
    }
}

struct HomeDashboardView: View {
    @EnvironmentObject private var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant
    let savedRecipes: [Recipe]
    @Binding var selectedTab: AppTab
    let onOpenGrocery: () -> Void
    let onOpenLiveCookingPicker: () -> Void

    @State private var pantrySpaces: [SimplePantrySpace] = []
    @State private var weeklySlots: [MealPlanSlot] = []
    @State private var pantryListener: ListenerRegistration? = nil
    @State private var mealPlanListener: ListenerRegistration? = nil
    @State private var greetingText = ""
    @State private var dailyPrompt = "What are we cooking today? 🍳"

    private let mealTypeOrder = ["Breakfast", "Lunch", "Dinner"]

    private var userId: String {
        authVM.userSession?.uid ?? ""
    }

    private var displayName: String {
        if let name = authVM.userSession?.displayName, !name.isEmpty {
            return String(name.split(separator: " ").first ?? "")
        } else if let email = authVM.userSession?.email {
            return String(email.split(separator: "@").first ?? "Chef")
        }
        return "Chef"
    }

    private var pantryItemCount: Int {
        pantrySpaces.reduce(0) { $0 + $1.ingredients.count }
    }

    private var plannedSlotCount: Int {
        weeklySlots.filter { !$0.displayTitle.isEmpty }.count
    }

    private var todayName: String {
        let weekday = Calendar.current.component(.weekday, from: Date())
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[max(0, min(names.count - 1, weekday - 1))]
    }

    private var todaySlots: [MealPlanSlot] {
        mealTypeOrder.compactMap { mealType in
            weeklySlots.first {
                $0.day == todayName && $0.mealType == mealType && !$0.displayTitle.isEmpty
            }
        }
    }

    private var todayCaloriesTotal: Int {
        Int(todaySlots.reduce(0) { partial, slot in
            partial + numericValue(from: slot.plannedRecipe?.calories ?? "")
        }.rounded())
    }

    private var todayPlanSubtitle: String {
        if todaySlots.isEmpty {
            return "No meals are locked in for \(todayName) yet."
        }

        if todayCaloriesTotal > 0 {
            return "\(todaySlots.count) meal\(todaySlots.count == 1 ? "" : "s") lined up for today • about \(todayCaloriesTotal) kcal."
        }

        return "\(todaySlots.count) meal\(todaySlots.count == 1 ? "" : "s") lined up for today."
    }

    private var homeInsight: String {
        if pantryItemCount == 0 {
            return "Scan your pantry once and ChefBuddy can stop guessing what’s actually in your kitchen."
        }
        if savedRecipes.isEmpty {
            return "Save a couple of recipes and Live Cooking gets much more useful on busy nights."
        }
        if todaySlots.isEmpty {
            return "You’ve got the tools ready. A quick day plan makes dinner feel way less random."
        }
        return "Your kitchen is in a good spot today. Keep it simple and cook what already fits the moment."
    }

    var body: some View {
        ZStack {
            ChefBuddyBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    greetingSection
                    liveCookingSection
                    todayPlanSection
                    navigationGridSection
                    insightSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 120)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            greetingText = makeTimeBasedGreeting()
            setupDynamicPrompts()
            startListeners()
        }
        .onDisappear {
            stopListeners()
        }
    }

    private var greetingSection: some View {
        HomeGreetingCard(
            title: greetingText.isEmpty ? makeTimeBasedGreeting() : greetingText,
            subtitle: dailyPrompt
        )
        .padding(.top, 8)
    }

    private var todayPlanSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Today in your kitchen")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Today’s Plan")
                            .font(.system(size: 24, weight: .bold, design: .rounded))

                        Text(todayPlanSubtitle)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(todayName)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }

                if todaySlots.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Nothing’s planned yet, but ChefBuddy can turn that around fast.")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)

                        Button(action: { selectedTab = .plan }) {
                            Label("Open Meal Plan", systemImage: "calendar.badge.plus")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    LinearGradient(colors: [.orange, .green.opacity(0.88)], startPoint: .leading, endPoint: .trailing)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    VStack(spacing: 12) {
                        ForEach(todaySlots, id: \.mealType) { slot in
                            TodayPlanRow(slot: slot)
                        }

                        HStack {
                            if todayCaloriesTotal > 0 {
                                Label("About \(todayCaloriesTotal) kcal planned", systemImage: "bolt.heart.fill")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.green)
                            }

                            Spacer()

                            Button("See full week") {
                                selectedTab = .plan
                            }
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(.top, 6)
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private var liveCookingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to cook?")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(savedRecipes.isEmpty ? "Build a recipe first" : "Jump into Live Cooking")
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)

                        Text(
                            savedRecipes.isEmpty
                            ? "Open Recipes, save something you actually want to make, then ChefBuddy can guide you step by step."
                            : "Pick one of your saved recipes and get real-time help without leaving the kitchen flow."
                        )
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(3)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: savedRecipes.isEmpty ? "book.closed.fill" : "video.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                }

                HStack(spacing: 10) {
                    Button(action: {
                        if savedRecipes.isEmpty {
                            selectedTab = .recipes
                        } else {
                            onOpenLiveCookingPicker()
                        }
                    }) {
                        Text(savedRecipes.isEmpty ? "Open Recipes" : "Start Live Cooking")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.95), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: { selectedTab = .recipes }) {
                        Text("Browse Recipes")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.orange.opacity(0.96), .green.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: .orange.opacity(0.20), radius: 16, y: 8)
        }
    }

    private var navigationGridSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jump Into ChefBuddy")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            HomeAmbientIcons()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                HomeNavigationCard(title: "Pantry", subtitle: "Manage ingredients", icon: "basket.fill", accent: .green) {
                    selectedTab = .pantry
                }

                HomeNavigationCard(title: "Recipes", subtitle: "Discover and save", icon: "book.closed.fill", accent: .orange) {
                    selectedTab = .recipes
                }

                HomeNavigationCard(title: "Meal Plan", subtitle: "Shape your week", icon: "calendar", accent: .teal) {
                    selectedTab = .plan
                }

                HomeNavigationCard(title: "Grocery List", subtitle: "What you still need", icon: "cart.fill", accent: .pink) {
                    onOpenGrocery()
                }
            }

            HomeNavigationWideCard(title: "Profile", subtitle: "Preferences, goals, and settings", icon: "person.crop.circle", accent: .blue) {
                selectedTab = .profile
            }
        }
    }

    private var insightSection: some View {
        Text(homeInsight)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineSpacing(4)
            .padding(.horizontal, 2)
    }

    private func makeTimeBasedGreeting() -> String {
        let date = Date()
        let hour = Calendar.current.component(.hour, from: date)
        let minute = Calendar.current.component(.minute, from: date)

        switch (hour, minute) {
        case (0...2, _), (3, 0...30):
            return [
                "Midnight munchies, \(displayName)? 🦉",
                "Late night cravings, \(displayName)? 🌙",
                "Fueling the midnight oil, \(displayName)? 🍜"
            ].randomElement() ?? "Late night snack, \(displayName)?"
        case (3...11, _):
            return [
                "Rise and shine, Chef \(displayName)! 🍳",
                "Let's get this bread, \(displayName). 🍞",
                "Time to fuel up for the day, \(displayName). ☕️"
            ].randomElement() ?? "Good morning, \(displayName)!"
        case (12...16, _):
            return [
                "Lunchtime cravings, \(displayName)? 🌮",
                "Midday fuel, \(displayName)? 🥗",
                "Let’s cook up a midday masterpiece, \(displayName). 🧑‍🍳"
            ].randomElement() ?? "Good afternoon, \(displayName)!"
        default:
            return [
                "What's on the dinner menu, \(displayName)? 🥘",
                "Time to unwind and dine, \(displayName). 🍽️",
                "Let's cook up something cozy tonight, \(displayName). 🍲"
            ].randomElement() ?? "Good evening, \(displayName)!"
        }
    }

    private func setupDynamicPrompts() {
        let prompts = [
            "Ready to whip up something tasty? 🍳",
            "What's on the menu today? 🌮",
            "Time to make some magic in the kitchen! ✨",
            "Let's cook up a storm! 🌪️",
            "Hungry for something new? 🤤",
            "Grab your apron, it's cooking time! 👨‍🍳"
        ]

        dailyPrompt = prompts.randomElement() ?? prompts[0]
    }

    private func startListeners() {
        guard !userId.isEmpty else { return }

        stopListeners()

        pantryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }
                DispatchQueue.main.async {
                    pantrySpaces = documents.compactMap { document in
                        let data = document.data()
                        let name = data["name"] as? String ?? "Pantry"
                        let emoji = data["emoji"] as? String ?? "🥑"
                        let colorTheme = data["colorTheme"] as? String ?? "Orange"
                        let virtualPantry = data["virtualPantry"] as? [String: [String]] ?? [:]
                        return SimplePantrySpace(
                            id: document.documentID,
                            name: name,
                            emoji: emoji,
                            ingredients: virtualPantry.values.flatMap { $0 },
                            colorTheme: colorTheme
                        )
                    }.sorted { $0.name < $1.name }
                }
            }

        mealPlanListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("mealPlan")
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }
                DispatchQueue.main.async {
                    weeklySlots = documents.compactMap { try? $0.data(as: MealPlanSlot.self) }
                }
            }

    }

    private func stopListeners() {
        pantryListener?.remove()
        pantryListener = nil
        mealPlanListener?.remove()
        mealPlanListener = nil
    }

    private func numericValue(from raw: String) -> Double {
        guard let range = raw.range(of: #"[-+]?\d*\.?\d+"#, options: .regularExpression) else {
            return 0
        }
        return Double(raw[range]) ?? 0
    }

}

struct RecipesTabRootView: View {
    @ObservedObject var assistant: CookingAssistant
    let savedRecipes: [Recipe]
    let onOpenLiveCookingPicker: () -> Void

    var body: some View {
        RecipesView(
            assistant: assistant,
            savedRecipes: savedRecipes,
            onOpenLiveCookingPicker: onOpenLiveCookingPicker
        )
    }
}

struct PantryTabRootView: View {
    @EnvironmentObject private var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant
    let onOpenGrocery: () -> Void

    @State private var availablePantries: [SimplePantrySpace] = []
    @State private var selectedPantryId: String? = nil
    @State private var pantryListener: ListenerRegistration? = nil
    @State private var showVirtualPantry = false

    private var currentPantry: SimplePantrySpace? {
        availablePantries.first(where: { $0.id == selectedPantryId })
    }

    var body: some View {
        ZStack {
            ChefBuddyBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    pantryHeader
                    if availablePantries.isEmpty {
                        pantryEmptyState
                    } else {
                        pantryControlHeader
                        pantrySection
                        grocerySection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 120)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            startListening()
        }
        .onDisappear {
            stopListening()
        }
        .onChange(of: selectedPantryId) { pantryId in
            authVM.updateActivePantrySelection(pantryId)
        }
        .onChange(of: authVM.currentUserProfile?.activePantryId) { pantryId in
            guard pantryId != selectedPantryId else { return }
            if let pantryId,
               availablePantries.contains(where: { $0.id == pantryId }) {
                selectedPantryId = pantryId
            } else if pantryId == nil {
                selectedPantryId = availablePantries.first?.id
            }
        }
        .navigationDestination(isPresented: $showVirtualPantry) {
            VirtualPantryView(assistant: assistant)
                .environmentObject(authVM)
        }
    }

    private var pantryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            AnimatedScreenHeader(
                eyebrow: "Pantry",
                title: "Keep your kitchen in sync",
                subtitle: "Manage ingredients and groceries here, then head to Recipes when you're ready to cook.",
                systemImage: "basket.fill",
                accent: .green
            )

            Text("Pantry & Grocery")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)
        }
    }

    private var pantryEmptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("No pantry spaces yet")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("Create your first pantry space, scan what you have, and ChefBuddy will stop guessing what’s actually in the kitchen.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineSpacing(3)

            Button(action: { showVirtualPantry = true }) {
                Label("Set Up Pantry", systemImage: "basket.fill")
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
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var pantryControlHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shopping From")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Set the pantry ChefBuddy should use for pantry checks and grocery planning.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                pantryPickerMenu
            }

            if let pantry = currentPantry {
                HStack(spacing: 8) {
                    Label("Using \(pantry.emoji) \(pantry.name)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                    Spacer()
                    Text("\(pantry.ingredients.count) items")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var pantryPickerMenu: some View {
        Menu {
            ForEach(availablePantries) { pantry in
                Button {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
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
            HStack(spacing: 8) {
                Text(currentPantry.map { "\($0.emoji) \($0.name)" } ?? "Select Pantry")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var pantrySection: some View {
        Group {
            if let pantry = currentPantry {
                activePantryCard(for: pantry)
            }
        }
    }

    private func activePantryCard(for pantry: SimplePantrySpace) -> some View {
        let previewIngredients = Array(pantry.ingredients.prefix(6))
        let remaining = max(0, pantry.ingredients.count - previewIngredients.count)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Pantry Overview")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("\(pantry.emoji) \(pantry.name)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))

                    Text("\(pantry.ingredients.count) ingredient\(pantry.ingredients.count == 1 ? "" : "s") ready to compare against your recipes.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Button(action: { showVirtualPantry = true }) {
                    Label("Open Pantry", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }

            if previewIngredients.isEmpty {
                Text("This pantry is still empty. Open Manage Pantry to scan shelves or add ingredients manually.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick pantry preview")
                        .font(.system(size: 14, weight: .bold, design: .rounded))

                    FlexibleTagWrap(items: previewIngredients) { ingredient in
                        Text(ingredient)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }

                    if remaining > 0 {
                        Text("and \(remaining) more")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.green.opacity(0.35), lineWidth: 1.5)
        )
        .shadow(color: Color.green.opacity(0.10), radius: 12, y: 6)
    }

    private var grocerySection: some View {
        Button(action: onOpenGrocery) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Grocery List")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                        Text("Open the list ChefBuddy builds from recipe gaps and pantry checks, then shop with the active pantry already in mind.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 10)

                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.orange.opacity(0.14))
                            .frame(width: 54, height: 54)

                        Image(systemName: "cart.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 10) {
                    pantryUtilityPill(
                        title: currentPantry.map { "\($0.emoji) \($0.name)" } ?? "No pantry",
                        systemImage: "basket.fill",
                        tint: .green
                    )
                    pantryUtilityPill(
                        title: "Missing-item aware",
                        systemImage: "checklist",
                        tint: .orange
                    )
                }

                HStack {
                    Text("Review what is missing, mark items off, and move faster when it is time to shop.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func pantryUtilityPill(title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func startListening() {
        guard let userId = authVM.userSession?.uid else { return }

        stopListening()

        pantryListener = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("pantrySpaces")
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else { return }

                let spaces = documents.compactMap { document -> SimplePantrySpace? in
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
                    availablePantries = spaces

                    let preferredPantryId = authVM.currentUserProfile?.activePantryId
                    if let selectedPantryId,
                       spaces.contains(where: { $0.id == selectedPantryId }) == false {
                        self.selectedPantryId = nil
                    }

                    if self.selectedPantryId == nil,
                       let preferredPantryId,
                       spaces.contains(where: { $0.id == preferredPantryId }) {
                        self.selectedPantryId = preferredPantryId
                    } else if self.selectedPantryId == nil {
                        self.selectedPantryId = spaces.first?.id
                    }
                }
            }
    }

    private func stopListening() {
        pantryListener?.remove()
        pantryListener = nil
    }
}

struct PlanTabRootView: View {
    @ObservedObject var assistant: CookingAssistant

    var body: some View {
        WeeklyMealPlanView(assistant: assistant)
    }
}

struct ProfileTabRootView: View {
    var body: some View {
        ProfileHubView()
    }
}

private struct FloatingShellTabBar: View {
    @Binding var selectedTab: AppTab

    private let items: [(AppTab, String, String)] = [
        (.plan, "calendar", "Plan"),
        (.pantry, "basket.fill", "Pantry"),
        (.home, "house.fill", "Home"),
        (.recipes, "book.closed.fill", "Recipes"),
        (.profile, "person.crop.circle", "Profile")
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let isSelected = selectedTab == item.0
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedTab = item.0
                    }
                } label: {
                    VStack(spacing: 3) {
                        ZStack {
                            if item.0 == .home && isSelected {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [.orange, .green.opacity(0.86)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 36, height: 36)
                            }

                            Image(systemName: item.1)
                                .font(.system(size: item.0 == .home ? 15 : 12, weight: .bold))
                                .foregroundStyle(
                                    item.0 == .home && isSelected
                                    ? Color.white
                                    : isSelected ? Color.orange : Color.secondary
                                )
                        }
                        .frame(height: 36)

                        Text(item.2)
                            .font(.system(size: 9, weight: isSelected ? .bold : .semibold, design: .rounded))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
}

private struct HomeAmbientIcons: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 10) {
            ambientPill(symbol: "sparkles", accent: .orange, delay: 0.0)
            ambientPill(symbol: "fork.knife", accent: .green, delay: 0.14)
            ambientPill(symbol: "flame.fill", accent: .pink, delay: 0.28)
        }
        .onAppear {
            animate = true
        }
    }

    private func ambientPill(symbol: String, accent: Color, delay: Double) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(accent.opacity(0.12), in: Capsule())
            .offset(y: animate ? -2 : 2)
            .animation(
                .easeInOut(duration: 1.8)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: animate
            )
    }
}

private struct HomeGreetingCard: View {
    let title: String
    let subtitle: String

    @State private var animateIcon = false
    @State private var animateContent = false
    @State private var homeIconIndex = 0
    @State private var iconTimer: Timer?

    private let rotatingIcons = ["house.fill", "fork.knife.circle.fill", "sparkles", "sun.max.fill"]

    private var activeIcon: String {
        rotatingIcons[homeIconIndex % rotatingIcons.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                HomeAmbientIcons()

                Spacer(minLength: 10)

                HStack(spacing: 8) {
                    Image("ChefBuddyLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)

                    Text("ChefBuddy")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }

            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.18), .green.opacity(0.12), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 62, height: 62)

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                        .frame(width: 52, height: 52)

                    Image(systemName: activeIcon)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.orange)
                        .offset(y: animateIcon ? -1 : 1)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: activeIcon)
                }
                .frame(width: 72, height: 72, alignment: .center)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Home")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text(title)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .lineSpacing(1)
                        .lineLimit(2)
                        .minimumScaleFactor(0.68)
                        .allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: animateContent ? 0 : 6)
                .opacity(animateContent ? 1 : 0.72)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                animateIcon = true
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.84).delay(0.05)) {
                animateContent = true
            }
            if iconTimer == nil {
                iconTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { _ in
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        homeIconIndex = (homeIconIndex + 1) % rotatingIcons.count
                    }
                }
            }
        }
        .onDisappear {
            iconTimer?.invalidate()
            iconTimer = nil
        }
    }
}

private struct TodayPlanRow: View {
    let slot: MealPlanSlot

    private var iconName: String {
        switch slot.mealType.lowercased() {
        case "breakfast":
            return "sunrise.fill"
        case "lunch":
            return "sun.max.fill"
        default:
            return "moon.stars.fill"
        }
    }

    private var accent: Color {
        switch slot.mealType.lowercased() {
        case "breakfast":
            return .orange
        case "lunch":
            return .green
        default:
            return .blue
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.14))
                    .frame(width: 38, height: 38)

                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(slot.mealType)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(slot.displayTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(2)
            }

            Spacer(minLength: 10)

            if let plannedRecipe = slot.plannedRecipe,
               !plannedRecipe.calories.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(plannedRecipe.calories)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(accent.opacity(0.10), in: Capsule())
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct HomeNavigationCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accent.opacity(0.14))
                            .frame(width: 44, height: 44)

                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(accent)
                    }

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 132, alignment: .topLeading)
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct HomeNavigationWideCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.14))
                        .frame(width: 44, height: 44)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PantrySecondaryActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct FlexibleTagWrap<Content: View>: View {
    let items: [String]
    let content: (String) -> Content

    var body: some View {
        let columns = [
            GridItem(.adaptive(minimum: 120), alignment: .leading)
        ]

        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                content(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
