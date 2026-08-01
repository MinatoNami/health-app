<script setup>
/* The structured insight, rendered as the three categories §6 asks the UI to
 * keep separate: what the data shows, what to try, and when a clinician is the
 * right answer instead.
 *
 * The separation is visual, not just semantic. An observation and a suggestion
 * that look alike get read as equally evidenced, and only one of them is.
 *
 * Every branch here is reachable in normal use — a blocked answer, an
 * unreachable model, an urgent escalation — so none of them is an error state.
 * The measured numbers are always shown regardless, by the parent.
 */
import { computed } from 'vue'

const props = defineProps({
  result: { type: Object, required: true },
})

const answer = computed(() => props.result.answer)
const safety = computed(() => props.result.safety || {})
const model = computed(() => props.result.model)

const LEVEL_COPY = {
  urgent: 'Seek medical attention',
  review_recommended: 'Worth a professional review',
  coaching: 'Wellness coaching',
  informational: 'Informational',
}

const showBanner = computed(() =>
  ['urgent', 'review_recommended'].includes(safety.value.level)
)
</script>

<template>
  <section class="card answer">
    <!-- The escalation banner is decided by rules before the model runs, so it
         is present whether or not anything was generated. -->
    <div v-if="showBanner" class="banner" :class="safety.level">
      <strong>{{ LEVEL_COPY[safety.level] }}</strong>
      <ul v-if="safety.reasons?.length">
        <li v-for="reason in safety.reasons" :key="reason">{{ reason }}</li>
      </ul>
    </div>

    <div v-if="result.error" class="notice">
      {{ result.error }}
    </div>

    <template v-if="answer">
      <p class="summary">{{ answer.summary }}</p>
      <p v-if="answer.period_examined" class="muted">Period examined: {{ answer.period_examined }}</p>

      <div v-if="answer.observations.length" class="block">
        <h4>What the data shows</h4>
        <div v-for="(o, i) in answer.observations" :key="i" class="observation">
          <p class="statement">{{ o.statement }}</p>
          <p class="evidence">{{ o.evidence }}</p>
          <span class="conf" :class="o.confidence">{{ o.confidence }} confidence</span>
        </div>
      </div>

      <div v-if="answer.actions.length" class="block">
        <h4>Worth trying</h4>
        <div v-for="(a, i) in answer.actions" :key="i" class="action">
          <p class="statement">{{ a.action }}</p>
          <p class="evidence">{{ a.reason }}</p>
          <span class="timeframe">{{ a.timeframe }}</span>
        </div>
      </div>

      <div v-if="answer.limitations.length" class="block">
        <h4>What this cannot tell you</h4>
        <ul class="limits">
          <li v-for="(l, i) in answer.limitations" :key="i">{{ l }}</li>
        </ul>
      </div>

      <div v-if="answer.professional_review_recommended" class="review">
        <strong>A qualified healthcare professional is the right person to ask.</strong>
        <p v-if="answer.professional_review_reason">{{ answer.professional_review_reason }}</p>
      </div>
    </template>

    <footer class="meta">
      <span v-if="model">
        {{ model.name }} · {{ (model.latency_ms / 1000).toFixed(1) }}s ·
        {{ model.tool_rounds }} tool call{{ model.tool_rounds === 1 ? '' : 's' }} ·
        processed {{ model.destination?.description || 'locally' }}
      </span>
      <span v-else-if="result.source === 'safety_rules'">
        Answered from reviewed guidance. No model was consulted.
      </span>
      <span v-else>No model ran. The measured summary below is unaffected.</span>
    </footer>
  </section>
</template>

<style scoped>
.answer { display: flex; flex-direction: column; gap: 14px; }

.banner { padding: 12px 14px; border-radius: 8px; font-size: 13px; line-height: 1.5; }
.banner ul { margin: 6px 0 0; padding-left: 18px; }
.banner li { margin-bottom: 2px; }
/* Status colours, and each carries its own words — never colour alone. */
.banner.urgent {
  background: color-mix(in srgb, var(--status-critical) 12%, transparent);
  box-shadow: inset 0 0 0 1px var(--status-critical);
}
.banner.review_recommended {
  background: color-mix(in srgb, var(--status-warning) 14%, transparent);
  box-shadow: inset 0 0 0 1px var(--status-warning);
}

.notice {
  font-size: 12px; color: var(--text-secondary);
  background: color-mix(in srgb, var(--text-muted) 10%, transparent);
  padding: 10px 12px; border-radius: 8px; line-height: 1.5;
}

.summary { font-size: 15px; line-height: 1.55; margin: 0; }

.block h4 {
  font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em;
  color: var(--text-muted); margin: 0 0 8px; font-weight: 600;
}

/* An observation is evidenced and an action is a suggestion. Different left
   rules so they are not read as carrying the same weight. */
.observation, .action {
  padding: 0 0 10px 12px; margin-bottom: 10px;
  border-left: 2px solid var(--gridline);
}
.action { border-left-color: var(--series-3); }
.observation:last-child, .action:last-child { margin-bottom: 0; padding-bottom: 0; }

.statement { margin: 0 0 3px; font-size: 13.5px; line-height: 1.5; }
.evidence { margin: 0 0 5px; font-size: 12px; color: var(--text-secondary); line-height: 1.5; }

.conf, .timeframe {
  font-size: 11px; color: var(--text-muted); text-transform: capitalize;
}
.conf.high { color: var(--success-text); }
.conf.low { color: var(--status-critical); }

.limits { margin: 0; padding-left: 18px; font-size: 12px; color: var(--text-secondary); line-height: 1.6; }

.review {
  padding: 12px 14px; border-radius: 8px; font-size: 13px; line-height: 1.5;
  background: color-mix(in srgb, var(--status-warning) 10%, transparent);
}
.review p { margin: 4px 0 0; color: var(--text-secondary); }

.meta { font-size: 11px; color: var(--text-muted); border-top: 1px solid var(--gridline); padding-top: 10px; }
</style>
