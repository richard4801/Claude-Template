// Live events for GET /v1/events, scoped per studio, per role and per user (plans/api.md "Live events").
// In-memory: one API instance. A second instance would need Postgres LISTEN/NOTIFY behind the same interface.
export type EventType = 'job' | 'take' | 'balance' | 'wallet' | 'model' | 'outfit' | 'lora' | 'post' | 'gpu' | 'tool' | 'template' | 'clip'
  | 'settings' | 'member' | 'invite' | 'studio' | 'account' | 'prompts'
  | 'editor' /* Editor v2 AI jobs (workstream 3) */;
export type ApiEvent = { type: EventType; [k: string]: unknown };
export type Viewer = { userId: string; studioId: string; role: 'owner' | 'member' };
type Payload = ApiEvent | null | undefined;
/** A fixed event (everyone gets the same line), or a view per viewer (null: this viewer gets nothing). */
export type EventSource = Payload | ((v: Viewer) => Payload | Promise<Payload>);
type Client = Viewer & { send: (line: string) => void; tail: Promise<void>; pending: number };

const line = (ev: ApiEvent) => `data: ${JSON.stringify(ev)}\n\n`;

export class EventHub {
  private clients = new Set<Client>();
  /** Where a failing per-viewer view is reported (set by the app). */
  onError: (e: unknown) => void = () => {};

  subscribe(studioId: string, userId: string, send: (line: string) => void, role: 'owner' | 'member' = 'member') {
    const c: Client = { studioId, userId, role, send, tail: Promise.resolve(), pending: 0 };
    this.clients.add(c);
    return () => { this.clients.delete(c); };
  }

  /** Everyone in the studio; a function is called once per user (owners and members can get different views). */
  emit(studioId: string, ev: EventSource) { return this.deliver([...this.clients].filter(c => c.studioId === studioId), ev); }
  /** One user (all their devices). */
  emitTo(userId: string, ev: EventSource) { return this.deliver([...this.clients].filter(c => c.userId === userId), ev); }
  /** The studio's owners only (studio balance, top-ups, members, invites, engines). */
  emitOwners(studioId: string, ev: EventSource) {
    return this.deliver([...this.clients].filter(c => c.studioId === studioId && c.role === 'owner'), ev);
  }

  connectedUsers(studioId: string) { return new Set([...this.clients].filter(c => c.studioId === studioId).map(c => c.userId)); }
  get size() { return this.clients.size; }

  /** Keeps each client's events in the order they were emitted, even when a view has to read the database. */
  private deliver(targets: Client[], ev: EventSource): Promise<void> {
    if (!targets.length || ev == null) return Promise.resolve();
    if (typeof ev !== 'function') {
      const l = line(ev);
      for (const c of targets) {
        if (!c.pending) { this.safeSend(c, l); continue; }
        c.pending++;
        c.tail = c.tail.then(() => this.safeSend(c, l)).finally(() => { c.pending--; });
      }
      return Promise.all(targets.map(c => c.tail)).then(() => {});
    }
    const perUser = new Map<string, Promise<Payload>>();
    for (const c of targets) {
      let p = perUser.get(c.userId);
      if (!p) {
        p = Promise.resolve().then(() => ev({ userId: c.userId, studioId: c.studioId, role: c.role })).catch(e => { this.onError(e); return null; });
        perUser.set(c.userId, p);
      }
      const view = p;
      c.pending++;
      c.tail = c.tail.then(async () => { const v = await view; if (v) this.safeSend(c, line(v)); }).finally(() => { c.pending--; });
    }
    return Promise.all(targets.map(c => c.tail)).then(() => {});
  }
  private safeSend(c: Client, l: string) { try { c.send(l); } catch (e) { this.onError(e); } }
}
