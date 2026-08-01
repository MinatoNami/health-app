<script setup>
import { ref, computed, watch, onMounted } from 'vue'
import { api } from './api.js'
import OverviewView from './views/OverviewView.vue'
import ExploreView from './views/ExploreView.vue'
import ExportView from './views/ExportView.vue'

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

const PRESETS = [
  { label: '7d', days: 7 },
  { label: '30d', days: 30 },
  { label: '90d', days: 90 },
  { label: '1y', days: 365 },
]
const preset = ref(30)

function isoDaysAgo(days) {
  const d = new Date()
  d.setDate(d.getDate() - (days - 1))
  return d.toISOString().slice(0, 10)
}

const range = ref({ from: isoDaysAgo(30), to: new Date().toISOString().slice(0, 10) })

function applyPreset(days) {
  preset.value = days
  range.value = { from: isoDaysAgo(days), to: new Date().toISOString().slice(0, 10) }
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
        <button :class="{ active: tab === 'explore' }" @click="tab = 'explore'">Explore</button>
        <button :class="{ active: tab === 'export' }" @click="tab = 'export'">Export</button>
      </nav>
      <span class="spacer" />
      <span class="muted">{{ user.username }}</span>
      <button class="linkbtn" @click="signOut">Sign out</button>
    </header>

    <!-- One filter row, above everything it scopes. Every view re-renders
         against the same slice rather than carrying its own date control. -->
    <div class="filterbar">
      <label>Range</label>
      <button
        v-for="p in PRESETS" :key="p.days"
        class="chip" :class="{ active: preset === p.days }"
        @click="applyPreset(p.days)"
      >{{ p.label }}</button>
      <span class="spacer" />
      <input v-model="range.from" type="date" @change="preset = null" />
      <span class="muted">→</span>
      <input v-model="range.to" type="date" @change="preset = null" />
    </div>

    <p v-if="error" class="error">{{ error }}</p>

    <OverviewView v-if="tab === 'overview'" :data="overview" :refreshing="refreshing" />
    <ExploreView v-else-if="tab === 'explore'" :range="range" />
    <ExportView v-else :range="range" />
  </div>
</template>
