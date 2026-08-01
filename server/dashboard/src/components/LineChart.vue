<script setup>
/* Single-series time line.
 *
 * Specs held to deliberately: 2px stroke with round joins, a 10%-opacity area
 * wash rather than a saturated block, hairline solid gridlines (never dashed),
 * an end marker ≥8px carrying a 2px surface ring, and direct labels only on the
 * endpoint and the extreme — never a number on every point.
 *
 * The container height includes the x-axis band, so the axis is never cropped
 * into a nested scrollbar.
 */
import { computed, ref } from 'vue'

const props = defineProps({
  points: { type: Array, required: true }, // [{ date, value, source }]
  unit: { type: String, default: '' },
  height: { type: Number, default: 190 },
})

const PAD = { top: 16, right: 52, bottom: 26, left: 46 }
const W = 640

const hover = ref(null)
const svg = ref(null)

const clean = computed(() => props.points.filter((p) => p.value !== null && p.value !== undefined))

const scale = computed(() => {
  const values = clean.value.map((p) => p.value)
  if (!values.length) return null
  let min = Math.min(...values)
  let max = Math.max(...values)
  if (min === max) { min -= 1; max += 1 }
  // A little headroom so the line never touches the frame.
  const pad = (max - min) * 0.12
  min = Math.max(0, min - pad)
  max = max + pad
  const plotW = W - PAD.left - PAD.right
  const plotH = props.height - PAD.top - PAD.bottom
  const n = clean.value.length
  return {
    min, max, plotW, plotH,
    x: (i) => PAD.left + (n <= 1 ? plotW / 2 : (i / (n - 1)) * plotW),
    y: (v) => PAD.top + plotH - ((v - min) / (max - min)) * plotH,
  }
})

const path = computed(() => {
  if (!scale.value) return ''
  return clean.value.map((p, i) => `${i ? 'L' : 'M'}${scale.value.x(i).toFixed(1)},${scale.value.y(p.value).toFixed(1)}`).join(' ')
})

const areaPath = computed(() => {
  if (!scale.value || clean.value.length < 2) return ''
  const base = PAD.top + scale.value.plotH
  return `${path.value} L${scale.value.x(clean.value.length - 1).toFixed(1)},${base} L${scale.value.x(0).toFixed(1)},${base} Z`
})

const ticks = computed(() => {
  if (!scale.value) return []
  const { min, max } = scale.value
  const step = niceStep((max - min) / 3)
  const out = []
  for (let v = Math.ceil(min / step) * step; v <= max; v += step) out.push(v)
  return out
})

function niceStep(raw) {
  const mag = Math.pow(10, Math.floor(Math.log10(Math.abs(raw) || 1)))
  const norm = raw / mag
  return (norm >= 5 ? 5 : norm >= 2 ? 2 : 1) * mag
}

const extreme = computed(() => {
  if (!clean.value.length) return null
  let best = 0
  clean.value.forEach((p, i) => { if (p.value > clean.value[best].value) best = i })
  return best
})

const last = computed(() => (clean.value.length ? clean.value.length - 1 : null))

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

/* Nearest-point lookup rather than per-mark hit areas: on a dense daily series
 * the points are only a few pixels apart, well under any sane hit target. */
function onMove(event) {
  if (!scale.value || !clean.value.length || !svg.value) return
  const rect = svg.value.getBoundingClientRect()
  const x = ((event.clientX - rect.left) / rect.width) * W
  let best = 0
  let bestDist = Infinity
  clean.value.forEach((_, i) => {
    const d = Math.abs(scale.value.x(i) - x)
    if (d < bestDist) { bestDist = d; best = i }
  })
  hover.value = best
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
      <!-- Hairline, solid, recessive. -->
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

      <path v-if="areaPath" :d="areaPath" fill="var(--series-1)" opacity="0.1" />
      <path :d="path" fill="none" stroke="var(--series-1)" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" />

      <!-- Crosshair -->
      <g v-if="hover !== null">
        <line
          :x1="scale.x(hover)" :x2="scale.x(hover)"
          :y1="PAD.top" :y2="PAD.top + scale.plotH"
          stroke="var(--axis)" stroke-width="1"
        />
        <circle
          :cx="scale.x(hover)" :cy="scale.y(clean[hover].value)" r="4.5"
          fill="var(--series-1)" stroke="var(--surface-1)" stroke-width="2"
        />
      </g>

      <!-- End marker: ≥8px diameter, 2px surface ring. -->
      <circle
        v-if="last !== null && hover === null"
        :cx="scale.x(last)" :cy="scale.y(clean[last].value)" r="4.5"
        fill="var(--series-1)" stroke="var(--surface-1)" stroke-width="2"
      />

      <!-- Selective direct labels: the endpoint, and the peak when it is not
           the endpoint. Text wears ink tokens, never the series colour. -->
      <text
        v-if="last !== null"
        :x="scale.x(last) + 8" :y="scale.y(clean[last].value) + 3.5"
        font-size="11" font-weight="600" fill="var(--text-primary)"
      >{{ fmt(clean[last].value) }}</text>
      <text
        v-if="extreme !== null && extreme !== last && clean.length > 4"
        :x="scale.x(extreme)" :y="scale.y(clean[extreme].value) - 9"
        text-anchor="middle" font-size="10" fill="var(--text-secondary)"
      >{{ fmt(clean[extreme].value) }}</text>

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

    <div v-if="hover !== null && scale" class="tip" :style="{ left: `${(scale.x(hover) / W) * 100}%` }">
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
