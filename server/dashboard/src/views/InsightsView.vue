<script setup>
/* Ask My Health, as a conversation you can come back to.
 *
 * Three columns: the chats you have had, the one you are having, and the
 * measured numbers it is built from. The transcript was already the middle
 * column; what changed is that it now outlives a page reload.
 *
 * The session is created lazily — on the first question, not on the first
 * click. Creating one when the screen opens would leave an empty "New chat" in
 * the sidebar every time somebody looked at this tab and left, which is how a
 * history list fills with nothing.
 *
 * Everything explanatory — how the windows are chosen, where processing
 * happens, goals, retention — lives in Settings. It is read once; it was
 * costing a paragraph a day here.
 */
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { api } from '../api.js'
import ChatMessage from '../components/ChatMessage.vue'
import ChatSidebar from '../components/ChatSidebar.vue'
import ContextRail from '../components/ContextRail.vue'

const snapshot = ref(null)
const status = ref(null)
const turns = ref([])
const question = ref('')
const asking = ref(false)
const error = ref('')
const transcript = ref(null)

const sessions = ref([])
const projects = ref([])
const activeId = ref(null)
const loadingList = ref(false)
const loadingChat = ref(false)
const search = ref('')
const showArchived = ref(false)
const drawerOpen = ref(false)
const editing = ref(null)   // project whose instructions are open
// Which project a not-yet-created chat will be filed under. Held separately
// because there is no session row to hang it on until the first question.
const pendingProject = ref(null)

/* Compaction state for the open chat. `detail` is the transcript payload the
 * server returned, which carries the summary, how many turns it covers, and the
 * measured token usage of the last prompt. */
const detail = ref(null)
const compacting = ref(false)
const showSummary = ref(false)
const notice = ref('')

/* Short on purpose. Full sentences on five chips was a paragraph of its own. */
const SUGGESTIONS = [
  'How is my sleep?',
  'Am I more active?',
  'Enough data to see a trend?',
  'What should I focus on?',
]

const ready = computed(() => status.value?.enabled && status.value?.reachable)
const empty = computed(() => !turns.value.length)
const activeSession = computed(() => sessions.value.find((s) => s.id === activeId.value) || null)
const activeProject = computed(
  () => projects.value.find((p) => p.id === activeSession.value?.project_id) || null,
)

/* The transcript opens with the measured week rather than an empty panel, so
 * the screen says something true before any model has run. Only on a new chat:
 * printing this week's numbers above a conversation from three weeks ago would
 * caption it with figures it never mentioned. */
