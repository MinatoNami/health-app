import Foundation
import HealthKit

/// The full set of HealthKit types this app reads, grouped for the permission UI.
///
/// Identifiers are built from raw strings rather than the typed static members
/// (`.stepCount` etc.) on purpose. HealthKit adds identifiers every release and
/// `HKObjectType.quantityType(forIdentifier:)` returns `nil` for anything the
/// running OS doesn't know — so a raw-string catalog degrades gracefully on
/// older systems instead of failing to compile, and newly shipped types can be
/// added without an availability maze. Anything unresolved is surfaced in the
/// Diagnostics screen so silent drops stay visible.
enum MetricCatalog {

    struct Group: Identifiable {
        var id: String
        var title: String
        var blurb: String
        /// Bare CamelCase names; the `HKQuantityTypeIdentifier` prefix is added.
        var quantities: [String] = []
        var categories: [String] = []
        var includesWorkouts: Bool = false
        var includesCharacteristics: Bool = false
        /// Reproductive health and symptoms default off — they are the most
        /// sensitive data here and the least likely to drive a workflow.
        var enabledByDefault: Bool = true
    }

    // MARK: - Groups

    static let groups: [Group] = [
        Group(
            id: "activity",
            title: "Activity & Fitness",
            blurb: "Steps, distance, energy, workout-adjacent metrics.",
            quantities: [
                "StepCount", "DistanceWalkingRunning", "DistanceCycling", "DistanceWheelchair",
                "DistanceSwimming", "DistanceDownhillSnowSports", "DistanceCrossCountrySkiing",
                "DistancePaddleSports", "DistanceRowing", "DistanceSkatingSports",
                "BasalEnergyBurned", "ActiveEnergyBurned", "FlightsClimbed", "NikeFuel",
                "AppleExerciseTime", "AppleMoveTime", "AppleStandTime", "PushCount",
                "SwimmingStrokeCount", "VO2Max", "CyclingCadence", "CyclingPower",
                "CyclingSpeed", "CyclingFunctionalThresholdPower", "CrossCountrySkiingSpeed",
                "PaddleSportsSpeed", "RowingSpeed", "RunningPower", "RunningSpeed",
                "RunningStrideLength", "RunningVerticalOscillation", "RunningGroundContactTime",
                "UnderwaterDepth", "PhysicalEffort", "TimeInDaylight",
                "EstimatedWorkoutEffortScore", "WorkoutEffortScore"
            ],
            categories: ["AppleStandHour"],
            includesWorkouts: true
        ),
        Group(
            id: "vitals",
            title: "Heart & Vitals",
            blurb: "Heart rate, HRV, blood pressure, oxygen, temperature.",
            quantities: [
                "HeartRate", "RestingHeartRate", "WalkingHeartRateAverage",
                "HeartRateVariabilitySDNN", "HeartRateRecoveryOneMinute",
                "AtrialFibrillationBurden", "OxygenSaturation", "BodyTemperature",
                "BasalBodyTemperature", "AppleSleepingWristTemperature", "WaterTemperature",
                "BloodPressureSystolic", "BloodPressureDiastolic", "RespiratoryRate",
                "PeripheralPerfusionIndex"
            ],
            categories: [
                "HighHeartRateEvent", "LowHeartRateEvent", "IrregularHeartRhythmEvent",
                "LowCardioFitnessEvent"
            ]
        ),
        Group(
            id: "sleep",
            title: "Sleep",
            blurb: "Sleep stages and breathing disturbances.",
            quantities: ["AppleSleepingBreathingDisturbances"],
            categories: ["SleepAnalysis", "SleepApneaEvent"]
        ),
        Group(
            id: "body",
            title: "Body Measurements",
            blurb: "Weight, height, body fat, lean mass.",
            quantities: [
                "BodyMass", "BodyMassIndex", "BodyFatPercentage", "LeanBodyMass",
                "Height", "WaistCircumference"
            ],
            includesCharacteristics: true
        ),
        Group(
            id: "mobility",
            title: "Mobility",
            blurb: "Gait, walking steadiness, stair speed.",
            quantities: [
                "WalkingSpeed", "WalkingStepLength", "WalkingAsymmetryPercentage",
                "WalkingDoubleSupportPercentage", "StairAscentSpeed", "StairDescentSpeed",
                "AppleWalkingSteadiness", "SixMinuteWalkTestDistance"
            ],
            categories: ["AppleWalkingSteadinessEvent"]
        ),
        Group(
            id: "nutrition",
            title: "Nutrition",
            blurb: "Macros, micronutrients, water, caffeine.",
            quantities: [
                "DietaryEnergyConsumed", "DietaryCarbohydrates", "DietaryProtein",
                "DietaryFatTotal", "DietaryFatSaturated", "DietaryFatMonounsaturated",
                "DietaryFatPolyunsaturated", "DietaryCholesterol", "DietaryFiber",
                "DietarySugar", "DietaryWater", "DietaryCaffeine", "DietarySodium",
                "DietaryPotassium", "DietaryCalcium", "DietaryIron", "DietaryMagnesium",
                "DietaryPhosphorus", "DietaryZinc", "DietaryIodine", "DietarySelenium",
                "DietaryCopper", "DietaryManganese", "DietaryChromium", "DietaryMolybdenum",
                "DietaryChloride", "DietaryVitaminA", "DietaryVitaminB6", "DietaryVitaminB12",
                "DietaryVitaminC", "DietaryVitaminD", "DietaryVitaminE", "DietaryVitaminK",
                "DietaryThiamin", "DietaryRiboflavin", "DietaryNiacin", "DietaryFolate",
                "DietaryBiotin", "DietaryPantothenicAcid"
            ]
        ),
        Group(
            id: "hearing",
            title: "Hearing",
            blurb: "Environmental and headphone audio exposure.",
            quantities: [
                "EnvironmentalAudioExposure", "HeadphoneAudioExposure",
                "EnvironmentalSoundReduction"
            ],
            categories: ["EnvironmentalAudioExposureEvent", "HeadphoneAudioExposureEvent"]
        ),
        Group(
            id: "clinical",
            title: "Respiratory & Lab Results",
            blurb: "Spirometry, glucose, insulin, other measurements.",
            quantities: [
                "ForcedExpiratoryVolume1", "ForcedVitalCapacity", "PeakExpiratoryFlowRate",
                "InhalerUsage", "BloodGlucose", "BloodAlcoholContent", "InsulinDelivery",
                "ElectrodermalActivity", "NumberOfTimesFallen", "UVExposure"
            ]
        ),
        Group(
            id: "mindfulness",
            title: "Mindfulness & Hygiene",
            blurb: "Mindful minutes, handwashing, toothbrushing.",
            categories: ["MindfulSession", "HandwashingEvent", "ToothbrushingEvent"]
        ),
        Group(
            id: "reproductive",
            title: "Reproductive Health",
            blurb: "Cycle tracking, pregnancy, sexual activity.",
            categories: [
                "MenstrualFlow", "IntermenstrualBleeding", "InfrequentMenstrualCycles",
                "IrregularMenstrualCycles", "PersistentIntermenstrualBleeding",
                "ProlongedMenstrualPeriods", "CervicalMucusQuality", "OvulationTestResult",
                "SexualActivity", "Contraceptive", "Pregnancy", "PregnancyTestResult",
                "ProgesteroneTestResult", "Lactation", "BleedingAfterPregnancy",
                "BleedingDuringPregnancy"
            ],
            enabledByDefault: false
        ),
        Group(
            id: "symptoms",
            title: "Symptoms",
            blurb: "Self-reported symptom log.",
            categories: [
                "AbdominalCramps", "Acne", "AppetiteChanges", "BladderIncontinence",
                "Bloating", "BreastPain", "ChestTightnessOrPain", "Chills", "Constipation",
                "Coughing", "Diarrhea", "Dizziness", "DrySkin", "Fainting", "Fatigue",
                "Fever", "GeneralizedBodyAche", "HairLoss", "Headache", "Heartburn",
                "HotFlashes", "LossOfSmell", "LossOfTaste", "LowerBackPain", "MemoryLapse",
                "MoodChanges", "Nausea", "NightSweats", "PelvicPain",
                "RapidPoundingOrFlutteringHeartbeat", "RunnyNose", "ShortnessOfBreath",
                "SinusCongestion", "SkippedHeartbeat", "SleepChanges", "SoreThroat",
                "VaginalDryness", "Vomiting", "Wheezing"
            ],
            enabledByDefault: false
        )
    ]

