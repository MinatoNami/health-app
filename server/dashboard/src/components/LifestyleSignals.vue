<script setup>
/* Habits and recovery: the lifestyle signals the server computes from data the
 * phone was already sending — overnight vitals, sleep regularity, the week's
 * exercise minutes, daylight and cardio fitness.
 *
 * Each card is a measurement and what it was judged against, never a score.
 * The server decides every status and every range; this only lays them out,
 * for the same reason the rest of the page does — a range recomputed in the
 * browser is a second opinion about the same night.
 *
 * Status colour is rare on purpose. Only an overnight flag and a range edge
 * that was crossed get a tint, and both carry the words as well.
 */
import { computed } from 'vue'

const props = defineProps({
  signals: { type: Object, default: null },
})

const overnight = computed(() => props.signals?.overnight ?? null)
const regularity = computed(() => props.signals?.sleep_regularity ?? null)
const activity = computed(() => props.signals?.activity ?? null)
const daylight = computed(() => props.signals?.daylight ?? null)
const fitness = computed(() => props.signals?.cardio_fitness ?? null)

const any = computed(
  () => overnight.value || regularity.value || activity.value || daylight.value || fitness.value,
)

// Spelled as the rest of the dashboard spells them (format.js), so one page
// does not say BPM in one row and bpm in the next.
const UNITS = { 'count/min': 'BPM', degC: '°C', ms: 'ms', '%': '%', h: 'h' }
// Breaths, not beats: the server sends both as count/min.
const unit = (m) => (m.metric === 'respiratory_rate' ? 'br/min' : UNITS[m.unit] ?? m.unit)

const hm = (hours) => {
  const h = Math.floor(hours)
  return `${h}h ${String(Math.round((hours - h) * 60)).padStart(2, '0')}m`
}

function night(o) {
  if (!o?.night_of) return 'Overnight'
  if (o.is_last_night) return 'Last night'
  const d = new Date(`${o.night_of}T12:00:00`)
  return `Night of ${d.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' })}`
}

const STATUS = {
  outside_range: 'Outside your usual range',
  within_range: 'Within your usual range',
  building: 'Learning your range',
  no_recent_night: 'No recent night',
}

function value(m) {
  if (m.value == null) return '—'
  if (m.metric === 'sleep_duration') return hm(m.value)
  return m.unit === '%' ? `${m.value}%` : `${m.value} ${unit(m)}`
}

function range(m) {
  if (m.typical_low == null) return m.status === 'missing' ? 'not recorded' : 'no range yet'
  if (m.metric === 'sleep_duration') return `usual ${hm(m.typical_low)}–${hm(m.typical_high)}`
  return `usual ${m.typical_low}–${m.typical_high}`
}

const activityPct = computed(() => {
  const minutes = activity.value?.current?.minutes ?? 0
  return Math.min(100, (minutes / 300) * 100)
})

function signed(v, digits = 0) {
  if (v == null) return ''
  const s = Math.abs(v).toFixed(digits)
  return v > 0 ? `+${s}` : v < 0 ? `−${s}` : '±0'
}

const FITNESS = { rising: 'rising', falling: 'falling', steady: 'steady', unclear: 'too few estimates to say' }
</script>

