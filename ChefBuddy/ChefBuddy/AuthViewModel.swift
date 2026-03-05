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
    @Published var currentUserProfile: DBUser?
    @Published var isFetchingProfile: Bool = true
    @Published var errorMessage: String = ""
    
    private let db = Firestore.firestore()
    
    init() {
        // Check if a user is already logged in when the app starts
        self.userSession = Auth.auth().currentUser
        if self.userSession != nil {
            fetchUserProfile()
        } else {
            self.isFetchingProfile = false
        }
    }
    
    // MARK: - Firestore Sync
    
    func saveUserPreferences(level: String, diets: Set<String>, allergy: Set<String>, macros: Set<String>,
                             age: String, height: String, weight: String, targetGoal: String, activity: String,
                             appliances: Set<String>, cookTime: String, mealPrep: Bool, cuisines: Set<String>,
                             spice: String, dislikes: String, servings: String, budget: String) {
        guard let user = userSession else { return }
        
        let newUser = DBUser(
            auth: user, level: level, diets: diets, allergy: allergy, macros: macros,
            age: age, height: height, weight: weight, targetGoal: targetGoal, activityLevel: activity,
            appliances: appliances, cookTime: cookTime, mealPrep: mealPrep, cuisines: cuisines,
            spiceTolerance: spice, dislikes: dislikes, servingSize: servings, budget: budget
        )
        
        do {
            try db.collection("users").document(user.uid).setData(from: newUser)
            self.currentUserProfile = newUser
            print("Successfully saved all user preferences to Firestore.")
        } catch {
            self.errorMessage = "Failed to save profile: \(error.localizedDescription)"
        }
    }
    
    func fetchUserProfile() {
        guard let uid = userSession?.uid else {
            self.isFetchingProfile = false
            return
        }
        
        self.isFetchingProfile = true
        db.collection("users").document(uid).getDocument { [weak self] snapshot, error in
            DispatchQueue.main.async {
                self?.isFetchingProfile = false
                if let document = snapshot, document.exists {
                    do {
                        self?.currentUserProfile = try document.data(as: DBUser.self)
                    } catch {
                        print("Error decoding user profile: \(error)")
                        self?.currentUserProfile = nil
                    }
                } else {
                    self?.currentUserProfile = nil
                }
            }
        }
    }
    
    func updateUserPreferences(level: String, diets: Set<String>, allergy: Set<String>, macros: Set<String>,
                               age: String, height: String, weight: String, targetGoal: String, activity: String,
                               appliances: Set<String>, cookTime: String, mealPrep: Bool, cuisines: Set<String>,
                               spice: String, dislikes: String, servings: String, budget: String) {
        guard let uid = userSession?.uid else { return }
        
        let updatedData: [String: Any] = [
            "chefLevel": level,
            "dietTags": Array(diets),
            "allergies": Array(allergy),
            "macroTags": Array(macros),
            "age": age,
            "height": height,
            "weight": weight,
            "targetGoal": targetGoal,
            "activityLevel": activity,
            "appliances": Array(appliances),
            "cookTime": cookTime,
            "mealPrep": mealPrep,
            "cuisines": Array(cuisines),
            "spiceTolerance": spice,
            "dislikes": dislikes,
            "servingSize": servings,
            "budget": budget
        ]
        
        db.collection("users").document(uid).setData(updatedData, merge: true) { [weak self] error in
            if let error = error {
                self?.errorMessage = "Failed to update preferences: \(error.localizedDescription)"
            } else {
                self?.fetchUserProfile()
                print("Successfully updated extensive preferences.")
            }
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
            self?.fetchUserProfile()
        }
    }
    
    func signIn(email: String, pass: String) {
        Auth.auth().signIn(withEmail: email, password: pass) { [weak self] result, error in
            if let error = error {
                self?.errorMessage = error.localizedDescription
                return
            }
            self?.userSession = result?.user
            self?.fetchUserProfile()
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
            
            guard let user = result?.user, let idToken = user.idToken?.tokenString else { return }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: user.accessToken.tokenString)
            
            Auth.auth().signIn(with: credential) { authResult, authError in
                if let error = authError {
                    self?.errorMessage = error.localizedDescription
                    return
                }
                self?.userSession = authResult?.user
                self?.fetchUserProfile()
            }
        }
    }
    
    // MARK: - Sign Out
    
    func signOut() {
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
        self.userSession = nil
        self.currentUserProfile = nil
    }
}
