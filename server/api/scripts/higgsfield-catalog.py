# Builds assets/higgsfield/catalog.json (the Bring-your-own Higgsfield catalog) from Higgsfield's published docs.
# Higgsfield has no model-list API: every model page in https://docs.higgsfield.ai/llms-full.txt carries its
# "Endpoint ID" and a "Complete JSON schema" for its input. Refresh when Higgsfield adds models:
#   curl -sS https://docs.higgsfield.ai/llms-full.txt -o /tmp/hf-docs.txt
#   python3 -I scripts/higgsfield-catalog.py /tmp/hf-docs.txt assets/higgsfield/catalog.json
# Field descriptions are dropped (the owner reads them on Higgsfield's docs page, linked per model).
import datetime, json, re, sys

# Image models by endpoint prefix (Higgsfield's "Image Generation API" group); everything else is video.
IMAGE = ('higgsfield/ads-studio/', 'xai/grok-imagine-image', 'ideogram/', 'marketing-studio/image', 'alibaba/qwen-image',
         'recraft/', 'higgsfield-ai/soul/', 'z-image/')

def strip(s):
    if isinstance(s, dict):
        return {k: strip(v) for k, v in s.items() if k not in ('description', 'examples', 'title')}
    if isinstance(s, list):
        return [strip(x) for x in s]
    return s

def main(src, out):
    lines = open(src, encoding='utf-8').read().split('\n')
    models, cur, i = [], None, 0
    while i < len(lines):
        l = lines[i]
        if l.startswith('# '):
            cur = {'title': l[2:].strip(), 'source': None, 'ref': None}
        elif cur is not None and l.startswith('Source: '):
            cur['source'] = l[8:].strip()
        elif cur is not None and l.startswith('**Endpoint ID:**'):
            m = re.search(r'`([^`]+)`', l)
            cur['ref'] = m.group(1) if m else None
        elif cur is not None and cur.get('ref') and 'Complete JSON schema' in l:
            j = i + 1
            while '```json' not in lines[j]:
                j += 1
            j += 1
            buf = []
            while not lines[j].lstrip('> ').startswith('```'):
                buf.append(re.sub(r'^>\s?', '', lines[j]))
                j += 1
            schema = json.loads('\n'.join(buf))
            ref = cur['ref']
            models.append({'ref': ref, 'name': re.sub(r'\s+API$', '', cur['title']), 'kind': 'image' if ref.startswith(IMAGE) else 'video',
                           'docs': cur['source'], 'schema': strip(schema)})
            cur, i = None, j
        i += 1
    seen, res = set(), []
    for m in models:
        if m['ref'] not in seen:
            seen.add(m['ref'])
            res.append(m)
    res.sort(key=lambda m: m['name'].lower())
    json.dump({'source': 'https://docs.higgsfield.ai/llms-full.txt', 'readAt': datetime.date.today().isoformat(), 'models': res},
              open(out, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print(f"{len(res)} models: {sum(m['kind'] == 'image' for m in res)} image, {sum(m['kind'] == 'video' for m in res)} video")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
