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
  <div v-if="turn.role === 'user'" class="row user">
    <div class="bubble user">{{ turn.text }}</div>
  </div>

  <!-- Pending -->
  <div v-else-if="turn.role === 'pending'" class="row">
    <div class="bubble assistant pending">
      <span class="dots"><i /><i /><i /></span>
      Reading your summaries…
    </div>
  </div>

  <!-- Assistant turn -->
  <div v-else class="row">
    <div class="bubble assistant">
      <div v-if="banner" class="banner" :class="safety.level">
        <strong>{{ banner }}</strong>
        <span v-for="r in safety.reasons" :key="r">{{ r }}</span>
      </div>

      <p v-if="turn.result?.error" class="notice">{{ turn.result.error }}</p>

      <template v-if="answer">
        <p class="summary">{{ answer.summary }}</p>

        <ul v-if="answer.observations.length" class="observations">
          <li v-for="(o, i) in answer.observations" :key="i">
            {{ o.statement }}
            <span class="evidence">{{ o.evidence }}</span>
          </li>
        </ul>

        <button v-if="detailCount" class="linkbtn more" @click="showDetail = !showDetail">
          {{ showDetail ? 'Less' : `Suggestions and limits (${detailCount})` }}
        </button>

        <div v-if="showDetail" class="detail">
          <template v-if="answer.actions.length">
            <h4>Try</h4>
            <ul class="actions">
              <li v-for="(a, i) in answer.actions" :key="i">
                {{ a.action }}
                <span class="evidence">{{ a.reason }} · {{ a.timeframe }}</span>
              </li>
            </ul>
          </template>

          <template v-if="answer.limitations.length">
            <h4>Limits</h4>
            <ul class="limits">
              <li v-for="(l, i) in answer.limitations" :key="i">{{ l }}</li>
            </ul>
          </template>
        </div>

        <p v-if="answer.professional_review_recommended" class="review">
          Worth raising with a healthcare professional.
          <span v-if="answer.professional_review_reason">{{ answer.professional_review_reason }}</span>
        </p>
      </template>

      <div class="footer">
        <p class="meta">
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
.row { display: flex; margin-bottom: 14px; }
.row.user { justify-content: flex-end; }

.bubble {
  max-width: 46em;
  padding: 12px 15px;
  border-radius: var(--radius-lg);
  font-size: 14px;
  line-height: 1.55;
}
.bubble.user {
  background: var(--bubble-user);
  border-bottom-right-radius: 5px;
}
.bubble.assistant {
  background: var(--bubble-assistant);
  border: 1px solid var(--border);
  border-bottom-left-radius: 5px;
}

.summary { margin: 0; }

.observations, .actions, .limits { margin: 10px 0 0; padding-left: 17px; }
.observations li, .actions li { margin-bottom: 7px; }
.limits li { margin-bottom: 3px; color: var(--text-secondary); font-size: 13px; }
.evidence {
  display: block;
  font-size: 12px;
  color: var(--text-muted);
  margin-top: 1px;
}

.more { margin-top: 10px; display: inline-block; }
.detail { margin-top: 10px; border-top: 1px solid var(--gridline); padding-top: 10px; }
.detail h4 {
  font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em;
  color: var(--text-muted); margin: 0 0 4px; font-weight: 600;
}
.detail h4 + ul + h4 { margin-top: 12px; }

/* Status colour plus words, never colour alone. */
.banner {
  padding: 9px 11px; border-radius: 9px; margin-bottom: 10px;
  font-size: 13px; line-height: 1.45;
}
.banner strong { display: block; }
.banner span { display: block; color: var(--text-secondary); font-size: 12px; }
.banner.urgent {
  background: color-mix(in srgb, var(--status-critical) 13%, transparent);
  box-shadow: inset 0 0 0 1px var(--status-critical);
}
.banner.review_recommended {
  background: color-mix(in srgb, var(--status-warning) 15%, transparent);
  box-shadow: inset 0 0 0 1px var(--status-warning);
}

.notice { margin: 0 0 8px; font-size: 13px; color: var(--text-secondary); }
.review {
  margin: 10px 0 0; font-size: 12.5px; color: var(--warning-text);
}
.review span { display: block; color: var(--text-secondary); }

.meta { margin: 0; font-size: 11px; color: var(--text-muted); }

.footer {
  display: flex; align-items: center; gap: 10px;
  margin-top: 9px; flex-wrap: wrap;
}
.footer .meta { flex: 1; min-width: 0; }

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

.pending { color: var(--text-secondary); display: flex; align-items: center; gap: 9px; }
.dots { display: inline-flex; gap: 3px; }
.dots i {
  width: 5px; height: 5px; border-radius: 50%;
  background: var(--text-muted); animation: pulse 1.2s infinite ease-in-out;
}
.dots i:nth-child(2) { animation-delay: 0.15s; }
.dots i:nth-child(3) { animation-delay: 0.3s; }
@keyframes pulse {
  0%, 60%, 100% { opacity: 0.25; }
  30% { opacity: 1; }
}
@media (prefers-reduced-motion: reduce) {
  .dots i { animation: none; opacity: 0.6; }
}
</style>
