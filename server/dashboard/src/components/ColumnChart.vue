<script setup>
/* Single-series daily columns, for cumulative metrics (steps, energy).
 *
 * Mark spec: capped at 24px thick so the band always keeps some air, 4px
 * rounded cap at the data end and square at the baseline, and a 2px gap in the
 * surface colour between adjacent bars — the gap does the separating, never a
 * stroke drawn around the bar.
 */
import { computed, ref } from 'vue'

const props = defineProps({
  points: { type: Array, required: true },
  unit: { type: String, default: '' },
  height: { type: Number, default: 190 },
})

const PAD = { top: 18, right: 14, bottom: 26, left: 46 }
const W = 640
const MAX_BAR = 24
const GAP = 2

const hover = ref(null)
const svg = ref(null)

const clean = computed(() => props.points.filter((p) => p.value !== null && p.value !== undefined))

const DAY_MS = 86_400_000

function dayTime(point) {
  return new Date(point.date + 'T00:00:00').getTime()
}

const scale = computed(() => {
  const values = clean.value.map((p) => p.value)
  if (!values.length) return null
  const max = Math.max(...values) * 1.12 || 1
  const plotW = W - PAD.left - PAD.right
  const plotH = props.height - PAD.top - PAD.bottom
  // One band per calendar day in the range, not per data point: a day with no
  // data has to leave a hole rather than let its neighbours close ranks.
  const t0 = dayTime(clean.value[0])
  const days = Math.max(1, Math.round((dayTime(clean.value[clean.value.length - 1]) - t0) / DAY_MS) + 1)
  const band = plotW / days
  const width = Math.max(1, Math.min(MAX_BAR, band - GAP))
  const offset = (i) => Math.round((dayTime(clean.value[i]) - t0) / DAY_MS)
  return {
    max, plotW, plotH, band, width, offset,
    x: (i) => PAD.left + offset(i) * band + (band - width) / 2,
    y: (v) => PAD.top + plotH - (v / max) * plotH,
    h: (v) => Math.max(1, (v / max) * plotH),
  }
})

const ticks = computed(() => {
  if (!scale.value) return []
  const step = niceStep(scale.value.max / 3)
  const out = []
  for (let v = step; v <= scale.value.max; v += step) out.push(v)
  return out
})

function niceStep(raw) {
  const mag = Math.pow(10, Math.floor(Math.log10(Math.abs(raw) || 1)))
  const norm = raw / mag
  return (norm >= 5 ? 5 : norm >= 2 ? 2 : 1) * mag
}

const peak = computed(() => {
  if (!clean.value.length) return null
  let best = 0
  clean.value.forEach((p, i) => { if (p.value > clean.value[best].value) best = i })
  return best
})

/* Rounded at the data end, square at the baseline — a plain rx would round all
 * four corners and lift the bar off its own baseline. */
function barPath(i, value) {
  const s = scale.value
  const x = s.x(i)
  const w = s.width
  const y = s.y(value)
  const h = s.h(value)
  const r = Math.min(4, w / 2, h)
  return `M${x},${y + h} L${x},${y + r} Q${x},${y} ${x + r},${y} L${x + w - r},${y} Q${x + w},${y} ${x + w},${y + r} L${x + w},${y + h} Z`
}

/* Keyboard parity with hover: a value revealed only on mouseover is
 * unreachable for anyone navigating by keyboard, and the tooltip is the
 * highest-resolution reading on the chart. Arrows step, Home/End jump,
 * Escape clears. */
function onKey(event) {
  const n = clean.value.length
  if (!n) return
  const key = event.key
  if (key === 'Escape') { hover.value = null; return }
  let next = hover.value
  if (key === 'ArrowRight') next = next === null ? 0 : Math.min(n - 1, next + 1)
  else if (key === 'ArrowLeft') next = next === null ? n - 1 : Math.max(0, next - 1)
  else if (key === 'Home') next = 0
  else if (key === 'End') next = n - 1
  else return
  event.preventDefault()
  hover.value = next
}

function fmt(v) {
  if (v === null || v === undefined) return '—'
  const abs = Math.abs(v)
  if (abs >= 1_000_000) return (v / 1_000_000).toFixed(1) + 'M'
  if (abs >= 10_000) return (v / 1000).toFixed(1) + 'K'
  if (abs >= 100) return Math.round(v).toLocaleString()
  return Number(v.toFixed(abs < 10 ? 1 : 0)).toLocaleString()
}

