<script setup>
/* What the week did, then the range you chose to look at.
 *
 * The old order led with "Records in range — 47,213". That is a property of the
 * database rather than of the person: it answers "did the pipeline run", which
 * is a question with its own screen. Whoop and Oura both compress the top of a
 * health screen to one thing that answers the reader's actual question, and the
 * server has been writing exactly that sentence for the phone's morning
 * notification the whole time.
 *
 * The page is now in two halves, and the filter row sits between them rather
 * than above everything:
 *
 *   fixed    — the lead, what moved, what held steady. Read from the snapshot,
 *              whose windows are 7 days against the preceding 28 and are not
 *              negotiable. A range control above these did nothing to them.
 *   ranged   — the charts, which are what the range actually scopes.
 *
 * The filter row arrives through the `filters` slot so App.vue keeps owning
 * the range and this view only decides where it goes.
 */
import { computed, onMounted, ref } from 'vue'
import ChartCard from '../components/ChartCard.vue'
import CoverageStrip from '../components/CoverageStrip.vue'
import { api } from '../api.js'
import { shortLabel, unitFor } from '../format.js'

const props = defineProps({
  data: { type: Object, default: null },
  refreshing: { type: Boolean, default: false },
})

const snapshot = ref(null)
const brief = ref(null)

/* Both deterministic and both cheap — no model runs to serve either, which is
 * why the top of the page can depend on them. Settled independently: a missing
 * brief should cost the sentence, not the tiles. */
