<script setup>
/* Ask My Health, as a conversation.
 *
 * The previous layout stacked a privacy notice, six tiles, a sleep card, a text
 * box, an answer and a goals form down one column. Everything was present and
 * nothing was in a relationship with anything else — the answer appeared below
 * the question box and pushed the goals form down, which reads as a report that
 * happens to sit near a form.
 *
 * A transcript fixes that for free: turns are ordered, the question stays next
 * to its answer, and follow-ups have somewhere obvious to go. The measured
 * numbers move beside the conversation, because they are what the answers are
 * built from and should stay in view while you read one.
 *
 * Everything explanatory — how the windows are chosen, where processing
 * happens, goals, retention — moved to Settings. It is read once; it was
 * costing a paragraph a day here.
 */
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { api } from '../api.js'
import ChatMessage from '../components/ChatMessage.vue'
import ContextRail from '../components/ContextRail.vue'

const snapshot = ref(null)
const status = ref(null)
const turns = ref([])
const question = ref('')
const asking = ref(false)
const error = ref('')
const transcript = ref(null)

/* Short on purpose. Full sentences on five chips was a paragraph of its own. */
const SUGGESTIONS = [
  'How is my sleep?',
  'Am I more active?',
  'Enough data to see a trend?',
  'What should I focus on?',
]

const ready = computed(() => status.value?.enabled && status.value?.reachable)

/* The transcript opens with the measured week rather than an empty panel, so
 * the screen says something true before any model has run. */
const opening = computed(() => {
  if (!snapshot.value) return null
  const moved = snapshot.value.metrics
    .filter((m) => m.significance === 'notable' && m.confidence !== 'insufficient')
    .map((m) => `${m.label.toLowerCase()} ${m.change > 0 ? 'up' : 'down'} ${Math.abs(m.change_pct).toFixed(0)}%`)
  const stale = snapshot.value.metrics_not_syncing || []
  const parts = []
  parts.push(moved.length ? `Against your 28-day baseline: ${moved.join(', ')}.` : 'Nothing moved much against your baseline this week.')
  if (stale.length) {
    parts.push(`${stale.map((s) => s.label).join(' and ')} stopped arriving — a gap, not a zero.`)
  }
  return parts.join(' ')
})

async function scrollDown() {
  await nextTick()
  const el = transcript.value
  if (el) el.scrollTop = el.scrollHeight
}

async function load() {
  try {
    snapshot.value = await api.snapshot()
  } catch (e) {
    error.value = e.message
  }
  try {
    status.value = await api.insightStatus()
  } catch {
    status.value = { enabled: false, reachable: false }
  }
}

async function ask(text) {
  const asked = (text ?? question.value).trim()
  if (!asked || asking.value) return

  question.value = ''
  error.value = ''
  turns.value.push({ role: 'user', text: asked })
  // Any turn after the first is a follow-up: the transcript is visibly a
  // conversation, so behaving like one is the only consistent option.
  const isFollowUp = turns.value.some((t) => t.role === 'assistant')
  turns.value.push({ role: 'pending' })
  asking.value = true
  scrollDown()

  try {
    const result = await api.ask({ question: asked, follow_up: isFollowUp })
    turns.value.splice(-1, 1, { role: 'assistant', result })
  } catch (e) {
    turns.value.splice(-1, 1)
    error.value = e.message
  } finally {
    asking.value = false
    scrollDown()
  }
}

async function weekly() {
  if (asking.value) return
  turns.value.push({ role: 'user', text: 'Weekly review' })
  turns.value.push({ role: 'pending' })
  asking.value = true
  scrollDown()
  try {
    turns.value.splice(-1, 1, { role: 'assistant', result: await api.weeklyReview() })
  } catch (e) {
    turns.value.splice(-1, 1)
    error.value = e.message
  } finally {
    asking.value = false
    scrollDown()
  }
}

/* Enter sends, Shift+Enter breaks the line — the convention every chat box
 * shares, and the one people try first. */
function onKey(event) {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault()
    ask()
  }
}

watch(turns, scrollDown, { deep: true })
onMounted(load)
</script>

