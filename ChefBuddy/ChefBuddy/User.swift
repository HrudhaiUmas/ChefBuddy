// User.swift
// Defines DBUser — the Firestore document model for a user's full profile.
// Stores authentication identifiers, physical metrics, dietary preferences,
// kitchen setup, and scheduling preferences.
// Used by AuthViewModel to read/write user data and by CookingAssistant
// to personalise every AI prompt with the user's actual preferences.

import Foundation
import FirebaseFirestore
import FirebaseAuth

// Firestore document model for a user's full profile.
// Every field maps 1-to-1 to a Firestore key — Codable handles encoding
// automatically so we never write manual dictionary packing.
struct DBUser: Codable {
    let id: String
    let email: String?
    var dateCreated: Date


    var chefLevel: String
    var dietTags: [String]
    var allergies: [String]
    var macroTags: [String]


    var age: String
    var height: String
    var weight: String
    var sex: String
    var targetGoal: String
    var activityLevel: String


    var appliances: [String]


    var cookTime: String
    var mealPrep: Bool


    var cuisines: [String]
    var spiceTolerance: String
    var dislikes: String


    var servingSize: String
    var budget: String

    // Converts Firebase Auth user + onboarding form values into a storable
    // struct. Sets are converted to arrays because Firestore doesn't support Swift Sets.
    init(
        auth: FirebaseAuth.User,
        level: String,
        diets: Set<String>,
        allergy: Set<String>,
        macros: Set<String>,
        age: String,
        height: String,
        weight: String,
        sex: String,
        targetGoal: String,
        activityLevel: String,
        appliances: Set<String>,
        cookTime: String,
        mealPrep: Bool,
        cuisines: Set<String>,
        spiceTolerance: String,
        dislikes: String,
        servingSize: String,
        budget: String
    ) {
        self.id = auth.uid
        self.email = auth.email
        self.dateCreated = Date()

        self.chefLevel = level
        self.dietTags = Array(diets)
        self.allergies = Array(allergy)
        self.macroTags = Array(macros)

        self.age = age
        self.height = height
        self.weight = weight
        self.sex = sex
        self.targetGoal = targetGoal
        self.activityLevel = activityLevel

        self.appliances = Array(appliances)

        self.cookTime = cookTime
        self.mealPrep = mealPrep

        self.cuisines = Array(cuisines)
        self.spiceTolerance = spiceTolerance
        self.dislikes = dislikes

        self.servingSize = servingSize
        self.budget = budget
    }
}
