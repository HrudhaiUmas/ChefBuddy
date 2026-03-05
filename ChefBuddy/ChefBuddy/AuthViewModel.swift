//
//  AuthViewModel.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/4/26.
//

import SwiftUI
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import GoogleSignIn
import Combine

// A helper to let Google Sign-In present its web overlay over our SwiftUI view - firebase documentation
extension UIApplication {
    func getRootViewController() -> UIViewController {
        guard let screen = self.connectedScenes.first as? UIWindowScene else { return UIViewController() }
        guard let root = screen.windows.first?.rootViewController else { return UIViewController() }
        return root
    }
}

class AuthViewModel: ObservableObject {
    @Published var userSession: FirebaseAuth.User?
    @Published var errorMessage: String = ""
    
    private let db = Firestore.firestore()
    
    init() {
        // Check if a user is already logged in when the app starts
        self.userSession = Auth.auth().currentUser
    }
    
    // MARK: - Firestore Sync
    
    func saveUserPreferences(level: String, diets: Set<String>, allergy: Set<String>, macros: Set<String>) {
        guard let user = userSession else { return }
        
        let newUser = DBUser(auth: user, level: level, diets: diets, allergy: allergy, macros: macros)
        
        do {
            try db.collection("users").document(user.uid).setData(from: newUser)
            print("Successfully saved user preferences to Firestore.")
        } catch {
            self.errorMessage = "Failed to save profile: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Email / Password Auth
    
    func signUp(email: String, pass: String) {
        Auth.auth().createUser(withEmail: email, password: pass) { [weak self] result, error in
            if let error = error {
                self?.errorMessage = error.localizedDescription
                return
            }
            self?.userSession = result?.user
        }
    }
    
    func signIn(email: String, pass: String) {
        Auth.auth().signIn(withEmail: email, password: pass) { [weak self] result, error in
            if let error = error {
                self?.errorMessage = error.localizedDescription
                return
            }
            self?.userSession = result?.user
        }
    }
    
    // MARK: - Google Sign-In Auth
    
    func signInWithGoogle() {
        // Get the Client ID from your GoogleService-Info.plist
        guard let clientID = FirebaseApp.app()?.options.clientID else { return }
        
        // Create the Google configuration
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config
        
        // Start the sign in flow
        GIDSignIn.sharedInstance.signIn(withPresenting: UIApplication.shared.getRootViewController()) { [weak self] result, error in
            if let error = error {
                self?.errorMessage = error.localizedDescription
                return
            }
            
            guard let user = result?.user,
                  let idToken = user.idToken?.tokenString else {
                self?.errorMessage = "Failed to fetch Google tokens"
                return
            }
            
            // Exchange Google tokens for Firebase credentials
            let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                           accessToken: user.accessToken.tokenString)
            
            // Sign in to Firebase with the Google credential
            Auth.auth().signIn(with: credential) { authResult, authError in
                if let error = authError {
                    self?.errorMessage = error.localizedDescription
                    return
                }
                self?.userSession = authResult?.user
            }
        }
    }
    
    // MARK: - Sign Out
    
    func signOut() {
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
        self.userSession = nil
    }
}
