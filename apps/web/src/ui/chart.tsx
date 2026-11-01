type AreaChartProps = {
  values: number[]
  width?: number
  height?: number
  min?: number
  max?: number
  label: string
  className?: string
  guides?: number[]
}

export function AreaChart({ values, width = 640, height = 200, min, max, label, className = '', guides = [0.5] }: AreaChartProps) {
  if (values.length === 0) return null
  const lo = min ?? Math.min(...values)
  const hi = max ?? Math.max(...values)
  const span = hi - lo || 1
  const x = (i: number) => (values.length === 1 ? width / 2 : Math.round((i / (values.length - 1)) * width))
  const y = (v: number) => Math.round(height - ((v - lo) / span) * height)
  const points = values.map((v, i) => `${x(i)},${y(v)}`).join(' ')
  const rising = values[values.length - 1] >= values[0]
  return (
    <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" role="img" aria-label={label} className={`area-chart ${rising ? 'up' : 'down'} ${className}`}>
      {guides.map((g) => (
        <line key={g} x1="0" x2={width} y1={height * g} y2={height * g} className="guide" vectorEffect="non-scaling-stroke" />
      ))}
      <polygon points={`0,${height} ${points} ${width},${height}`} className="area" />
      <polyline points={points} className="line" vectorEffect="non-scaling-stroke" />
    </svg>
  )
}
