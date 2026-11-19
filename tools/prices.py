"""Base de prix TCGplayer (USD, prix 'market') pour toutes les cartes de cards-db.json.
1) API Pokémon TCG (api.pokemontcg.io) par set  2) TCGCSV (tcgcsv.com, données TCGplayer quotidiennes) pour combler les trous.
Sortie prices.json : {"d": date, "src": {...}, "p": {"<sid>-<num>": {"n":..,"h":..,"r":..,"1h":..,"1n":..}}}
"""
import json, re, time, unicodedata, urllib.request, datetime
D = json.load(open('cards-db.json'))
UA = {'User-Agent': 'Mozilla/5.0 InventoryMonitoring-prices'}
def get(u, tries=3):
    for t in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=60) as r: return json.loads(r.read())
        except Exception as e:
            err = e; time.sleep(2 + 3 * t)
    raise err
KEY = {'normal': 'n', 'holofoil': 'h', 'reverseHolofoil': 'r', '1stEditionHolofoil': '1h', '1stEditionNormal': '1n', '1stEdition': '1n', 'unlimitedHolofoil': 'h', 'unlimited': 'n'}
SUB = {'Normal': 'n', 'Holofoil': 'h', 'Reverse Holofoil': 'r', '1st Edition Holofoil': '1h', '1st Edition Normal': '1n', '1st Edition': '1n', 'Unlimited Holofoil': 'h', 'Unlimited': 'n'}
nk = lambda s: re.sub(r'^0+(?=\d)', '', str(s).split('/')[0].strip()).lower()
norm = lambda s: re.sub(r'[^a-z0-9]', '', unicodedata.normalize('NFD', str(s).lower()).encode('ascii', 'ignore').decode())
want = {}
for r in D['cards']:
    s = D['sets'][r[0]]; want.setdefault(s[0], set()).add(nk(r[1]))
P = {}; src = {'ptcg': 0, 'tcgcsv': 0}
# 1) TCGCSV (rapide)
missing = want
try:
    groups = get('https://tcgcsv.com/tcgplayer/3/groups')['results']
except Exception as e:
    groups = []; print('tcgcsv groups fail', e)
gname = {}
for g in groups: gname.setdefault(norm(g['name']), []).append(g)
SETN = {s[0]: s[1] for s in D['sets']}
def groups_for(sid):
    n = norm(SETN[sid]); out = []
    for k, gs in gname.items():
        if k == n or k.endswith(n) or n.endswith(k) or (len(n) > 5 and n in k): out += gs
    if sid.endswith('p') or 'promo' in n:
        out = [g for g in out if 'promo' in norm(g['name'])] or out
    return out
for sid, nums in missing.items():
    for g in groups_for(sid):
        try:
            prods = get(f'https://tcgcsv.com/tcgplayer/3/{g["groupId"]}/products')['results']
            prices = get(f'https://tcgcsv.com/tcgplayer/3/{g["groupId"]}/prices')['results']
        except Exception as e: print('tcgcsv fail', g['name'], e); continue
        num = {}
        for p in prods:
            for x in p.get('extendedData') or []:
                if x.get('name') == 'Number': num[p['productId']] = nk(x.get('value', ''))
        for q in prices:
            n = num.get(q['productId']); m = q.get('marketPrice') or q.get('midPrice'); k = SUB.get(q.get('subTypeName'))
            if not n or not m or not k or n not in nums: continue
            d = P.setdefault(f'{sid}-{n}', {})
            if k not in d: d[k] = round(float(m), 2); 
        time.sleep(.2)

src['tcgcsv'] = len(P)
print('tcgcsv', len(P))
# 2) API Pokémon TCG seulement pour les sets où il manque des prix (limite de temps)
T0 = time.time()
lack = [sid for sid, nums in want.items() if any(f'{sid}-{n}' not in P for n in nums)]
print('sets avec trous', len(lack))
for sid in lack:
    if time.time() - T0 > 900: print('ptcg: limite de temps'); break
    page = 1
    while True:
        try: j = get(f'https://api.pokemontcg.io/v2/cards?q=set.id:{sid}&pageSize=250&page={page}&select=id,number,tcgplayer')
        except Exception as e: print('ptcg fail', sid, e); break
        for c in j.get('data', []):
            pr = ((c.get('tcgplayer') or {}).get('prices') or {})
            out = {}
            for k, v in pr.items():
                m = (v or {}).get('market') or (v or {}).get('mid')
                if m and KEY.get(k) and KEY[k] not in out: out[KEY[k]] = round(float(m), 2)
            key = f'{sid}-{nk(c["number"])}'
            if out and nk(c['number']) in want[sid] and key not in P: P[key] = out; src['ptcg'] += 1
        if page * 250 >= j.get('totalCount', 0): break
        page += 1
    time.sleep(.3)
print('ptcg', src['ptcg'])
tot = sum(len(v) for v in want.values())
print('tcgcsv', src['tcgcsv'], 'total', len(P), '/', tot)
json.dump({'d': datetime.date.today().isoformat(), 'src': src, 'n': len(P), 'tot': tot, 'p': P}, open('prices.json', 'w'), separators=(',', ':'))
