<script setup>
import { computed } from 'vue'
import ChartCard from '../components/ChartCard.vue'

const props = defineProps({
  data: { type: Object, default: null },
  refreshing: { type: Boolean, default: false },
})

const TITLES = {
  step_count: 'Steps',
  active_energy_burned: 'Active energy',
  heart_rate: 'Heart rate',
  resting_heart_rate: 'Resting heart rate',
  sleep_analysis: 'Sleep',
  body_mass: 'Weight',
}

const title = (slug) => TITLES[slug] || slug.replace(/_/g, ' ')

const summary = computed(() => props.data?.summary ?? {})

function fmtCompact(v) {
  if (v === null || v === undefined) return '—'
  if (v >= 1_000_000) return (v / 1_000_000).toFixed(2) + 'M'
  if (v >= 10_000) return (v / 1000).toFixed(1) + 'K'
  return v.toLocaleString()
}
</script>

<template>
  <div v-if="data">
    <!-- Exactly one hero figure per view: the number this dashboard leads with. -->
    <section class="card" style="margin-bottom: 16px">
      <div class="tile-label">Records in range</div>
      <div class="hero">{{ fmtCompact(summary.records_in_range) }}</div>
      <div class="tile-sub">
        {{ data.from }} → {{ data.to }} · {{ summary.metrics_seen }} metric types ·
        {{ data.available_metrics }} tracked overall
      </div>
    </section>

    <div class="tiles">
      <div class="tile">
        <div class="tile-label">Days with data</div>
        <div class="tile-value">{{ summary.active_days ?? '—' }}</div>
      </div>
      <div class="tile">
        <div class="tile-label">Workouts</div>
        <div class="tile-value">{{ summary.workouts ?? '—' }}</div>
        <div class="tile-sub">{{ summary.workout_hours }} h recorded</div>
      </div>
      <div
        v-for="(reading, slug) in data.latest" :key="slug"
        class="tile"
      >
        <!-- A cumulative metric's tile is a completed day's total; a discrete
             one is an actual instantaneous reading. Saying which avoids the
             reader assuming "steps: 18" is a live count. -->
        <div class="tile-label">
          {{ reading.basis === 'day' ? 'Last full day' : 'Latest' }} {{ title(slug).toLowerCase() }}
        </div>
        <div class="tile-value">
          {{ fmtCompact(Math.round(reading.value * 10) / 10) }}<span class="tile-unit">{{ reading.unit }}</span>
        </div>
        <div class="tile-sub">{{ (reading.at || '').slice(0, 10) }}</div>
      </div>
    </div>

    <div v-if="!data.charts.length" class="card empty">
      No headline metrics have arrived yet. Once the phone uploads, charts appear here.
    </div>

    <div class="grid">
      <ChartCard
        v-for="chart in data.charts" :key="chart.metric_slug"
        :series="chart"
        :title="title(chart.metric_slug)"
        :unit="chart.unit"
        :cumulative="chart.cumulative"
        :refreshing="refreshing"
      />
    </div>
  </div>
</template>
