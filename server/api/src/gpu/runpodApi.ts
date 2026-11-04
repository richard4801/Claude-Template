// Minimal RunPod GraphQL client. The API key is sent only in the Authorization header and never logged:
// errors carry RunPod's message, not the request.
export type RunpodPod = { id: string; desiredStatus?: string; costPerHr?: number; runtime?: { uptimeInSeconds?: number } | null };

export class RunpodError extends Error {}

export class RunpodApi {
  constructor(private key: string | undefined, private url = 'https://api.runpod.io/graphql', private fetchFn: typeof fetch = fetch) {}

  get configured() { return !!this.key; }

  async gql<T>(query: string, variables: Record<string, unknown> = {}): Promise<T> {
    if (!this.key) throw new RunpodError('RUNPOD_API_KEY is not set');
    let res: Response;
    try {
      res = await this.fetchFn(this.url, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${this.key}` },
        body: JSON.stringify({ query, variables }),
        signal: AbortSignal.timeout(20_000),
      });
    } catch (e) {
      throw new RunpodError(`RunPod unreachable: ${(e as Error).name}`);
    }
    const body = (await res.json().catch(() => ({}))) as { data?: T; errors?: { message: string }[] };
    if (!res.ok || body.errors?.length) throw new RunpodError(`RunPod API error ${res.status}: ${body.errors?.map(e => e.message).join('; ') ?? 'no body'}`);
    return body.data as T;
  }

  async myself() {
    const d = await this.gql<{ myself: { clientBalance: number; currentSpendPerHr: number } }>('query { myself { clientBalance currentSpendPerHr } }');
    return d.myself;
  }
  async gpuTypes() {
    const d = await this.gql<{ gpuTypes: { id: string; displayName: string; memoryInGb: number }[] }>('query { gpuTypes { id displayName memoryInGb } }');
    return d.gpuTypes;
  }
  async pod(podId: string) {
    const d = await this.gql<{ pod: RunpodPod | null }>('query Pod($input: PodFilter!) { pod(input: $input) { id desiredStatus costPerHr runtime { uptimeInSeconds } } }', { input: { podId } });
    return d.pod;
  }
  async deployOnDemand(input: Record<string, unknown>) {
    const d = await this.gql<{ podFindAndDeployOnDemand: RunpodPod }>(
      'mutation Deploy($input: PodFindAndDeployOnDemandInput!) { podFindAndDeployOnDemand(input: $input) { id desiredStatus costPerHr } }', { input });
    return d.podFindAndDeployOnDemand;
  }
  async resume(podId: string) {
    const d = await this.gql<{ podResume: RunpodPod }>('mutation Resume($input: PodResumeInput!) { podResume(input: $input) { id desiredStatus costPerHr } }', { input: { podId, gpuCount: 1 } });
    return d.podResume;
  }
  async stop(podId: string) {
    await this.gql('mutation Stop($input: PodStopInput!) { podStop(input: $input) { id desiredStatus } }', { input: { podId } });
  }
  async terminate(podId: string) {
    await this.gql('mutation Terminate($input: PodTerminateInput!) { podTerminate(input: $input) }', { input: { podId } });
  }
}
