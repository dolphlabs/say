import { useQuery } from '@tanstack/react-query'
import { get } from '../../api'

export type ProfileCall = { market: { slug: string; question: string }; side: string; status: 'OPEN' | 'WON' | 'LOST' | 'VOIDED' | string; chance_pct?: number }

export type Profile = {
  username: string
  avatar_color: string
  joined_season: string
  share_url: string
  current_season: { rank: number; of: number; profit: number; calls: number; right: number; settled: number }
  calls: ProfileCall[]
}

export type Preference = { kind: string; label: string; hint: string; in_app: boolean; email: boolean }

export const useProfile = (username: string | undefined) =>
  useQuery({ queryKey: ['profile', username], queryFn: () => get<Profile>(`/v1/users/${encodeURIComponent(username ?? '')}`), enabled: !!username, retry: false })

export const usePreferences = () => useQuery({ queryKey: ['notification-prefs'], queryFn: () => get<Preference[]>('/v1/me/notification-prefs') })
