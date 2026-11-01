import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import ts from 'typescript'

async function load(file) {
  const source = await readFile(new URL(`../src/${file}`, import.meta.url), 'utf8')
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
  return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`)
}

const { request, ApiError, query } = await load('api.ts')
const { sedi } = await load('format.ts')

test('requests send session cookies and preserve structured API errors', async () => {
  const original = globalThis.fetch
  globalThis.fetch = async (_url, options) => {
    assert.equal(options.credentials, 'same-origin')
    return new Response(JSON.stringify({ error: { code: 'INSUFFICIENT_FUNDS', message: 'Not enough credits', fields: [{ field: 'spend', reason: 'too_high' }] } }), { status: 409 })
  }
  try {
    await assert.rejects(request('/v1/me'), (error) => error instanceof ApiError && error.code === 'INSUFFICIENT_FUNDS' && error.message === 'Not enough credits' && error.fields[0].field === 'spend')
  } finally {
    globalThis.fetch = original
  }
})

test('unreadable error bodies become a retryable unavailable error', async () => {
  const original = globalThis.fetch
  globalThis.fetch = async () => new Response('<html>bad gateway</html>', { status: 502 })
  try {
    await assert.rejects(request('/v1/me'), (error) => error instanceof ApiError && error.status === 502 && error.code === 'UNAVAILABLE')
  } finally {
    globalThis.fetch = original
  }
})

test('empty responses and absent amounts remain distinct from zero', async () => {
  const original = globalThis.fetch
  globalThis.fetch = async () => new Response(null, { status: 204 })
  try {
    assert.equal(await request('/v1/auth/logout', { method: 'POST' }), undefined)
  } finally {
    globalThis.fetch = original
  }
  assert.equal(sedi(null), '—')
  assert.equal(sedi(0), 'S 0')
})

test('query strings drop empty values', () => {
  assert.equal(query({ status: 'open', market_id: '', cursor: undefined }), '?status=open')
  assert.equal(query({}), '')
})
