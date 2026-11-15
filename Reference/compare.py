# Web reference vs native renderer: side-by-side sheet + numbers.
#   python compare.py <ref-prefix> <native-prefix> <t,t,...> <sheet.png> [--crop y0:y1]
# Numbers per frame: mean |ΔRGB| where either side draws (0–255), alpha IoU, and per-word box deltas.
import sys, json
import numpy as np
from PIL import Image

def load(p):
    return np.asarray(Image.open(p).convert('RGBA')).astype(np.float32)

def over(img, bg=(90, 64, 54)):
    a = img[..., 3:4] / 255.0
    return img[..., :3] * a + np.array(bg, np.float32) * (1 - a)

def main():
    args = sys.argv[1:]
    crop = None
    if '--crop' in args:
        i = args.index('--crop'); y0, y1 = map(int, args[i + 1].split(':')); crop = (y0, y1); del args[i:i + 2]
    ref, nat, times, sheet = args[0], args[1], [float(x) for x in args[2].split(',')], args[3]
    lref = json.load(open(ref + '_layout.json')) if crop is not None or True else {}
    try: lnat = json.load(open(nat + '_layout.json'))
    except Exception: lnat = {}
    rows = []
    for t in times:
        k = f'{t:.2f}'
        a, b = load(f'{ref}_{k}.png'), load(f'{nat}_{k}.png')
        A, B = over(a), over(b)
        mask = (a[..., 3] > 8) | (b[..., 3] > 8)
        diff = np.abs(A - B)[mask].mean() if mask.any() else 0
        inter = ((a[..., 3] > 64) & (b[..., 3] > 64)).sum(); union = ((a[..., 3] > 64) | (b[..., 3] > 64)).sum()
        iou = inter / union if union else 1
        line = f't={k}: mean|Δ|={diff:5.1f}  alpha IoU={iou:.3f}'
        wr, wn = lref.get(k, []), lnat.get(k, [])
        if wr and wn and len(wr) == len(wn):
            d = [max(abs(r['x'] - n['x']), abs(r['y'] - n['y']), abs(r['w'] - n['w']), abs(r['h'] - n['h'])) for r, n in zip(wr, wn)]
            fs = max(abs(r['fs'] - n['fs']) for r, n in zip(wr, wn))
            line += f'  boxes max Δ={max(d):.2f}px  font Δ={fs:.2f}px'
        elif wr or wn:
            line += f'  words ref {len(wr)} native {len(wn)}'
        print(line)
        y0, y1 = crop or (0, a.shape[0])
        pair = np.concatenate([A[y0:y1], B[y0:y1]], axis=1)
        rows.append(pair)
    img = np.concatenate(rows, axis=0).clip(0, 255).astype(np.uint8)
    im = Image.fromarray(img)
    if im.width > 1600: im = im.resize((1600, int(im.height * 1600 / im.width)))
    im.save(sheet)

main()
