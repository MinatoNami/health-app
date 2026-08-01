import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  // Served by nginx under /dashboard/, so every asset URL has to be prefixed.
  base: '/dashboard/',
  build: { outDir: 'dist', emptyOutDir: true },
  server: {
    // `npm run dev` against the real server; same-origin in production so no
    // CORS config is needed there.
    proxy: {
      '/v1': { target: 'https://alena-server.tail03bec9.ts.net', changeOrigin: true, secure: false },
    },
  },
})
