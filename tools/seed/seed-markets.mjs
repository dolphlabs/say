#!/usr/bin/env node
// Seeds sample markets through the admin API, so every market goes through
// the same create -> submit -> approve path (and checks) as one made by hand.
// Re-running is safe: markets are matched by question and resumed, not duplicated.

import { readFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HOUR = 3600_000
const DAY = 24 * HOUR

const env = (name, fallback) => {
  const v = process.env[name] ?? fallback
  if (v === undefined || v === '') throw new Error(`${name} is required`)
  return v
}

const base = env('SAY_URL', 'http://localhost:3320').replace(/\/$/, '')
const dataPath = process.env.SEED_FILE ?? join(dirname(fileURLToPath(import.meta.url)), 'markets.json')
const dryRun = process.argv.includes('--dry-run')

class Client {
  constructor(label) {
    this.label = label
    this.cookie = ''
  }

  async call(method, path, body) {
    const res = await fetch(base + path, {
      method,
      headers: { 'content-type': 'application/json', ...(this.cookie ? { cookie: this.cookie } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    const setCookie = res.headers.getSetCookie?.() ?? []
    const session = setCookie.map((c) => c.split(';')[0]).find((c) => c.startsWith('say_session='))
    if (session) this.cookie = session
    const text = await res.text()
    const json = text ? JSON.parse(text) : null
    if (!res.ok) {
      const e = json?.error
      const fields = (e?.details?.fields ?? e?.fields)?.map((f) => `${f.field}: ${f.message}`).join('; ')
      throw new Error(`${this.label} ${method} ${path} -> ${res.status} ${e?.code ?? ''} ${e?.message ?? text}${fields ? ` (${fields})` : ''}`)
    }
    return json
  }

  async login(email, password) {
    const r = await this.call('POST', '/v1/auth/login', { email, password })
    if (!this.cookie) throw new Error(`${this.label}: login succeeded but no session cookie came back`)
    return r.user
  }
}

async function listAll(client) {
  const out = []
  let cursor = ''
  do {
    const page = await client.call('GET', `/v1/admin/markets?limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`)
    out.push(...page.items)
    cursor = page.next_cursor ?? ''
  } while (cursor)
  return out
}

async function ensureSource(author, approver, want) {
  const sources = await author.call('GET', '/v1/admin/resolution-sources')
  let source = sources.find((s) => s.name === want.name)
  if (!source) {
    source = await author.call('POST', '/v1/admin/resolution-sources', want)
    console.log(`created source "${want.name}"`)
  }
  if (!source.approved) {
    source = await approver.call('POST', `/v1/admin/resolution-sources/${source.id}/approve`)
    console.log(`approved source "${want.name}"`)
  }
  return source.id
}

function terms(spec, ids, season, now) {
  const seasonEnd = Date.parse(season.ends_at)
  const close = Math.min(now + spec.close_in_days * DAY, seasonEnd - 2 * HOUR)
  if (close <= now + HOUR) throw new Error(`season ${season.ordinal} ends too soon to seed "${spec.question}"`)
  return {
    question: spec.question,
    category_id: ids.category,
    season_id: season.id,
    resolution_source_id: ids.source,
    rules: { yes_if: spec.yes_if, no_if: spec.no_if, edge_cases: spec.edge_cases },
    open_at: new Date(now + 2 * 60_000).toISOString(),
    close_at: new Date(close).toISOString(),
    resolve_by: new Date(close + 2 * HOUR).toISOString(),
    redemption_units: 100,
    min_price: 1,
    max_price: 99,
    tick: 1,
    max_order_qty: 10000,
    fee_units: 1,
    min_order_notional: 2,
    liquidity_request: 0,
    featured_rank: spec.featured_rank ?? 0,
    opening_price: spec.opening_price ?? 50,
  }
}

async function main() {
  const data = JSON.parse(await readFile(dataPath, 'utf8'))
  const author = new Client('author')
  const approver = new Client('approver')
  const a = await author.login(env('SEED_AUTHOR_EMAIL'), env('SEED_AUTHOR_PASSWORD'))
  const b = await approver.login(env('SEED_APPROVER_EMAIL'), env('SEED_APPROVER_PASSWORD'))
  if (a.id === b.id) throw new Error('author and approver must be different accounts: nobody may approve their own market')
  console.log(`signed in to ${base} as ${a.username} (author) and ${b.username} (approver)`)

  const categories = await author.call('GET', '/v1/categories')
  const seasons = (await author.call('GET', '/v1/admin/seasons')).items
  const season = seasons.find((s) => s.status === 'ACTIVE')
  if (!season) throw new Error('no ACTIVE season; markets can only open inside one')

  const existing = await listAll(author)
  const plan = data.markets.map((spec) => ({ spec, found: existing.find((m) => m.question === spec.question && m.status !== 'REJECTED') }))
  for (const { spec, found } of plan) console.log(`${found ? `exists (${found.status})` : 'new'}: ${spec.question}`)
  if (dryRun) return

  const source = await ensureSource(author, approver, data.source)
  const waiting = []
  for (const { spec, found } of plan) {
    const category = categories.find((c) => c.name.toLowerCase() === spec.category.toLowerCase())
    if (!category) throw new Error(`unknown category "${spec.category}" (have: ${categories.map((c) => c.name).join(', ')})`)
    let m = found
    if (!m) m = await author.call('POST', '/v1/admin/markets', terms(spec, { category: category.id, source }, season, Date.now()))
    if (m.status === 'DRAFT' || m.status === 'CHANGES_REQUESTED') m = await author.call('POST', `/v1/admin/markets/${m.id}/submit`, { version: m.version })
    if (m.status === 'REVIEW') m = await approver.call('POST', `/v1/admin/markets/${m.id}/approve`, { version: m.version })
    console.log(`${m.status.padEnd(9)} ${spec.question}`)
    if (m.status !== 'OPEN') waiting.push(m)
  }

  // Approved markets are opened by the server's scheduler once open_at passes.
  const deadline = Date.now() + Number(process.env.SEED_WAIT_SECONDS ?? 240) * 1000
  while (waiting.length && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 10_000))
    for (let i = waiting.length - 1; i >= 0; i--) {
      const m = await author.call('GET', `/v1/markets/${waiting[i].id}`).catch(() => null)
      if (m?.status === 'OPEN') {
        console.log(`OPEN      ${waiting[i].question}`)
        waiting.splice(i, 1)
      }
    }
  }
  if (waiting.length) {
    console.log(`${waiting.length} market(s) approved but not open yet; the scheduler opens them shortly after open_at.`)
  } else {
    console.log('all seeded markets are open')
  }
}

main().catch((e) => {
  console.error(e.message)
  process.exit(1)
})
