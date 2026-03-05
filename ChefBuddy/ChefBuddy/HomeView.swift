//
//  HomeView.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/5/26.
//

import SwiftUI
import FirebaseAuth

struct HomeView: View {
    @EnvironmentObject var authVM: AuthViewModel
    
    @State private var showDropdown = false
    @State private var showSettings = false
    @State private var appearAnimation = false

    // Safely pull the user's name from Google or email
    var displayName: String {
        if let name = authVM.userSession?.displayName, !name.isEmpty {
            // "Hrudhai Umas" -> "Hrudhai"
            return String(name.split(separator: " ").first ?? "")
        } else if let email = authVM.userSession?.email {
            // "hrudhaiumas20@gmail.com" -> "hrudhaiumas20"
            return String(email.split(separator: "@").first ?? "Chef")
        }
        return "Chef"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                // Background
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    Circle().fill(Color.orange.opacity(0.12)).blur(radius: 70).offset(x: -120, y: -250)
                    Circle().fill(Color.green.opacity(0.1)).blur(radius: 70).offset(x: 120, y: 250)
                }
                
                // Main Content
                VStack(alignment: .leading, spacing: 20) {
                    
                    // Welcome Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hello, \(displayName)!")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .offset(y: appearAnimation ? 0 : 15)
                            .opacity(appearAnimation ? 1.0 : 0)
                        
                        Text("What are we cooking today?")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .offset(y: appearAnimation ? 0 : 15)
                            .opacity(appearAnimation ? 1.0 : 0)
                    }
                    .padding(.top, 80)
                    .padding(.horizontal, 24)
                    
                    Spacer()
                    
                    VStack {
                        Image("ChefBuddyLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .scaleEffect(appearAnimation ? 1.0 : 0.8)
                            .opacity(appearAnimation ? 1.0 : 0)
                        
                        Text("AI Recipe Cards Placeholder")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // MARK: - Animated Top Bar
                HStack {
                    Spacer()
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            showDropdown.toggle()
                        }
                    }) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(LinearGradient(colors: [.orange, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .background(Circle().fill(.ultraThinMaterial).shadow(color: .black.opacity(0.1), radius: 5, y: 2))
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }
                
                // MARK: - Glassmorphic Dropdown Menu i found on google
                if showDropdown {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { showDropdown = false }
                        }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        MenuRow(icon: "slider.horizontal.3", title: "Profile / Preferences") {
                            showDropdown = false
                            showSettings = true
                        }
                        
                        Divider().padding(.horizontal, 16)
                        
                        MenuRow(icon: "arrow.right.square.fill", title: "Log Out", color: .red) {
                            showDropdown = false
                            authVM.signOut()
                        }
                    }
                    .padding(.vertical, 16).background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 15, y: 10)
                    .frame(width: 220).padding(.trailing, 24).padding(.top, 70)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity),
                        removal: .scale(scale: 0.8, anchor: .topTrailing).combined(with: .opacity)
                    ))
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                ProfileSettingsView()
            }
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) { appearAnimation = true }
            }
        }
    }
}

private struct MenuRow: View {
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
            .foregroundStyle(color).padding(.horizontal, 20).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
