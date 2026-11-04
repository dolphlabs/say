import { useState, type FormEvent } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { errorMessage, get, isApiError, post } from '../../api'
import { Chip, Empty, Loading, Notice } from '../../ui/kit'
import { AdminHeader } from './Shell'

type Source = { id: string; name: string; url_pattern: string; kind: 'html' | 'json'; approved: boolean }

const SOURCES_KEY = ['admin', 'sources']

function NewSource({ onDone }: { onDone: () => void }) {
  const client = useQueryClient()
  const [name, setName] = useState('')
  const [url, setUrl] = useState('')
  const [kind, setKind] = useState<'html' | 'json'>('html')
  const create = useMutation({
    mutationFn: () => post<Source>('/v1/admin/resolution-sources', { name: name.trim(), url_pattern: url.trim(), kind }),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: SOURCES_KEY })
      onDone()
    },
  })
  const submit = (e: FormEvent) => {
    e.preventDefault()
    create.mutate()
  }
  return (
    <form className="panel admin-form" onSubmit={submit} aria-labelledby="source-form-h">
      <div className="panel-head">
        <h2 id="source-form-h">New resolution source</h2>
        <button type="button" className="button ghost small" onClick={onDone}>
          Close
        </button>
      </div>
      <label>
        Name
        <input value={name} onChange={(e) => setName(e.target.value)} maxLength={120} required />
        <span className="hint">What resolvers will check, for example “NPFL official results”.</span>
      </label>
      <div className="two">
        <label>
          Address
          <input type="url" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://" required />
        </label>
        <label>
          Kind
          <select value={kind} onChange={(e) => setKind(e.target.value as 'html' | 'json')}>
            <option value="html">Web page</option>
            <option value="json">JSON feed</option>
          </select>
        </label>
      </div>
      <p className="muted small">A new source starts unapproved. Another curator has to approve it before markets can use it.</p>
      <Notice error={create.error ? errorMessage(create.error) : undefined} />
      <div className="row">
        <button type="submit" className="button lime" disabled={create.isPending || !name.trim() || !url.trim()}>
          Add source
        </button>
      </div>
    </form>
  )
}

function SourceRow({ source }: { source: Source }) {
  const client = useQueryClient()
  const approve = useMutation({
    mutationFn: () => post<Source>(`/v1/admin/resolution-sources/${source.id}/approve`),
    onSuccess: () => void client.invalidateQueries({ queryKey: SOURCES_KEY }),
  })
  const own = isApiError(approve.error, 'SELF_APPROVAL_FORBIDDEN')
  return (
    <tr>
      <td>
        <div className="strong">{source.name}</div>
        <a className="muted small" href={source.url_pattern} target="_blank" rel="noreferrer noopener">
          {source.url_pattern}
        </a>
      </td>
      <td>{source.kind === 'json' ? 'JSON feed' : 'Web page'}</td>
      <td>{source.approved ? <Chip tone="green">Approved</Chip> : <Chip tone="white">Waiting for approval</Chip>}</td>
      <td className="right">
        {!source.approved && (
          <button type="button" className="button dim small" disabled={approve.isPending} onClick={() => approve.mutate()}>
            Approve
          </button>
        )}
        {approve.error && (
          <div className="small danger-text" role="alert">
            {own ? 'You added this source, so another curator has to approve it.' : errorMessage(approve.error)}
          </div>
        )}
      </td>
    </tr>
  )
}

export function AdminSources() {
  const [adding, setAdding] = useState(false)
  const sources = useQuery({ queryKey: SOURCES_KEY, queryFn: () => get<Source[]>('/v1/admin/resolution-sources') })
  const list = sources.data ?? []
  const waiting = list.filter((s) => !s.approved).length
  return (
    <>
      <AdminHeader
        title="Resolution sources"
        subtitle={waiting ? `${waiting} waiting for approval` : 'Where results are checked before a market resolves'}
        action={
          !adding && (
            <button type="button" className="button lime" onClick={() => setAdding(true)}>
              New source
            </button>
          )
        }
      />
      {adding && <NewSource onDone={() => setAdding(false)} />}
      <section className="panel flush" aria-label="Resolution sources">
        {sources.isLoading ? (
          <Loading />
        ) : sources.error ? (
          <Notice error={sources.error} />
        ) : list.length ? (
          <div className="table-scroll">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Source</th>
                  <th>Kind</th>
                  <th>Status</th>
                  <th className="right">
                    <span className="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {list.map((s) => (
                  <SourceRow key={s.id} source={s} />
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <Empty title="No sources yet">Add the first place results will be checked, then ask another curator to approve it.</Empty>
        )}
      </section>
    </>
  )
}
