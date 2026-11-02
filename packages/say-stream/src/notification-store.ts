// Notification store for Say stream clients per Prompt 07 section 3 & 5.

export interface NotificationItem {
  id: string;
  kind: string;
  dedupe_key: string;
  title: string;
  body: string;
  link: string;
  data: Record<string, unknown>;
  created_at: string;
  updated_at: string;
  unread: boolean;
}

export interface NotificationState {
  items: NotificationItem[];
  unreadCount: number;
}

export type NotificationListener = (state: NotificationState) => void;

export class NotificationStore {
  private items: NotificationItem[] = [];
  private unreadCount: number = 0;
  private listeners: Set<NotificationListener> = new Set();

  constructor(initialItems: NotificationItem[] = [], initialUnreadCount: number = 0) {
    this.items = [...initialItems];
    this.unreadCount = initialUnreadCount;
  }

  public getState(): NotificationState {
    return {
      items: [...this.items],
      unreadCount: this.unreadCount,
    };
  }

  public subscribe(listener: NotificationListener): () => void {
    this.listeners.add(listener);
    listener(this.getState());
    return () => {
      this.listeners.delete(listener);
    };
  }

  private notify(): void {
    const state = this.getState();
    for (const listener of this.listeners) {
      listener(state);
    }
  }

  /**
   * Handle incoming notification event from stream / WebSocket.
   * Dedupes or coalesces existing items by dedupe_key or id.
   */
  public handleEvent(event: {
    id: string;
    kind: string;
    dedupe_key?: string;
    title: string;
    body: string;
    link?: string;
    data?: Record<string, unknown>;
    created_at?: string;
    updated_at?: string;
  }): void {
    const dedupeKey = event.dedupe_key || event.id;
    const existingIndex = this.items.findIndex(
      (item) => item.dedupe_key === dedupeKey || item.id === event.id
    );

    const now = new Date().toISOString();
    if (existingIndex >= 0) {
      const existing = this.items[existingIndex];
      const wasUnread = existing.unread;
      // Coalesce / update in place
      const updatedItem: NotificationItem = {
        ...existing,
        title: event.title,
        body: event.body,
        link: event.link ?? existing.link,
        data: event.data ?? existing.data,
        updated_at: event.updated_at ?? now,
        unread: true, // Marked unread again on coalesced update
      };
      this.items[existingIndex] = updatedItem;
      if (!wasUnread) {
        this.unreadCount += 1;
      }
    } else {
      // New item at the beginning
      const newItem: NotificationItem = {
        id: event.id,
        kind: event.kind,
        dedupe_key: dedupeKey,
        title: event.title,
        body: event.body,
        link: event.link ?? "",
        data: event.data ?? {},
        created_at: event.created_at ?? now,
        updated_at: event.updated_at ?? now,
        unread: true,
      };
      this.items.unshift(newItem);
      this.unreadCount += 1;
    }

    this.notify();
  }

  /**
   * Optimistically marks items as read.
   */
  public markRead(ids?: string[]): void {
    if (!ids) {
      // Mark all read
      for (const item of this.items) {
        item.unread = false;
      }
      this.unreadCount = 0;
    } else {
      const idSet = new Set(ids);
      for (const item of this.items) {
        if (idSet.has(item.id) && item.unread) {
          item.unread = false;
          this.unreadCount = Math.max(0, this.unreadCount - 1);
        }
      }
    }
    this.notify();
  }

  /**
   * Resets entire store from authoritative REST payload.
   */
  public setAuthoritative(items: NotificationItem[], unreadCount: number): void {
    this.items = [...items];
    this.unreadCount = unreadCount;
    this.notify();
  }
}