<template>
  <section v-if="any" class="lifestyle">
    <div class="seclabel">Habits &amp; recovery</div>
    <div class="ls-grid">
      <!-- Overnight vitals -->
      <article v-if="overnight" class="card ls-card overnight">
        <header class="ls-head">
          <span class="ls-title">{{ night(overnight) }}</span>
          <span class="ls-status" :class="{ flag: overnight.status === 'outside_range' }">
            {{ STATUS[overnight.status] }}
          </span>
        </header>
        <table class="ls-rows">
          <tbody>
            <tr v-for="m in overnight.metrics" :key="m.metric">
              <th scope="row">{{ m.label }}</th>
              <td class="v">{{ value(m) }}</td>
              <td class="r" :class="{ out: m.status === 'above' || m.status === 'below' }">
                <template v-if="m.status === 'above' || m.status === 'below'">{{ m.status }} · </template>{{ range(m) }}
              </td>
            </tr>
          </tbody>
        </table>
        <p class="ls-foot">{{ overnight.observation }}</p>
        <p v-if="overnight.possible_factors?.length" class="ls-foot muted">
          Often moved by {{ overnight.possible_factors.slice(0, 5).join(', ') }}.
        </p>
      </article>

      <!-- Sleep regularity -->
      <article v-if="regularity" class="card ls-card">
        <header class="ls-head"><span class="ls-title">Sleep regularity</span></header>
        <template v-if="regularity.sri != null">
          <!-- "index", not "/ 100": out of a hundred reads as a grade, and
               the phone names it the same way. -->
          <div class="tile-value">{{ regularity.sri }}<span class="tile-unit">index</span></div>
          <div class="ls-sub">
            {{ regularity.label }}
            <template v-if="regularity.baseline.sri != null">
              · previous 4 weeks {{ regularity.baseline.sri }}
              <span class="delta" :class="regularity.significance === 'notable' ? (regularity.change > 0 ? 'good' : 'watch') : 'none'">
                {{ signed(regularity.change) }}
              </span>
            </template>
          </div>
        </template>
        <p v-else class="ls-sub">{{ regularity.confidence_reason }}.</p>
        <p class="ls-foot muted">
          How alike your sleep and wake times are day to day. In a cohort of 61,000 adults the
          median was {{ regularity.reference.median }} — context, not a target.
        </p>
      </article>

      <!-- Weekly activity -->
      <article v-if="activity" class="card ls-card">
        <header class="ls-head"><span class="ls-title">Exercise, last 7 days</span></header>
        <div class="tile-value">{{ activity.current.minutes }}<span class="tile-unit">min</span></div>
        <div class="bar" role="img" :aria-label="`${activity.current.minutes} of a 150 to 300 minute guideline`">
          <div class="bar-fill" :style="{ width: activityPct + '%' }" />
          <div class="bar-mark" style="left: 50%" />
        </div>
        <div class="bar-scale"><span>0</span><span>150</span><span>300</span></div>
        <div class="ls-sub">
          Guideline met {{ activity.weeks_met }} of the last {{ activity.weeks_counted }}
          {{ activity.weeks_counted === 1 ? 'week' : 'weeks' }}
        </div>
        <p class="ls-foot muted">{{ activity.observation }}</p>
      </article>

      <!-- Daylight -->
      <article v-if="daylight" class="card ls-card">
        <header class="ls-head"><span class="ls-title">Time in daylight</span></header>
        <div class="tile-value">
          {{ daylight.current.value ?? '—' }}<span class="tile-unit">min / day</span>
        </div>
        <div class="ls-sub">
          28-day baseline {{ daylight.baseline.value ?? '—' }} min
          <span v-if="daylight.change_pct != null" class="delta" :class="daylight.significance === 'notable' ? (daylight.change > 0 ? 'good' : 'watch') : 'none'">
            {{ signed(daylight.change_pct) }}%
          </span>
        </div>
        <p class="ls-foot muted">{{ daylight.current.valid_days }} of {{ daylight.current.window_days }} days measured by the watch.</p>
      </article>

      <!-- Cardio fitness -->
      <article v-if="fitness" class="card ls-card">
        <header class="ls-head"><span class="ls-title">Cardio fitness</span></header>
        <div class="tile-value">{{ fitness.latest }}<span class="tile-unit">VO₂ max</span></div>
        <div class="ls-sub">
          90 days: {{ FITNESS[fitness.direction] ?? fitness.direction }}
          <template v-if="fitness.change_over_window != null && fitness.direction !== 'unclear'">
            ({{ signed(fitness.change_over_window, 1) }})
          </template>
          · {{ fitness.estimates }} estimates
        </div>
        <p class="ls-foot muted">An estimate from outdoor walks and runs; the direction over months means more than one value.</p>
      </article>
    </div>
  </section>
</template>

<style scoped>
.seclabel {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 11px; font-weight: 600; letter-spacing: 0.09em;
  text-transform: uppercase; color: var(--text-muted);
  margin-bottom: 10px;
}
.lifestyle { margin-bottom: 22px; }
.ls-grid {
  display: grid; gap: 12px;
  grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
}
.ls-card { padding: 16px 18px; display: flex; flex-direction: column; gap: 6px; min-width: 0; }
.overnight { grid-column: span 2; }
@media (max-width: 720px) { .overnight { grid-column: auto; } }

.ls-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; margin-bottom: 4px; }
.ls-title { font-size: 13px; font-weight: 600; flex: 1; }
.ls-status { font-size: 12px; color: var(--text-muted); }
.ls-status.flag { color: var(--warning-text); font-weight: 600; }

.ls-sub { font-size: 12px; color: var(--text-secondary); display: flex; gap: 6px; align-items: baseline; flex-wrap: wrap; }
.ls-sub .delta { min-width: 0; text-align: left; }
.ls-foot { font-size: 12px; line-height: 1.45; margin: 4px 0 0; color: var(--text-secondary); text-wrap: pretty; }

.ls-rows { width: 100%; border-collapse: collapse; font-size: 12px; }
.ls-rows th, .ls-rows td { padding: 5px 0; border-bottom: 1px solid var(--gridline); text-align: left; }
.ls-rows th { font-weight: 500; color: var(--text-secondary); }
.ls-rows td.v { font-variant-numeric: tabular-nums; text-align: right; padding-right: 14px; white-space: nowrap; }
.ls-rows td.r { color: var(--text-muted); text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
.ls-rows td.r.out { color: var(--warning-text); font-weight: 600; }

.bar { position: relative; height: 6px; border-radius: 3px; background: var(--gridline); margin-top: 8px; }
.bar-fill { position: absolute; inset: 0 auto 0 0; border-radius: 3px; background: var(--accent); }
.bar-mark { position: absolute; top: -3px; bottom: -3px; width: 2px; background: var(--text-muted); transform: translateX(-1px); }
.bar-scale {
  display: flex; justify-content: space-between;
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 10px; color: var(--text-muted);
}
</style>