onMounted(async () => {
  const settle = (p) => p.catch(() => null)
  const [s, b] = await Promise.all([settle(api.snapshot()), settle(api.dailyBrief())])
  snapshot.value = s
  brief.value = b
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
const short = (m) => shortLabel(m.metric_slug, m.label)
const unit = (m) => unitFor(m.metric_slug, m.unit)

const summary = computed(() => props.data?.summary ?? {})

const usable = computed(() =>
  (snapshot.value?.metrics ?? []).filter((m) => m.confidence !== 'insufficient'),
)
const moved = computed(() => usable.value.filter((m) => m.significance === 'notable').slice(0, 3))
const steady = computed(() => usable.value.filter((m) => m.significance !== 'notable'))
const stale = computed(() => snapshot.value?.metrics_not_syncing ?? [])

/* The lead. The brief's headline if the server wrote one, else the snapshot's
 * own account of the week — never a sentence assembled here beyond naming what
 * moved, because a paragraph composed in the browser is one more place the
 * numbers can drift from the ones the model was given. */
const lead = computed(() => {
  if (brief.value?.headline) return brief.value.headline
  if (!snapshot.value) return null
  if (!moved.value.length) return 'Nothing moved much against your 28-day baseline this week.'
  const names = moved.value.map((m) => short(m))
  return `Against your 28-day baseline, ${names.join(', ')} moved this week.`
})
const detail = computed(() => brief.value?.detail || '')

/* Coverage for the lead: the weakest evidence behind the sentence above it.
 *
 * Two corrections to the obvious version, both of which it got wrong first.
 * It must be scoped to the metrics that MOVED, because those are what the
 * sentence claims — a headline about sleep sat beside "3 of 7 days measured"
 * borrowed from weight, which is in the steady row and not mentioned. And the
 * comparison is on `coverage`, not on raw valid_days: the server scores
 * coverage against how often a metric is *expected*, so three weighings a week
 * is full coverage for weight and comparing its 3 against sleep's 7 is
 * comparing incomparable things. */
const leadCoverage = computed(() => {
  const pool = (moved.value.length ? moved.value : usable.value)
    .map((m) => m.current)
    .filter((c) => c?.window_days)
  if (!pool.length) return null
  return pool.reduce((worst, c) => ((c.coverage ?? 1) < (worst.coverage ?? 1) ? c : worst))
})

const tone = (m) => (m.tone === 'good' ? 'good' : m.tone === 'watch' ? 'watch' : 'none')

function delta(m) {
  if (m.change_pct == null) return '—'
  if (Math.abs(m.change_pct) < 0.5) return '±0%'
  return `${m.change_pct > 0 ? '+' : '−'}${Math.abs(m.change_pct).toFixed(0)}%`
}

function fmt(v) {
  if (v == null) return '—'
  const size = Math.abs(v)
  if (size >= 10_000) return (v / 1000).toFixed(1) + 'k'
  if (size >= 100) return v.toFixed(0)
  return v.toFixed(size < 10 ? 1 : 0)
}

function fmtCompact(v) {
  if (v === null || v === undefined) return '—'
  if (v >= 1_000_000) return (v / 1_000_000).toFixed(2) + 'M'
  if (v >= 10_000) return (v / 1000).toFixed(1) + 'K'
  return v.toLocaleString()
}
</script>

<template>
  <div>
    <!-- ── Fixed window: 7 days against the preceding 28 ──────────────── -->
    <section v-if="snapshot" class="card lead">
      <div class="lead-main">
        <div class="seclabel">This week</div>
        <p class="lead-line">{{ lead }}</p>
        <p v-if="detail" class="lead-detail">{{ detail }}</p>
      </div>

      <div v-if="leadCoverage" class="lead-cov">
        <div class="seclabel">Coverage</div>
        <CoverageStrip
          :valid-days="leadCoverage.valid_days"
          :window-days="leadCoverage.window_days"
          :thickness="5"
        />
        <div class="cov-count">
          {{ leadCoverage.valid_days }} of {{ leadCoverage.window_days }} days measured
        </div>
        <p v-if="stale.length" class="cov-stale">
          {{ stale.map((s) => s.label).join(', ') }}
          stopped arriving and {{ stale.length === 1 ? 'is' : 'are' }} left out — a gap, not a zero.
        </p>
      </div>
    </section>

    <template v-if="moved.length">
      <div class="seclabel">What moved</div>
      <div class="tiles moved-tiles">
        <div v-for="m in moved" :key="m.metric_slug" class="tile">
          <div class="tile-head">
            <span class="tile-label">{{ short(m) }}</span>
            <span class="delta" :class="tone(m)">{{ delta(m) }}</span>
          </div>
          <div class="tile-value">
            {{ fmt(m.current.value) }}<span v-if="unit(m)" class="tile-unit">{{ unit(m) }}</span>
          </div>
          <div class="tile-sub">28-day baseline {{ fmt(m.baseline.value) }} {{ unit(m) }}</div>
          <CoverageStrip
            class="tile-cov"
            :valid-days="m.current.valid_days"
            :window-days="m.current.window_days"
            :thickness="4"
          />
        </div>
      </div>
    </template>

    <!-- One quiet row rather than four more cards. A metric that did not move
         is worth confirming and not worth a tile. -->
    <div v-if="steady.length" class="card steady">
      <span class="seclabel">Steady</span>
      <span v-for="m in steady" :key="m.metric_slug" class="steady-item">
        {{ short(m) }} {{ fmt(m.current.value) }} {{ unit(m) }}
      </span>
      <span class="spacer" />
      <span class="muted">within day-to-day variation</span>
    </div>

    <!-- ── Ranged: everything below answers to the row above it ────────── -->
    <slot name="filters" />

    <div v-if="data">
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

      <!-- The row count kept, at the bottom, at its real size. It answers "did
           the pipeline run", which is worth being able to check and was never
           worth the largest number on the page. -->
      <p class="rowcount muted">
        {{ fmtCompact(summary.records_in_range) }} records in range ·
        {{ data.from }} → {{ data.to }} ·
        {{ summary.metrics_seen }} metric types · {{ data.available_metrics }} tracked overall
      </p>
    </div>
  </div>
</template>

<style scoped>
.seclabel {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 11px; font-weight: 600; letter-spacing: 0.09em;
  text-transform: uppercase; color: var(--text-muted);
  margin-bottom: 10px;
}

.lead { display: flex; gap: 32px; align-items: flex-start; padding: 22px 24px; margin-bottom: 20px; }
.lead-main { flex: 1; }
.lead-line {
  font-size: 26px; font-weight: 650; letter-spacing: -0.022em;
  line-height: 1.26; margin: 0; text-wrap: pretty;
}
.lead-detail { font-size: 13px; color: var(--text-secondary); line-height: 1.5; margin: 12px 0 0; }

.lead-cov { width: 230px; flex-shrink: 0; border-left: 1px solid var(--gridline); padding-left: 24px; }
.cov-count {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 12px; color: var(--text-secondary); margin-top: 9px;
}
.cov-stale { font-size: 12px; color: var(--text-muted); line-height: 1.45; margin: 12px 0 0; }

/* Capped and left-aligned. `.tiles` is auto-fit with 1fr, so on a week where
   one metric moved — which the real record says is the common case — the single
   tile stretched the full width of the page and read as a banner. */
.moved-tiles { grid-template-columns: repeat(auto-fit, minmax(210px, 300px)); justify-content: start; }

.tile-head { display: flex; align-items: baseline; gap: 8px; margin-bottom: 8px; }
.tile-head .tile-label { flex: 1; margin-bottom: 0; }
.tile-cov { margin-top: 12px; }

.steady {
  display: flex; align-items: center; flex-wrap: wrap; gap: 14px;
  padding: 13px 18px; margin-bottom: 22px;
}
.steady .seclabel { margin-bottom: 0; }
.steady-item { font-size: 13px; color: var(--text-secondary); }

.rowcount { margin-top: 18px; }

@media (max-width: 720px) {
  .lead { flex-direction: column; gap: 20px; }
  .lead-cov { width: 100%; border-left: 0; border-top: 1px solid var(--gridline); padding: 18px 0 0; }
  .lead-line { font-size: 22px; }
}
</style>