const opening = computed(() => {
  if (!snapshot.value || !empty.value) return null
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

// --------------------------------------------------------------------------
// Loading
// --------------------------------------------------------------------------

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
  await Promise.all([loadSessions(), loadProjects()])
}

async function loadSessions() {
  loadingList.value = true
  try {
    // `archived` is left off entirely when showing everything — the filter is
    // tri-state on the server, and sending 1 would show *only* archived chats.
    const params = { q: search.value }
    if (!showArchived.value) params.archived = 0
    sessions.value = (await api.chatSessions(params)).sessions
  } catch (e) {
    error.value = e.message
  } finally {
    loadingList.value = false
  }
}

async function loadProjects() {
  try {
    projects.value = (await api.chatProjects()).projects
  } catch { /* the sidebar works without projects */ }
}

/* A stored turn, rendered as the live payload ChatMessage already knows.
 *
 * The stored row keeps the model's name and latency as columns rather than the
 * nested `model` object the ask endpoint returns, because a turn that never
 * reached a model has no such object to store. Rebuilding it here keeps one
 * renderer for both paths — a second "historical message" component would drift
 * from the live one within a release. */
function fromStored(message) {
  return {
    // The live ask payload calls it `turn_id`; the stored row calls it `id`.
    // Normalised here so one renderer handles both and the rating control does
    // not have to know which path it is looking at.
    turn_id: message.id,
    rating: message.rating ?? null,
    note: message.note || '',
    answer: message.answer,
    safety: message.safety || {},
    tool_calls: message.tool_calls || [],
    error: message.error || null,
    model: message.model_name
      ? { name: message.model_name, latency_ms: message.latency_ms }
      : null,
    // Not stored, so inferred from the one thing that produces it: the safety
    // layer answering an urgent question without calling a model at all.
    source: message.safety?.level === 'urgent' ? 'safety_rules' : undefined,
  }
}

/* Records a thumb or a note against one answer.
 *
 * The bubble is updated from the server's response rather than optimistically:
 * this is the data a feedback loop is built on, and a thumb that looks saved
 * but is not would poison it quietly. */
async function rate(turnId, body) {
  const index = turns.value.findIndex((t) => t.result?.turn_id === turnId)
  if (index === -1) return
  try {
    const updated = await api.rateMessage(turnId, body)
    turns.value[index] = {
      ...turns.value[index],
      result: { ...turns.value[index].result, rating: updated.rating, note: updated.note },
    }
  } catch (e) {
    error.value = e.message
  }
}

function toTranscript(messages) {
  const rows = []
  for (const message of messages) {
    // A blank question means the weekly review, which is asked by instruction
    // rather than by a question. It still needs a bubble, or the answer appears
    // to have arrived unprompted.
    rows.push({ role: 'user', text: message.question || 'Weekly review' })
    rows.push({ role: 'assistant', result: fromStored(message) })
  }
  return rows
}

async function openSession(session) {
  if (asking.value || session.id === activeId.value) return
  drawerOpen.value = false
  loadingChat.value = true
  error.value = ''
  notice.value = ''
  showSummary.value = false
  try {
    const body = await api.chatSession(session.id)
    activeId.value = body.id
    detail.value = body
    turns.value = toTranscript(body.messages)
    scrollDown()
  } catch (e) {
    error.value = e.message
  } finally {
    loadingChat.value = false
  }
}

function newChat(projectId = null) {
  if (asking.value) return
  activeId.value = null
  turns.value = []
  detail.value = null
  error.value = ''
  notice.value = ''
  showSummary.value = false
  drawerOpen.value = false
  pendingProject.value = projectId
}

// --------------------------------------------------------------------------
// Compaction
// --------------------------------------------------------------------------

/* How many of the visible messages sit behind the compaction line. The server
 * counts turns; the transcript renders two rows per turn, so the divider goes
 * after twice that many rows. */
const compactedRows = computed(() => (detail.value?.summary_turns || 0) * 2)

/* Measured, not estimated: `last_prompt_tokens` is what the model server
 * actually counted for the most recent prompt. Only shown once it is worth
 * knowing — a meter that sits at 4% all day is decoration. */
const contextUse = computed(() => {
  const context = detail.value?.context
  if (!context?.limit_tokens || !context.last_prompt_tokens) return null
  const pct = Math.round((context.last_prompt_tokens / context.limit_tokens) * 100)
  return pct >= 50 ? { pct, ...context } : null
})

const canCompact = computed(
  () => activeId.value && !asking.value && !compacting.value && ready.value
    && (detail.value?.context?.pending_turns || 0) >= 2,
)

async function refreshDetail() {
  if (!activeId.value) return
  try {
    detail.value = await api.chatSession(activeId.value)
  } catch { /* the transcript on screen is still correct */ }
}

async function compactNow() {
  if (!canCompact.value) return
  compacting.value = true
  notice.value = ''
  error.value = ''
  try {
    const result = await api.compactChatSession(activeId.value)
    detail.value = { ...detail.value, ...result.session }
    notice.value = result.compacted
      ? `Compacted ${result.turns} earlier ${result.turns === 1 ? 'message' : 'messages'}. The transcript is unchanged — this only affects what the model is sent.`
      : `Nothing compacted: ${result.reason}`
  } catch (e) {
    error.value = e.message
  } finally {
    compacting.value = false
  }
}

// --------------------------------------------------------------------------
// Asking
// --------------------------------------------------------------------------

/* Returns the id to ask against, creating the chat if this is the first
 * question. A failure here is not fatal: the question is still worth asking,
 * it just lands outside any conversation. */
async function ensureSession() {
  if (activeId.value) return activeId.value
  try {
    const session = await api.createChatSession(
      pendingProject.value ? { project_id: pendingProject.value } : {},
    )
    activeId.value = session.id
    pendingProject.value = null
    return session.id
  } catch {
    return null
  }
}

async function run(label, call) {
  turns.value.push({ role: 'user', text: label })
  turns.value.push({ role: 'pending' })
  asking.value = true
  error.value = ''
  scrollDown()
  try {
    const sessionId = await ensureSession()
    const result = await call(sessionId)
    turns.value.splice(-1, 1, { role: 'assistant', result })
    // Said out loud rather than left to be noticed: the alternative is a
    // conversation that quietly forgets its own opening.
    if (result.compacted) {
      notice.value = `Compacted ${result.compacted} earlier messages to make room in the model's context. Nothing was deleted.`
    }
    // The list changes shape on the first question of a chat — it gains a
    // title — and reorders on every one after that.
    loadSessions()
    refreshDetail()
  } catch (e) {
    turns.value.splice(-1, 1)
    error.value = e.message
  } finally {
    asking.value = false
    scrollDown()
  }
}

async function ask(text) {
  const asked = (text ?? question.value).trim()
  if (!asked || asking.value) return
  question.value = ''
  // No `follow_up` flag: the server replays this session's own history, which
  // is both narrower and more correct than the last two turns from anywhere.
  await run(asked, (sessionId) => api.ask({ question: asked, session_id: sessionId }))
}

async function weekly() {
  if (asking.value) return
  await run('Weekly review', (sessionId) => api.weeklyReview({ session_id: sessionId }))
}

/* Enter sends, Shift+Enter breaks the line — the convention every chat box
 * shares, and the one people try first. */
function onKey(event) {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault()
    ask()
  }
}

