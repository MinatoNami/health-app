<script setup>
/* CSV export.
 *
 * The row count is fetched before the download so nobody accidentally starts a
 * million-row export without knowing. The download itself is a plain link, not
 * a fetch — the browser streams it to disk, where a fetch would hold the whole
 * file in memory first.
 */
import { ref, computed, watch } from 'vue'
import { api } from '../api.js'

const props = defineProps({ range: { type: Object, required: true } })

const catalog = ref([])
const chosen = ref([])
const preview = ref(null)
const loading = ref(false)
const error = ref('')
const search = ref('')

const filtered = computed(() => {
  const q = search.value.trim().toLowerCase()
  if (!q) return catalog.value
  return catalog.value.filter(
    (m) => m.metric_slug.includes(q) || (m.label || '').toLowerCase().includes(q)
  )
})

const params = computed(() => ({
  metrics: chosen.value.join(','),
  from: props.range.from,
  to: props.range.to,
}))

const downloadUrl = computed(() => api.exportUrl(params.value))

const sizeLabel = computed(() => {
  if (!preview.value) return ''
  const bytes = preview.value.estimated_bytes
  if (bytes > 1024 ** 3) return (bytes / 1024 ** 3).toFixed(1) + ' GB'
  if (bytes > 1024 ** 2) return (bytes / 1024 ** 2).toFixed(1) + ' MB'
  return Math.max(1, Math.round(bytes / 1024)) + ' KB'
})

async function loadCatalog() {
  try {
    catalog.value = (await api.metrics()).metrics
  } catch (e) {
    error.value = e.message
  }
}

async function refreshPreview() {
  loading.value = true
  error.value = ''
  try {
    preview.value = await api.exportSummary(params.value)
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

function toggleAll() {
  chosen.value = chosen.value.length ? [] : catalog.value.map((m) => m.metric_slug)
}

watch([chosen, () => props.range], refreshPreview, { deep: true })
loadCatalog().then(refreshPreview)
</script>

<template>
  <div>
    <section class="card" style="margin-bottom: 16px">
      <h3 class="card-title">Export to CSV</h3>
      <p class="card-sub">
        One row per record, with source and timezone preserved. Leave every metric
        unticked to export all of them.
      </p>

      <div style="display: flex; gap: 8px; align-items: center; margin-bottom: 10px">
        <input v-model="search" type="text" placeholder="filter metrics…" style="width: 200px" />
        <button class="chip" @click="toggleAll">
          {{ chosen.length ? 'Clear selection' : 'Select all' }}
        </button>
        <span class="muted">{{ chosen.length || 'all' }} selected</span>
      </div>

      <div class="checks">
        <label v-for="m in filtered" :key="m.metric_slug">
          <input v-model="chosen" type="checkbox" :value="m.metric_slug" />
          {{ m.label || m.metric_slug }}
          <span class="muted">{{ m.count.toLocaleString() }}</span>
        </label>
      </div>
    </section>

    <section class="card">
      <div :class="{ refreshing: loading }">
        <div class="tile-label">Rows to export</div>
        <div class="tile-value">{{ preview ? preview.rows.toLocaleString() : '—' }}</div>
        <div class="tile-sub">
          {{ range.from }} → {{ range.to }}<span v-if="preview"> · about {{ sizeLabel }}</span>
        </div>
      </div>

      <p v-if="preview?.capped" class="card-sub" style="margin-top: 10px">
        <span class="badge warn">capped</span>
        Only the first {{ preview.max_rows.toLocaleString() }} rows are included.
        Narrow the date range or pick fewer metrics to get everything.
      </p>

      <p v-if="error" class="error">{{ error }}</p>

      <p style="margin: 16px 0 0">
        <a
          class="btn"
          :href="downloadUrl"
          :style="{ pointerEvents: preview && preview.rows ? 'auto' : 'none', opacity: preview && preview.rows ? 1 : 0.45, textDecoration: 'none', display: 'inline-block' }"
          download
        >Download CSV</a>
      </p>
      <p class="muted" style="margin-top: 8px">
        Large exports stream — the file grows as it downloads rather than
        appearing all at once.
      </p>
    </section>
  </div>
</template>
