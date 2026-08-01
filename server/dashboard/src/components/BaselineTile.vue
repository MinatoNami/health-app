<script setup>
/* One metric: current value, how it compares with the personal baseline, and
 * how much of that is trustworthy.
 *
 * A stat tile rather than a chart, because the job is "one current value plus a
 * delta" — the form heuristic's own example of when a chart is the wrong answer.
 *
 * Two decisions worth keeping:
 *
 * The delta is only coloured when the metric has a direction. Steps up is good
 * and resting heart rate up is not, but weight up is neither — painting a weight
 * change red is a judgement this app has no business making, so neutral metrics
 * get ink instead of a status colour.
 *
 * Confidence is a badge with words in it, never a colour alone. "moderate" has
 * to survive being printed in greyscale by someone who cannot tell the swatches
 * apart.
 */
import { computed } from 'vue'

const props = defineProps({
  metric: { type: Object, required: true },
  quality: { type: Object, default: null },
})

const CONFIDENCE_RANK = { insufficient: 0, low: 1, moderate: 2, high: 3 }

const value = computed(() => props.metric.current?.value)
const baseline = computed(() => props.metric.baseline?.value)
const usable = computed(() => props.metric.confidence !== 'insufficient')

/* Direction × whether up is good. Neutral metrics deliberately get neither. */
const deltaTone = computed(() => {
  const { direction, significance, change } = props.metric
  if (!usable.value || change === null || change === undefined) return 'none'
  if (direction === 'neutral' || significance === 'stable') return 'none'
  const better = direction === 'higher_better' ? change > 0 : change < 0
  return better ? 'good' : 'watch'
})

/* The server's figure, not a recomputed one. It scores against how often the
 * metric is expected — weight three times a week is full coverage for weight,
 * and dividing by 7 here painted normal behaviour as a data problem. */
const coverage = computed(() => {
  const current = props.metric.current
  if (!current) return 0
  if (typeof current.coverage === 'number') return current.coverage
  return current.window_days ? Math.min(1, current.valid_days / current.window_days) : 0
})

const cadenceNote = computed(() => {
  const cadence = props.metric.expected_cadence
  return cadence && cadence < 1 ? ' recorded' : ''
})

/* The meter's colour has to describe the same thing its width does. Colouring a
 * full-width bar by the confidence grade produced a 7-of-7-days meter painted
 * amber, which reads as "incomplete" while showing complete. */
const coverageTone = computed(() => {
  if (coverage.value >= 0.85) return 'full'
  if (coverage.value >= 0.5) return 'partial'
  return 'sparse'
})

function fmt(v) {
  if (v === null || v === undefined) return '—'
  const abs = Math.abs(v)
  if (abs >= 1_000_000) return (v / 1_000_000).toFixed(2) + 'M'
  if (abs >= 10_000) return (v / 1000).toFixed(1) + 'K'
  if (abs >= 1000) return Math.round(v).toLocaleString()
  return Number(v.toFixed(abs < 10 ? 2 : abs < 100 ? 1 : 0)).toLocaleString()
}

const deltaLabel = computed(() => {
  const { change, change_pct: pct } = props.metric
  if (change === null || change === undefined) return null
  const sign = change > 0 ? '+' : change < 0 ? '−' : ''
  const magnitude = fmt(Math.abs(change))
  return pct === null || pct === undefined
    ? `${sign}${magnitude}`
    : `${sign}${magnitude} (${sign}${Math.abs(pct).toFixed(1)}%)`
})
</script>

<template>
  <div class="tile baseline">
    <div class="tile-label">{{ metric.label }}</div>

    <div class="tile-value">
      {{ fmt(value) }}<span class="tile-unit">{{ metric.unit }}</span>
    </div>

    <!-- The comparison, not just the number. A value on its own says nothing
         about whether it is normal for this person. -->
    <div v-if="usable && deltaLabel" class="delta" :class="deltaTone">
      {{ deltaLabel }}
      <span class="delta-context">vs {{ fmt(baseline) }} baseline</span>
    </div>
    <div v-else class="delta none">
      <span class="delta-context">not enough data to compare</span>
    </div>

    <!-- Meter: fill and track are steps of the same ramp, so the state reads
         across the whole bar rather than only where it is filled. -->
    <div
      class="meter"
      role="img"
      :aria-label="`${metric.current.valid_days} of ${metric.current.window_days} days recorded`"
    >
      <span class="meter-fill" :class="coverageTone" :style="{ width: `${coverage * 100}%` }" />
    </div>

    <div class="tile-sub">
      <span class="conf" :class="metric.confidence">{{ metric.confidence }}</span>
      · {{ metric.current.valid_days }}/{{ metric.current.window_days }} days{{ cadenceNote }}
      <span v-if="metric.significance !== 'stable' && usable">· {{ metric.significance }}</span>
    </div>

    <p v-if="quality?.notes?.length" class="caveat">{{ quality.notes[0] }}</p>
  </div>
</template>

<style scoped>
.baseline { display: flex; flex-direction: column; gap: 6px; }

.delta { font-size: 13px; font-weight: 600; display: flex; flex-wrap: wrap; gap: 6px; align-items: baseline; }
.delta.good { color: var(--success-text); }
.delta.watch { color: var(--status-critical); }
.delta.none { color: var(--text-secondary); font-weight: 500; }
.delta-context { font-size: 11px; font-weight: 400; color: var(--text-muted); }

.meter {
  height: 5px; border-radius: 999px; overflow: hidden;
  /* Lighter step of the same ink, so the unfilled part still reads as track. */
  background: color-mix(in srgb, var(--text-muted) 22%, transparent);
}
.meter-fill { display: block; height: 100%; border-radius: 999px; background: var(--series-1); }
.meter-fill.full { background: var(--status-good); }
.meter-fill.partial { background: var(--status-warning); }
.meter-fill.sparse { background: var(--status-critical); }

/* Word first, colour second: the label is what carries the meaning. */
.conf { text-transform: capitalize; font-weight: 600; color: var(--text-secondary); }
.conf.high { color: var(--success-text); }
.conf.moderate { color: var(--text-secondary); }
.conf.low, .conf.insufficient { color: var(--status-critical); }

.caveat { font-size: 11px; color: var(--text-muted); margin: 2px 0 0; line-height: 1.4; }
</style>
