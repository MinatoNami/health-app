<script setup>
/* Wraps a chart with the two things the skill requires alongside it: a table
 * view (so no value is reachable by colour or tooltip alone) and, when the
 * numbers are raw sums rather than Apple's deduplicated rollups, a visible
 * caveat rather than a confidently wrong total.
 */
import { computed, ref } from 'vue'
import LineChart from './LineChart.vue'
import ColumnChart from './ColumnChart.vue'
import { NIGHTLY, localToday, unitFor } from '../format.js'

const props = defineProps({
  series: { type: Object, required: true },
  title: { type: String, required: true },
  unit: { type: String, default: '' },
  cumulative: { type: Boolean, default: false },
  refreshing: { type: Boolean, default: false },
})

const showTable = ref(false)

/* The unit a person reads, not HealthKit's: "count/min" is BPM. */
const displayUnit = computed(() => unitFor(props.series?.metric_slug ?? '', props.unit))

/* Today is still running: half a day of steps drawn as a whole one reads as a
 * collapse that is only the clock, so today's point is marked partial and drawn
 * as such rather than hidden. (Percentages arrive as percentages — the server
 * converts HealthKit's 0.97 once, for every reader.) */
const points = computed(() => {
  const raw = props.series?.points ?? []
  // A night that ended this morning is over; only a day can still be running.
  const today = NIGHTLY.has(props.series?.metric_slug) ? null : localToday()
  return raw.map((p) => ({ ...p, partial: p.date === today }))
})

const subtitle = computed(() => {
  const agg = props.series?.aggregation
  const label = { sum: 'daily total', avg: 'daily average', min: 'daily minimum', max: 'daily maximum', count: 'samples per day' }[agg] || agg
  return displayUnit.value ? `${label} · ${displayUnit.value}` : label
})

function fmt(v) {
  if (v === null || v === undefined) return '—'
  const abs = Math.abs(v)
  if (abs >= 1_000_000) return (v / 1_000_000).toFixed(2) + 'M'
  if (abs >= 1000) return Math.round(v).toLocaleString()
  return Number(v.toFixed(abs < 10 ? 2 : 0)).toLocaleString()
}
</script>

<template>
  <section class="card">
    <div class="card-head">
      <h3 class="card-title">{{ title }}</h3>
      <div class="spacer" />
      <button class="linkbtn" @click="showTable = !showTable">
        {{ showTable ? 'Chart' : 'Table' }}
      </button>
    </div>
    <p class="card-sub">
      {{ subtitle }}
      <span v-if="series?.may_double_count" class="badge warn" :title="`${series.estimated_days} of ${points.length} days are summed from raw samples, which iPhone and Watch can both write. Only ${series.rollup_days} day(s) use Apple's deduplicated rollup.`">
        ≈ estimated
      </span>
    </p>

    <div :class="{ refreshing }">
      <div v-if="!points.length" class="empty">No data in this range.</div>

      <div v-else-if="showTable" class="table-scroll">
        <table class="data">
          <thead>
            <tr><th>Date</th><th>Value</th><th>Source</th></tr>
          </thead>
          <tbody>
            <tr v-for="p in [...points].reverse()" :key="p.date">
              <td>{{ p.date }}</td>
              <td>{{ fmt(p.value) }}</td>
              <td>
                {{ p.source === 'statistic' ? 'rollup' : 'estimated' }}<template v-if="p.partial"> · today, so far</template>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <ColumnChart v-else-if="cumulative" :points="points" :unit="displayUnit" />
      <LineChart v-else :points="points" :unit="displayUnit" />
    </div>
  </section>
</template>
