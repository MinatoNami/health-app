<script setup>
/* One turn in the conversation.
 *
 * The structured insight is rendered *inside* an assistant bubble rather than
 * as its own stack of cards. Same information, but it reads as something that
 * was said in reply to a question instead of a report that happens to sit below
 * a text box — which is what made the old layout feel unrelated to the thing
 * above it.
 *
 * Sections are collapsed by default past the summary and observations. The
 * limitations matter, but printing five of them under every answer buries the
 * answer; behind a one-line toggle they stay one click away.
 */
import { computed, ref } from 'vue'

const props = defineProps({
  turn: { type: Object, required: true },
})

const emit = defineEmits(['rate'])

const showDetail = ref(false)
const noteOpen = ref(false)
const draft = ref('')

/* Only a stored turn can be rated — a rating needs a row to live on, and the
 * turn id only exists once the answer has been persisted. Questions asked with
 * "don't remember this" therefore have no thumbs, which is correct: there is
 * nothing to attach an opinion to. */
const turnId = computed(() => props.turn.result?.turn_id ?? null)
const rating = computed(() => props.turn.result?.rating ?? null)
const note = computed(() => props.turn.result?.note || '')

function rate(value) {
  // A second press on the same thumb clears it. People mis-tap, and a rating
  // you cannot take back is one nobody trusts enough to give.
  emit('rate', turnId.value, { rating: rating.value === value ? null : value })
}

function openNote() {
  draft.value = note.value
  noteOpen.value = true
}

function saveNote() {
  emit('rate', turnId.value, { note: draft.value })
  noteOpen.value = false
}

const answer = computed(() => props.turn.result?.answer)
const safety = computed(() => props.turn.result?.safety || {})
const model = computed(() => props.turn.result?.model)

const LEVEL = {
  urgent: 'Seek medical attention',
  review_recommended: 'Worth a professional review',
}

const banner = computed(() => LEVEL[safety.value.level] || null)
const detailCount = computed(
  () => (answer.value?.actions?.length || 0) + (answer.value?.limitations?.length || 0)
)
</script>

