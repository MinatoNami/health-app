<script setup>
/* Past conversations, grouped the way people already expect.
 *
 * Projects first, then everything unfiled under date headings. The ordering is
 * not arbitrary: a project is something you chose to make, so it stays where
 * you put it, while loose chats are found by "roughly when was that" and belong
 * under Today / Yesterday / Previous 7 days.
 *
 * The list carries titles, not transcripts. A month of conversations is a lot
 * of prose, and it does not need to travel every time somebody starts a new
 * chat — the transcript is fetched when a chat is opened, and only then.
 *
 * Search hits question text as well as titles, because a title here is only
 * ever the first question truncated. Searching titles alone would silently miss
 * everything asked after the opening line, which is most of what gets asked.
 */
import { computed, ref, watch } from 'vue'

const props = defineProps({
  sessions: { type: Array, default: () => [] },
  projects: { type: Array, default: () => [] },
  activeId: { type: String, default: null },
  loading: { type: Boolean, default: false },
  retentionDays: { type: Number, default: null },
  showArchived: { type: Boolean, default: false },
  hasMore: { type: Boolean, default: false },
})

const emit = defineEmits([
  'new-chat', 'open', 'rename', 'delete', 'move', 'archive',
  'create-project', 'edit-project', 'delete-project', 'search', 'show-archived',
  'load-more',
])

const search = ref('')
const open = ref({})          // project id → expanded
const menuFor = ref(null)     // session id whose row menu is showing

/* Debounced: the search box filters server-side so it reaches question bodies,
 * and a request per keystroke would queue behind itself on a slow list. */
let timer = null
watch(search, (value) => {
  clearTimeout(timer)
  timer = setTimeout(() => emit('search', value.trim()), 220)
})

const unfiled = computed(() => props.sessions.filter((s) => !s.project_id))

function forProject(id) {
  return props.sessions.filter((s) => s.project_id === id)
}

/* Buckets by last activity. `startOf` compares calendar days rather than
 * elapsed hours: something asked at 23:50 last night is "Yesterday" at 00:10,
 * not "12 minutes ago". */
const BUCKETS = [
  { label: 'Today', days: 0 },
  { label: 'Yesterday', days: 1 },
  { label: 'Previous 7 days', days: 7 },
  { label: 'Previous 30 days', days: 30 },
  { label: 'Older', days: Infinity },
]

function daysAgo(iso) {
  const then = new Date(iso)
  const a = new Date(then.getFullYear(), then.getMonth(), then.getDate())
  const now = new Date()
  const b = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  return Math.round((b - a) / 86_400_000)
}

const grouped = computed(() => {
  const buckets = BUCKETS.map((b) => ({ ...b, items: [] }))
  for (const session of unfiled.value) {
    const age = daysAgo(session.last_message_at)
    const bucket = buckets.find((b) => age <= b.days)
    bucket.items.push(session)
  }
  return buckets.filter((b) => b.items.length)
})

function toggle(id) {
  open.value = { ...open.value, [id]: !open.value[id] }
}

function rename(session) {
  menuFor.value = null
  const title = window.prompt('Rename this chat', session.title)
  if (title !== null) emit('rename', session, title.trim())
}

function remove(session) {
  menuFor.value = null
  const count = session.message_count
  const warning = count
    ? `Delete “${session.title}” and its ${count} message${count === 1 ? '' : 's'}?`
    : `Delete “${session.title}”?`
  if (window.confirm(warning)) emit('delete', session)
}

function move(session, event) {
  const raw = event.target.value
  menuFor.value = null
  emit('move', session, raw === '' ? null : Number(raw))
}

function archive(session) {
  menuFor.value = null
  emit('archive', session, !session.archived)
}

function exportChat(session, format) {
  menuFor.value = null
  // A plain navigation rather than a fetch: the response is an attachment, so
  // the browser saves it under the name the server chose instead of us
  // rebuilding a blob and a filename on this side.
  window.location.href = `/v1/chat/sessions/${session.id}/export.${format}`
}

function newProject() {
  const name = window.prompt('Name this project')
  if (name?.trim()) emit('create-project', name.trim())
}
</script>

