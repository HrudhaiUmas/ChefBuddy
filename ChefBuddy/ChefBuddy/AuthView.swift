//
//  AuthView.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/4/26.
//

import SwiftUI

struct AuthView: View {
    @StateObject private var authVM = AuthViewModel()

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    @State private var isSignUp = true
    @State private var showPassword = false

    // Animation States
    @State private var appearAnimation = false
    @State private var backgroundRotation: Double = 0.0

    let onAuthSuccess: () -> Void

    // MARK: - Validation Logic

    func isValidEmail(_ email: String) -> Bool {
        let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPred = NSPredicate(format:"SELF MATCHES %@", emailRegEx)
        return emailPred.evaluate(with: email)
    }

    func isValidPassword(_ pass: String) -> Bool {
        let passwordRegex = "^(?=.*[0-9])(?=.*[!@#$%^&*()_+\\-=\\[\\]{};':\"\\\\|,.<>\\/?]).{6,}$"
        return NSPredicate(format: "SELF MATCHES %@", passwordRegex).evaluate(with: pass)
    }

    var isFormValid: Bool {
        if !isValidEmail(email) { return false }
        if !isValidPassword(password) { return false }
        if isSignUp && password != confirmPassword { return false }
        return true
    }

    var body: some View {
        ZStack {
            // MARK: - Animated Ambient Background
            Color(.systemBackground).ignoresSafeArea()

            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 300, height: 300)
                    .blur(radius: 60)
                    .offset(x: -100, y: -150)

                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 300, height: 300)
                    .blur(radius: 60)
                    .offset(x: 100, y: 150)
            }
            .rotationEffect(.degrees(backgroundRotation))
            .onAppear {
                withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                    backgroundRotation = 360
                }
            }

            // MARK: - Form Content
            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {

                    // Header
                    VStack(spacing: 8) {
                        Text(isSignUp ? "Join ChefBuddy" : "Welcome Back")
                            .font(.system(size: 32, weight: .bold, design: .rounded))

                        Text(isSignUp ? "Create an account to save your recipes." : "Log in to pick up where you left off.")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)
                    .offset(y: appearAnimation ? 0 : 20)
                    .opacity(appearAnimation ? 1 : 0)

                    // Input Fields
                    VStack(spacing: 16) {
                        // Email Field
                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(email.isEmpty ? .secondary : (isValidEmail(email) ? .green : .orange))
                                .frame(width: 24)
                            TextField("Email Address", text: $email)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .autocorrectionDisabled()
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isValidEmail(email) || email.isEmpty ? Color.clear : Color.orange.opacity(0.5), lineWidth: 1)
                        )

                        // Password Section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.secondary)
                                    .frame(width: 24)

                                if showPassword {
                                    TextField("Password", text: $password)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                } else {
                                    SecureField("Password", text: $password)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }

                                Button(action: { showPassword.toggle() }) {
                                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                        .foregroundColor(.secondary)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.05), lineWidth: 1))

                            if isSignUp && !password.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    RequirementRow(isMet: password.count >= 6, text: "At least 6 characters")
                                    RequirementRow(isMet: password.rangeOfCharacter(from: .decimalDigits) != nil, text: "At least 1 number")
                                    RequirementRow(isMet: password.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*()_+-=[]{};':\"|,.<>/?")) != nil, text: "At least 1 symbol")
                                }
                                .padding(.leading, 8)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }

                        // Confirm Password
                        if isSignUp {
                            VStack(spacing: 8) {
                                HStack {
                                    Image(systemName: "lock.fill")
                                        .foregroundColor(.secondary)
                                        .frame(width: 24)

                                    if showPassword {
                                        TextField("Confirm Password", text: $confirmPassword)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                    } else {
                                        SecureField("Confirm Password", text: $confirmPassword)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                    }

                                    Button(action: { showPassword.toggle() }) {
                                        Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding()
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.05), lineWidth: 1))

                                if !confirmPassword.isEmpty && password != confirmPassword {
                                    Text("Passwords do not match.")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                }
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .offset(y: appearAnimation ? 0 : 20)
                    .opacity(appearAnimation ? 1 : 0)

                    // Error Message
                    if !authVM.errorMessage.isEmpty {
                        Text(authVM.errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Main Auth Button
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        if isSignUp {
                            authVM.signUp(email: email, pass: password)
                        } else {
                            authVM.signIn(email: email, pass: password)
                        }
                    }) {
                        Text(isSignUp ? "Create Account" : "Log In")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(isFormValid ? Color.orange : Color.orange.opacity(0.5))
                            .clipShape(Capsule())
                            .shadow(color: Color.orange.opacity(isFormValid ? 0.3 : 0.0), radius: 10, y: 5)
                    }
                    .disabled(!isFormValid)
                    .offset(y: appearAnimation ? 0 : 20)
                    .opacity(appearAnimation ? 1 : 0)

                    // Toggle Login/Signup
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            isSignUp.toggle()
                            authVM.errorMessage = ""
                            confirmPassword = ""
                        }
                    }) {
                        Text(isSignUp ? "Already have an account? Log in" : "Need an account? Sign up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.secondary)
                    }

                    // Divider
                    HStack {
                        VStack { Divider() }
                        Text("OR").font(.caption.bold()).foregroundStyle(.tertiary)
                        VStack { Divider() }
                    }
                    .padding(.vertical, 8)

                    // MARK: - Google Button (custom made this cause the Google one they provide is old)
                    ModernGoogleButton {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        authVM.signInWithGoogle()
                    }
                    .frame(height: 56)
                    .offset(y: appearAnimation ? 0 : 20)
                    .opacity(appearAnimation ? 1 : 0)

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                appearAnimation = true
            }
        }
        .onChange(of: authVM.userSession) { _, newValue in
            if newValue != nil {
                onAuthSuccess()
            }
        }
    }
}

private struct RequirementRow: View {
    let isMet: Bool
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isMet ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isMet ? .green : .secondary.opacity(0.5))
                .font(.system(size: 14))

            Text(text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(isMet ? .primary : .secondary)
        }
    }
}

// MARK: - Modern Google Button

private struct ModernGoogleButton: View {
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 1))

                    Text("G")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.26, green: 0.52, blue: 0.96),
                                    Color(red: 0.91, green: 0.26, blue: 0.20),
                                    Color(red: 0.98, green: 0.74, blue: 0.18),
                                    Color(red: 0.20, green: 0.66, blue: 0.33)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .frame(width: 34, height: 34)

                Text("Continue with Google")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 12, y: 6)
            .scaleEffect(isPressed ? 0.98 : 1.0)
        }
        .buttonStyle(.plain)
        .pressableScale($isPressed)
        .accessibilityLabel("Continue with Google")
    }
}

// MARK: - Tiny press helper

private extension View {
    func pressableScale(_ isPressed: Binding<Bool>) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed.wrappedValue {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isPressed.wrappedValue = true
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isPressed.wrappedValue = false
                    }
                }
        )
    }
}
