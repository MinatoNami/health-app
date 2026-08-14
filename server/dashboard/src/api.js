/* Same-origin API client using the session cookie.
 *
 * `credentials: 'include'` on every call, and the CSRF token echoed on unsafe
 * methods — Django rejects an unsafe session-authenticated request without it.
 */

function cookie(name) {
  return document.cookie
    .split('; ')
    .find((row) => row.startsWith(name + '='))
    ?.split('=')[1]
}

async function request(path, options = {}) {
  const headers = { ...(options.headers || {}) }
  if (options.method && options.method !== 'GET') {
    headers['Content-Type'] = 'application/json'
    const token = cookie('csrftoken')
    if (token) headers['X-CSRFToken'] = token
  }

  const response = await fetch(path, { credentials: 'include', ...options, headers })
  if (response.status === 401 || response.status === 403) {
    const error = new Error('Not signed in')
    error.unauthorized = true
    throw error
  }
  if (!response.ok) {
    let detail = `HTTP ${response.status}`
    try {
      detail = (await response.json()).detail || detail
    } catch {
      /* non-JSON error body — the status is enough */
    }
    throw new Error(detail)
  }
  return response.json()
}

const qs = (params) =>
  Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== null && v !== '')
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join('&')

export const api = {
  async ensureCsrf() {
    await request('/v1/auth/csrf')
  },
  me: () => request('/v1/auth/me'),
  async login(username, password) {
    await api.ensureCsrf()
    return request('/v1/auth/session', {
      method: 'POST',
      body: JSON.stringify({ username, password }),
    })
  },
  logout: () => request('/v1/auth/session/logout', { method: 'POST' }),

  overview: (params) => request(`/v1/analytics/overview?${qs(params)}`),
  metrics: () => request('/v1/analytics/metrics'),
  series: (params) => request(`/v1/analytics/series?${qs(params)}`),
  exportSummary: (params) => request(`/v1/export/summary?${qs(params)}`),

  // Deterministic analysis. Same inputs, same numbers, no model involved —
  // which is why these load instantly and the ask below does not.
  snapshot: (params = {}) => request(`/v1/analysis/snapshot?${qs(params)}`),
  quality: (params = {}) => request(`/v1/analysis/quality?${qs(params)}`),
  sleepDetail: (params = {}) => request(`/v1/analysis/sleep?${qs(params)}`),
  goals: () => request('/v1/analysis/goals'),
  saveGoal: (body) =>
    request('/v1/analysis/goals', { method: 'POST', body: JSON.stringify(body) }),
  deleteGoal: (id) => request(`/v1/analysis/goals/${id}`, { method: 'DELETE' }),

  // Model-backed. Slow by nature: a local model works through this for tens of
  // seconds, so callers must show that something is happening.
  insightStatus: () => request('/v1/insights/status'),
  // `session_id` puts the question in a conversation, which is what makes the
  // server replay that chat's earlier turns. Only their summaries — the figures
  // are re-read from the snapshot every time, so the model cannot cite its own
  // earlier prose back as a measurement.
  ask: (body) => request('/v1/insights/ask', { method: 'POST', body: JSON.stringify(body) }),
  weeklyReview: (body = {}) =>
    request('/v1/insights/weekly', { method: 'POST', body: JSON.stringify(body) }),
  insightHistory: () => request('/v1/insights/history'),
  forgetInsights: () => request('/v1/insights/history', { method: 'DELETE' }),

  // Conversations. The list endpoint is deliberately separate from the
  // transcript one: the sidebar reloads on every new chat and must not drag a
  // month of message bodies with it.
  chatProjects: () => request('/v1/chat/projects'),
  createChatProject: (body) =>
    request('/v1/chat/projects', { method: 'POST', body: JSON.stringify(body) }),
  updateChatProject: (id, body) =>
    request(`/v1/chat/projects/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  deleteChatProject: (id) => request(`/v1/chat/projects/${id}`, { method: 'DELETE' }),

  chatSessions: (params = {}) => request(`/v1/chat/sessions?${qs(params)}`),
  createChatSession: (body = {}) =>
    request('/v1/chat/sessions', { method: 'POST', body: JSON.stringify(body) }),
  chatSession: (id) => request(`/v1/chat/sessions/${id}`),
  updateChatSession: (id, body) =>
    request(`/v1/chat/sessions/${id}`, { method: 'PATCH', body: JSON.stringify(body) }),
  deleteChatSession: (id) => request(`/v1/chat/sessions/${id}`, { method: 'DELETE' }),
  // Folds older turns into a written summary so a long chat keeps its thread
  // instead of losing its opening to the turn cap. Affects what is sent to the
  // model; the transcript is never rewritten. Slow — it runs the model.
  compactChatSession: (id) =>
    request(`/v1/chat/sessions/${id}/compact`, { method: 'POST', body: '{}' }),

  // What you thought of one answer. `rating` is 1, -1, or null to clear; the
  // note is the half worth having, because "used the wrong sleep window" is
  // something you can act on and a bare thumbs-down is not.
  rateMessage: (turnId, body) =>
    request(`/v1/chat/messages/${turnId}/feedback`, {
      method: 'POST',
      body: JSON.stringify(body),
    }),

  // A URL rather than a fetch, for the same reason the CSV export is: handing
  // it to the browser as a normal download lets it name and save the file.
  chatExportUrl: (id, format = 'md') => `/v1/chat/sessions/${id}/export.${format}`,

  // Flat across every conversation, oldest first, with the safety verdict, the
  // tools that ran and the model that answered attached to each turn. This is
  // the one to read from a script when scoring answers.
  chatMessages: (params = {}) => request(`/v1/chat/messages?${qs(params)}`),

  // Deliberately a URL rather than a fetch: handing it to the browser as a
  // normal download lets it stream to disk. Fetching it would buffer the whole
  // CSV in memory, which for a multi-year export is hundreds of megabytes.
  exportUrl: (params) => `/v1/export/records.csv?${qs(params)}`,
}
