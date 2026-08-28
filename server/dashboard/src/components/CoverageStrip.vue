<script setup>
/* One segment per day in a window, filled where that day has data.
 *
 * The figure that separates "you slept 7.0 hours" from "you slept 7.0 hours on
 * the two nights the watch was on". The server has returned `valid_days` and
 * `window_days` on every comparison since the analysis was written; the rail
 * showed them as a "5/7d" badge, and only when the window was incomplete — so
 * a full week looked exactly like a metric with no coverage information at all.
 *
 * Not a progress bar. Filling 5 of 7 is not 71% of the way to anything; it is
 * five days of evidence and two of silence, and the gaps are drawn as gaps for
 * the same reason a line chart must not join across them.
 *
 * The phone draws the same control (HealthExporter/UI/CoverageStrip.swift).
 * Keeping the two the same shape is most of what makes them read as one
 * product, given the palettes deliberately differ.
 */
import { computed } from 'vue'

const props = defineProps({
  validDays: { type: Number, required: true },
  windowDays: { type: Number, required: true },
  /* 3px on an evidence row beside a figure, 4-5 under a lead sentence. */
  thickness: { type: Number, default: 3 },
})

const total = computed(() => Math.max(props.windowDays, 1))
const filled = computed(() => Math.max(0, Math.min(props.validDays, total.value)))
const label = computed(() => `${filled.value} of ${total.value} days measured`)
</script>

<template>
  <!-- One element, one sentence. Seven separately-announced segments is a
       screen-reader reading of "dimmed, dimmed, dimmed" that means nothing. -->
  <div class="cov-strip" role="img" :aria-label="label" :title="label">
    <span
      v-for="i in total" :key="i"
      class="cov-seg" :class="{ on: i <= filled }"
      :style="{ height: thickness + 'px' }"
    />
  </div>
</template>

<style scoped>
.cov-strip { display: flex; gap: 2px; }
.cov-seg {
  flex: 1;
  border-radius: 2px;
  background: var(--gridline);
}
/* `--series-3` is the palette's green, which is also what the delta uses for a
   change in the good direction. That is deliberate: both mean "this rests on
   days that were actually recorded". */
.cov-seg.on { background: var(--series-3); }
</style>
