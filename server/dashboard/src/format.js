/* How a metric is named and how its unit is spelled.
 *
 * The server sends HealthKit's own units, which are precise and not what anyone
 * writes: resting heart rate arrives as `count/min` and steps as `count`. Those
 * were being printed raw — "66 count/min", "9,470 count" — everywhere a value
 * appears, which nobody noticed while the screens were being read against
 * fixtures that used 'bpm' and 'steps'.
 *
 * The same mapping the phone applies in MetricStyle.unit, deliberately spelled
 * the same way: two products showing the same reading should not disagree about
 * what it is called.
 */

const UNITS = {
  step_count: '',
  resting_heart_rate: 'BPM',
  heart_rate: 'BPM',
  walking_heart_rate_average: 'BPM',
  apple_exercise_time: 'min',
  sleep_analysis: 'hr',
  respiratory_rate: 'br/min',
}

/* `count` means "a number of the thing the label already names" — "9,470 count"
 * says nothing "9,470 steps" does not, and the label is right there. */
export function unitFor(slug, raw) {
  if (slug in UNITS) return UNITS[slug]
  return raw === 'count' ? '' : raw || ''
}

const SHORT = {
  resting_heart_rate: 'Resting HR',
  heart_rate_variability_sdnn: 'HRV',
  walking_heart_rate_average: 'Walking HR',
  apple_exercise_time: 'Exercise',
  active_energy_burned: 'Active energy',
  distance_walking_running: 'Distance',
  sleep_analysis: 'Sleep',
  respiratory_rate: 'Respiratory rate',
  oxygen_saturation: 'Blood oxygen',
  body_fat_percentage: 'Body fat',
}

/* A row is not wide enough for "Heart-rate variability" beside a value and a
 * delta, and "Sleep duration" is two words where one will do. */
export function shortLabel(slug, fallback) {
  return SHORT[slug] || fallback || slug.replace(/_/g, ' ')
}

/* A value and its unit, with the space only where there is a unit to separate
 * from. `${v} ${unit}` leaves a trailing space on every step count. */
export function withUnit(value, slug, raw) {
  const unit = unitFor(slug, raw)
  return unit ? `${value} ${unit}` : `${value}`
}
