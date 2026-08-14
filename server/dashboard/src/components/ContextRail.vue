<script setup>
/* The measured numbers, beside the conversation rather than above it.
 *
 * This is what the model is answering *from*, so it belongs in view while you
 * read the answer — that is the "additional information around" part. It is
 * also where the wordiness went: each metric is now a line, not a card with a
 * caveat paragraph. The explanations moved to Settings, where they are read
 * once rather than skipped daily.
 *
 * One colour rule: the delta is the only thing tinted. The old version coloured
 * the delta, the coverage bar and the confidence word, which turned six metrics
 * into eighteen coloured elements and read as a traffic light.
 */
import { computed } from 'vue'

const props = defineProps({
  snapshot: { type: Object, default: null },
})

const metrics = computed(() => props.snapshot?.metrics ?? [])
const stale = computed(() => props.snapshot?.metrics_not_syncing ?? [])

function tone(metric) {
  const { direction, significance, change, confidence } = metric
  if (confidence === 'insufficient' || change == null) return 'none'
  if (direction === 'neutral' || significance === 'stable') return 'none'
  return (direction === 'higher_better' ? change > 0 : change < 0) ? 'good' : 'watch'
}

function fmt(v) {
  if (v == null) return '—'
  const abs = Math.abs(v)
  if (abs >= 10_000) return (v / 1000).toFixed(1) + 'K'
  if (abs >= 1000) return Math.round(v).toLocaleString()
  return Number(v.toFixed(abs < 10 ? 1 : 0)).toLocaleString()
}

function delta(metric) {
  if (metric.confidence === 'insufficient' || metric.change_pct == null) return null
  // "+0%" is not a reading, it is rounding. Showing it invites the eye to a
  // number that says nothing.
  if (Math.abs(metric.change_pct) < 0.5) return '±0%'
  const sign = metric.change > 0 ? '+' : '−'
  return `${sign}${Math.abs(metric.change_pct).toFixed(0)}%`
}

/* Standard abbreviations, for a column too narrow for the full names. Wrapping
 * "Resting heart rate" onto two lines makes one row twice the height of its
 * neighbours and breaks the scan down the value column. */
const SHORT = {
  resting_heart_rate: 'Resting HR',
  heart_rate_variability_sdnn: 'HRV',
  walking_heart_rate_average: 'Walking HR',
  active_energy_burned: 'Active energy',
  distance_walking_running: 'Distance',
  apple_exercise_time: 'Exercise',
  sleep_analysis: 'Sleep',
  body_fat_percentage: 'Body fat',
  oxygen_saturation: 'Blood oxygen',
  respiratory_rate: 'Respiratory',
}
const label = (m) => SHORT[m.metric_slug] || m.label

const coverage = (m) => m.current?.coverage ?? 0
</script>

<template>
  <aside class="rail">
    <div v-if="snapshot" class="panel">
      <div class="head">
        <h3>This week</h3>
        <span class="muted">vs your 28-day baseline</span>
      </div>

      <div v-if="!metrics.length" class="muted">No analysable metrics yet.</div>

      <div v-for="m in metrics" :key="m.metric_slug" class="metric">
        <div class="name" :title="m.label">{{ label(m) }}</div>
        <div class="value">
          {{ fmt(m.current.value) }}<span class="unit">{{ m.unit }}</span>
        </div>
        <div class="delta" :class="tone(m)">{{ delta(m) || '—' }}</div>
        <!-- Coverage only earns pixels when it is not full: a 7-of-7 bar drawn
             on every row is decoration that says nothing. -->
        <div v-if="coverage(m) < 0.99" class="cov" :title="`${m.current.valid_days} of ${m.current.window_days} days recorded`">
          {{ m.current.valid_days }}/{{ m.current.window_days }}d
        </div>
      </div>

      <p class="foot muted">Through {{ snapshot.as_of }}</p>
    </div>

    <div v-if="stale.length" class="panel warn">
      <div class="head"><h3>Not syncing</h3></div>
      <div v-for="s in stale" :key="s.metric_slug" class="metric stale">
        <div class="name">{{ s.label }}</div>
        <div class="cov">{{ s.days_since }}d ago</div>
      </div>
    </div>

    <div v-if="snapshot?.sleep?.nights_recorded" class="panel">
      <div class="head"><h3>Sleep</h3></div>
      <div class="metric">
        <div class="name">Average</div>
        <div class="value">{{ snapshot.sleep.average_hours }}<span class="unit">h</span></div>
      </div>
      <div class="metric">
        <div class="name">Bed / wake</div>
        <div class="value small">
          {{ snapshot.sleep.typical_bedtime }}–{{ snapshot.sleep.typical_wake_time }}
        </div>
      </div>
      <div class="metric">
        <div class="name">Schedule</div>
        <div class="value small">{{ snapshot.sleep.consistency }}</div>
      </div>
    </div>
  </aside>
</template>

<style scoped>
.rail { display: flex; flex-direction: column; gap: 12px; }

.panel {
  background: var(--surface-1);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 13px 15px;
}
.panel.warn { box-shadow: inset 0 0 0 1px var(--status-warning); }

.head { display: flex; align-items: baseline; gap: 7px; margin-bottom: 9px; flex-wrap: wrap; }
.head h3 { font-size: 12px; font-weight: 600; margin: 0; letter-spacing: 0.01em; }

/* label · value · delta on one line. A metric is a row, not a card. */
.metric {
  display: grid;
  grid-template-columns: 1fr auto auto;
  align-items: baseline;
  gap: 4px 8px;
  padding: 5px 0;
  border-bottom: 1px solid var(--gridline);
}
.metric:last-of-type { border-bottom: 0; }

.name { font-size: 12.5px; color: var(--text-secondary); }
.value { font-size: 15px; font-weight: 600; font-variant-numeric: tabular-nums; }
.value.small { font-size: 12.5px; font-weight: 500; }
.unit { font-size: 11px; color: var(--text-muted); font-weight: 400; margin-left: 2px; }

.cov { grid-column: 1 / -1; font-size: 11px; color: var(--warning-text); }
.stale .cov { grid-column: auto; text-align: right; }

.foot { margin: 9px 0 0; }
</style>
