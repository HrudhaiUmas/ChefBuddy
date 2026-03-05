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
    var chefLevel: String
    var dietTags: [String]
    var allergies: [String]
    var macroTags: [String]
    var dateCreated: Date
    
    // Converting the Sets we have to Arrays for Firestore storage
    init(auth: FirebaseAuth.User, level: String, diets: Set<String>, allergy: Set<String>, macros: Set<String>) {
        self.id = auth.uid
        self.email = auth.email
        self.chefLevel = level
        self.dietTags = Array(diets)
        self.allergies = Array(allergy)
        self.macroTags = Array(macros)
        self.dateCreated = Date()
    }
}
