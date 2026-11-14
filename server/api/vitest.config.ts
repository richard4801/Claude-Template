import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    testTimeout: 30_000,
    hookTimeout: 60_000,
    pool: 'forks',
    // The suite runs as the small (Trial) media profile: one pipeline at a time, today's thread counts (lib/resources.ts).
    env: { MEDIA_MEM_MB: '1024', MEDIA_CPUS: '2' },
  },
});
