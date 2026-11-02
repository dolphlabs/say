import type { ReactNode } from 'react'

type IconProps = { size?: number; label?: string; className?: string }

function Svg({ size = 18, label, className, children, width = 2 }: IconProps & { children: ReactNode; width?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={width}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      role={label ? 'img' : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    >
      {children}
    </svg>
  )
}

export const SearchIcon = (p: IconProps) => <Svg {...p}><circle cx="11" cy="11" r="7" /><path d="M20 20l-3.5-3.5" /></Svg>
export const BellIcon = (p: IconProps) => <Svg {...p}><path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4z M10 21h4" /></Svg>
export const CloseIcon = (p: IconProps) => <Svg {...p} width={2.5}><path d="M6 6l12 12M18 6L6 18" /></Svg>
export const CheckIcon = (p: IconProps) => <Svg {...p} width={3}><path d="M5 12l5 5 9-10" /></Svg>
export const LockIcon = (p: IconProps) => <Svg {...p} width={1.8}><path d="M6 11h12v10H6z M9 11V8a3 3 0 0 1 6 0v3" /></Svg>
export const ShareIcon = (p: IconProps) => <Svg {...p}><path d="M4 12v8h16v-8 M12 3v13 M7 8l5-5 5 5" /></Svg>
export const MenuIcon = (p: IconProps) => <Svg {...p}><path d="M4 7h16M4 12h16M4 17h16" /></Svg>
export const InboxIcon = (p: IconProps) => <Svg {...p} width={1.8}><path d="M3 13l3-8h12l3 8v6H3z M3 13h5l1 3h6l1-3h5" /></Svg>

const CATEGORY_PATHS: Record<string, string> = {
  football: 'M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z M12 7l4 3-1.5 4.5h-5L8 10z',
  music: 'M9 18V5l11-2v13 M9 18a3 3 0 1 1-6 0a3 3 0 1 1 6 0z M20 16a3 3 0 1 1-6 0a3 3 0 1 1 6 0z',
  laptop: 'M7 7h10v10H7z M10 2v5 M14 2v5 M10 17v5 M14 17v5 M2 10h5 M2 14h5 M17 10h5 M17 14h5',
  culture: 'M4 5h16v14H4z M8 5v14 M16 5v14 M4 9h4 M4 15h4 M16 9h4 M16 15h4',
  'cloud-rain': 'M7 15a4 4 0 1 1 1-7.9A5 5 0 0 1 18 9a3 3 0 0 1 0 6z M9 19l-1 2 M13 19l-1 2 M17 19l-1 2',
}

const FALLBACK_PATH = 'M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z M12 8v5 M12 16h.01'

const TINTS: Record<string, string> = {
  football: 'blue',
  music: 'pink',
  laptop: 'purple',
  culture: 'orange',
  'cloud-rain': 'cyan',
}

export function CategoryIcon({ icon, size = 'md' }: { icon?: string; size?: 'sm' | 'md' | 'lg' }) {
  const key = icon ?? ''
  const glyph = { sm: 22, md: 28, lg: 34 }[size]
  return (
    <span className={`category-icon ${size} tint-${TINTS[key] ?? 'grey'}`}>
      <Svg size={glyph} width={1.8}>
        <path d={CATEGORY_PATHS[key] ?? FALLBACK_PATH} />
      </Svg>
    </span>
  )
}
