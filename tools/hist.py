"""Historique des prix TCGplayer (via TCGCSV) pour chaque set : hist/<sid>.json + prices-chg.json

hist/<sid>.json  {"e": fin quotidien, "we": fin hebdo, "k": {"<num>": {"<impr>": [90 valeurs]}}, "w": {"<num>": {"<impr>": [52 valeurs]}}}
  - valeurs en cents (USD), 0 = inconnu ; k = 90 derniers jours (le dernier = e), w = 52 semaines (le dernier = we)
prices-chg.json  {"d": date, "c": {"<sid>-<num>": {"<impr>": [var 7 j, var 30 j, var 90 j]}}}  en %, null si inconnu

python tools/hist.py              → ajoute le prix du jour (prices.json)
python tools/hist.py --backfill   → remplit aussi le passé depuis l'archive TCGCSV (reprend où il s'est arrêté)
"""
import json, os, sys, time, datetime, subprocess, shutil, tempfile, urllib.request, concurrent.futures as cf
ND, NW = 90, 52
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HD = os.path.join(ROOT, 'hist')
UA = {'User-Agent': 'Mozilla/5.0 InventoryMonitoring-hist'}
SUB = {'Normal': 'n', 'Holofoil': 'h', 'Reverse Holofoil': 'r', '1st Edition Holofoil': '1h', '1st Edition Normal': '1n', '1st Edition': '1n', 'Unlimited Holofoil': 'h', 'Unlimited': 'n'}
D = lambda s: datetime.date.fromisoformat(s)
P = json.load(open(os.path.join(ROOT, 'prices.json')))
TODAY = D(P['d'])
WE = TODAY - datetime.timedelta(days=(TODAY - datetime.date(2024, 1, 1)).days % 7)  # points hebdo alignés sur les lundis
os.makedirs(HD, exist_ok=True)

# ---------- chargement / roulement ----------
H = {}
for f in os.listdir(HD):
    if f.endswith('.json'): H[f[:-5]] = json.load(open(os.path.join(HD, f)))
def shard(sid):
    if sid not in H: H[sid] = {'e': TODAY.isoformat(), 'we': WE.isoformat(), 'k': {}, 'w': {}}
    return H[sid]
for h in H.values():
    g = (TODAY - D(h['e'])).days
    if g > 0:
        for prs in h['k'].values():
            for c, a in prs.items(): prs[c] = (a[g:] + [0] * g)[-ND:] if g < ND else [0] * ND
        h['e'] = TODAY.isoformat()
    wg = (WE - D(h['we'])).days // 7
    if wg > 0:
        for prs in h['w'].values():
            for c, a in prs.items(): prs[c] = (a[wg:] + [0] * wg)[-NW:] if wg < NW else [0] * NW
    h['we'] = WE.isoformat()
def put(sid, num, c, d, cents, over=True):
    h = shard(sid); e, we = D(h['e']), D(h['we'])
    i = ND - 1 - (e - d).days
    if 0 <= i < ND:
        a = h['k'].setdefault(num, {}).setdefault(c, [0] * ND)
        if over or not a[i]: a[i] = cents
    dd = (we - d).days
    if dd >= 0 and dd % 7 == 0 and dd // 7 < NW:
        a = h['w'].setdefault(num, {}).setdefault(c, [0] * NW); j = NW - 1 - dd // 7
        if over or not a[j]: a[j] = cents

# ---------- prix du jour ----------
for key, prs in P['p'].items():
    sid, num = key.split('-', 1)
    for c, v in prs.items():
        if v: put(sid, num, c, TODAY, int(round(v * 100)))

