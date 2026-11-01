import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react'
import { CheckIcon, CloseIcon } from './icons'

type Toast = { title: string; body?: string }

const ToastContext = createContext<(toast: Toast) => void>(() => {})

const TOAST_MS = 6000

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toast, setToast] = useState<Toast | null>(null)
  const show = useCallback((next: Toast) => setToast(next), [])
  useEffect(() => {
    if (!toast) return
    const id = setTimeout(() => setToast(null), TOAST_MS)
    return () => clearTimeout(id)
  }, [toast])
  return (
    <ToastContext.Provider value={show}>
      {children}
      {toast && (
        <div className="toast" role="status">
          <span className="toast-mark">
            <CheckIcon size={16} />
          </span>
          <div>
            <strong>{toast.title}</strong>
            {toast.body && <span>{toast.body}</span>}
          </div>
          <button type="button" aria-label="Dismiss" onClick={() => setToast(null)}>
            <CloseIcon size={14} />
          </button>
        </div>
      )}
    </ToastContext.Provider>
  )
}

export const useToast = () => useContext(ToastContext)
