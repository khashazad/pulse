from diet_tracker_server.usda import normalize_food_nutrients


# Summary: Ensures nutrient normalization extracts standard macros from search-style payloads.
# Parameters:
# - None: Uses a representative static USDA food search result sample.
# Returns:
# - None: Performs assertions on normalized nutrient fields.
# Raises/Throws:
# - AssertionError: Raised when normalized fields are incorrect.
def test_normalize_extracts_macros_from_search_result() -> None:
    raw = {
        "fdcId": 171287,
        "description": "Egg, whole, raw, fresh",
        "foodNutrients": [
            {"nutrientId": 1008, "value": 143},
            {"nutrientId": 1003, "value": 12.56},
            {"nutrientId": 1005, "value": 0.72},
            {"nutrientId": 1004, "value": 9.51},
        ],
        "servingSize": 50.0,
        "servingSizeUnit": "g",
    }
    result = normalize_food_nutrients(raw)
    assert result["fdc_id"] == 171287
    assert result["calories"] == 143
    assert result["protein_g"] == 12.56
    assert result["fat_g"] == 9.51
    assert result["serving_size"] == 50.0


# Summary: Ensures normalization supports USDA's nested nutrient metadata format.
# Parameters:
# - None: Uses a sample where nutrient IDs are nested under `nutrient` metadata.
# Returns:
# - None: Performs assertions on normalized nutrient and serving fields.
# Raises/Throws:
# - AssertionError: Raised when normalized fields are incorrect.
def test_normalize_handles_nested_nutrient_format() -> None:
    raw = {
        "fdcId": 173430,
        "description": "Butter, salted",
        "foodNutrients": [
            {"nutrient": {"id": 1008, "name": "Energy"}, "amount": 717},
            {"nutrient": {"id": 1003, "name": "Protein"}, "amount": 0.85},
            {"nutrient": {"id": 1005, "name": "Carbohydrate, by difference"}, "amount": 0.06},
            {"nutrient": {"id": 1004, "name": "Total lipid (fat)"}, "amount": 81.11},
        ],
        "servingSize": 14.2,
        "householdServingFullText": "1 tbsp",
    }
    result = normalize_food_nutrients(raw)
    assert result["calories"] == 717
    assert result["fat_g"] == 81.11
    assert result["serving_size_unit"] == "1 tbsp"


# Summary: Ensures normalization provides safe zero defaults when nutrient data is absent.
# Parameters:
# - None: Uses a payload with no nutrient rows.
# Returns:
# - None: Performs assertions on default values.
# Raises/Throws:
# - AssertionError: Raised when defaults are incorrect.
def test_normalize_handles_missing_nutrients() -> None:
    raw = {"fdcId": 1, "description": "Mystery food", "foodNutrients": []}
    result = normalize_food_nutrients(raw)
    assert result["calories"] == 0
    assert result["protein_g"] == 0.0