const ariaSummary = computed(() => {
  if (!clean.value.length) return 'No data'
  const values = clean.value.map((p) => p.value)
  const min = Math.min(...values)
  const max = Math.max(...values)
  return `${clean.value.length} daily points from ${clean.value[0].date} to `
    + `${clean.value[clean.value.length - 1].date}. Low ${fmt(min)}, high ${fmt(max)}, `
    + `latest ${fmt(values[values.length - 1])} ${props.unit}. `
    + 'Use arrow keys to read individual days.'
})

function shortDate(iso) {
  const d = new Date(iso + 'T00:00:00')
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

/* Band-based hit testing: the target is the whole column slot, not the drawn
 * bar, so a 3px-wide bar is still comfortably hoverable. */
function onMove(event) {
  if (!scale.value || !svg.value) return
  const rect = svg.value.getBoundingClientRect()
  const x = ((event.clientX - rect.left) / rect.width) * W - PAD.left
  const slot = Math.floor(x / scale.value.band)
  // Bands are days now, so find the point sitting on that day — a band with no
  // data simply has no tooltip.
  const found = clean.value.findIndex((_, i) => scale.value.offset(i) === slot)
  hover.value = found >= 0 ? found : null
}
</script>

<template>
  <div class="chart">
    <svg
      v-if="scale"
      ref="svg"
      :viewBox="`0 0 ${W} ${height}`"
      :style="{ height: height + 'px' }"
      role="img"
      tabindex="0"
      :aria-label="ariaSummary"
      @mousemove="onMove"
      @mouseleave="hover = null"
      @keydown="onKey"
      @focus="hover === null && clean.length ? (hover = clean.length - 1) : null"
      @blur="hover = null"
    >
      <g>
        <line
          v-for="t in ticks" :key="'g' + t"
          :x1="PAD.left" :x2="W - PAD.right"
          :y1="scale.y(t)" :y2="scale.y(t)"
          stroke="var(--gridline)" stroke-width="1"
        />
        <text
          v-for="t in ticks" :key="'l' + t"
          :x="PAD.left - 8" :y="scale.y(t) + 3.5"
          text-anchor="end" font-size="10" fill="var(--text-muted)"
          style="font-variant-numeric: tabular-nums"
        >{{ fmt(t) }}</text>
      </g>

      <path
        v-for="(p, i) in clean" :key="p.date"
        :d="barPath(i, p.value)"
        fill="var(--series-1)"
        :opacity="hover === null || hover === i ? 1 : 0.55"
      />

      <!-- One direct label: the peak. A number on every column is unreadable. -->
      <text
        v-if="peak !== null && clean.length > 2"
        :x="scale.x(peak) + scale.width / 2"
        :y="scale.y(clean[peak].value) - 6"
        text-anchor="middle" font-size="10" font-weight="600" fill="var(--text-primary)"
      >{{ fmt(clean[peak].value) }}</text>

      <line
        :x1="PAD.left" :x2="W - PAD.right"
        :y1="PAD.top + scale.plotH" :y2="PAD.top + scale.plotH"
        stroke="var(--axis)" stroke-width="1"
      />
      <text :x="PAD.left" :y="height - 8" font-size="10" fill="var(--text-muted)">
        {{ shortDate(clean[0].date) }}
      </text>
      <text :x="W - PAD.right" :y="height - 8" text-anchor="end" font-size="10" fill="var(--text-muted)">
        {{ shortDate(clean[clean.length - 1].date) }}
      </text>
    </svg>

    <div
      v-if="hover !== null && scale"
      class="tip"
      :style="{ left: `${((scale.x(hover) + scale.width / 2) / W) * 100}%` }"
    >
      <strong>{{ fmt(clean[hover].value) }}</strong> {{ unit }}
      <span>{{ shortDate(clean[hover].date) }}</span>
      <span v-if="clean[hover].source === 'raw_sum'" class="est">estimated</span>
    </div>
  </div>
</template>

<style scoped>
.chart { position: relative; }
svg { width: 100%; display: block; }
.tip {
  position: absolute; top: 0; transform: translateX(-50%);
  background: var(--text-primary); color: var(--surface-1);
  border-radius: 6px; padding: 5px 9px; font-size: 11px;
  pointer-events: none; white-space: nowrap; display: flex; gap: 6px; align-items: baseline;
}
.tip span { opacity: 0.75; }
.tip .est { opacity: 1; font-style: italic; }
</style>
