//
//  RecipesView.swift
//  ChefBuddy
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import Combine

// MARK: - Model

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
    var createdAt: Date
    var isFavorite: Bool

    init(title: String, emoji: String = "🍽️", description: String, ingredients: [String],
         steps: [String], cookTime: String, servings: String, difficulty: String,
         tags: [String] = [], calories: String = "", createdAt: Date = Date(), isFavorite: Bool = false) {
        self.title = title; self.emoji = emoji; self.description = description
        self.ingredients = ingredients; self.steps = steps; self.cookTime = cookTime
        self.servings = servings; self.difficulty = difficulty; self.tags = tags
        self.calories = calories; self.createdAt = createdAt; self.isFavorite = isFavorite
    }
}

// MARK: - ViewModel

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

    let filters = ["All", "❤️ Saved", "⚡ Quick", "💪 Protein", "🥗 Healthy"]

    var filteredRecipes: [Recipe] {
        switch selectedFilter {
        case "❤️ Saved":   return recipes.filter { $0.isFavorite }
        case "⚡ Quick":   return recipes.filter { $0.cookTime.contains("15") || $0.cookTime.lowercased().contains("quick") }
        case "💪 Protein": return recipes.filter { $0.tags.contains(where: { $0.lowercased().contains("protein") }) }
        case "🥗 Healthy": return recipes.filter { $0.tags.contains(where: { $0.lowercased().contains("healthy") || $0.lowercased().contains("low cal") }) }
        default:           return recipes
        }
    }

    func startListening(userId: String) {
        listener = db.collection("users").document(userId)
            .collection("recipes")
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { [weak self] snap, _ in
                guard let docs = snap?.documents else { return }
                DispatchQueue.main.async {
                    self?.recipes = docs.compactMap { try? $0.data(as: Recipe.self) }
                }
            }
    }

    func stopListening() { listener?.remove() }

    func toggleFavorite(_ recipe: Recipe, userId: String) {
        guard let id = recipe.id else { return }
        db.collection("users").document(userId).collection("recipes").document(id)
            .updateData(["isFavorite": !recipe.isFavorite])
    }

    func deleteRecipe(_ recipe: Recipe, userId: String) {
        guard let id = recipe.id else { return }
        db.collection("users").document(userId).collection("recipes").document(id).delete()
    }

    func generateAndSave(prompt: String, assistant: CookingAssistant, userId: String) {
        isGenerating = true
        elapsedSeconds = 0
        errorMessage = nil
        justGeneratedRecipe = nil

        // Start elapsed timer — ticks every second
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self.elapsedSeconds += 1 }
            }
        }

        Task {
            do {
                // Wait for the AI model to finish loading before calling it
                try await assistant.waitUntilReady()

                let fullPrompt = """
                Generate a recipe based on: \(prompt)

                Respond ONLY in this exact format, no extra text:
                Title: [recipe name]
                Emoji: [single relevant emoji]
                Description: [one sentence about the dish]
                Cook Time: [e.g. 25 mins]
                Servings: [e.g. 2 people]
                Difficulty: [Easy / Medium / Hard]
                Calories: [e.g. 420 kcal]
                Tags: [comma-separated, e.g. High Protein, Healthy, Quick]

                Ingredients:
                - [ingredient 1]
                - [ingredient 2]

                Instructions:
                1. [step one]
                2. [step two]
                """

                // Call the AI
                let raw = try await assistant.getHelp(question: fullPrompt)

                // Parse into a Recipe model
                var recipe = RecipesViewModel.parseRecipe(from: raw)

                // Save to Firestore and capture the document ID
                let encoded = try Firestore.Encoder().encode(recipe)
                let ref = try await db.collection("users").document(userId)
                    .collection("recipes").addDocument(data: encoded)
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
        var title = "New Recipe"; var emoji = "🍽️"; var description = ""
        var ingredients: [String] = []; var steps: [String] = []
        var cookTime = "30 mins"; var servings = "2 people"
        var difficulty = "Medium"; var tags: [String] = []; var calories = ""
        var section = ""

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let low = line.lowercased()
            if      low.hasPrefix("title:")       { title       = after("Title:", in: line) }
            else if low.hasPrefix("emoji:")       { emoji       = after("Emoji:", in: line) }
            else if low.hasPrefix("description:") { description = after("Description:", in: line) }
            else if low.hasPrefix("cook time:")   { cookTime    = after("Cook Time:", in: line) }
            else if low.hasPrefix("servings:")    { servings    = after("Servings:", in: line) }
            else if low.hasPrefix("difficulty:")  { difficulty  = after("Difficulty:", in: line) }
            else if low.hasPrefix("calories:")    { calories    = after("Calories:", in: line) }
            else if low.hasPrefix("tags:")        { tags = after("Tags:", in: line).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            else if low.contains("ingredient")    { section = "ingredients" }
            else if low.contains("instruction") || low.contains("direction") { section = "steps" }
            else if line.hasPrefix("-") || line.hasPrefix("•") {
                let item = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { section == "steps" ? steps.append(item) : ingredients.append(item) }
            } else if let first = line.first, first.isNumber, line.count > 2 {
                let secondIdx = line.index(line.startIndex, offsetBy: 1)
                if line[secondIdx] == "." {
                    let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !item.isEmpty && section == "steps" { steps.append(item) }
                }
            }
        }
        if description.isEmpty { description = "A delicious recipe generated just for you by ChefBuddy." }
        return Recipe(title: title, emoji: emoji, description: description, ingredients: ingredients,
                      steps: steps, cookTime: cookTime, servings: servings, difficulty: difficulty,
                      tags: tags, calories: calories)
    }

    private static func after(_ prefix: String, in line: String) -> String {
        guard let r = line.range(of: prefix, options: .caseInsensitive) else { return line }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Main View

struct RecipesView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @ObservedObject var assistant: CookingAssistant
    @StateObject private var vm = RecipesViewModel()

    @State private var selectedRecipe: Recipe? = nil
    @State private var showGenerateSheet = false
    @State private var appeared = false
    @State private var showJustGenerated = false

    private var userId: String { authVM.userSession?.uid ?? "" }

    private func timeString(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Circle().fill(Color.orange.opacity(0.10)).blur(radius: 80).offset(x: -160, y: -320).ignoresSafeArea()
            Circle().fill(Color.green.opacity(0.08)).blur(radius: 80).offset(x: 160, y: 320).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Recipes")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                        Text("\(vm.recipes.count) recipe\(vm.recipes.count == 1 ? "" : "s") saved")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: { showGenerateSheet = true }) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .clipShape(Circle())
                            .shadow(color: .orange.opacity(0.35), radius: 8, y: 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : -10)

                // Filter Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Spacer().frame(width: 16)
                        ForEach(vm.filters, id: \.self) { f in
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { vm.selectedFilter = f }
                            }) {
                                Text(f)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(vm.selectedFilter == f ? .white : .primary)
                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                    .background(
                                        vm.selectedFilter == f
                                        ? AnyView(LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                                        : AnyView(Color(.systemGray6))
                                    )
                                    .clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                        Spacer().frame(width: 16)
                    }.padding(.vertical, 4)
                }
                .opacity(appeared ? 1 : 0)

                // Content
                if vm.filteredRecipes.isEmpty {
                    RecipesEmptyState(filter: vm.selectedFilter) { showGenerateSheet = true }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(vm.filteredRecipes) { recipe in
                                RecipeCard(
                                    recipe: recipe,
                                    onTap: { selectedRecipe = recipe },
                                    onFavorite: { vm.toggleFavorite(recipe, userId: userId) }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                    }
                }
            }

            // Error toast
            if let err = vm.errorMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
                        Text(err)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Spacer()
                        Button(action: { vm.errorMessage = nil }) {
                            Image(systemName: "xmark").foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .background(Color.red.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .red.opacity(0.3), radius: 10, y: 4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.4), value: vm.errorMessage)
            }

            // Generating toast with live timer
            if vm.isGenerating {
                VStack {
                    Spacer()
                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("ChefBuddy is cooking...")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                            Spacer()
                            Text(timeString(vm.elapsedSeconds))
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        // Progress bar that fills over ~20s (typical generation time)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.2)).frame(height: 4)
                                Capsule()
                                    .fill(.white)
                                    .frame(width: geo.size.width * min(Double(vm.elapsedSeconds) / 20.0, 0.95), height: 4)
                                    .animation(.linear(duration: 1), value: vm.elapsedSeconds)
                            }
                        }
                        .frame(height: 4)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .orange.opacity(0.4), radius: 12, y: 6)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.4), value: vm.isGenerating)
            }
        }
        .onAppear {
            vm.startListening(userId: userId)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05)) { appeared = true }
        }
        .onDisappear { vm.stopListening() }
        .onChange(of: vm.justGeneratedRecipe) { recipe in
            if recipe != nil {
                // small delay so Firestore listener has time to insert into grid first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    selectedRecipe = recipe
                    vm.justGeneratedRecipe = nil
                }
            }
        }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateRecipeSheet(vm: vm, assistant: assistant, userId: userId)
                .presentationDetents([.fraction(0.6)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedRecipe) { recipe in
            RecipeDetailView(
                recipe: recipe,
                onFavorite: { vm.toggleFavorite(recipe, userId: userId) },
                onDelete: { vm.deleteRecipe(recipe, userId: userId); selectedRecipe = nil }
            )
        }
    }
}

