<script setup>
/* Ask My Health.
 *
 * The layout puts the measured numbers first and the generated prose second,
 * deliberately. The snapshot is what was recorded; the answer is an explanation
 * of it. If the model is asleep on a laptop somewhere — which it will be — the
 * page is still useful, because the part that was measured is still there.
 *
 * The snapshot loads immediately and independently of any question, so the
 * screen is never a bare text box waiting on a model that takes half a minute.
 */
import { computed, onMounted, ref } from 'vue'
import { api } from '../api.js'
import BaselineTile from '../components/BaselineTile.vue'
import InsightAnswer from '../components/InsightAnswer.vue'

const snapshot = ref(null)
const status = ref(null)
const goals = ref([])
const analysable = ref([])

const question = ref('')
const context = ref('')
const remember = ref(true)
const asking = ref(false)
const result = ref(null)
const error = ref('')
const loading = ref(true)

const newGoal = ref({ metric_slug: '', target_value: '' })

/* Starter questions from §10 phase 3. Present because a blank box invites
 * "how am I doing", which is the one question with no good answer. */
const SUGGESTIONS = [
  'How has my sleep changed this month?',
  'Am I becoming more or less active?',
  'Is there enough data to identify a trend?',
  'What are three realistic goals for next week?',
  'Which area should I focus on first?',
]

const qualityBySlug = computed(() =>
  Object.fromEntries((snapshot.value?.data_quality || []).map((q) => [q.metric_slug, q]))
)

const modelReady = computed(() => status.value?.enabled && status.value?.reachable)

