"""Empreintes visuelles des cartes (doit rester identique au code JS visDesc de index.html).
Pour chaque carte de cards-db.json : image officielle -> 320x440 bilinéaire -> moyennes 10x10 -> 32x44 RGB
 - pHash 64 bits : DCT 2D du gris 44x32, bloc 8x8 basse fréquence, comparé à la médiane (DC exclu)
 - grille couleur 4x4 (cellules 8x11) normalisée par canal (moyenne/écart-type) -> 48 octets
Fichier : 'CV01' + uint32 n + n * (1 octet ok + 8 octets pHash + 48 octets grille)
"""
import json, io, sys, struct, time, urllib.request, concurrent.futures as cf
import numpy as np
from PIL import Image

def card_url(D, r):
    s = D['sets'][r[0]]; sid, num = s[0], r[1]
    if len(r) > 4 and r[4] == 1: return f'https://images.scrydex.com/pokemon/{sid}-{num}/small'
    if len(r) > 4 and isinstance(r[4], str): return r[4]
    return f'https://images.pokemontcg.io/{sid}/{num}.png'

def dct_mat(n):
    k = np.arange(n)[:, None]; i = np.arange(n)[None, :]
    return np.cos(np.pi * (2 * i + 1) * k / (2 * n))

CR, CC = dct_mat(44), dct_mat(32)

def desc_from_small(a):  # a: 44x32x3 float
    g = a[..., 0] * .299 + a[..., 1] * .587 + a[..., 2] * .114
    F = CR @ g @ CC.T
    low = F[:8, :8].flatten()
    med = np.median(low[1:])
    bits = (low > med).astype(np.uint8); bits[0] = 0
    ph = 0
    for b in bits: ph = (ph << 1) | int(b)
    grid = []
    m = a.reshape(-1, 3).mean(0); s = a.reshape(-1, 3).std(0) + 1e-6
    for ry in range(4):
        for cx in range(4):
            cell = a[ry * 11:(ry + 1) * 11, cx * 8:(cx + 1) * 8].reshape(-1, 3).mean(0)
            for c in range(3): grid.append(int(np.clip(np.round(128 + (cell[c] - m[c]) / s[c] * 50), 0, 255)))
    return ph, grid

def desc(im):
    im = im.convert('RGBA'); bg = Image.new('RGBA', im.size, (255, 255, 255, 255)); bg.alpha_composite(im)
    a = np.asarray(bg.convert('RGB').resize((320, 440), Image.BILINEAR), dtype=np.float32)
    a = a.reshape(44, 10, 32, 10, 3).mean(axis=(1, 3))
    return desc_from_small(a)

def fetch(u):
    for t in range(4):
        try:
            req = urllib.request.Request(u, headers={'User-Agent': 'Mozilla/5.0 InventoryMonitoring'})
            with urllib.request.urlopen(req, timeout=25) as r: return Image.open(io.BytesIO(r.read()))
        except Exception as e:
            err = e; time.sleep(1 + t * 2)
    raise err

def main():
    D = json.load(open('cards-db.json'))
    cards = D['cards']; out = [None] * len(cards); fails = []
    def job(i):
        u = card_url(D, cards[i])
        try: return i, desc(fetch(u)), None
        except Exception as e: return i, None, f'{u} {e}'
    with cf.ThreadPoolExecutor(32) as ex:
        for n, (i, d, e) in enumerate(ex.map(job, range(len(cards)))):
            out[i] = d
            if e: fails.append(e)
            if n % 500 == 0: print(n, len(fails), flush=True)
    b = bytearray(b'CV01' + struct.pack('<I', len(cards)))
    for d in out:
        if d is None: b += bytes(57); continue
        ph, grid = d
        b += bytes([1]) + ph.to_bytes(8, 'big') + bytes(grid)
    open('cards-vis.bin', 'wb').write(b)
    open('tools/vis_report.txt', 'w').write(f'v={D.get("v")} cards={len(cards)} fails={len(fails)}\n' + '\n'.join(fails[:300]))
    print('done', len(cards), 'fails', len(fails))

if __name__ == '__main__':
    main()
