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

const showDetail = ref(false)

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

      <p class="meta">
        <template v-if="model">
          {{ (model.latency_ms / 1000).toFixed(0) }}s · {{ model.name }}
        </template>
        <template v-else-if="turn.result?.source === 'safety_rules'">
          Reviewed guidance — no model was consulted.
        </template>
        <template v-else-if="turn.result">No model ran.</template>
      </p>
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

.meta { margin: 9px 0 0; font-size: 11px; color: var(--text-muted); }

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
