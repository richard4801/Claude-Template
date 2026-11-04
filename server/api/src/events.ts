// Live events for GET /v1/events, scoped per studio (and per user for wallet/balance events).
// In-memory: one API instance. A second instance would need Postgres LISTEN/NOTIFY behind the same interface.
export type ApiEvent = { type: 'job' | 'balance' | 'model' | 'outfit' | 'lora' | 'post' | 'wallet' | 'gpu'; [k: string]: unknown };
type Client = { studioId: string; userId: string; send: (line: string) => void };

export class EventHub {
  private clients = new Set<Client>();

  subscribe(studioId: string, userId: string, send: (line: string) => void) {
    const c = { studioId, userId, send };
    this.clients.add(c);
    return () => { this.clients.delete(c); };
  }
  /** Everyone in the studio. */
  emit(studioId: string, ev: ApiEvent) {
    const line = `data: ${JSON.stringify(ev)}\n\n`;
    for (const c of this.clients) if (c.studioId === studioId) c.send(line);
  }
  /** One user (all their devices). */
  emitTo(userId: string, ev: ApiEvent) {
    const line = `data: ${JSON.stringify(ev)}\n\n`;
    for (const c of this.clients) if (c.userId === userId) c.send(line);
  }
  connectedUsers(studioId: string) { return new Set([...this.clients].filter(c => c.studioId === studioId).map(c => c.userId)); }
  get size() { return this.clients.size; }
}
