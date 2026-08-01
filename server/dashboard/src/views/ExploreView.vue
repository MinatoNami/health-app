<script setup>
/* Any metric, any aggregation. The catalog tells us which aggregations are
 * meaningful — summing an instantaneous reading like heart rate is nonsense, so
 * those options are not offered rather than merely discouraged.
 */
import { ref, watch, computed } from 'vue'
import { api } from '../api.js'
import ChartCard from '../components/ChartCard.vue'

const props = defineProps({ range: { type: Object, required: true } })

const catalog = ref([])
const selected = ref('')
const agg = ref('')
const series = ref(null)
const loading = ref(false)
const error = ref('')
const search = ref('')

const current = computed(() => catalog.value.find((m) => m.metric_slug === selected.value))
const filtered = computed(() => {
  const q = search.value.trim().toLowerCase()
  return q ? catalog.value.filter((m) => m.metric_slug.includes(q)) : catalog.value
})

async function loadCatalog() {
  try {
    catalog.value = (await api.metrics()).metrics
    if (!selected.value && catalog.value.length) {
      selected.value = catalog.value[0].metric_slug
      agg.value = catalog.value[0].default_agg
    }
  } catch (e) {
    error.value = e.message
  }
}

async function load() {
  if (!selected.value) return
  loading.value = true
  error.value = ''
  try {
    series.value = await api.series({
      metric: selected.value, agg: agg.value,
      from: props.range.from, to: props.range.to,
    })
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

watch(selected, () => {
  agg.value = current.value?.default_agg || 'avg'
  load()
})
watch([agg, () => props.range], load)

loadCatalog().then(load)
</script>

<template>
  <div>
    <div class="filterbar">
      <label for="metric">Metric</label>
      <select id="metric" v-model="selected">
        <option v-for="m in filtered" :key="m.metric_slug" :value="m.metric_slug">
          {{ m.metric_slug }} ({{ m.count.toLocaleString() }})
        </option>
      </select>
      <input v-model="search" type="text" placeholder="filter metrics…" style="width: 150px" />
      <span class="spacer" />
      <label>Aggregate</label>
      <button
        v-for="option in current?.allowed_aggs || []" :key="option"
        class="chip" :class="{ active: agg === option }"
        @click="agg = option"
      >{{ option }}</button>
    </div>

    <p v-if="error" class="error">{{ error }}</p>

    <ChartCard
      v-if="series"
      :series="series"
      :title="selected.replace(/_/g, ' ')"
      :unit="current?.unit || ''"
      :cumulative="agg === 'sum'"
      :refreshing="loading"
    />

    <p v-if="current" class="muted" style="margin-top: 10px">
      {{ current.count.toLocaleString() }} samples · {{ current.aggregation || 'n/a' }} ·
      first {{ (current.first_sample || '').slice(0, 10) }} · last {{ (current.last_sample || '').slice(0, 10) }}
    </p>
  </div>
</template>