async function loadSnapshot() {
  loading.value = true
  try {
    snapshot.value = await api.snapshot()
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

async function loadStatus() {
  try {
    status.value = await api.insightStatus()
  } catch {
    status.value = { enabled: false, reachable: false, detail: 'Could not read model status.' }
  }
}

async function loadGoals() {
  try {
    const body = await api.goals()
    goals.value = body.goals
    analysable.value = body.analysable_metrics
    if (!newGoal.value.metric_slug && analysable.value.length) {
      newGoal.value.metric_slug = analysable.value[0].metric_slug
    }
  } catch { /* goals are optional furniture */ }
}

async function ask(text) {
  const asked = (text ?? question.value).trim()
  if (!asked || asking.value) return
  question.value = asked
  asking.value = true
  error.value = ''
  try {
    result.value = await api.ask({
      question: asked,
      context: context.value,
      remember: remember.value,
    })
  } catch (e) {
    error.value = e.message
  } finally {
    asking.value = false
  }
}

async function weekly() {
  if (asking.value) return
  asking.value = true
  error.value = ''
  try {
    result.value = await api.weeklyReview()
    question.value = ''
  } catch (e) {
    error.value = e.message
  } finally {
    asking.value = false
  }
}

async function saveGoal() {
  const target = Number(newGoal.value.target_value)
  if (!newGoal.value.metric_slug || !Number.isFinite(target) || target <= 0) return
  try {
    await api.saveGoal({ metric_slug: newGoal.value.metric_slug, target_value: target })
    newGoal.value.target_value = ''
    await loadGoals()
  } catch (e) {
    error.value = e.message
  }
}

async function removeGoal(id) {
  try {
    await api.deleteGoal(id)
    await loadGoals()
  } catch (e) {
    error.value = e.message
  }
}

async function forget() {
  if (!window.confirm('Delete every stored question and answer? This cannot be undone.')) return
  try {
    await api.forgetInsights()
    result.value = null
  } catch (e) {
    error.value = e.message
  }
}

onMounted(() => {
  loadSnapshot()
  loadStatus()
  loadGoals()
})
</script>

<template>
  <div class="insights">
    <p v-if="error" class="error">{{ error }}</p>

    <!-- Where the data goes, stated before anything is sent. §8 requires the
         user be told which provider receives it, and "your own laptop over your
         tailnet" and "a company's API" are different promises. -->
    <section v-if="status" class="card privacy" :class="{ off: !modelReady }">
      <div>
        <strong>{{ modelReady ? 'Insights are processed' : 'Insight generation is unavailable' }}
          {{ modelReady ? status.destination?.description : '' }}</strong>
        <p class="muted">
          <template v-if="modelReady">
            {{ status.model }} · questions and answers are deleted after
            {{ status.retention_days }} days · nothing is sent to a third party.
          </template>
          <template v-else>
            {{ status.detail || 'The model server is not reachable.' }}
            The measured analysis below does not need it.
          </template>
        </p>
      </div>
      <button class="linkbtn" @click="forget">Delete stored questions</button>
    </section>

    <!-- Measured first. -->
    <section v-if="snapshot" class="block">
      <div class="block-head">
        <h3>Last 7 days vs your own 28-day baseline</h3>
        <span class="muted">
          through {{ snapshot.as_of }} · today is excluded because it is incomplete
        </span>
      </div>

      <div v-if="!snapshot.metrics.length" class="card empty">
        No analysable metrics have arrived yet. Once the phone uploads steps, sleep,
        or heart rate, comparisons appear here.
      </div>

      <div v-else class="tiles">
        <BaselineTile
          v-for="metric in snapshot.metrics" :key="metric.metric_slug"
          :metric="metric"
          :quality="qualityBySlug[metric.metric_slug]"
        />
      </div>

      <!-- A metric that stopped arriving is a sync problem, not a habit change,
           and it is the failure mode that hides best: nothing errors, the
           numbers just quietly stop. -->
      <div v-if="snapshot.metrics_not_syncing?.length" class="card stale">
        <strong>Not syncing</strong>
        <p v-for="item in snapshot.metrics_not_syncing" :key="item.metric_slug" class="muted">
          {{ item.label }} — last recorded
          {{ item.last_recorded_at ? item.last_recorded_at.slice(0, 10) : 'never' }}<template
            v-if="item.days_since"> ({{ item.days_since }} days ago)</template>.
        </p>
        <p class="muted">
          A gap is not a zero. Check Health permissions for these types, and that the
          phone has synced recently.
        </p>
      </div>

      <p v-if="snapshot.metrics_unavailable.length" class="muted note">
        Not recorded on this phone: {{ snapshot.metrics_unavailable.join(', ') }}.
      </p>
    </section>

    <section v-if="snapshot?.sleep?.nights_recorded" class="card sleep">
      <h3>Sleep pattern</h3>
      <div class="sleep-figures">
        <div><span class="k">Average</span>{{ snapshot.sleep.average_hours }} h</div>
        <div><span class="k">Typical bedtime</span>{{ snapshot.sleep.typical_bedtime }}</div>
        <div><span class="k">Typical wake</span>{{ snapshot.sleep.typical_wake_time }}</div>
        <div>
          <span class="k">Schedule</span>{{ snapshot.sleep.consistency }}
          <em v-if="snapshot.sleep.midpoint_spread_minutes !== null">
            (±{{ snapshot.sleep.midpoint_spread_minutes }} min)
          </em>
        </div>
      </div>
      <p class="muted">
        {{ snapshot.sleep.nights_recorded }} of {{ snapshot.sleep.window_days }} nights recorded.
        Consistency is the spread of the sleep midpoint — when you sleep, not how long.
      </p>
    </section>

    <!-- Then the explanation. -->
    <section class="card ask">
      <h3>Ask about your data</h3>
      <p class="card-sub">
        Answers come from the measured summaries above. This is wellness guidance,
        not medical advice, and it cannot diagnose anything.
      </p>

      <div class="suggestions">
        <button
          v-for="s in SUGGESTIONS" :key="s"
          class="chip" :disabled="asking"
          @click="ask(s)"
        >{{ s }}</button>
      </div>

      <form @submit.prevent="ask()">
        <textarea
          v-model="question"
          rows="2"
          placeholder="e.g. What might be contributing to my tiredness?"
          :disabled="asking"
        />
        <input
          v-model="context"
          type="text"
          placeholder="Optional context — travel, illness, a new routine…"
          :disabled="asking"
        />
        <div class="ask-actions">
          <button class="btn" type="submit" :disabled="asking || !question.trim()">
            {{ asking ? 'Thinking…' : 'Ask' }}
          </button>
          <button class="btn secondary" type="button" :disabled="asking" @click="weekly">
            Weekly review
          </button>
          <label class="remember">
            <input v-model="remember" type="checkbox" />
            Keep this question
          </label>
        </div>
      </form>

      <p v-if="asking" class="muted working">
        Working through the summaries. A local model takes about half a minute.
      </p>
    </section>

    <InsightAnswer v-if="result" :result="result" />

    <!-- Goals last: useful, but not the reason anyone opens this tab. -->
    <section class="card goals">
      <h3>Goals</h3>
      <p class="card-sub">Targets the insight layer counts progress against.</p>

      <div v-if="goals.length" class="goal-list">
        <div v-for="goal in goals" :key="goal.id" class="goal">
          <div class="goal-text">
            <strong>{{ goal.label }}</strong>
            <span class="muted"> ≥ {{ goal.target_value.toLocaleString() }} {{ goal.unit }} {{ goal.cadence }}</span>
            <div v-if="goal.progress" class="muted">
              met {{ goal.progress.days_met }}/{{ goal.progress.days_with_data }} recorded days ·
              streak {{ goal.progress.current_streak_days }} (best {{ goal.progress.longest_streak_days }})
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

    <p v-if="loading" class="muted">Loading your summary…</p>
  </div>
</template>

<style scoped>
.insights { display: flex; flex-direction: column; gap: 20px; }

.privacy { display: flex; align-items: flex-start; gap: 16px; }
.privacy > div { flex: 1; }
.privacy strong { font-size: 13px; }
.privacy p { margin: 4px 0 0; line-height: 1.5; }
.privacy.off { box-shadow: inset 0 0 0 1px var(--status-warning); }

.block-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; margin-bottom: 12px; }
.block-head h3 { font-size: 14px; font-weight: 600; margin: 0; }
.note { margin-top: 10px; }

.stale { margin-top: 14px; box-shadow: inset 0 0 0 1px var(--status-warning); }
.stale strong { font-size: 13px; }
.stale p { margin: 4px 0 0; line-height: 1.5; }

/* Wider than the default KPI row: each tile carries a delta, a meter, and a
   caveat line, and squeezing that into 150px produces four-line wraps. */
.tiles { grid-template-columns: repeat(auto-fit, minmax(215px, 1fr)); margin-bottom: 0; }

.sleep h3, .ask h3, .goals h3 { font-size: 14px; font-weight: 600; margin: 0 0 4px; }
.sleep-figures {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr));
  gap: 12px; margin: 12px 0;
}
.sleep-figures div { font-size: 15px; font-weight: 600; }
.sleep-figures em { font-size: 11px; font-weight: 400; color: var(--text-muted); font-style: normal; }
.k { display: block; font-size: 11px; color: var(--text-muted); font-weight: 400; margin-bottom: 2px; }

.suggestions { display: flex; flex-wrap: wrap; gap: 6px; margin: 12px 0; }
.suggestions .chip { text-align: left; }

textarea, .ask input[type='text'] {
  width: 100%; font-family: inherit; font-size: 13px; padding: 9px 11px;
  border: 1px solid var(--border); border-radius: 8px;
  background: var(--surface-1); color: var(--text-primary); margin-bottom: 8px;
  resize: vertical;
}
.ask-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.remember { font-size: 12px; color: var(--text-secondary); display: inline-flex; align-items: center; gap: 6px; }
.working { margin-top: 10px; }

.goal-list { display: flex; flex-direction: column; gap: 10px; margin: 12px 0; }
/* Flex, not grid. Grid auto-placement put the Remove button ahead of the text
   it belonged to, which read as a button with a stray label beside it. */
.goal {
  display: flex; justify-content: space-between; align-items: flex-start; gap: 12px;
  padding-bottom: 10px; border-bottom: 1px solid var(--gridline); font-size: 13px;
}
.goal:last-child { border-bottom: 0; padding-bottom: 0; }
.goal-text > div { margin-top: 2px; }
.goal-form { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.goal-form input { width: 110px; }
</style>
