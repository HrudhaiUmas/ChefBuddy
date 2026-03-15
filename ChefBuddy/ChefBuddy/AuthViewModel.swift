// AuthViewModel.swift
// Manages everything related to who is logged in.
// Handles sign-up, sign-in (email and Google), sign-out, and keeping the user's
// Firestore profile in sync. Published properties drive the routing in ContentView
// so the app automatically shows the right screen when auth state changes.

import SwiftUI
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import GoogleSignIn
import Combine

// UIKit helper needed because GIDSignIn requires a UIViewController to present
// the OAuth web view. SwiftUI doesn't expose one directly, so we reach into
// the connected scene hierarchy to get the root view controller.
extension UIApplication {
    func getRootViewController() -> UIViewController {
        guard let screen = self.connectedScenes.first as? UIWindowScene else { return UIViewController() }
        guard let root = screen.windows.first?.rootViewController else { return UIViewController() }
        return root
    }
}

// Single source of truth for authentication state. All views that need to know
// who is logged in read from this object via @EnvironmentObject.
class AuthViewModel: ObservableObject {
    @Published var userSession: FirebaseAuth.User?
    @Published var currentUserProfile: DBUser?
    @Published var isFetchingProfile: Bool = true
    @Published var errorMessage: String = ""

    private let db = Firestore.firestore()

    init() {

        self.userSession = Auth.auth().currentUser
        if self.userSession != nil {
            fetchUserProfile()
        } else {
            self.isFetchingProfile = false
        }
    }


    // Writes a brand-new DBUser document to Firestore after the user completes
    // onboarding. Called once — subsequent edits use updateUserPreferences.
    func saveUserPreferences(level: String, diets: Set<String>, allergy: Set<String>, macros: Set<String>,
                             age: String, height: String, weight: String, sex: String, targetGoal: String, activity: String,
                             appliances: Set<String>, cookTime: String, mealPrep: Bool, cuisines: Set<String>,
                             spice: String, dislikes: String, servings: String, budget: String) {
        guard let user = userSession else { return }

        let newUser = DBUser(
            auth: user,
            level: level,
            diets: diets,
            allergy: allergy,
            macros: macros,
            age: age,
            height: height,
            weight: weight,
            sex: sex,
            targetGoal: targetGoal,
            activityLevel: activity,
            appliances: appliances,
            cookTime: cookTime,
            mealPrep: mealPrep,
            cuisines: cuisines,
            spiceTolerance: spice,
            dislikes: dislikes,
            servingSize: servings,
            budget: budget
        )

        do {
            try db.collection("users").document(user.uid).setData(from: newUser)
            self.currentUserProfile = newUser
            print("Successfully saved all user preferences to Firestore.")
        } catch {
            self.errorMessage = "Failed to save profile: \(error.localizedDescription)"
        }
    }

    // Reads the user's Firestore document and populates currentUserProfile.
    // Called on init and after sign-in so the app always has fresh preferences.
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

    // Merges updated preferences into the existing Firestore document.
    // Using merge: true means fields not included here are left untouched.
    func updateUserPreferences(level: String, diets: Set<String>, allergy: Set<String>, macros: Set<String>,
                               age: String, height: String, weight: String, sex: String, targetGoal: String, activity: String,
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
            "sex": sex,
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


    // Creates a new Firebase Auth account then immediately fetches the profile
    // so ContentView can route to the preferences setup screen.
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

    // Signs in with email/password and fetches the profile to restore app state.
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


    // Triggers the Google OAuth flow. On success, exchanges the Google credential
    // for a Firebase credential so Auth and Firestore stay in sync.
    func signInWithGoogle() {

        guard let clientID = FirebaseApp.app()?.options.clientID else { return }


        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config


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


    // Clears both Firebase and Google sessions and wipes local state so the
    // next view render routes back to onboarding immediately.
    func signOut() {
        try? Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
        self.userSession = nil
        self.currentUserProfile = nil
    }
}
