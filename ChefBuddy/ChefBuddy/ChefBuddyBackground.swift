//
//  ChefBuddyBackground.swift
//  ChefBuddy
//
//  Created by Arkita Jain on 3/10/26.
//

import SwiftUI

struct ChefBuddyBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            Circle()
                .fill(Color.orange.opacity(0.10))
                .blur(radius: 80)
                .offset(x: -160, y: -320)
                .ignoresSafeArea()

            Circle()
                .fill(Color.green.opacity(0.08))
                .blur(radius: 80)
                .offset(x: 160, y: 320)
                .ignoresSafeArea()
        }
    }
}
