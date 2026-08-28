import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  // Served under /health-app/, straight off disk from /var/www/health-dashboard,
  // so every asset URL has to be prefixed. src/api.js reads this back at runtime
  // as import.meta.env.BASE_URL and calls <base>/v1/... — the API answers at both
  // the root and the prefix, and the dashboard uses the prefixed one so its
  // session cookie can be scoped to this app rather than to the whole origin.
  base: '/health-app/',
  build: { outDir: 'dist', emptyOutDir: true },
  server: {
    // `npm run dev` against the real server; same-origin in production so no
    // CORS config is needed there.
    //
    // Overridable so the dashboard can be driven against a throwaway local
    // server with seeded data — `secure: false` because the tailnet host's
    // certificate is self-signed and pinned by the app, not by a CA.
    proxy: {
      // Matches what api.js now asks for. The upstream serves these routes at
      // the root, so the prefix comes off on the way out — dev and production
      // agree on the URL the browser sees, which is the half that decides
      // whether the cookie is sent.
      '/health-app/v1': {
        target: process.env.DASHBOARD_API || 'https://alena-server.tail03bec9.ts.net',
        changeOrigin: true,
        secure: false,
        rewrite: (path) => path.replace(/^\/health-app/, ''),
      },
    },
  },
})
