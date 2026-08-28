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
 * its own: the natural move after reading a finding is to ask about it, and the
 * box to do that is directly below.
 *
 * The order here was decided by running it against a real record rather than a
 * fixture. Weekly patterns lead because they are what actually turns up;
 * associations come second and only when there are any — on 90 days of real
 * data, ten pairs were tested and none survived correction. An empty panel
 * where the headline used to be is what that first draft produced.
 */
import { computed, onMounted, ref } from 'vue'
import { api } from '../api.js'
import { withUnit } from '../format.js'

const emit = defineEmits(['ask'])

const correlations = ref(null)
const patterns = ref(null)
const anomalies = ref([])
const loading = ref(true)
const showExamined = ref(false)

/* Three independent requests, and one failing must not blank the other two —
 * a correlation report that 500s should cost you the correlations, not the
 * patterns. Nothing here is worth an error banner either: this whole panel is
 * an extra on a screen that works without it, so a failure is silence. */
onMounted(async () => {
  const settle = (r) => r.catch(() => null)
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

const found = computed(() => correlations.value?.associations ?? [])
const week = computed(() => patterns.value?.patterns ?? [])

/* Everything that was looked at and came back with nothing. A pair that was
 * tested and found nothing is a result about a body; a pair that could not be
 * tested is a gap in the record, and the server says which in a sentence. Both
 * were being thrown away by rendering only the winners. */
const tested = computed(() =>
  (correlations.value?.all_pairs ?? []).filter((p) => p.testable && !p.significant),
)
const skipped = computed(() => (correlations.value?.all_pairs ?? []).filter((p) => !p.testable))

const num = (v) => (v == null ? '—' : Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 }))

/* The two group means as a pair of bars, scaled against the larger of them
 * rather than zero — these are means of the same measure, and a bar anchored at
 * zero for 6.5 against 7.4 hours draws a difference nobody can see. Floor of
 * 55% so the shorter bar stays a bar. */
function width(value, other) {
  const top = Math.max(Math.abs(value ?? 0), Math.abs(other ?? 0)) || 1
  return `${55 + 45 * (Math.abs(value ?? 0) / top)}%`
}

function lag(days) {
  if (!days) return 'same day'
  return days === 1 ? 'next-day lag' : `${days}-day lag`
}

/* Composed from the pattern's own numbers rather than printing its `statement`.
 * That field is written for the model's prompt and says "this person's own
 * day-to-day variation" — third person, correct where it is used, and odd on a
 * screen addressed to the person. Nothing is recalculated here: every figure
 * below is a field of the payload. */
function weekLine(p) {
  const v = (n) => withUnit(num(n), p.metric_slug, p.unit)
  return `${p.label} on ${p.group} averages ${v(p.group_mean)}, ${v(Math.abs(p.difference))} ${p.direction} than the rest of the week (${v(p.rest_mean)}), across ${p.observations} of them.`
}
</script>

