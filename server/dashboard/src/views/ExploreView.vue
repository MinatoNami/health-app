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
  if (!q) return catalog.value
  // Matches the readable name *and* the slug: the list is read by name, but
  // anything you copy out of a log or an API response is a slug.
  return catalog.value.filter(
    (m) => m.metric_slug.includes(q) || (m.label || '').toLowerCase().includes(q)
  )
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

/* Two guards on one load.
 *
 * Coalescing: picking a metric changes `selected`, which resets `agg`, and both
 * are watched — so a single choice, and the first mount, each fetched the same
 * series two or three times. Triggers in the same turn now make one request.
 *
 * Ordering: responses can land out of order — click 7d then 1y quickly and the
 * 7d answer may arrive last. Only the newest request may write the chart. */
let loadTimer = null
let loadSeq = 0
function scheduleLoad() {
  clearTimeout(loadTimer)
  loadTimer = setTimeout(load, 0)
}

async function load() {
  if (!selected.value) return
  const seq = ++loadSeq
  loading.value = true
  error.value = ''
  try {
    const result = await api.series({
      metric: selected.value, agg: agg.value,
      from: props.range.from, to: props.range.to,
    })
    if (seq === loadSeq) series.value = result
  } catch (e) {
    if (seq === loadSeq) error.value = e.message
  } finally {
    if (seq === loadSeq) loading.value = false
  }
}

watch(selected, () => {
  agg.value = current.value?.default_agg || 'avg'
  scheduleLoad()
})
// deep, because the date inputs mutate range.from/range.to in place rather
// than replacing the object — without it, editing a date silently leaves this
// view showing the previous range's data.
watch([agg, () => props.range], scheduleLoad, { deep: true })

loadCatalog().then(scheduleLoad)
</script>

<template>
  <div>
    <div class="filterbar">
      <label for="metric">Metric</label>
      <select id="metric" v-model="selected">
        <option v-for="m in filtered" :key="m.metric_slug" :value="m.metric_slug">
          {{ m.label || m.metric_slug }} ({{ m.count.toLocaleString() }})
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
      :title="current?.label || selected"
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
