//
//  User.swift
//  ChefBuddy
//
//  Created by Hrudhai Umas on 3/5/26.
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

struct DBUser: Codable {
    let id: String
    let email: String?
    var dateCreated: Date
    
    // Core Preferences
    var chefLevel: String
    var dietTags: [String]
    var allergies: [String]
    var macroTags: [String]
    
    // Physical Metrics
    var age: String
    var height: String
    var weight: String
    var targetGoal: String
    var activityLevel: String
    
    // Kitchen Hardware
    var appliances: [String]
    
    // Time & Schedule
    var cookTime: String
    var mealPrep: Bool
    
    // Flavor Profiles
    var cuisines: [String]
    var spiceTolerance: String
    var dislikes: String
    
    // Household & Budget
    var servingSize: String
    var budget: String
    
    init(auth: FirebaseAuth.User, level: String, diets: Set<String>, allergy: Set<String>, macros: Set<String>,
         age: String, height: String, weight: String, targetGoal: String, activityLevel: String,
         appliances: Set<String>, cookTime: String, mealPrep: Bool, cuisines: Set<String>,
         spiceTolerance: String, dislikes: String, servingSize: String, budget: String) {
        
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