// --------------------------------------------------------------------------
// Sidebar actions
// --------------------------------------------------------------------------

async function guard(action) {
  try {
    await action()
  } catch (e) {
    error.value = e.message
  }
}

const renameSession = (session, title) =>
  guard(async () => {
    await api.updateChatSession(session.id, { title })
    await loadSessions()
  })

const deleteSession = (session) =>
  guard(async () => {
    await api.deleteChatSession(session.id)
    if (session.id === activeId.value) newChat()
    await loadSessions()
  })

const moveSession = (session, projectId) =>
  guard(async () => {
    await api.updateChatSession(session.id, { project_id: projectId })
    await Promise.all([loadSessions(), loadProjects()])
  })

/* Archiving is the answer to "I am done with this but do not want it gone".
 * Deleting is the other answer, and keeping them as separate gestures is what
 * makes the destructive one safe to offer at all. */
const archiveSession = (session, archived) =>
  guard(async () => {
    await api.updateChatSession(session.id, { archived })
    if (archived && !showArchived.value && session.id === activeId.value) newChat()
    await loadSessions()
  })

function toggleArchived(value) {
  showArchived.value = value
  loadSessions()
}

const createProject = (name) =>
  guard(async () => {
    await api.createChatProject({ name })
    await loadProjects()
  })

const deleteProject = (project) =>
  guard(async () => {
    if (!window.confirm(`Delete the project “${project.name}”? Its chats are kept and moved out.`)) return
    await api.deleteChatProject(project.id)
    await Promise.all([loadSessions(), loadProjects()])
  })

const saveInstructions = () =>
  guard(async () => {
    await api.updateChatProject(editing.value.id, { instructions: editing.value.instructions })
    editing.value = null
    await loadProjects()
  })

function onSearch(value) {
  search.value = value
  loadSessions()
}

watch(turns, scrollDown, { deep: true })
onMounted(load)
</script>

