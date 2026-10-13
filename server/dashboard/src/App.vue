<script setup>
import { ref, computed, watch, onMounted } from 'vue'
import { api } from './api.js'
import OverviewView from './views/OverviewView.vue'
import ExploreView from './views/ExploreView.vue'
import ExportView from './views/ExportView.vue'
import InsightsView from './views/InsightsView.vue'
import SettingsView from './views/SettingsView.vue'
import FilterBar from './components/FilterBar.vue'

const user = ref(null)
const checking = ref(true)
const username = ref('')
const password = ref('')
const loginError = ref('')
const signingIn = ref(false)

const tab = ref('overview')
const overview = ref(null)
const refreshing = ref(false)
const error = ref('')

const preset = ref(30)

// The local calendar date, not `toISOString()`'s UTC one: in Singapore that
// is yesterday until 08:00, so every morning the default range ended a day
// early and today's data was missing from Overview, Explore and Export.
function localIsoDate(d) {
  const pad = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

function isoDaysAgo(days) {
  const d = new Date()
  d.setDate(d.getDate() - (days - 1))
  return localIsoDate(d)
}

const range = ref({ from: isoDaysAgo(30), to: localIsoDate(new Date()) })

function applyPreset(days) {
  // `null` arrives when a date input is edited by hand: the preset is cleared
  // but the range the user typed must survive it.
  if (days === null) {
    preset.value = null
    return
  }
  preset.value = days
  range.value = { from: isoDaysAgo(days), to: localIsoDate(new Date()) }
}

async function loadOverview() {
  refreshing.value = true
  error.value = ''
  try {
    overview.value = await api.overview({ from: range.value.from, to: range.value.to })
  } catch (e) {
    if (e.unauthorized) user.value = null
    else error.value = e.message
  } finally {
    refreshing.value = false
  }
}

async function signIn() {
  signingIn.value = true
  loginError.value = ''
  try {
    user.value = await api.login(username.value, password.value)
    password.value = ''
    await loadOverview()
  } catch (e) {
    loginError.value = e.unauthorized ? 'Invalid username or password' : e.message
  } finally {
    signingIn.value = false
  }
}

async function signOut() {
  try { await api.logout() } catch { /* signing out locally regardless */ }
  user.value = null
  overview.value = null
}

watch(range, () => { if (user.value && tab.value === 'overview') loadOverview() }, { deep: true })
watch(tab, (value) => { if (value === 'overview' && user.value && !overview.value) loadOverview() })

onMounted(async () => {
  try {
    const me = await api.me()
    if (me.authenticated) {
      user.value = me
      await loadOverview()
    }
  } catch { /* not signed in */ } finally {
    checking.value = false
  }
})
</script>

<template>
  <div v-if="checking" class="login-wrap"><p class="muted">Loading…</p></div>

  <div v-else-if="!user" class="login-wrap">
    <div class="login">
      <div class="card">
        <h1>Health Dashboard</h1>
        <p class="card-sub">Sign in with your server account.</p>
        <form @submit.prevent="signIn">
          <label class="field">
            <span>Username</span>
            <input v-model="username" type="text" autocomplete="username" autocapitalize="none" />
          </label>
          <label class="field">
            <span>Password</span>
            <input v-model="password" type="password" autocomplete="current-password" />
          </label>
          <button class="btn" type="submit" :disabled="signingIn || !username || !password" style="width: 100%">
            {{ signingIn ? 'Signing in…' : 'Sign in' }}
          </button>
          <p v-if="loginError" class="error">{{ loginError }}</p>
        </form>
      </div>
    </div>
  </div>

  <div v-else class="app">
    <header class="topbar">
      <h1>Health Dashboard</h1>
      <nav class="nav">
        <button :class="{ active: tab === 'overview' }" @click="tab = 'overview'">Overview</button>
        <button :class="{ active: tab === 'insights' }" @click="tab = 'insights'">Insights</button>
        <button :class="{ active: tab === 'explore' }" @click="tab = 'explore'">Explore</button>
        <button :class="{ active: tab === 'export' }" @click="tab = 'export'">Export</button>
        <button :class="{ active: tab === 'settings' }" @click="tab = 'settings'">Settings</button>
      </nav>
      <span class="spacer" />
      <span class="muted">{{ user.username }}</span>
      <button class="linkbtn" @click="signOut">Sign out</button>
    </header>

    <!-- One filter row, above everything it scopes — but no longer always at
         the top of the page. Explore and Export are range-scoped end to end, so
         it leads there. Overview is not: its first section reads from the
         snapshot, whose windows are fixed at 7 days against the preceding 28,
         so the row is handed to that view to place below them. Insights has no
         range at all, for the same reason.

         The state stays here. Only the position moved. -->
    <FilterBar
      v-if="['explore', 'export'].includes(tab)"
      :preset="preset" :range="range"
      @preset="applyPreset" @range="range = $event"
    />

    <p v-if="error" class="error">{{ error }}</p>

    <OverviewView v-if="tab === 'overview'" :data="overview" :refreshing="refreshing">
      <template #filters>
        <FilterBar
          :preset="preset" :range="range" scope="scopes the charts below"
          @preset="applyPreset" @range="range = $event"
        />
      </template>
    </OverviewView>
    <InsightsView v-else-if="tab === 'insights'" />
    <SettingsView v-else-if="tab === 'settings'" />
    <ExploreView v-else-if="tab === 'explore'" :range="range" />
    <ExportView v-else :range="range" />
  </div>
</template>