    // MARK: - Identifier resolution

    static func quantityIdentifier(_ name: String) -> HKQuantityTypeIdentifier {
        HKQuantityTypeIdentifier(rawValue: "HKQuantityTypeIdentifier" + name)
    }

    static func categoryIdentifier(_ name: String) -> HKCategoryTypeIdentifier {
        HKCategoryTypeIdentifier(rawValue: "HKCategoryTypeIdentifier" + name)
    }

    static let characteristicNames = [
        "DateOfBirth", "BiologicalSex", "BloodType", "FitzpatrickSkinType", "WheelchairUse"
    ]

    /// Names in the catalog that the running OS does not recognise. Surfaced in
    /// Diagnostics so a typo or an OS-version gap never silently loses a metric.
    static private(set) var unresolved: [String] = []

    /// Sample types for the given group ids, skipping anything this OS lacks.
    static func sampleTypes(groupIDs: Set<String>) -> Set<HKSampleType> {
        var types = Set<HKSampleType>()
        var missing: [String] = []

        for group in groups where groupIDs.contains(group.id) {
            for name in group.quantities {
                if let t = HKObjectType.quantityType(forIdentifier: quantityIdentifier(name)) {
                    types.insert(t)
                } else {
                    missing.append("HKQuantityTypeIdentifier" + name)
                }
            }
            for name in group.categories {
                if let t = HKObjectType.categoryType(forIdentifier: categoryIdentifier(name)) {
                    types.insert(t)
                } else {
                    missing.append("HKCategoryTypeIdentifier" + name)
                }
            }
            if group.includesWorkouts {
                types.insert(HKObjectType.workoutType())
            }
        }

        unresolved = missing.sorted()
        if !missing.isEmpty {
            Log.shared.warn("catalog", "\(missing.count) identifier(s) not available on this OS")
        }
        return types
    }