<template>
  <div class="insights">
    <!-- Below 860px the sidebar becomes a drawer rather than a column. A 220px
         list next to a 100px transcript is two unusable things instead of one
         usable one. -->
    <ChatSidebar
      class="sidebar-col" :class="{ open: drawerOpen }"
      :sessions="sessions"
      :projects="projects"
      :active-id="activeId"
      :loading="loadingList"
      :retention-days="status?.retention_days ?? null"
      :show-archived="showArchived"
      @new-chat="newChat()"
      @open="openSession"
      @rename="renameSession"
      @delete="deleteSession"
      @move="moveSession"
      @archive="archiveSession"
      @create-project="createProject"
      @edit-project="editing = { ...$event }"
      @delete-project="deleteProject"
      @search="onSearch"
      @show-archived="toggleArchived"
    />
    <div v-if="drawerOpen" class="scrim" @click="drawerOpen = false" />

    <section class="chat">
      <div class="chathead">
        <button class="drawerbtn" aria-label="Show chats" @click="drawerOpen = true">☰</button>
        <h2>{{ activeSession?.title || 'New chat' }}</h2>
        <span v-if="activeProject" class="badge">{{ activeProject.name }}</span>
        <span class="spacer" />
        <!-- Only once the prompt is genuinely filling up. A context meter that
             reads 4% every day is decoration people stop seeing. -->
        <span
          v-if="contextUse" class="ctx" :class="{ tight: contextUse.pct >= 80 }"
          :title="`Last prompt used about ${contextUse.last_prompt_tokens.toLocaleString()} of ${contextUse.limit_tokens.toLocaleString()} tokens`"
        >{{ contextUse.pct }}% context</span>
        <a
          v-if="activeId && turns.length" class="linkbtn compact"
          :href="api.chatExportUrl(activeId, 'md')"
          title="Download this conversation as Markdown"
        >Download</a>
        <button
          v-if="activeId" class="linkbtn compact"
          :disabled="!canCompact"
          title="Summarise the earlier part of this chat so it still fits the model's context. The transcript is not changed."
          @click="compactNow"
        >{{ compacting ? 'Compacting…' : 'Compact' }}</button>
      </div>

      <div ref="transcript" class="transcript">
        <!-- margin-top:auto on this wrapper is what makes a short conversation
             sit against the composer instead of stranded at the top of an empty
             panel. `justify-content: flex-end` on the scroller itself would do
             the same until the content overflows, at which point it clips the
             oldest messages out of reach. -->
        <div class="messages">
          <p v-if="loadingChat" class="offline">Loading this conversation…</p>

          <div v-if="opening" class="row">
            <div class="bubble assistant opening">{{ opening }}</div>
          </div>

          <p v-if="empty && activeProject?.instructions" class="projectnote">
            This chat inherits the standing context you wrote for
            “{{ activeProject.name }}”.
          </p>

          <template v-for="(turn, i) in turns" :key="i">
            <ChatMessage :turn="turn" @rate="rate" />
            <!-- The line where the model's memory of this chat becomes a
                 summary. Everything above it is still here to read — that is
                 the whole point of keeping the transcript out of it. -->
            <div v-if="compactedRows && i === compactedRows - 1" class="compactline">
              <span class="rule" />
              <button class="linkbtn" @click="showSummary = !showSummary">
                {{ detail.summary_turns }} earlier
                {{ detail.summary_turns === 1 ? 'message' : 'messages' }} compacted
                {{ showSummary ? '▾' : '▸' }}
              </button>
              <span class="rule" />
            </div>
            <p v-if="showSummary && compactedRows && i === compactedRows - 1" class="summarybox">
              {{ detail.summary }}
            </p>
          </template>

          <p v-if="notice" class="notice">{{ notice }}</p>
          <p v-if="error" class="error">{{ error }}</p>

          <p v-if="!ready && status" class="offline">
            The model is unreachable, so answers are unavailable. The measured
            numbers alongside do not need it.
          </p>
        </div>
      </div>

      <div class="composer">
        <!-- Suggestions only on an empty chat. Once a conversation is running
             they are five prompts competing with the answer you just read. -->
        <div class="chips">
          <template v-if="empty">
            <button
              v-for="s in SUGGESTIONS" :key="s"
              class="chip" :disabled="asking || !ready"
              @click="ask(s)"
            >{{ s }}</button>
          </template>
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

    <ContextRail class="rail-col" :snapshot="snapshot" />

    <!-- Standing context is the only thing that makes a project more than a
         folder, so it gets a textarea rather than a one-line prompt box. -->
    <div v-if="editing" class="modalwrap" @click.self="editing = null">
      <div class="modal">
        <h3>{{ editing.name }}</h3>
        <p class="card-sub">
          Background about you that every chat in this project starts with. It is
          context, never a measurement — figures still come from your data.
        </p>
        <textarea
          v-model="editing.instructions"
          rows="6"
          maxlength="2000"
          placeholder="e.g. Training for a half marathon in October. I work nights on Tuesdays and Wednesdays."
        />
        <div class="modalactions">
          <button class="btn secondary" @click="editing = null">Cancel</button>
          <button class="btn" @click="saveInstructions">Save</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* Chats, conversation, context. The conversation is the only column that grows;
   the two beside it are fixed because a list of titles and a column of numbers
   do not get better with more width. */
