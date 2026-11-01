import type { ComponentType } from 'react'
import { Navigate, useParams } from '@tanstack/react-router'
import { AdminApprovals } from './Approvals'
import { AdminMarkets } from './Markets'
import { AdminResolution } from './Resolution'
import { AdminShell, type Section } from './Shell'
import { AdminTreasury } from './Treasury'

const PAGES: Record<Section, ComponentType> = {
  markets: AdminMarkets,
  resolution: AdminResolution,
  treasury: AdminTreasury,
  approvals: AdminApprovals,
}

export function AdminPage() {
  const { section } = useParams({ from: '/admin/$section' })
  const Page = PAGES[section as Section]
  if (!Page) return <Navigate to="/admin/$section" params={{ section: 'markets' }} replace />
  return (
    <AdminShell section={section as Section}>
      <Page />
    </AdminShell>
  )
}