<template>
  <div class="insights">
    <section class="chat">
      <div ref="transcript" class="transcript">
        <!-- margin-top:auto on this wrapper is what makes a short conversation
             sit against the composer instead of stranded at the top of an empty
             panel. `justify-content: flex-end` on the scroller itself would do
             the same until the content overflows, at which point it clips the
             oldest messages out of reach. -->
        <div class="messages">
        <div v-if="opening" class="row">
          <div class="bubble assistant opening">{{ opening }}</div>
        </div>

        <ChatMessage v-for="(turn, i) in turns" :key="i" :turn="turn" />

        <p v-if="error" class="error">{{ error }}</p>

        <p v-if="!ready && status" class="offline">
          The model is unreachable, so answers are unavailable. The measured
          numbers alongside do not need it.
        </p>
        </div>
      </div>

      <div class="composer">
        <div class="chips">
          <button
            v-for="s in SUGGESTIONS" :key="s"
            class="chip" :disabled="asking || !ready"
            @click="ask(s)"
          >{{ s }}</button>
          <button class="chip" :disabled="asking || !ready" @click="weekly">Weekly review</button>
        </div>

        <form @submit.prevent="ask()">
          <textarea
            v-model="question"
            rows="1"
            placeholder="Ask about your health data…"
            :disabled="asking || !ready"
            @keydown="onKey"
          />
          <button class="send" type="submit" :disabled="asking || !question.trim() || !ready" aria-label="Send">
            <svg viewBox="0 0 20 20" width="17" height="17" aria-hidden="true">
              <path d="M2 10 L18 3 L11 18 L9.5 11.5 Z" fill="currentColor" />
            </svg>
          </button>
        </form>
        <p class="disclaimer">Wellness guidance from your own data. Not medical advice.</p>
      </div>
    </section>

    <ContextRail :snapshot="snapshot" />
  </div>
</template>

<style scoped>
/* Conversation leads, context follows. Below 940px the rail drops underneath
   rather than squeezing — a 200px column of numbers is unreadable. */
.insights {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 260px;
  gap: 18px;
  align-items: start;
}
@media (max-width: 940px) {
  .insights { grid-template-columns: 1fr; }
}

.chat {
  display: flex;
  flex-direction: column;
  background: var(--page);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  overflow: hidden;
  /* Tall enough that the composer sits at a predictable place rather than
     wandering up and down as the transcript grows. */
  height: calc(100vh - 190px);
  min-height: 420px;
}

.transcript {
  flex: 1; overflow-y: auto; padding: 18px 18px 6px; scroll-behavior: smooth;
  display: flex; flex-direction: column;
}
.messages { margin-top: auto; }
@media (prefers-reduced-motion: reduce) { .transcript { scroll-behavior: auto; } }

.row { display: flex; margin-bottom: 14px; }
.bubble {
  max-width: 46em; padding: 12px 15px; border-radius: var(--radius-lg);
  font-size: 14px; line-height: 1.55;
}
.bubble.assistant {
  background: var(--surface-1); border: 1px solid var(--border);
  border-bottom-left-radius: 5px;
}
.opening { color: var(--text-secondary); }

.composer { border-top: 1px solid var(--border); background: var(--surface-1); padding: 11px 14px 12px; }

.chips { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 9px; }

form { display: flex; gap: 8px; align-items: flex-end; }
textarea {
  flex: 1; font-family: inherit; font-size: 14px; line-height: 1.45;
  padding: 9px 12px; border: 1px solid var(--border); border-radius: 11px;
  background: var(--page); color: var(--text-primary);
  resize: none; min-height: 40px; max-height: 140px; field-sizing: content;
}
textarea:focus-visible { outline: 2px solid var(--accent); outline-offset: -1px; }

.send {
  display: grid; place-items: center; width: 40px; height: 40px; flex: none;
  border: 0; border-radius: 11px;
  background: var(--accent); color: #fff;
}
.send:disabled { opacity: 0.35; cursor: not-allowed; }

.disclaimer { margin: 8px 0 0; font-size: 11px; color: var(--text-muted); }
.offline { font-size: 13px; color: var(--warning-text); }
</style>
