import { useEffect } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { browserSocketFactory, StreamConnection } from '../../../packages/say-stream/src/index'
import { endSession } from './session'

const REFRESH_DELAY_MS = 1000

function streamUrl(anonymous: boolean) {
  const url = new URL('/v1/stream', window.location.href)
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  if (anonymous) url.searchParams.set('anonymous', 'true')
  return url.toString()
}

// Stream events only trigger throttled REST refetches: the REST views carry
// no per-entity revision the stream's private hydrator could reconcile with.
export function useLiveMarkets(marketId?: string) {
  const client = useQueryClient()
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined
    const refresh = () => {
      if (timer) return
      timer = setTimeout(() => {
        timer = undefined
        void client.invalidateQueries({ queryKey: ['markets'] })
        void client.invalidateQueries({ queryKey: ['featured'] })
        if (marketId) {
          for (const key of ['market', 'book', 'trades', 'history', 'resolution']) void client.invalidateQueries({ queryKey: [key] })
        }
      }, REFRESH_DELAY_MS)
    }
    let stream: StreamConnection | undefined
    try {
      stream = new StreamConnection({
        getUrl: streamUrl,
        socketFactory: browserSocketFactory,
        onEvent: refresh,
        onState: (state) => {
          if (state === 'LIVE') refresh()
        },
        onReauthenticate: () => {
          void endSession(client).then(() => client.invalidateQueries({ queryKey: ['me'] }))
        },
      })
      stream.subscribe(marketId ? ['cards', `market:${marketId}:book`, `market:${marketId}:trades`, `market:${marketId}:status`] : ['cards'])
      stream.connect()
    } catch (error) {
      // Every view also polls over REST, so a stream that cannot start costs
      // freshness, not correctness; it must not take the page down.
      console.warn('live updates unavailable', error)
    }
    return () => {
      if (timer) clearTimeout(timer)
      stream?.dispose()
    }
  }, [client, marketId])
}
