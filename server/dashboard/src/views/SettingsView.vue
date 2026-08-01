<script setup>
/* Where the explanations live.
 *
 * All of this used to sit on the Insights screen, costing a paragraph of
 * reading every visit to say something that only needs saying once. It matters
 * — how the windows are chosen, where health summaries are processed, how long
 * questions are kept — so it is one click away rather than deleted.
 */
import { onMounted, ref } from 'vue'
import { api } from '../api.js'

const status = ref(null)
const goals = ref([])
const analysable = ref([])
const quality = ref([])
const error = ref('')
const newGoal = ref({ metric_slug: '', target_value: '' })

async function load() {
  try {
    status.value = await api.insightStatus()
  } catch {
    status.value = { enabled: false, reachable: false }
  }
  try {
    const body = await api.goals()
    goals.value = body.goals
    analysable.value = body.analysable_metrics
    if (!newGoal.value.metric_slug && analysable.value.length) {
      newGoal.value.metric_slug = analysable.value[0].metric_slug
    }
  } catch (e) { error.value = e.message }
  try {
    quality.value = (await api.quality()).metrics
  } catch { /* optional */ }
}

async function saveGoal() {
  const target = Number(newGoal.value.target_value)
  if (!newGoal.value.metric_slug || !Number.isFinite(target) || target <= 0) return
  try {
    await api.saveGoal({ metric_slug: newGoal.value.metric_slug, target_value: target })
    newGoal.value.target_value = ''
    await load()
  } catch (e) { error.value = e.message }
}

async function removeGoal(id) {
  try { await api.deleteGoal(id); await load() } catch (e) { error.value = e.message }
}

async function forget() {
  if (!window.confirm('Delete every stored question and answer? This cannot be undone.')) return
  try { await api.forgetInsights() } catch (e) { error.value = e.message }
}

onMounted(load)
</script>

<template>
  <div class="settings">
    <p v-if="error" class="error full">{{ error }}</p>

    <!-- Two explicit columns rather than auto-fit: one card here is five times
         the height of the others, and letting the grid place them left a void
         the size of the page. -->
    <div class="col">
    <section class="card">
      <h3>Insights</h3>
      <dl>
        <dt>Processed</dt>
        <dd :class="{ warn: status && !status.reachable }">
          {{ status?.reachable ? status.destination?.description : 'Model unreachable' }}
          <span v-if="status?.detail" class="muted">{{ status.detail }}</span>
        </dd>

        <dt>Model</dt>
        <dd>{{ status?.model || '—' }}</dd>

        <dt>Questions kept</dt>
        <dd>
          {{ status?.retention_days ?? 30 }} days, then deleted
          <button class="linkbtn" @click="forget">Delete now</button>
        </dd>

        <dt>Third parties</dt>
        <dd>None. Nothing leaves your tailnet.</dd>
      </dl>
    </section>

    <section class="card">
      <h3>Goals</h3>
      <div v-if="goals.length" class="goals">
        <div v-for="goal in goals" :key="goal.id" class="goal">
          <div>
            <strong>{{ goal.label }}</strong>
            <span class="muted"> ≥ {{ goal.target_value.toLocaleString() }} {{ goal.unit }} {{ goal.cadence }}</span>
            <div v-if="goal.progress" class="muted">
              {{ goal.progress.days_met }}/{{ goal.progress.days_with_data }} days ·
              streak {{ goal.progress.current_streak_days }}
            </div>
          </div>
          <button class="linkbtn" @click="removeGoal(goal.id)">Remove</button>
        </div>
      </div>
      <p v-else class="muted">No goals set.</p>

      <form class="goal-form" @submit.prevent="saveGoal">
        <select v-model="newGoal.metric_slug">
          <option v-for="m in analysable" :key="m.metric_slug" :value="m.metric_slug">
            {{ m.label }} ({{ m.unit }})
          </option>
        </select>
        <input v-model="newGoal.target_value" type="number" step="any" min="0" placeholder="target" />
        <button class="btn secondary" type="submit">Set goal</button>
      </form>
    </section>

    <section v-if="quality.length" class="card">
      <h3>Data quality</h3>
      <table class="data">
        <thead>
          <tr><th>Metric</th><th>Days</th><th>Quality</th></tr>
        </thead>
        <tbody>
          <tr v-for="q in quality" :key="q.metric_slug">
            <td>{{ q.label }}</td>
            <td>{{ q.valid_days }}/{{ q.window_days }}</td>
            <td>{{ q.quality }}</td>
          </tr>
        </tbody>
      </table>
    </section>
    </div>

    <div class="col">
    <section class="card">
      <h3>How these numbers work</h3>
      <dl>
        <dt>Windows</dt>
        <dd>Last 7 days vs the 28 before. They don't overlap — a week inside its own
          baseline hides the change.</dd>

        <dt>Today</dt>
        <dd>Excluded. Half a day against full-day baselines reads as a collapse that is
          only the clock.</dd>

        <dt>Coverage</dt>
        <dd>Scored against how often a metric is expected. Three weighings a week is
          full coverage for weight.</dd>

        <dt>Estimated</dt>
        <dd>iPhone and Watch both write steps, so a day without Apple's deduplicated
          total can read high. Totals only — averages are unaffected.</dd>

        <dt>Consistency</dt>
        <dd>Spread of your sleep midpoint: when you sleep, not how long.</dd>

        <dt>Escalation</dt>
        <dd>Decided by rules before the model runs. Anything urgent is answered from
          reviewed text, with no model involved.</dd>
      </dl>
    </section>
    </div>
  </div>
</template>

<style scoped>
.settings {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 16px;
  align-items: start;
}
@media (max-width: 820px) { .settings { grid-template-columns: 1fr; } }
.col { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.full { grid-column: 1 / -1; }
.card h3 { font-size: 14px; font-weight: 600; margin: 0 0 12px; }

dl { margin: 0; display: grid; grid-template-columns: minmax(6em, auto) 1fr; gap: 8px 14px; }
dt { font-size: 12px; color: var(--text-muted); }
dd { margin: 0; font-size: 13px; line-height: 1.5; }
dd .muted { display: block; }
dd.warn { color: var(--warning-text); }

.goals { display: flex; flex-direction: column; gap: 9px; margin-bottom: 12px; }
.goal {
  display: flex; justify-content: space-between; align-items: flex-start; gap: 12px;
  font-size: 13px; padding-bottom: 9px; border-bottom: 1px solid var(--gridline);
}
.goal:last-child { border-bottom: 0; padding-bottom: 0; }
.goal-form { display: flex; gap: 8px; flex-wrap: wrap; }
.goal-form input { width: 100px; }
</style>
