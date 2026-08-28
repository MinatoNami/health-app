<script setup>
/* The date range, as its own component so a view can decide where it sits.
 *
 * It used to be markup in App.vue, rendered above whichever view was showing.
 * That was right while every view was range-scoped, and wrong the moment
 * Overview grew a section that is not: the snapshot's windows are fixed at 7
 * days against the preceding 28, so a range control above it silently did
 * nothing to the first thing you read. A control that appears to scope
 * something it cannot is worse than no control — the same reason this row is
 * hidden on Insights entirely.
 *
 * The state still lives in App.vue. This owns the markup and nothing else, so
 * every view that shows it shows the same one.
 */
const props = defineProps({
  preset: { type: Number, default: null },
  range: { type: Object, required: true },
  /* What the row scopes, said plainly when it is not the whole screen. */
  scope: { type: String, default: '' },
})

const emit = defineEmits(['preset', 'range'])

const PRESETS = [
  { label: '7d', days: 7 },
  { label: '30d', days: 30 },
  { label: '90d', days: 90 },
  { label: '1y', days: 365 },
]

/* Typing a date is a deliberate choice of window, so it clears the preset —
 * leaving "30d" lit beside a hand-picked fortnight would be a lie. */
function edit(field, value) {
  emit('range', { ...props.range, [field]: value })
  emit('preset', null)
}
</script>

<template>
  <div class="filterbar">
    <label>Range</label>
    <button
      v-for="p in PRESETS" :key="p.days"
      class="chip" :class="{ active: preset === p.days }"
      @click="emit('preset', p.days)"
    >{{ p.label }}</button>
    <span v-if="scope" class="scope muted">{{ scope }}</span>
    <span class="spacer" />
    <input :value="range.from" type="date" @change="edit('from', $event.target.value)" />
    <span class="muted">→</span>
    <input :value="range.to" type="date" @change="edit('to', $event.target.value)" />
  </div>
</template>

<style scoped>
.scope { margin-left: 4px; }
</style>