// MARK: - Recipe Card

private struct RecipeCard: View {
    let recipe: Recipe
    let onTap: () -> Void
    let onFavorite: () -> Void
    @State private var pressed = false

    var difficultyColor: Color {
        switch recipe.difficulty.lowercased() {
        case "easy": return .green
        case "hard": return .red
        default: return .orange
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: [Color.orange.opacity(0.12), Color.green.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    Text(recipe.emoji).font(.system(size: 52))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

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

                VStack(alignment: .leading, spacing: 6) {
                    Text(recipe.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text(recipe.cookTime).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(recipe.difficulty)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(difficultyColor)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(difficultyColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .foregroundStyle(.secondary)

                    if !recipe.calories.isEmpty {
                        Text(recipe.calories)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(12)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.05), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
            .scaleEffect(pressed ? 0.96 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.spring(response: 0.2)) { pressed = true } }
            .onEnded   { _ in withAnimation(.spring(response: 0.3)) { pressed = false } }
        )
    }
}

// MARK: - Generate Sheet

struct GenerateRecipeSheet: View {
    @ObservedObject var vm: RecipesViewModel
    let assistant: CookingAssistant
    let userId: String

    @State private var prompt = ""
    @State private var selectedQuick: String? = nil
    @FocusState private var focused: Bool
    @Environment(\.dismiss) var dismiss

    let quickPrompts = ["Something quick & healthy", "High protein dinner", "Use chicken & rice", "Vegetarian pasta", "30-min meal prep"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Generate a Recipe")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                    Text("Tell ChefBuddy what you're craving")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(LinearGradient(colors: [.orange, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickPrompts, id: \.self) { q in
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            prompt = q; selectedQuick = q
                        }) {
                            Text(q)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(selectedQuick == q ? .white : .primary)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(
                                    selectedQuick == q
                                    ? AnyView(LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                                    : AnyView(Color(.systemGray6))
                                )
                                .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }

            TextField("Or describe your own idea...", text: $prompt)
                .font(.system(size: 16, design: .rounded))
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .focused($focused)
                .onChange(of: prompt) { _ in selectedQuick = nil }

            Button(action: {
                guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                focused = false
                vm.generateAndSave(prompt: prompt, assistant: assistant, userId: userId)
                dismiss()
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                    Text("Generate Recipe").font(.system(size: 17, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(
                    prompt.trimmingCharacters(in: .whitespaces).isEmpty
                    ? AnyView(Color.gray.opacity(0.35))
                    : AnyView(LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
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

// MARK: - Detail View

struct RecipeDetailView: View {
    let recipe: Recipe
    let onFavorite: () -> Void
    let onDelete: () -> Void

    @State private var activeTab = 0
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) var dismiss

    var difficultyColor: Color {
        switch recipe.difficulty.lowercased() {
        case "easy": return .green
        case "hard": return .red
        default: return .orange
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // Hero
                ZStack(alignment: .top) {
                    LinearGradient(colors: [Color.orange.opacity(0.18), Color.green.opacity(0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 220)

                    Text(recipe.emoji).font(.system(size: 100))
                        .frame(maxWidth: .infinity).padding(.top, 60)

                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                                .background(Circle().fill(.ultraThinMaterial))
                        }
                        Spacer()
                        Button(action: { UIImpactFeedbackGenerator(style: .light).impactOccurred(); onFavorite() }) {
                            Image(systemName: recipe.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(recipe.isFavorite ? .red : .secondary)
                                .padding(10).background(Circle().fill(.ultraThinMaterial))
                        }
                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(10).background(Circle().fill(.ultraThinMaterial))
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 56)
                }

                // Title + Meta
                VStack(alignment: .leading, spacing: 12) {
                    Text(recipe.title).font(.system(size: 28, weight: .heavy, design: .rounded))

                    HStack(spacing: 10) {
                        StatBadge(icon: "clock",    label: recipe.cookTime, color: .orange)
                        StatBadge(icon: "person.2", label: recipe.servings, color: .blue)
                        StatBadge(icon: "flame",    label: recipe.calories.isEmpty ? "—" : recipe.calories, color: .red)
                        Spacer()
                        Text(recipe.difficulty)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(difficultyColor)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(difficultyColor.opacity(0.12)).clipShape(Capsule())
                    }

                    Text(recipe.description).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)

                    if !recipe.tags.filter({ !$0.isEmpty }).isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recipe.tags.filter { !$0.isEmpty }, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Color.green.opacity(0.12)).clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)

                // Tab selector
                HStack(spacing: 0) {
                    ForEach(["Ingredients", "Instructions"].indices, id: \.self) { i in
                        let label = ["Ingredients", "Instructions"][i]
                        Button(action: { withAnimation(.spring(response: 0.3)) { activeTab = i } }) {
                            VStack(spacing: 6) {
                                Text(label)
                                    .font(.system(size: 15, weight: activeTab == i ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(activeTab == i ? .primary : .secondary)
                                Rectangle().fill(activeTab == i ? Color.orange : Color.clear)
                                    .frame(height: 2).clipShape(Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity).buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 4)

                Divider().padding(.horizontal, 24)

                if activeTab == 0 {
                    IngredientsTab(ingredients: recipe.ingredients)
                } else {
                    InstructionsTab(steps: recipe.steps)
                }

                Spacer(minLength: 40)
            }
        }
        .ignoresSafeArea(edges: .top)
        .confirmationDialog("Delete this recipe?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct StatBadge: View {
    let icon: String; let label: String; let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.08)).clipShape(Capsule())
    }
}

private struct IngredientsTab: View {
    let ingredients: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(ingredients.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 14) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8).padding(.top, 6)
                    Text(item).font(.system(size: 15, design: .rounded)).lineSpacing(3)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 20)
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
                        .background(LinearGradient(colors: [.orange, .green.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(Circle())
                    Text(step).font(.system(size: 15, design: .rounded)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                }
                if index < steps.count - 1 {
                    Rectangle().fill(Color.primary.opacity(0.05)).frame(height: 1).padding(.leading, 42)
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 20)
    }
}

private struct RecipesEmptyState: View {
    let filter: String
    let onGenerate: () -> Void
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("🍳").font(.system(size: 80))
                .offset(y: bounce ? -10 : 0)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: bounce)
                .onAppear { bounce = true }
            Text(filter == "All" ? "No recipes yet.\nGenerate your first one!" : "No \"\(filter)\" recipes yet.")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if filter == "All" {
                Button(action: onGenerate) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Generate a Recipe").font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28).padding(.vertical, 16)
                    .background(LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                    .clipShape(Capsule())
                    .shadow(color: .orange.opacity(0.3), radius: 10, y: 4)
                }
            }
            Spacer()
        }.padding()
    }
}