# ---------- passé (archive TCGCSV) ----------
def backfill(budget):
    PM = json.load(open(os.path.join(ROOT, 'tools', 'pmap.json')))  # {groupId: {productId: [clé, ...]}}
    donef = os.path.join(ROOT, 'tools', 'hist_done.json')
    st = json.load(open(donef)) if os.path.exists(donef) else []
    if isinstance(st, list): st = {'done': st, 'fail': {}}
    done, fail = set(st['done']), st.get('fail', {})
    dates = {TODAY - datetime.timedelta(days=k) for k in range(1, ND)} | {WE - datetime.timedelta(days=7 * k) for k in range(NW)}
    dates.discard(TODAY)
    redo = any(not h.get('bf') for h in H.values())  # set nouveau ou incomplet : on relit tout (les valeurs existantes ne sont pas écrasées)
    todo = sorted((d for d in dates if (redo or d.isoformat() not in done) and fail.get(d.isoformat(), 0) < 3 and d >= datetime.date(2024, 2, 8)), reverse=True)
    print('relecture complète' if redo else 'dates manquantes seulement')
    print('archives à lire', len(todo)); T0 = time.time()
    def one(d):
        ds = d.isoformat(); tmp = tempfile.mkdtemp(); f = os.path.join(tmp, 'a.7z'); t = time.time()
        for k in range(3):
            try:
                with urllib.request.urlopen(urllib.request.Request(f'https://tcgcsv.com/archive/tcgplayer/prices-{ds}.ppmd.7z', headers=UA), timeout=180) as r, open(f, 'wb') as o: shutil.copyfileobj(r, o)
                break
            except Exception as e:
                code = getattr(e, 'code', 0)
                if code == 404: shutil.rmtree(tmp, True); return ds, None, 'absent'
                time.sleep(10 * (k + 1))
        else: shutil.rmtree(tmp, True); return ds, None, 'échec'
        size = os.path.getsize(f); out = os.path.join(tmp, 'x')
        subprocess.run(['7z', 'x', f, '-o' + out, '-y', '-bd', '-bso0', '-bsp0', '-r', f'{ds}/3/*'], check=False)
        base = os.path.join(out, ds, '3')
        if not os.path.isdir(base):
            subprocess.run(['7z', 'x', f, '-o' + out, '-y', '-bd', '-bso0', '-bsp0'], check=False)
        rows = []
        for gid, prods in PM.items():
            pf = os.path.join(base, gid, 'prices')
            if not os.path.exists(pf): continue
            try: j = json.load(open(pf))
            except Exception: continue
            for q in (j.get('results') if isinstance(j, dict) else j) or []:
                keys = prods.get(str(q.get('productId'))); m = q.get('marketPrice') or q.get('midPrice'); c = SUB.get(q.get('subTypeName'))
                if keys and m and c: rows.append((keys, c, int(round(float(m) * 100))))
        shutil.rmtree(tmp, True)
        return ds, rows, f'{size/1e6:.1f} Mo, {time.time()-t:.0f} s'
    with cf.ThreadPoolExecutor(3) as ex:
        futs = {}
        it = iter(todo)
        for d in it:
            futs[ex.submit(one, d)] = d
            if len(futs) >= 3: break
        while futs:
            fin, _ = cf.wait(futs, return_when=cf.FIRST_COMPLETED)
            for fu in fin:
                d = futs.pop(fu); ds, rows, info = fu.result()
                print(ds, info, len(rows or []), 'prix', flush=True)
                if rows is None and info != 'absent': fail[ds] = fail.get(ds, 0) + 1
                if rows is not None or info == 'absent':
                    seen = set()
                    for keys, c, v in rows or []:
                        for key in keys:
                            if (key, c) in seen: continue
                            seen.add((key, c)); sid, num = key.split('-', 1); put(sid, num, c, d, v, over=False)
                    done.add(ds)
                if time.time() - T0 < budget:
                    nx = next(it, None)
                    if nx: futs[ex.submit(one, nx)] = nx
    keep = {d.isoformat() for d in dates}
    json.dump({'done': sorted(x for x in done if x in keep), 'fail': {k: v for k, v in fail.items() if k in keep}}, open(donef, 'w'), separators=(',', ':'))
    if time.time() - T0 < budget:
        for h in H.values(): h['bf'] = 1
    print('archives lues', len(done), 'en', round(time.time() - T0), 's')

if '--backfill' in sys.argv: backfill(float(os.environ.get('BUDGET', 5400)))

# ---------- variations ----------
CH = {}
def last(a, upto):
    for x in reversed(a[:upto]):
        if x: return x
    return 0
def clean(a):  # prix aberrants (prévente, annonce isolée) : ignorés pour les variations
    v = sorted(x for x in a if x)
    if len(v) < 5: return a
    md = v[len(v) // 2]
    return [x if md / 4 <= x <= md * 4 else 0 for x in a]
for sid, h in H.items():
    for num, prs in h['k'].items():
        for c, a in prs.items():
            a = clean(a)
            now = a[-1] or last(a, ND)
            if now < 50: continue
            v = []
            for back in (7, 30):
                p = a[ND - 1 - back] or last(a, ND - back)
                v.append(round((now / p - 1) * 100) if p else None)
            w = clean(h['w'].get(num, {}).get(c) or [])
            p = (w[NW - 1 - 13] if len(w) == NW else 0) or a[0]
            v.append(round((now / p - 1) * 100) if p else None)
            if any(x for x in v): CH.setdefault(f'{sid}-{num}', {})[c] = v
json.dump({'d': TODAY.isoformat(), 'c': CH}, open(os.path.join(ROOT, 'prices-chg.json'), 'w'), separators=(',', ':'), sort_keys=True)
for sid, h in H.items():
    json.dump(h, open(os.path.join(HD, sid + '.json'), 'w'), separators=(',', ':'), sort_keys=True)
tot = sum(len(h['k']) for h in H.values())
print('sets', len(H), 'cartes', tot, 'variations', len(CH))