<template>
  <aside class="sidebar">
    <div class="top">
      <button class="newchat" @click="emit('new-chat')">
        <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
          <path d="M8 3v10M3 8h10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
        </svg>
        New chat
      </button>
      <input v-model="search" type="text" class="search" placeholder="Search chats…" />
    </div>

    <div class="scroll">
      <section v-if="projects.length" class="group">
        <div class="grouphead">
          <span>Projects</span>
          <button class="linkbtn" title="New project" @click="newProject">＋</button>
        </div>

        <div v-for="p in projects" :key="p.id" class="project">
          <button class="projectrow" @click="toggle(p.id)">
            <svg class="caret" :class="{ open: open[p.id] }" viewBox="0 0 12 12" width="9" height="9" aria-hidden="true">
              <path d="M4 2 L8 6 L4 10" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" />
            </svg>
            <span class="pname">{{ p.name }}</span>
            <span class="count">{{ p.session_count }}</span>
          </button>

          <div v-if="open[p.id]" class="children">
            <p v-if="p.instructions" class="instructions" :title="p.instructions">
              {{ p.instructions }}
            </p>
            <p v-if="!forProject(p.id).length" class="empty-line">No chats in here yet.</p>
            <button
              v-for="s in forProject(p.id)" :key="s.id"
              class="chatrow" :class="{ active: s.id === activeId }"
              @click="emit('open', s)"
            >
              <span class="title">{{ s.title }}</span>
            </button>
            <div class="projectactions">
              <button class="linkbtn" @click="emit('edit-project', p)">Instructions</button>
              <button class="linkbtn" @click="emit('delete-project', p)">Delete</button>
            </div>
          </div>
        </div>
      </section>

      <button v-else class="addproject linkbtn" @click="newProject">＋ New project</button>

      <section v-for="bucket in grouped" :key="bucket.label" class="group">
        <div class="grouphead"><span>{{ bucket.label }}</span></div>
        <div v-for="s in bucket.items" :key="s.id" class="chatwrap">
          <button
            class="chatrow" :class="{ active: s.id === activeId }"
            @click="emit('open', s)"
          >
            <span class="title">{{ s.title }}</span>
            <span v-if="s.archived" class="archived" title="Archived">archived</span>
          </button>
          <button
            class="dots" aria-label="Chat options"
            @click.stop="menuFor = menuFor === s.id ? null : s.id"
          >⋯</button>

          <div v-if="menuFor === s.id" class="menu">
            <button @click="rename(s)">Rename</button>
            <label>
              <span>Project</span>
              <select :value="s.project_id ?? ''" @change="move(s, $event)">
                <option value="">None</option>
                <option v-for="p in projects" :key="p.id" :value="p.id">{{ p.name }}</option>
              </select>
            </label>
            <button @click="exportChat(s, 'md')">Download as Markdown</button>
            <button @click="exportChat(s, 'json')">Download as JSON</button>
            <button @click="archive(s)">{{ s.archived ? 'Unarchive' : 'Archive' }}</button>
            <button class="danger" @click="remove(s)">Delete</button>
          </div>
        </div>
      </section>

      <!-- The server caps a page of chats. Without this the list simply
           stopped at the cap with nothing to say older ones existed. -->
      <button
        v-if="hasMore" class="loadmore" :disabled="loading"
        @click="emit('load-more')"
      >{{ loading ? 'Loading…' : 'Load older chats' }}</button>

      <p v-if="loading && !sessions.length" class="empty-line">Loading…</p>
      <p v-else-if="!sessions.length" class="empty-line">
        {{ search ? 'Nothing matched.' : 'No chats yet. Ask something to start one.' }}
      </p>
    </div>

    <div class="foot">
      <label class="archivetoggle">
        <input
          type="checkbox" :checked="showArchived"
          @change="emit('show-archived', $event.target.checked)"
        />
        <span>Show archived</span>
      </label>
      <!-- Stated, not buried in Settings. A history panel that silently drops
           conversations after a month reads as data loss the first time
           somebody notices, and as a broken feature the second. -->
      <p v-if="retentionDays" class="retention">
        Chats are deleted after {{ retentionDays }} days.
      </p>
    </div>
  </aside>
</template>

<style scoped>
.sidebar {
  display: flex;
  flex-direction: column;
  background: var(--surface-1);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  height: calc(100vh - 190px);
  min-height: 420px;
  overflow: hidden;
}

.top { padding: 11px 11px 9px; border-bottom: 1px solid var(--border); }

.newchat {
  display: flex; align-items: center; gap: 7px; width: 100%;
  padding: 8px 11px; margin-bottom: 8px;
  border: 1px solid var(--border); border-radius: 9px;
  background: var(--page); color: var(--text-primary);
  font-size: 13px; font-weight: 550;
}
.newchat:hover { border-color: var(--axis); }

