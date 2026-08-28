<script setup>
/* What the record says, before anyone asks it anything.
 *
 * Three endpoints the server has computed on every request for months and the
 * browser has never called: /v1/analysis/correlations, /analysis/patterns and
 * /analysis/anomalies. All three are deterministic — a fixed list of pairs
 * decided in advance, corrected for how many were asked — so this fills in
 * immediately and is still there when the model is asleep on a laptop
 * somewhere, which is the normal case.
 *
 * It lives in the opening state of the conversation rather than on a tab of
 * its own. That is the whole point: the natural next move after reading "sleep
 * was 0.9 hr longer after your hardest days" is to ask about it, and the box to
 * do that is directly below.
 *
 * Everything here is an association. None of it is a cause, the copy says so
 * once at the top rather than hedging every line, and no number on this panel
 * is computed in the browser.
 */
import { onMounted, ref } from 'vue'
import { api } from '../api.js'

const emit = defineEmits(['ask'])

const correlations = ref(null)
const patterns = ref(null)
const anomalies = ref([])
const loading = ref(true)

/* Three independent requests, and one failing must not blank the other two —
 * a correlation report that 500s should cost you the correlations, not the
 * anomalies. Nothing here is worth an error banner either: this whole panel is
 * an extra on a screen that works without it, so a failure is silence. */
onMounted(async () => {
  const settle = (p) => p.catch(() => null)
  const [c, p, a] = await Promise.all([
    settle(api.correlations()),
    settle(api.patterns()),
    settle(api.anomalies()),
  ])
  correlations.value = c
  patterns.value = p
  anomalies.value = a?.anomalies ?? []
  loading.value = false
})

/* The two group means as a pair of bars, scaled against the larger of them
 * rather than zero — these are means of the same measure, and a bar chart
 * anchored at zero for two values 6.5 and 7.4 hours draws a difference nobody
 * can see. Floor of 55% so the shorter bar stays a bar. */
function width(value, other) {
  const top = Math.max(Math.abs(value), Math.abs(other)) || 1
  return `${55 + 45 * (Math.abs(value) / top)}%`
}

const fmt = (v, unit) => (v == null ? '—' : `${v}${unit ? ' ' + unit : ''}`)

/* The lag the pair was tested at, in the words the question is asked in. */
function lag(days) {
  if (!days) return 'same day'
  return days === 1 ? 'next-day lag' : `${days}-day lag`
}
</script>

<template>
  <div v-if="!loading" class="findings">

    <template v-if="correlations?.associations?.length">
      <div class="flabel">Associations</div>
      <p class="fintro">
        Found in your own record over the last {{ correlations.window_days }} days. None of these is
        a cause — they are days that happened to go together.
      </p>

      <div v-for="a in correlations.associations" :key="a.pair" class="finding">
        <div class="fq">{{ a.question }}</div>
        <p class="fdesc">{{ a.description }}</p>

        <div class="fbar">
          <div class="fbar-key">high {{ a.driver.label.toLowerCase() }}</div>
          <div class="fbar-track">
            <div
              class="fbar-fill high"
              :style="{ width: width(a.outcome_on_high_days, a.outcome_on_low_days) }"
            />
          </div>
          <div class="fbar-val">{{ fmt(a.outcome_on_high_days, a.outcome.unit) }}</div>
        </div>
        <div class="fbar">
          <div class="fbar-key">low {{ a.driver.label.toLowerCase() }}</div>
          <div class="fbar-track">
            <div
              class="fbar-fill"
              :style="{ width: width(a.outcome_on_low_days, a.outcome_on_high_days) }"
            />
          </div>
          <div class="fbar-val">{{ fmt(a.outcome_on_low_days, a.outcome.unit) }}</div>
        </div>

        <div class="ffoot">
          <span class="badge">{{ a.group_size * 2 }} days compared</span>
          <span class="badge">{{ lag(a.lag_days) }}</span>
          <span class="spacer" />
          <button class="linkbtn fask" @click="emit('ask', a.question)">Ask about this →</button>
        </div>
      </div>
    </template>

    <!-- A pair that came back empty is a result, not a gap — and saying how
         many were examined is what stops two findings reading as the whole
         truth about a body. -->
    <p v-if="correlations?.pairs_tested" class="fnote">
      {{ correlations.pairs_tested }} pairs examined,
      {{ correlations.associations_found }} worth showing.
      <template v-if="correlations.pairs_skipped">
        {{ correlations.pairs_skipped }} had too few paired days to test.
      </template>
    </p>

    <div v-if="patterns?.patterns?.length || anomalies.length" class="fsplit">
      <div v-if="patterns?.patterns?.length">
        <div class="flabel">Your week</div>
        <p v-for="p in patterns.patterns.slice(0, 2)" :key="p.metric_slug + p.group" class="fdesc">
          {{ p.statement }}
        </p>
      </div>

      <div v-if="anomalies.length">
        <div class="flabel">Worth a look</div>
        <div v-for="a in anomalies.slice(0, 3)" :key="a.metric_slug" class="fanom">
          <div class="fanom-name">{{ a.label }} ran {{ a.direction }} your baseline</div>
          <div class="fanom-val">{{ fmt(a.current, a.unit) }} vs {{ fmt(a.baseline, a.unit) }}</div>
        </div>
        <p class="fnote">
          Flagged by distance from your own baseline, before any model runs. Not a diagnosis, and
          not a reason to wait if something feels wrong.
        </p>
      </div>
    </div>
  </div>
</template>

<style scoped>
.findings { margin-bottom: 18px; }

.flabel {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 11px; font-weight: 600; letter-spacing: 0.09em;
  text-transform: uppercase; color: var(--text-muted);
  margin-bottom: 8px;
}
.fintro { font-size: 12.5px; color: var(--text-muted); margin: 0 0 12px; line-height: 1.5; }

.finding {
  border: 1px solid var(--border); border-radius: var(--radius);
  padding: 14px 16px; margin-bottom: 10px;
}
.fq { font-size: 14.5px; font-weight: 600; letter-spacing: -0.008em; margin-bottom: 4px; }
.fdesc { font-size: 13px; color: var(--text-secondary); line-height: 1.55; margin: 0 0 12px; text-wrap: pretty; }

.fbar { display: flex; align-items: center; gap: 10px; margin-bottom: 5px; }
.fbar:last-of-type { margin-bottom: 0; }
.fbar-key {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 11px; color: var(--text-muted);
  width: 96px; flex-shrink: 0;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.fbar-track { flex: 1; height: 9px; background: var(--page); border-radius: 5px; overflow: hidden; }
.fbar-fill { height: 100%; border-radius: 5px; background: var(--axis); }
/* The driver's high group is the one the question is about; the low group is
   the comparison and stays grey. Two tinted bars would read as two categories
   rather than one contrast. */
.fbar-fill.high { background: var(--series-1); }
.fbar-val {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 12px; font-weight: 600; width: 62px; text-align: right; flex-shrink: 0;
}

.ffoot {
  display: flex; align-items: center; gap: 7px;
  margin-top: 13px; padding-top: 11px; border-top: 1px solid var(--gridline);
}
.fask { color: var(--accent); text-decoration: none; font-size: 12px; }
.fask:hover { text-decoration: underline; color: var(--accent); }

.fnote { font-size: 11.5px; color: var(--text-muted); line-height: 1.5; margin: 10px 0 0; }

.fsplit { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 18px; margin-top: 20px; }

.fanom { margin-bottom: 9px; }
.fanom-name { font-size: 13px; font-weight: 600; margin-bottom: 2px; }
.fanom-val {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 11.5px; color: var(--text-secondary);
}
</style>
