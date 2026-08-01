<script setup>
/* Wraps a chart with the two things the skill requires alongside it: a table
 * view (so no value is reachable by colour or tooltip alone) and, when the
 * numbers are raw sums rather than Apple's deduplicated rollups, a visible
 * caveat rather than a confidently wrong total.
 */
import { computed, ref } from 'vue'
import LineChart from './LineChart.vue'
import ColumnChart from './ColumnChart.vue'

const props = defineProps({
  series: { type: Object, required: true },
  title: { type: String, required: true },
  unit: { type: String, default: '' },
  cumulative: { type: Boolean, default: false },
  refreshing: { type: Boolean, default: false },
})

const showTable = ref(false)
const points = computed(() => props.series?.points ?? [])

const subtitle = computed(() => {
  const agg = props.series?.aggregation
  const label = { sum: 'daily total', avg: 'daily average', min: 'daily minimum', max: 'daily maximum', count: 'samples per day' }[agg] || agg
  return props.unit ? `${label} · ${props.unit}` : label
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
              <td>{{ p.source === 'statistic' ? 'rollup' : 'estimated' }}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <ColumnChart v-else-if="cumulative" :points="points" :unit="unit" />
      <LineChart v-else :points="points" :unit="unit" />
    </div>
  </section>
</template>
