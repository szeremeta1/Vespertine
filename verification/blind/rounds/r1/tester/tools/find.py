import sys, re, json, importlib.util
from pathlib import Path
room = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('cc', room / 'citecheck.py'); cc = importlib.util.module_from_spec(spec); spec.loader.exec_module(cc)
idx = json.load(open(room / 'corpus/index.json'))
_cache = {}
def find(doc, q):
    d = next(x for x in idx['docs'] if x['id'] == doc)
    if doc not in _cache:
        _cache[doc] = {p: cc.ws(t) for p, t in cc.load_pages(room / 'corpus' / d['file']).items()}
    q = cc.ws(q)
    out = [p for p, t in _cache[doc].items() if q in t]
    secs = [(s['id'], s['pages']) for s in d['sections'] if any(p in s['pages'] for p in out)]
    print(doc, repr(q[:60]), out, secs[:4])
if __name__ == '__main__':
    for line in sys.stdin:
        line = line.rstrip('\n')
        if line:
            doc, q = line.split('\t', 1); find(doc, q)
