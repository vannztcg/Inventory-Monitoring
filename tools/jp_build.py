"""Catalogue des cartes japonaises : cards-jp.json + empreintes visuelles cards-jp-vis.bin (pour le Smart Scan).
Sources : TCGplayer « Pokemon Japan » via TCGCSV (catégorie 85 : noms anglais, numéros, photos, productId pour les prix)
          + TCGdex (tools/jp_tcgdex.json : noms japonais, images de repli). Tourne dans GitHub Actions (accès réseau).
Ligne de carte : [set, numéro, nom, nom japonais, rareté, productId TCGplayer, image] ; image 1 = TCGplayer, 2 = TCGdex, 0 = aucune.
Set : [id, nom, total, date, code, nom japonais, série TCGdex, 0].
"""
import json, re, time, struct, collections, sys, os, urllib.request, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(__file__))
from vis_hash import desc
import io, urllib.error
from PIL import Image
def fetch(u):
    for t in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=20) as r: return Image.open(io.BytesIO(r.read()))
        except urllib.error.HTTPError as e:
            if e.code in (403, 404, 410): raise
            err = e; time.sleep(1 + 2 * t)
        except Exception as e: err = e; time.sleep(1 + 2 * t)
    raise err
UA = {'User-Agent': 'Mozilla/5.0 InventoryMonitoring-jp'}
def get(u, tries=9):
    for t in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=60) as r: return json.loads(r.read())
        except Exception as e:
            err = e; time.sleep(20 * (t + 1) if getattr(e, 'code', 0) in (401, 403, 429) else 2 + 2 * t)
    raise err
nk = lambda s: re.sub(r'^([a-z]*)0+(?=\d)', r'\1', str(s).split('/')[0].strip().lower())
B = json.load(open('tools/jp_tcgdex.json'))
sets = [list(s) for s in B['sets']]; rar = list(B['rar']); RI = {r: i for i, r in enumerate(rar)}
def ri(r):
    if r not in RI: RI[r] = len(rar); rar.append(r)
    return RI[r]
cards = [list(c) + [0] for c in B['cards']]  # [set, num, name, ja, rar, tp, img]
bycode = {s[4].lower(): i for i, s in enumerate(sets)}
bytp = {c[5]: c for c in cards if c[5]}
bynum = collections.defaultdict(list)
for c in cards: bynum[(c[0], nk(c[1]))].append(c)
groups = get('https://tcgcsv.com/tcgplayer/85/groups')['results']
print('groupes', len(groups), flush=True)
new_sets = 0; new_cards = 0; enriched = 0
for g in sorted(groups, key=lambda g: g.get('publishedOn') or ''):
    try: prods = get(f'https://tcgcsv.com/tcgplayer/85/{g["groupId"]}/products')['results']
    except Exception as e: print('fail', g['name'], e, flush=True); continue
    time.sleep(.8)
    rows = []
    for p in prods:
        ex = {x.get('name'): str(x.get('value', '')) for x in (p.get('extendedData') or [])}
        num = ex.get('Number', '').strip()
        if not num: continue
        name = re.sub(r'\s+-\s+[A-Za-z0-9]+(?:/[A-Za-z0-9]+)?\s*$', '', p['name']).strip()
        rows.append((p['productId'], num.split('/')[0].strip(), num, name, ex.get('Rarity', '')))
    if not rows: continue
    ab = (g.get('abbreviation') or '').lower(); gname = re.sub(r'^[^:]{1,14}:\s*', '', g['name']).strip()
    si = bycode.get(ab)
    if si is None:
        den = collections.Counter(r[2].split('/')[1] for r in rows if '/' in r[2]).most_common(1)
        tot = int(re.sub(r'\D', '', den[0][0]) or 0) if den else len(rows)
        sets.append(['ja-' + (g.get('abbreviation') or str(g['groupId'])), gname, tot, (g.get('publishedOn') or '')[:10], g.get('abbreviation') or '', '', '', 0])
        si = len(sets) - 1; bycode[ab or str(g['groupId'])] = si; new_sets += 1
    else:
        sets[si][1] = gname
    for pid, num, full, name, r in rows:
        c = bytp.get(pid)
        if c is None:
            same = [x for x in bynum.get((si, nk(num)), []) if not x[5]]
            if len(same) == 1: c = same[0]
        if c is not None:
            c[5] = pid; c[2] = name; enriched += 1
            if r and not rar[c[4]]: c[4] = ri(r)
        else:
            c = [si, num, name, '', ri(r), pid, 0]; cards.append(c); bytp[pid] = c; bynum[(si, nk(num))].append(c); new_cards += 1
print('sets ajoutés', new_sets, 'cartes ajoutées', new_cards, 'enrichies', enriched, 'total', len(cards), flush=True)
# ordre stable : par set (date), puis numéro
order = sorted(range(len(sets)), key=lambda i: (sets[i][3] or '9999', sets[i][0]))
pos = {o: k for k, o in enumerate(order)}
sets = [sets[o] for o in order]
for c in cards: c[0] = pos[c[0]]
def nkey(n):
    m = re.match(r'([A-Za-z-]*)(\d*)(.*)', str(n)); return (m.group(1), int(m.group(2) or 0), m.group(3))
cards.sort(key=lambda c: (c[0], nkey(c[1]), c[5]))
# images + empreintes : TCGplayer d'abord, TCGdex en repli
def urls(c):
    s = sets[c[0]]; u = []
    if c[5]: u.append((1, f'https://tcgplayer-cdn.tcgplayer.com/product/{c[5]}_200w.jpg'))
    if s[6] and s[7]: u.append((2, f'https://assets.tcgdex.net/ja/{s[6]}/{s[4]}/{c[1]}/low.webp'))
    return u
def job(i):
    for k, u in urls(cards[i]):
        try: return i, k, desc(fetch(u))
        except Exception: continue
    return i, 0, None
res = [None] * len(cards)
with cf.ThreadPoolExecutor(64) as ex:
    for n, (i, k, d) in enumerate(ex.map(job, range(len(cards)))):
        res[i] = (k, d)
        if n % 1000 == 0: print('img', n, flush=True)
# image « non disponible » de TCGplayer : même empreinte répétée → on l'écarte
cnt = collections.Counter(d[0] for k, d in res if d)
bad = {h for h, n in cnt.items() if n >= 25}
b = bytearray(b'CV01' + struct.pack('<I', len(cards))); ok = 0
for c, (k, d) in zip(cards, res):
    if d and d[0] not in bad:
        c[6] = k; ok += 1; b += bytes([1]) + d[0].to_bytes(8, 'big') + bytes(d[1])
    else:
        c[6] = 0; b += bytes(57)
for s in sets: s[7] = 0
open('cards-jp-vis.bin', 'wb').write(b)
json.dump({'v': time.strftime('%Y-%m-%d') + '-ja', 'src': 'TCGplayer (TCGCSV, catégorie 85) + TCGdex (MIT)', 'sets': sets, 'rar': rar, 'cards': cards}, open('cards-jp.json', 'w'), ensure_ascii=False, separators=(',', ':'))
open('tools/jp_report.txt', 'w').write(f'sets={len(sets)} cards={len(cards)} images={ok} placeholder={len(bad)} new_sets={new_sets} new_cards={new_cards}\n')
print('done', len(sets), len(cards), 'images', ok, flush=True)
