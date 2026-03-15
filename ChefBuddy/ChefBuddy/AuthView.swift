// AuthView.swift
// The login and sign-up screen. Handles both email/password auth and Google Sign-In.
// Validates input locally before calling AuthViewModel so the user gets instant
// feedback (password strength, email format, password match) without a network round trip.
// Calls onAuthSuccess() when Firebase confirms sign-in so the parent (OnboardingFlowView
// or ContentView) can decide where to navigate next without this view knowing about routing.

import SwiftUI

// Root view for authentication. Toggles between sign-up and log-in modes
// in place so the form fields animate smoothly without a sheet transition.
struct AuthView: View {
    @EnvironmentObject var authVM: AuthViewModel

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    @State private var isSignUp = true
    @State private var showPassword = false


    @State private var appearAnimation = false
    @State private var backgroundRotation: Double = 0.0

    let onAuthSuccess: () -> Void


    // Regex check run on every keystroke so the email field icon gives
    // real-time green/orange feedback without waiting for a submit tap.
    func isValidEmail(_ email: String) -> Bool {
        let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPred = NSPredicate(format:"SELF MATCHES %@", emailRegEx)
        return emailPred.evaluate(with: email)
    }

    // Enforces minimum 6 chars, at least one digit, and at least one symbol.
    // These requirements are shown live in RequirementRow so the user knows
    // exactly what to fix before the submit button enables.
    func isValidPassword(_ pass: String) -> Bool {
        let passwordRegex = "^(?=.*[0-9])(?=.*[!@#$%^&*()_+\\-=\\[\\]{};':\"\\\\|,.<>\\/?]).{6,}$"
        return NSPredicate(format: "SELF MATCHES %@", passwordRegex).evaluate(with: pass)
    }

    // Gates the submit button. Computed so it re-evaluates on every state
    // change — no manual calls needed to enable/disable the button.
    var isFormValid: Bool {
        if !isValidEmail(email) { return false }
        if !isValidPassword(password) { return false }
        if isSignUp && password != confirmPassword { return false }
        return true
    }

    var body: some View {
        ZStack {

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


            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {


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


                    VStack(spacing: 16) {

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


                    if !authVM.errorMessage.isEmpty {
                        Text(authVM.errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }


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


                    HStack {
                        VStack { Divider() }
                        Text("OR").font(.caption.bold()).foregroundStyle(.tertiary)
                        VStack { Divider() }
                    }
                    .padding(.vertical, 8)


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
        // Watches for Firebase to confirm a successful sign-in and calls
        // onAuthSuccess() so the parent can handle routing. Doing it here means
        // AuthView never needs to import or know about navigation state.
        .onChange(of: authVM.userSession) { _, newValue in
            if newValue != nil {
                onAuthSuccess()
            }
        }
    }
}

// A single password requirement indicator — checkmark when met, empty
// circle when not. Shown below the password field only during sign-up
// so sign-in mode stays clean and uncluttered.
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


// Custom Google Sign-In button built from scratch because the official
// Google Sign-In SDK button hasn't been updated for SwiftUI and looks dated.
// Uses a multicolour gradient "G" to match Google's brand without importing
// any Google UI assets.
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


// Adds a subtle scale-down press animation to any view.
// Applied to the Google button so it feels physically responsive,
// matching the haptic feedback that fires on tap.
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
