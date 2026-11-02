import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ mode }) => ({ plugins: [react()], server: { fs: { allow: ['../..'] }, proxy: { '/v1': { target: loadEnv(mode, '.', '').SAY_API_ORIGIN || 'http://localhost:8080', changeOrigin: true, ws: true } } } }))