<template>
  <!-- User turn -->
  <div v-if="turn.role === 'user'" class="chat-row user">
    <div class="chat-bubble user">{{ turn.text }}</div>
  </div>

  <!-- Pending -->
  <div v-else-if="turn.role === 'pending'" class="chat-row">
    <div class="chat-bubble assistant typing">
      <span class="typing-dots"><i /><i /><i /></span>
      Reading your summaries…
    </div>
  </div>

  <!-- Assistant turn -->
  <div v-else class="chat-row">
    <div class="chat-bubble assistant">
      <div v-if="banner" class="safety-banner" :class="safety.level">
        <strong>{{ banner }}</strong>
        <span v-for="r in safety.reasons" :key="r">{{ r }}</span>
      </div>

      <p v-if="turn.result?.error" class="answer-notice">{{ turn.result.error }}</p>

      <template v-if="answer">
        <p class="answer-summary">{{ answer.summary }}</p>

        <ul v-if="answer.observations.length" class="answer-list">
          <li v-for="(o, i) in answer.observations" :key="i">
            {{ o.statement }}
            <span class="answer-evidence">{{ o.evidence }}</span>
          </li>
        </ul>

        <button v-if="detailCount" class="linkbtn more" @click="showDetail = !showDetail">
          {{ showDetail ? 'Less' : `Suggestions and limits (${detailCount})` }}
        </button>

        <div v-if="showDetail" class="answer-detail">
          <template v-if="answer.actions.length">
            <h4>Try</h4>
            <ul class="answer-list">
              <li v-for="(a, i) in answer.actions" :key="i">
                {{ a.action }}
                <span class="answer-evidence">{{ a.reason }} · {{ a.timeframe }}</span>
              </li>
            </ul>
          </template>

          <template v-if="answer.limitations.length">
            <h4>Limits</h4>
            <ul class="answer-list limits">
              <li v-for="(l, i) in answer.limitations" :key="i">{{ l }}</li>
            </ul>
          </template>
        </div>

        <p v-if="answer.professional_review_recommended" class="answer-review">
          Worth raising with a healthcare professional.
          <span v-if="answer.professional_review_reason">{{ answer.professional_review_reason }}</span>
        </p>
      </template>

      <div class="footer">
        <p class="answer-meta">
          <template v-if="model">
            {{ (model.latency_ms / 1000).toFixed(0) }}s · {{ model.name }}
          </template>
          <template v-else-if="turn.result?.source === 'safety_rules'">
            Reviewed guidance — no model was consulted.
          </template>
          <template v-else-if="turn.result">No model ran.</template>
        </p>

        <!-- Rating sits with the answer, not in a survey afterwards. The
             judgement is worth most while the answer is still on screen and
             you can still see what it got wrong. -->
        <div v-if="turnId" class="rate">
          <button
            class="thumb" :class="{ on: rating === 1 }"
            :aria-pressed="rating === 1" title="Useful"
            @click="rate(1)"
          >
            <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">
              <path d="M5 14V7l3.5-5c.9 0 1.5.7 1.3 1.6L9.2 6H13c.8 0 1.3.8 1.1 1.5l-1.4 5c-.2.6-.7 1.5-1.5 1.5H5ZM2 7h2v7H2Z"
                    fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" />
            </svg>
          </button>
          <button
            class="thumb" :class="{ on: rating === -1 }"
            :aria-pressed="rating === -1" title="Not useful"
            @click="rate(-1)"
          >
            <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">
              <path d="M11 2v7l-3.5 5c-.9 0-1.5-.7-1.3-1.6L6.8 10H3c-.8 0-1.3-.8-1.1-1.5l1.4-5C3.5 2.9 4 2 4.8 2H11Zm3 0h-2v7h2Z"
                    fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" />
            </svg>
          </button>
          <button class="linkbtn notebtn" @click="openNote">
            {{ note ? 'Edit note' : 'Note' }}
          </button>
        </div>
      </div>

      <p v-if="note && !noteOpen" class="yournote">{{ note }}</p>

      <div v-if="noteOpen" class="noteedit">
        <textarea
          v-model="draft" rows="2" maxlength="2000"
          placeholder="What was wrong or right about this answer?"
        />
        <div class="noteactions">
          <button class="linkbtn" @click="noteOpen = false">Cancel</button>
          <button class="linkbtn" @click="saveNote">Save</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* Only what belongs to a single turn. The bubbles, the banner, the parts of a
   structured answer and the typing dots are shared with InsightsView and live
   in styles/chat.css. */

.more { margin-top: 10px; display: inline-block; }

/* The row under an answer: what produced it on the left, what you made of it
   on the right. */
.footer {
  display: flex; align-items: center; gap: 10px;
  margin-top: 9px; flex-wrap: wrap;
}
.footer .answer-meta { flex: 1; min-width: 0; }

.rate { display: flex; align-items: center; gap: 2px; flex: none; }
.thumb {
  display: grid; place-items: center; width: 24px; height: 24px;
  border: 0; border-radius: 6px; background: none; color: var(--text-muted);
}
.thumb:hover { background: var(--page); color: var(--text-primary); }
/* Colour plus fill, never colour alone — the pressed state is also carried by
   aria-pressed and by the button staying filled. */
.thumb.on { background: var(--accent-soft); color: var(--accent); }
.notebtn { margin-left: 4px; font-size: 11px; }

.yournote {
  margin: 8px 0 0; padding: 7px 10px;
  border-left: 2px solid var(--accent); background: var(--page);
  border-radius: 0 6px 6px 0;
  font-size: 12.5px; line-height: 1.45; color: var(--text-secondary);
}

.noteedit { margin-top: 9px; }
.noteedit textarea {
  width: 100%; font-family: inherit; font-size: 12.5px; line-height: 1.45;
  padding: 7px 9px; border: 1px solid var(--border); border-radius: 8px;
  background: var(--page); color: var(--text-primary); resize: vertical;
}
.noteactions { display: flex; justify-content: flex-end; gap: 12px; margin-top: 6px; }
</style>
