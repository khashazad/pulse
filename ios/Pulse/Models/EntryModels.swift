/// Request/response wire models for the food-entry write endpoints.
/// `FoodEntryCreate` mirrors the server's `FoodEntryCreate` input contract,
/// `EntriesCreateRequest` is the `POST /entries` batch envelope, and
/// `EntryWriteResponse` is the `{entries, daily_totals}` payload returned by
/// both `POST /entries` and `POST /meals/{id}/log`.
/// `snake_case` JSON ↔ camelCase Swift via explicit `CodingKeys`, matching
/// `FoodEntry.swift`.
import Foundation

/// Request payload for one item in `POST /entries`. Mirrors the server
/// `FoodEntryCreate`: exactly one food source must be supplied — either a USDA
/// reference (`fdcId` + `usdaDescription`) or a `customFoodId`. Use the
/// `usda(...)` / `custom(...)` factories, which make the invalid "both/neither
/// source" states unrepresentable (the server rejects them with HTTP 422).
///
/// `consumedAt` drives backdated logging. Encode it through
/// `JSONEncoder.pulseDefault()`, which writes a naive wall-clock datetime
/// (`yyyy-MM-dd'T'HH:mm:ss`, no timezone) in the device's current timezone. The
/// server derives the owning calendar day from this value
/// (`_effective_log_date`); the client must never compute the log date itself.
/// Pass a `Date` that falls on the intended local day (noon is safest); leave
/// `consumedAt` `nil` to log against the server's "now".
struct FoodEntryCreate: Encodable, Equatable {
    let displayName: String
    let quantityText: String
    let normalizedQuantityValue: Double?
    let normalizedQuantityUnit: String?
    let usdaFdcId: Int?
    let usdaDescription: String?
    let customFoodId: UUID?
    let calories: Int
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let consumedAt: Date?
    /// Whether the entry counts toward totals immediately. `true` for normal
    /// logging; `false` marks a future prep portion as pending until the user
    /// confirms it. Encoded as `confirmed`; the server defaults it to `true`.
    let confirmed: Bool

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case quantityText = "quantity_text"
        case normalizedQuantityValue = "normalized_quantity_value"
        case normalizedQuantityUnit = "normalized_quantity_unit"
        case usdaFdcId = "usda_fdc_id"
        case usdaDescription = "usda_description"
        case customFoodId = "custom_food_id"
        case calories
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case consumedAt = "consumed_at"
        case confirmed
    }

    /// Designated initializer. Private so callers go through the `usda`/`custom`
    /// factories and cannot construct an entry with an invalid food-source
    /// combination.
    /// - Parameters mirror the stored properties one-to-one.
    /// - Returns: A `FoodEntryCreate` with the given fields.
    private init(
        displayName: String,
        quantityText: String,
        normalizedQuantityValue: Double?,
        normalizedQuantityUnit: String?,
        usdaFdcId: Int?,
        usdaDescription: String?,
        customFoodId: UUID?,
        calories: Int,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        consumedAt: Date?,
        confirmed: Bool
    ) {
        self.displayName = displayName
        self.quantityText = quantityText
        self.normalizedQuantityValue = normalizedQuantityValue
        self.normalizedQuantityUnit = normalizedQuantityUnit
        self.usdaFdcId = usdaFdcId
        self.usdaDescription = usdaDescription
        self.customFoodId = customFoodId
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.consumedAt = consumedAt
        self.confirmed = confirmed
    }

    /// Builds an entry backed by a USDA FoodData Central food.
    /// - Parameters:
    ///   - displayName: Human-readable food name shown in the day's list.
    ///   - quantityText: Free-text quantity as entered (e.g. "1 cup", "150 g").
    ///   - fdcId: USDA FoodData Central id identifying the food source.
    ///   - usdaDescription: USDA description string (required by the server whenever `fdcId` is set).
    ///   - calories: Total calories for the logged quantity.
    ///   - proteinG: Protein in grams for the logged quantity.
    ///   - carbsG: Carbohydrates in grams for the logged quantity.
    ///   - fatG: Fat in grams for the logged quantity.
    ///   - normalizedQuantityValue: Optional parsed numeric quantity. Defaults to `nil`.
    ///   - normalizedQuantityUnit: Optional parsed quantity unit. Defaults to `nil`.
    ///   - consumedAt: Optional backdated consumption time; `nil` logs against the server's "now". Defaults to `nil`.
    /// - Returns: A valid USDA-sourced `FoodEntryCreate`.
    static func usda(
        displayName: String,
        quantityText: String,
        fdcId: Int,
        usdaDescription: String,
        calories: Int,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        normalizedQuantityValue: Double? = nil,
        normalizedQuantityUnit: String? = nil,
        consumedAt: Date? = nil,
        confirmed: Bool = true
    ) -> FoodEntryCreate {
        FoodEntryCreate(
            displayName: displayName,
            quantityText: quantityText,
            normalizedQuantityValue: normalizedQuantityValue,
            normalizedQuantityUnit: normalizedQuantityUnit,
            usdaFdcId: fdcId,
            usdaDescription: usdaDescription,
            customFoodId: nil,
            calories: calories,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            consumedAt: consumedAt,
            confirmed: confirmed
        )
    }

    /// Builds an entry backed by a user-defined custom food.
    /// - Parameters:
    ///   - displayName: Human-readable food name shown in the day's list.
    ///   - quantityText: Free-text quantity as entered (e.g. "1 serving").
    ///   - customFoodId: Identifier of the custom food owned by the user.
    ///   - calories: Total calories for the logged quantity.
    ///   - proteinG: Protein in grams for the logged quantity.
    ///   - carbsG: Carbohydrates in grams for the logged quantity.
    ///   - fatG: Fat in grams for the logged quantity.
    ///   - normalizedQuantityValue: Optional parsed numeric quantity. Defaults to `nil`.
    ///   - normalizedQuantityUnit: Optional parsed quantity unit. Defaults to `nil`.
    ///   - consumedAt: Optional backdated consumption time; `nil` logs against the server's "now". Defaults to `nil`.
    /// - Returns: A valid custom-food-sourced `FoodEntryCreate`.
    static func custom(
        displayName: String,
        quantityText: String,
        customFoodId: UUID,
        calories: Int,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        normalizedQuantityValue: Double? = nil,
        normalizedQuantityUnit: String? = nil,
        consumedAt: Date? = nil,
        confirmed: Bool = true
    ) -> FoodEntryCreate {
        FoodEntryCreate(
            displayName: displayName,
            quantityText: quantityText,
            normalizedQuantityValue: normalizedQuantityValue,
            normalizedQuantityUnit: normalizedQuantityUnit,
            usdaFdcId: nil,
            usdaDescription: nil,
            customFoodId: customFoodId,
            calories: calories,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            consumedAt: consumedAt,
            confirmed: confirmed
        )
    }
}

/// Request body envelope for `POST /entries` — a batch of entries inserted
/// atomically. All items in a batch share one server-assigned entry group.
struct EntriesCreateRequest: Encodable, Equatable {
    let items: [FoodEntryCreate]
}

/// Response body for the food-entry write endpoints (`POST /entries` and
/// `POST /meals/{id}/log`): the rows the server created plus the recomputed
/// daily macro totals for the affected day.
struct EntryWriteResponse: Decodable, Equatable {
    let entries: [FoodEntry]
    let dailyTotals: MacroTotals

    enum CodingKeys: String, CodingKey {
        case entries
        case dailyTotals = "daily_totals"
    }
}

/// Request body for `POST /entries/confirm` — the pending entry ids to confirm.
/// One id confirms a single pending entry; the day's pending ids confirm all of
/// that day at once. The server response reuses `EntryWriteResponse` (the
/// confirmed entries plus the affected day's recomputed totals).
struct EntriesConfirmRequest: Encodable, Equatable {
    let ids: [UUID]
}