<template>
  <div v-if="!loading && (week.length || found.length || anomalies.length || tested.length || skipped.length)" class="findings">

    <!-- Weekly rhythms first. On a real record this is the section with
         something in it. -->
    <template v-if="week.length">
      <div class="flabel">Your week</div>
      <div v-for="p in week" :key="p.metric_slug + p.group" class="finding">
        <p class="fdesc">{{ weekLine(p) }}</p>
        <div class="ffoot">
          <span class="badge">{{ p.significance }}</span>
          <span class="fnote-inline">against your own day-to-day variation</span>
          <span class="spacer" />
          <button class="linkbtn fask" @click="emit('ask', `Why are my ${p.label.toLowerCase()} lower on ${p.group}?`)">
            Ask about this →
          </button>
        </div>
      </div>
    </template>

    <!-- Only when there are any. -->
    <template v-if="found.length">
      <div class="flabel spaced">Associations</div>
      <p class="fintro">
        Found over the last {{ correlations.window_days }} days. None of these is a cause — they are
        days that happened to go together.
      </p>

      <div v-for="a in found" :key="a.pair" class="finding">
        <div class="fq">{{ a.question }}</div>
        <!-- `contrast`, not the association itself. The two group means and the
             written description are nested there; reading them off the top
             level rendered empty bars and no sentence, and with no association
             to show it never looked wrong. -->
        <p v-if="a.contrast" class="fdesc">{{ a.contrast.description }}</p>

        <template v-if="a.contrast">
          <div class="fbar">
            <div class="fbar-key">high {{ a.driver.label.toLowerCase() }}</div>
            <div class="fbar-track">
              <div
                class="fbar-fill high"
                :style="{ width: width(a.contrast.outcome_on_high_days, a.contrast.outcome_on_low_days) }"
              />
            </div>
            <div class="fbar-val">{{ withUnit(num(a.contrast.outcome_on_high_days), null, a.outcome.unit) }}</div>
          </div>
          <div class="fbar">
            <div class="fbar-key">low {{ a.driver.label.toLowerCase() }}</div>
            <div class="fbar-track">
              <div
                class="fbar-fill"
                :style="{ width: width(a.contrast.outcome_on_low_days, a.contrast.outcome_on_high_days) }"
              />
            </div>
            <div class="fbar-val">{{ withUnit(num(a.contrast.outcome_on_low_days), null, a.outcome.unit) }}</div>
          </div>
        </template>

        <div class="ffoot">
          <span class="badge">{{ a.paired_points }} {{ a.point_unit }} compared</span>
          <span class="badge">{{ lag(a.lag_days) }}</span>
          <span class="spacer" />
          <button class="linkbtn fask" @click="emit('ask', a.question)">Ask about this →</button>
        </div>

        <!-- The server writes these. An association with no note about what
             else could explain it is the half of the finding that misleads. -->
        <ul v-if="a.confounders?.length" class="fconf">
          <li v-for="c in a.confounders" :key="c">{{ c }}</li>
        </ul>
      </div>
    </template>

    <div v-if="anomalies.length" class="fsection">
      <div class="flabel">Worth a look</div>
      <div v-for="a in anomalies.slice(0, 3)" :key="a.metric_slug" class="fanom">
        <div class="fanom-name">{{ a.label }} ran {{ a.direction }} your baseline</div>
        <div class="fanom-val">{{ num(a.current) }} vs {{ withUnit(num(a.baseline), a.metric_slug, a.unit) }}</div>
      </div>
      <p class="fnote">
        Flagged by distance from your own baseline, before any model runs. Not a diagnosis, and not
        a reason to wait if something feels wrong.
      </p>
    </div>

    <!-- What was examined, whether or not it found anything.
         Ten pairs tested and none significant is a genuine result about a body,
         and rendering only the winners threw it away — leaving a reader unable
         to tell "nothing was found" from "nothing was looked for". -->
    <div v-if="tested.length || skipped.length" class="fsection">
      <p class="fnote">
        <template v-if="correlations.pairs_tested">
          {{ correlations.pairs_tested }} pairs tested over {{ correlations.window_days }} days,
          <template v-if="!correlations.associations_found">
            none significant after correcting for how many were asked.
          </template>
          <template v-else>{{ correlations.associations_found }} significant.</template>
        </template>
        <template v-if="skipped.length">
          {{ skipped.length }} could not be tested.
        </template>
        <button class="linkbtn" @click="showExamined = !showExamined">
          {{ showExamined ? 'Hide' : 'Show what was examined' }}
        </button>
      </p>

      <div v-if="showExamined" class="fexam">
        <div v-for="p in tested" :key="p.pair" class="fexam-row">
          <span class="fexam-q">{{ p.question }}</span>
          <span class="fexam-v">{{ p.strength }} · {{ p.paired_points }} {{ p.point_unit }}</span>
        </div>
        <!-- The reason is the actionable half: "only 0 days have both logged
             caffeine and sleep recorded" tells you what to start logging. -->
        <div v-for="p in skipped" :key="p.pair" class="fexam-row skipped">
          <span class="fexam-q">{{ p.question }}</span>
          <span class="fexam-why">{{ p.reason }}</span>
        </div>
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
.flabel.spaced { margin-top: 20px; }
.fintro { font-size: 12.5px; color: var(--text-muted); margin: 0 0 12px; line-height: 1.5; }

.finding {
  border: 1px solid var(--border); border-radius: var(--radius);
  padding: 14px 16px; margin-bottom: 10px;
}
.fq { font-size: 14.5px; font-weight: 600; letter-spacing: -0.008em; margin-bottom: 4px; }
.fdesc { font-size: 13.5px; color: var(--text-secondary); line-height: 1.55; margin: 0; text-wrap: pretty; }
.finding .fdesc + .fbar { margin-top: 12px; }

.fbar { display: flex; align-items: center; gap: 10px; margin-bottom: 5px; }
.fbar-key {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 11px; color: var(--text-muted);
  width: 96px; flex-shrink: 0;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.fbar-track { flex: 1; height: 9px; background: var(--page); border-radius: 5px; overflow: hidden; }
.fbar-fill { height: 100%; border-radius: 5px; background: var(--axis); }
/* The high group is what the question is about; the low group is the
   comparison and stays grey. Two tinted bars read as two categories rather
   than one contrast. */
.fbar-fill.high { background: var(--series-1); }
.fbar-val {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 12px; font-weight: 600; width: 74px; text-align: right; flex-shrink: 0;
}

.ffoot {
  display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
  margin-top: 13px; padding-top: 11px; border-top: 1px solid var(--gridline);
}
.fnote-inline { font-size: 11.5px; color: var(--text-muted); }
.fask { color: var(--accent); text-decoration: none; font-size: 12px; }
.fask:hover { text-decoration: underline; color: var(--accent); }

.fconf { margin: 10px 0 0; padding-left: 16px; }
.fconf li { font-size: 11.5px; color: var(--text-muted); line-height: 1.5; }

.fsection { margin-top: 20px; }
.fnote { font-size: 11.5px; color: var(--text-muted); line-height: 1.6; margin: 0; }
.fnote .linkbtn { margin-left: 4px; }

.fexam { margin-top: 10px; border-top: 1px solid var(--gridline); }
.fexam-row {
  display: flex; align-items: baseline; gap: 12px;
  padding: 7px 0; border-bottom: 1px solid var(--gridline);
}
.fexam-q { flex: 1; font-size: 12.5px; color: var(--text-secondary); }
.fexam-v {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 11px; color: var(--text-muted); flex-shrink: 0;
}
.fexam-why { font-size: 11.5px; color: var(--warning-text); max-width: 46%; text-align: right; }

.fanom { margin-bottom: 9px; }
.fanom-name { font-size: 13px; font-weight: 600; margin-bottom: 2px; }
.fanom-val {
  font-family: 'IBM Plex Mono', ui-monospace, Menlo, monospace;
  font-size: 11.5px; color: var(--text-secondary);
}
</style>