.search {
  width: 100%; font-family: inherit; font-size: 12.5px;
  padding: 6px 9px; border: 1px solid var(--border); border-radius: 8px;
  background: var(--page); color: var(--text-primary);
}

.scroll { flex: 1; overflow-y: auto; padding: 8px 8px 12px; }

.group { margin-bottom: 12px; }
.grouphead {
  display: flex; align-items: center; justify-content: space-between;
  font-size: 11px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase;
  color: var(--text-muted); padding: 5px 6px 4px;
}

.chatwrap { position: relative; display: flex; align-items: center; }

.chatrow {
  flex: 1; min-width: 0; text-align: left;
  padding: 7px 9px; border: 0; border-radius: 8px;
  background: none; color: var(--text-secondary);
  font-size: 13px; line-height: 1.35;
}
.chatrow:hover { background: var(--page); color: var(--text-primary); }
.chatrow.active { background: var(--accent-soft); color: var(--text-primary); font-weight: 550; }
.title { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

/* Always rendered rather than revealed on hover: a control that only exists
   when a mouse is over it does not exist on a touchscreen at all. */
.dots {
  flex: none; width: 24px; height: 24px; border: 0; border-radius: 6px;
  background: none; color: var(--text-muted); font-size: 15px; line-height: 1;
}
.dots:hover { background: var(--page); color: var(--text-primary); }

.menu {
  position: absolute; right: 4px; top: 100%; z-index: 5;
  min-width: 168px; padding: 5px;
  background: var(--page); border: 1px solid var(--border);
  border-radius: 9px; box-shadow: 0 6px 20px rgba(0, 0, 0, 0.16);
}
.menu button {
  display: block; width: 100%; text-align: left;
  padding: 6px 8px; border: 0; border-radius: 6px;
  background: none; color: var(--text-primary); font-size: 12.5px;
}
.menu button:hover { background: var(--surface-1); }
.menu button.danger { color: var(--critical-text); }
.menu label { display: block; padding: 6px 8px; font-size: 11px; color: var(--text-muted); }
.menu select {
  width: 100%; margin-top: 3px; font-family: inherit; font-size: 12.5px;
  padding: 4px 6px; border: 1px solid var(--border); border-radius: 6px;
  background: var(--surface-1); color: var(--text-primary);
}

.projectrow {
  display: flex; align-items: center; gap: 6px; width: 100%; text-align: left;
  padding: 7px 9px; border: 0; border-radius: 8px;
  background: none; color: var(--text-primary); font-size: 13px; font-weight: 550;
}
.projectrow:hover { background: var(--page); }
.caret { flex: none; color: var(--text-muted); transition: transform 120ms ease; }
.caret.open { transform: rotate(90deg); }
@media (prefers-reduced-motion: reduce) { .caret { transition: none; } }
.pname { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.count { font-size: 11px; color: var(--text-muted); font-variant-numeric: tabular-nums; }

.children { padding-left: 14px; border-left: 1px solid var(--gridline); margin-left: 13px; }
.instructions {
  margin: 2px 0 6px; padding: 0 9px;
  font-size: 11.5px; line-height: 1.4; color: var(--text-muted);
  display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
}
.projectactions { display: flex; gap: 10px; padding: 5px 9px 2px; }

.addproject { display: block; margin: 2px 6px 12px; }
.empty-line { margin: 6px 9px; font-size: 12px; color: var(--text-muted); }

.loadmore {
  display: block; width: calc(100% - 12px); margin: 6px;
  padding: 7px 9px; border: 1px solid var(--border); border-radius: 8px;
  background: none; color: var(--text-secondary); font-size: 12px;
}
.loadmore:hover:not(:disabled) { border-color: var(--axis); color: var(--text-primary); }
.loadmore:disabled { opacity: 0.5; cursor: default; }

.foot { border-top: 1px solid var(--border); padding: 8px 12px 9px; }

.archivetoggle {
  display: flex; align-items: center; gap: 6px;
  font-size: 11.5px; color: var(--text-secondary); cursor: pointer;
}
.archivetoggle input { accent-color: var(--series-1); margin: 0; }

.archived {
  display: inline-block; margin-top: 2px;
  font-size: 10px; letter-spacing: 0.04em; text-transform: uppercase;
  color: var(--text-muted);
}

.retention { margin: 6px 0 0; font-size: 11px; color: var(--text-muted); }
</style>
