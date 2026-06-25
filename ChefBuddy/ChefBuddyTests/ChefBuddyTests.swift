//
//  ChefBuddyTests.swift
//  ChefBuddyTests
//
//  Created by Hrudhai Umas on 3/3/26.
//

import Testing
import Foundation
@testable import ChefBuddy

struct ChefBuddyTests {

    @Test func retailerSearchURLsUseOfficialDomainsAndEncodeQueries() throws {
        let product = GroceryStoreProduct(
            name: "Organic Firm Tofu",
            brand: "Store Brand",
            size: "14 oz",
            price: "$3.49",
            section: "Produce",
            note: ""
        )

        let expectedHosts: [GroceryStore: String] = [
            .safeway: "www.safeway.com",
            .walmart: "www.walmart.com",
            .costco: "www.costco.com",
            .traderJoes: "www.traderjoes.com",
            .amazon: "www.amazon.com"
        ]

        for store in GroceryStore.allCases {
            let url = try #require(store.searchURL(for: product))
            #expect(url.host == expectedHosts[store])
            #expect(url.absoluteString.contains("Store"))
            #expect(url.absoluteString.contains("Tofu"))
            #expect(url.absoluteString.contains(" ") == false)
        }
    }

    @Test func currentWeekStartsOnMondayAndCrossesMonthBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12)))
        let week = mealPlanWeekDates(containing: date, calendar: calendar)

        #expect(week.count == 7)
        #expect(week.first?.day == "Monday")
        #expect(calendar.component(.month, from: try #require(week.first?.date)) == 6)
        #expect(calendar.component(.day, from: try #require(week.first?.date)) == 29)
        #expect(week.last?.day == "Sunday")
    }

    @Test func sharedRecipeSnapshotResetsPersonalState() {
        var original = sampleRecipe()
        original.isFavorite = true
        original.cookedCount = 7
        original.lastCookedAt = Date()

        let snapshot = SharedRecipeSnapshot(recipe: original, ownerId: "owner")
        let imported = snapshot.recipe

        #expect(imported.isFavorite == false)
        #expect(imported.cookedCount == 0)
        #expect(imported.lastCookedAt == nil)
        #expect(imported.title == original.title)
        #expect(imported.ingredients == original.ingredients)
    }

    @Test func equivalentRecipesIgnorePersonalMetadata() {
        var lhs = sampleRecipe()
        var rhs = sampleRecipe()
        lhs.isFavorite = true
        lhs.cookedCount = 4
        rhs.createdAt = Date().addingTimeInterval(900)

        #expect(RecipeShareService.isEquivalent(lhs, rhs))
        rhs.ingredients.append("1 lime")
        #expect(RecipeShareService.isEquivalent(lhs, rhs) == false)
    }

    @MainActor
    @Test func deepLinkRouterRetainsRecipeID() throws {
        let router = ChefBuddyDeepLinkRouter.shared
        router.clear()
        let url = try #require(URL(string: "chefbuddy://recipe/share-123"))

        #expect(router.handle(url))
        #expect(router.pendingShareID == "share-123")
        router.clear()
    }

    @Test func nutritionTargetsClampUnsafeValues() {
        let targets = NutritionTargets.validated(
            calories: 300,
            carbs: 2,
            protein: 900,
            fat: 0,
            sodium: 9000,
            source: .manual
        )

        #expect(targets.calories == 800)
        #expect(targets.carbs == 25)
        #expect(targets.protein == 400)
        #expect(targets.fat == 15)
        #expect(targets.sodium == 6000)
    }

    @Test func streakDoesNotIncrementTwiceOnSameDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let earlier = calendar.date(byAdding: .hour, value: -2, to: now)
        let value = GrowthEngine.nextStreakValue(lastActivityDate: earlier, now: now, currentValue: 4)
        #expect(value == 4)
    }

    @Test func streakIncrementsOnConsecutiveDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let value = GrowthEngine.nextStreakValue(lastActivityDate: yesterday, now: now, currentValue: 4)
        #expect(value == 5)
    }

    @Test func streakResetsAfterMissedDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: now))

        #expect(GrowthEngine.nextStreakValue(lastActivityDate: threeDaysAgo, now: now, currentValue: 8) == 1)
        #expect(GrowthEngine.refreshedStreakValue(lastActivityDate: threeDaysAgo, now: now, currentValue: 8) == 0)
    }

    private func sampleRecipe() -> Recipe {
        Recipe(
            title: "Crispy Tofu Bowl",
            emoji: "🥣",
            description: "A bright weeknight bowl.",
            ingredients: ["14 oz firm tofu", "1 cup cooked rice"],
            steps: ["Press and cube the tofu.", "Cook until crisp."],
            cookTime: "25 mins",
            servings: "2 people",
            difficulty: "Easy",
            tags: ["Asian"],
            calories: "430 kcal",
            nutrition: .empty
        )
    }

}
