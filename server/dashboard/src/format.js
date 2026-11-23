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
  heart_rate_recovery_one_minute: 'BPM',
  apple_sleeping_wrist_temperature: '°C',
  time_in_daylight: 'min',
  vo2_max: 'mL/kg/min',
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

/* Hours as a person says them. "7.8 hr" is a decimal nobody sleeps; "7h 48m"
 * is the same night in the form the phone and the overnight card both use. */
export function hoursMinutes(hours) {
  if (hours == null) return '—'
  const total = Math.round(hours * 60)
  return `${Math.floor(total / 60)}h ${String(total % 60).padStart(2, '0')}m`
}

/* Filed under the morning they ended, so "today" for these is last night —
 * complete once it is over, unlike today's steps. Mirrors the server's
 * sleep bucketing and analytics.END_ANCHORED. */
export const NIGHTLY = new Set([
  'sleep_analysis',
  'apple_sleeping_wrist_temperature',
  'apple_sleeping_breathing_disturbances',
])

/* Today's date where the browser is, as the YYYY-MM-DD the API uses. Not
 * toISOString(), which is UTC and calls a Singapore morning yesterday. */
export function localToday() {
  const d = new Date()
  const pad = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

/* Axis labels that keep the precision their step needs. Rounding every tick
 * to whole numbers turned a 72–73 kg axis into "72, 72, 73, 73". */
export function tickLabel(value, step) {
  // One notation per axis: switching from "8,000" to "10.0K" halfway up reads
  // as two different scales.
  if (step >= 1_000_000) return tickLabel(value / 1_000_000, step / 1_000_000) + 'M'
  if (step >= 1000) return tickLabel(value / 1000, step / 1000) + 'K'
  const decimals = step >= 1 ? 0 : Math.min(3, Math.ceil(-Math.log10(step) - 1e-9))
  return value.toLocaleString(undefined, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}
