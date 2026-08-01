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

  // Deliberately a URL rather than a fetch: handing it to the browser as a
  // normal download lets it stream to disk. Fetching it would buffer the whole
  // CSV in memory, which for a multi-year export is hundreds of megabytes.
  exportUrl: (params) => `/v1/export/records.csv?${qs(params)}`,
}