.insights {
  display: grid;
  grid-template-columns: 224px minmax(0, 1fr) 240px;
  gap: 14px;
  align-items: start;
}
/* The rail goes first: numbers stay legible on a phone stacked under the
   conversation, whereas the chat list is navigation and belongs behind a
   button by then. */
@media (max-width: 1180px) {
  .insights { grid-template-columns: 224px minmax(0, 1fr); }
  .rail-col { display: none; }
}
@media (max-width: 860px) {
  .insights { grid-template-columns: 1fr; }
  .sidebar-col {
    position: fixed; z-index: 20; top: 0; left: 0; bottom: 0;
    width: 280px; height: 100vh; min-height: 0;
    border-radius: 0; border-left: 0;
    transform: translateX(-100%); transition: transform 160ms ease;
  }
  .sidebar-col.open { transform: none; }
  .scrim { position: fixed; inset: 0; z-index: 15; background: rgba(0, 0, 0, 0.4); }
  .drawerbtn { display: block; }
}
@media (prefers-reduced-motion: reduce) { .sidebar-col { transition: none; } }

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

.chathead {
  display: flex; align-items: center; gap: 9px;
  padding: 10px 15px; border-bottom: 1px solid var(--border);
}
.chathead h2 {
  flex: 1; min-width: 0; margin: 0;
  font-size: 13.5px; font-weight: 600;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.drawerbtn {
  display: none; flex: none; width: 28px; height: 28px;
  border: 0; border-radius: 7px; background: none;
  color: var(--text-secondary); font-size: 14px;
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
.projectnote { margin: 0 0 14px; font-size: 12px; color: var(--text-muted); }

.ctx {
  flex: none; font-size: 11px; color: var(--text-muted);
  font-variant-numeric: tabular-nums;
}
.ctx.tight { color: var(--warning-text); font-weight: 600; }
.compact { flex: none; }
.compact:disabled { opacity: 0.4; cursor: not-allowed; text-decoration: none; }

/* A seam, not a banner. What happened is that the model's memory of the part
   above became a paragraph; the messages are still there, so this should read
   as a fold rather than as a deletion. */
.compactline { display: flex; align-items: center; gap: 10px; margin: 2px 0 16px; }
.compactline .rule { flex: 1; height: 1px; background: var(--gridline); }
.compactline .linkbtn { flex: none; font-size: 11px; text-decoration: none; }
.compactline .linkbtn:hover { text-decoration: underline; }

.summarybox {
  margin: -6px 0 16px; padding: 10px 13px;
  background: var(--surface-1); border: 1px dashed var(--border);
  border-radius: var(--radius);
  font-size: 12.5px; line-height: 1.5; color: var(--text-secondary);
}

.notice { margin: 0 0 14px; font-size: 12px; color: var(--text-secondary); }

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

.modalwrap {
  position: fixed; inset: 0; z-index: 30;
  display: grid; place-items: center; padding: 20px;
  background: rgba(0, 0, 0, 0.4);
}
.modal {
  width: 100%; max-width: 460px; padding: 20px;
  background: var(--page); border: 1px solid var(--border);
  border-radius: var(--radius-lg);
}
.modal h3 { margin: 0 0 4px; font-size: 15px; }
.modal textarea {
  width: 100%; font-family: inherit; font-size: 13px; line-height: 1.5;
  padding: 9px 11px; border: 1px solid var(--border); border-radius: 9px;
  background: var(--surface-1); color: var(--text-primary); resize: vertical;
}
.modalactions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 12px; }
</style>
