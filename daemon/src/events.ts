import type { Event } from "./protocol";

export type Subscriber = (event: Event) => void;

// In-process fan-out for the append-only event log. The store appends an event
// and then publishes it here; every events.subscribe connection listens to this
// bus (docs/protocol-mvp.md "Events"). Subscribers must never throw: one bad
// subscriber must not drop an event for the rest.
export class EventBus {
  private subscribers = new Set<Subscriber>();

  subscribe(fn: Subscriber): () => void {
    this.subscribers.add(fn);
    return () => {
      this.subscribers.delete(fn);
    };
  }

  emit(event: Event): void {
    for (const fn of this.subscribers) {
      try {
        fn(event);
      } catch {
        // A subscriber socket that closed mid-write must not break the others.
      }
    }
  }

  get subscriberCount(): number {
    return this.subscribers.size;
  }
}
