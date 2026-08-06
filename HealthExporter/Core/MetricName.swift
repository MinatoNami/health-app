import Foundation

/// Turns a metric slug into something a person would say.
///
/// `heart_rate_variability_sdnn` is an identifier. It is the right thing to send
/// over the wire, to key a dictionary on, and to put in a log line — and the
/// wrong thing to put on a screen. There are ~170 of these, so this is derived
/// rather than enumerated: split, expand the acronyms, title-case the rest, and
/// keep a short table for the ones where Apple's own wording differs from a
/// literal reading of the identifier.
///
/// The table is small on purpose. Every entry is a place where the algorithm
/// would produce something correct but not what Health calls it — "Oxygen
/// Saturation" versus "Blood Oxygen" — and each one has to earn its line.
enum MetricName {

    /// Slugs whose plain reading is wrong, awkward, or simply not what Apple
    /// calls the same measurement.
    private static let overrides: [String: String] = [
        "step_count": "Steps",
        "distance_walking_running": "Walking + Running Distance",
        "distance_cycling": "Cycling Distance",
        "distance_swimming": "Swimming Distance",
        "distance_wheelchair": "Wheelchair Distance",
        "distance_downhill_snow_sports": "Downhill Snow Sports Distance",
        "active_energy_burned": "Active Energy",
        "basal_energy_burned": "Resting Energy",
        "apple_exercise_time": "Exercise Minutes",
        "apple_stand_time": "Stand Minutes",
        "apple_move_time": "Move Minutes",
        "apple_stand_hour": "Stand Hours",
        "apple_walking_steadiness": "Walking Steadiness",
        "apple_sleeping_wrist_temperature": "Wrist Temperature",
        "sleep_analysis": "Sleep",
        "body_mass": "Weight",
        "lean_body_mass": "Lean Body Mass",
        "oxygen_saturation": "Blood Oxygen",
        "heart_rate_variability_sdnn": "Heart Rate Variability",
        "walking_heart_rate_average": "Walking Heart Rate",
        "resting_heart_rate": "Resting Heart Rate",
        "environmental_audio_exposure": "Environmental Sound Levels",
        "headphone_audio_exposure": "Headphone Audio Levels",
        "dietary_energy_consumed": "Dietary Energy",
        "dietary_water": "Water",
        // Only the fats need a line each: dropping the `dietary_` prefix leaves
        // the words in the wrong order, and Health calls these "Total Fat", not
        // "Fat Total". Every other nutrient reads correctly once it is gone.
        "dietary_fat_total": "Total Fat",
        "dietary_fat_saturated": "Saturated Fat",
        "dietary_fat_monounsaturated": "Monounsaturated Fat",
        "dietary_fat_polyunsaturated": "Polyunsaturated Fat",
        "number_of_times_fallen": "Number of Falls",
        "high_heart_rate_event": "High Heart Rate Notifications",
        "low_heart_rate_event": "Low Heart Rate Notifications",
        "irregular_heart_rhythm_event": "Irregular Rhythm Notifications",
        "workout": "Workouts",
        "unknown": "Unknown",
    ]

    /// Fragments that are acronyms or unit names, not words. Title-casing these
    /// produces "Sdnn" and "Vo2", which look like typos.
    private static let uppercased: Set<String> = [
        "sdnn", "vo2", "bmi", "uv", "ecg", "hrv", "spo2", "rr", "gmt", "utc", "id",
    ]

    /// Small words Apple leaves lowercase inside a title.
    private static let lowercased: Set<String> = ["of", "in", "on", "per", "and", "the"]

    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    /// The display name. Cached because coverage grids and metric lists render
    /// the same ~170 names on every redraw.
    static func display(_ slug: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[slug] { return cached }
        let value = derive(slug)
        cache[slug] = value
        return value
    }

    private static func derive(_ slug: String) -> String {
        if let override = overrides[slug] { return override }
        guard !slug.isEmpty else { return "Unknown" }

        var parts = slug.split(separator: "_").map(String.init)
        // "Apple Walking Steadiness" is Apple's branding on the identifier, not
        // part of the measurement's name. Anything still carrying it after the
        // override table reads better without it.
        if parts.count > 1, parts[0] == "apple" { parts.removeFirst() }
        // Nor is "dietary" a word anyone says. Health lists these as "Protein"
        // and "Calcium"; the prefix is a HealthKit namespace, and stripping it
        // here is what keeps forty nutrients out of the override table.
        if parts.count > 1, parts[0] == "dietary" { parts.removeFirst() }

        let words = parts.enumerated().map { index, part -> String in
            if uppercased.contains(part) { return part.uppercased() }
            if index > 0, lowercased.contains(part) { return part }
            return part.prefix(1).uppercased() + part.dropFirst()
        }
        return words.joined(separator: " ")
    }
}

extension String {
    /// `"heart_rate_variability_sdnn".metricDisplayName == "Heart Rate Variability"`
    var metricDisplayName: String { MetricName.display(self) }
}
