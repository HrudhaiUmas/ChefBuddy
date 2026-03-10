//
//  HomeView.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/5/26.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct HomeView: View {
    @EnvironmentObject var authVM: AuthViewModel
    // AI Integration: Manages the backend/API logic
    @StateObject private var assistant = CookingAssistant()

    @State private var showDropdown = false
    @State private var showSettings = false
    @State private var appearAnimation = false
    @State private var showRecipePicker = false
    @State private var selectedLiveRecipe: Recipe? = nil
    @State private var showLiveCooking = false
    @State private var savedRecipes: [Recipe] = []

    var displayName: String {
        if let name = authVM.userSession?.displayName, !name.isEmpty {
            return String(name.split(separator: " ").first ?? "")
        } else if let email = authVM.userSession?.email {
            return String(email.split(separator: "@").first ?? "Chef")
        }
        return "Chef"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                // background
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    Circle().fill(Color.orange.opacity(0.12)).blur(radius: 70).offset(x: -120, y: -250)
                    Circle().fill(Color.green.opacity(0.1)).blur(radius: 70).offset(x: 120, y: 250)
                }

                // content layout -->
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {

                        // welcome to homepage
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hello, \(displayName)!")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("What are we cooking today?")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 60)
                        .padding(.horizontal, 24)
                        .offset(y: appearAnimation ? 0 : 15)
                        .opacity(appearAnimation ? 1.0 : 0)

                        // fridge scanning feature
                        VStack(spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Empty Fridge?")
                                        .font(.headline)
                                    Text("Scan or type ingredients to start.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "camera.viewfinder")
                                    .font(.title)
                                    .foregroundStyle(.orange)
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.05), lineWidth: 1))
                            .onTapGesture {
                                // ingredient inputs
                            }
                        }
                        .padding(.horizontal, 24)
                        .offset(y: appearAnimation ? 0 : 15)
                        .opacity(appearAnimation ? 1.0 : 0)

                        // Live cooking help card
                        Button(action: { showRecipePicker = true }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Live Cooking Help")
                                        .font(.headline)
                                    Text("Pick a recipe — AI guides you step by step.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "video.fill")
                                    .font(.title)
                                    .foregroundStyle(.green)
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.05), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .offset(y: appearAnimation ? 0 : 15)
                        .opacity(appearAnimation ? 1.0 : 0)

                        // ai integrated recipes view
                        VStack(alignment: .leading, spacing: 16) {
                            RecipesView(assistant: assistant)
                                .environmentObject(authVM)
                        }
                        .offset(y: appearAnimation ? 0 : 20)
                        .opacity(appearAnimation ? 1.0 : 0)

                        // kitchen tools shortcuts
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Your Kitchen Tools")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .padding(.horizontal, 24)

                            HStack(spacing: 12) {
                                ToolButton(icon: "calendar", title: "Meal Plan", color: .green)
                                ToolButton(icon: "cart.fill", title: "Grocery List", color: .orange)
                            }
                            .padding(.horizontal, 24)
                        }
                        .offset(y: appearAnimation ? 0 : 25)
                        .opacity(appearAnimation ? 1.0 : 0)

                        Spacer(minLength: 100)
                    }
                }

                // profile button
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        showDropdown.toggle()
                    }
                }) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(LinearGradient(colors: [.orange, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .padding(4)
                        .background(Circle().fill(.ultraThinMaterial))
                        .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                // dropdown
                if showDropdown {
                    DropdownOverlay(
                        showDropdown: $showDropdown,
                        showSettings: $showSettings,
                        showRecipePicker: $showRecipePicker,
                        authVM: authVM
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                        removal:   .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity)
                    ))
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                ProfileSettingsView().environmentObject(authVM)
            }
            .sheet(isPresented: $showRecipePicker) {
                RecipePickerSheet(recipes: savedRecipes) { recipe in
                    selectedLiveRecipe = recipe
                    showLiveCooking = true
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showLiveCooking) {
                if let recipe = selectedLiveRecipe,
                   let uid = authVM.userSession?.uid {
                    LiveCookingView(recipe: recipe, assistant: assistant)
                }
            }
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) { appearAnimation = true }
                // AI Initialization
                if let uid = authVM.userSession?.uid {
                    Task { await assistant.setupAssistant(userId: uid) }
                    // Keep savedRecipes in sync for the RecipePicker
                    Firestore.firestore().collection("users").document(uid)
                        .collection("recipes").order(by: "createdAt", descending: true)
                        .addSnapshotListener { snap, _ in
                            guard let docs = snap?.documents else { return }
                            savedRecipes = docs.compactMap { try? $0.data(as: Recipe.self) }
                        }
                }
            }
        }
    }
}

// MARK: - Subviews

struct ToolButton: View {
    let icon: String
    let title: String
    let color: Color
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }
}

struct DropdownOverlay: View {
    @Binding var showDropdown: Bool
    @Binding var showSettings: Bool
    @Binding var showRecipePicker: Bool
    let authVM: AuthViewModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { showDropdown = false }
                }

            VStack(alignment: .leading, spacing: 12) {
                MenuRow(icon: "video.fill", title: "Live Help", color: .orange) {
                    showDropdown = false
                    showRecipePicker = true
                }
                Divider().padding(.horizontal, 16)
                MenuRow(icon: "slider.horizontal.3", title: "Profile") {
                    showDropdown = false
                    showSettings = true
                }
                Divider().padding(.horizontal, 16)
                MenuRow(icon: "arrow.right.square", title: "Log Out", color: .red) {
                    showDropdown = false
                    authVM.signOut()
                }
            }
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 15, y: 10)
            .frame(width: 200)
            .padding(.trailing, 24)
            .padding(.top, 60)
        }
    }
}

struct MenuRow: View {
    let icon: String
    let title: String
    var color: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(width: 24)
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(color)
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
