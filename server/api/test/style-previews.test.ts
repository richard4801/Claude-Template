// Style → Genre / Era / Tempo tile stills (workstream 4, resume item 12c): every visible option has its own still,
// the file exists in design/previews (bundled in both apps as `previews/`), and the apps' demo catalogs carry them.
import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { cameraCatalog } from '../src/suite/camera.js';

const DESIGN = path.resolve(__dirname, '../../../design/previews');

describe('Style tile stills', () => {
  const cat = cameraCatalog();
  for (const kind of ['genres', 'eras', 'tempos'] as const) {
    it(`${kind}: each option has its own still on disk`, () => {
      const list = cat[kind] as { id: string; visible: boolean; preview?: { poster: string } }[];
      expect(list.length).toBeGreaterThan(0);
      const posters = new Set<string>();
      for (const o of list.filter(x => x.visible)) {
        expect(o.preview?.poster, o.id).toBe(`${kind}/${o.id}.jpg`);
        expect(fs.existsSync(path.join(DESIGN, o.preview!.poster)), o.preview!.poster).toBe(true);
        posters.add(o.preview!.poster);
      }
      expect(posters.size).toBe(list.filter(x => x.visible).length);   // no two options share a still
    });
  }
  it("the apps' demo catalogs carry the same stills", () => {
    const android = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../../android/app/src/main/resources/suite_camera.json'), 'utf8'));
    const mac = fs.readFileSync(path.resolve(__dirname, '../../../mac/MuseCore/Sources/MuseCore/Suite/SuiteDemoCatalog.swift'), 'utf8');
    for (const kind of ['genres', 'eras', 'tempos'] as const) {
      for (const o of cat[kind] as { id: string; preview?: { poster: string } }[]) {
        expect(android[kind].find((x: { id: string }) => x.id === o.id)?.preview, `android ${kind}/${o.id}`).toEqual(o.preview);
        expect(mac, `mac ${kind}/${o.id}`).toContain(`"preview":{"poster":"${kind}/${o.id}.jpg"}`);
      }
    }
  });
});
