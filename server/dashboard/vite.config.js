import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  // Served by alena-gateway under /health-app/, straight off disk from
  // /var/www/health-dashboard, so every asset URL has to be prefixed. The API
  // calls in src/api.js stay root-absolute (/v1/...) on purpose: the gateway
  // keeps that prefix at the origin root for the iOS app, and the dashboard
  // rides along on the same routes.
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
      '/v1': {
        target: process.env.DASHBOARD_API || 'https://alena-server.tail03bec9.ts.net',
        changeOrigin: true,
        secure: false,
      },
    },
  },
})