    static func characteristicTypes(groupIDs: Set<String>) -> Set<HKObjectType> {
        guard groups.contains(where: { groupIDs.contains($0.id) && $0.includesCharacteristics })
        else { return [] }
        var types = Set<HKObjectType>()
        for name in characteristicNames {
            let id = HKCharacteristicTypeIdentifier(rawValue: "HKCharacteristicTypeIdentifier" + name)
            if let t = HKObjectType.characteristicType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }

    /// Everything to request read access for, in one set.
    static func readTypes(groupIDs: Set<String>) -> Set<HKObjectType> {
        var all = Set<HKObjectType>()
        for t in sampleTypes(groupIDs: groupIDs) { all.insert(t) }
        for t in characteristicTypes(groupIDs: groupIDs) { all.insert(t) }
        return all
    }

    static var defaultGroupIDs: Set<String> {
        Set(groups.filter(\.enabledByDefault).map(\.id))
    }

    static var allGroupIDs: Set<String> {
        Set(groups.map(\.id))
    }

    static func group(id: String) -> Group? {
        groups.first { $0.id == id }
    }

    /// Types that are intentionally out of scope for v1 — each needs a bespoke
    /// reader rather than the generic sample path. Listed in Diagnostics so the
    /// gap is explicit rather than a surprise.
    static let deferredTypes = [
        "HKElectrocardiogram — voltage series, ~15k measurements per reading",
        "HKAudiogramSample — per-frequency sensitivity points",
        "HKHeartbeatSeriesSample — beat-to-beat intervals, very high volume",
        "HKWorkoutRoute — GPS polylines, needs HKWorkoutRouteQuery",
        "HKStateOfMind (iOS 18) — valence/labels/associations",
        "HKClinicalRecord — separate entitlement, returns FHIR resources"
    ]
}
