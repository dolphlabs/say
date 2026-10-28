export class EventDeduplicator {
  private readonly eventIds = new Map<string, true>();
  readonly capacity: number;

  constructor(capacity = 1_000) {
    if (!Number.isInteger(capacity) || capacity < 1) {
      throw new RangeError("deduplicator capacity must be a positive integer");
    }
    this.capacity = capacity;
  }

  accept(eventId: string): boolean {
    if (this.eventIds.has(eventId)) {
      return false;
    }
    this.eventIds.set(eventId, true);
    if (this.eventIds.size > this.capacity) {
      const oldest = this.eventIds.keys().next().value;
      if (oldest !== undefined) {
        this.eventIds.delete(oldest);
      }
    }
    return true;
  }

  clear(): void {
    this.eventIds.clear();
  }
}
