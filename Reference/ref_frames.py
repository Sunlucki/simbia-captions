# Reference frames for the native caption/title engine: renders a .simbia project's captions and titles with
# overlay_ref.html in Chromium (Playwright), transparent 1080x1920 PNGs, plus the caption layout as JSON.
#   python ref_frames.py <project.simbia> <t,t,...> <out-prefix> [--style s4]
import sys, os, json, re, html
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, '..', 'Assets', 'Fonts')

# ---- T2 handwriting paths (EMS Allure single-line script), same as the V5 renderer
def allure():
    src = open(os.path.join(FONTS, 'EMSAllure.svg')).read(); G = {}
    for m in re.finditer(r'<glyph unicode="([^"]*)"[^>]*?horiz-adv-x="([\d.]+)"(?:[^>]*?d="([^"]*)")?', src):
        G[html.unescape(m.group(1))] = (float(m.group(2)), m.group(3) or '')
    return G

def smooth(pts):
    if len(pts) < 3: return 'M' + ' L'.join(f'{x:.1f} {y:.1f}' for x, y in pts)
    p = [pts[0]] + pts + [pts[-1]]; s = f'M{pts[0][0]:.1f} {pts[0][1]:.1f}'
    for i in range(1, len(p) - 2):
        p0, p1, p2, p3 = p[i - 1], p[i], p[i + 1], p[i + 2]
        s += f' C{p1[0] + (p2[0] - p0[0]) / 6:.1f} {p1[1] + (p2[1] - p0[1]) / 6:.1f} {p2[0] - (p3[0] - p1[0]) / 6:.1f} {p2[1] - (p3[1] - p1[1]) / 6:.1f} {p2[0]:.1f} {p2[1]:.1f}'
    return s

def write_paths(text):
    G = allure(); lines = []
    for line in text.split('|'):
        pen, strokes = 0, []
        for ch in line:
            adv, d = G.get(ch, (378, ''))
            for seg in re.split(r'(?=M)', d):
                pts = [(float(x) + pen, 800 - float(y)) for x, y in re.findall(r'(-?[\d.]+)\s+(-?[\d.]+)', seg)]
                if pts: strokes.append(pts)
            pen += adv
        lines.append(strokes)
    widths = [max(x for st in L for x, y in st) - min(x for st in L for x, y in st) for L in lines]
    Wd = max(widths) + 120; out, y0 = [], 0
    for L, wd in zip(lines, widths):
        x0 = min(x for st in L for x, y in st); ymin = min(y for st in L for x, y in st)
        dx = (Wd - wd) / 2 - x0; dy = 60 + y0 - ymin
        out += [smooth([(x + dx, y + dy) for x, y in st]) for st in L]
        y0 += 1000
    return dict(w=round(Wd), h=round(y0 + 150), paths=out)

def data_of(project, style=None):
    st = style or project['captions'].get('style', 's5')
    caps = [dict(a=c['start'], b=c['end'], words=[dict(t=w['text'], s=w['start'], acc=w.get('accent', False)) for w in c['words']])
            for c in project['captions'].get('chunks', [])]
    titles = []
    for t in project.get('titles', []):
        T = dict(style=t.get('style', 'T1'), text=t['text'], kicker=t.get('kicker'), start=t['start'], dur=t.get('duration', 3.6))
        if T['style'] == 'T2':
            T.update(write_paths(t['text'])); T['write'] = 2.4 if '|' in t['text'] else 1.6
        titles.append(T)
    return dict(capStyle=int(st[1:]) if st.startswith('s') else 5, caps=caps, titles=titles)

def render(project_path, times, prefix, style=None, titles=True):
    project = json.load(open(project_path))
    if not titles: project['titles'] = []
    page_html = open(os.path.join(HERE, 'overlay_ref.html')).read().replace('__DATA__', json.dumps(data_of(project, style)))
    tmp = os.path.join(HERE, '_render.html'); open(tmp, 'w').write(page_html)
    layouts = {}
    with sync_playwright() as pw:
        b = pw.chromium.launch(); pg = b.new_page(viewport={'width': 1080, 'height': 1920})
        pg.goto('file://' + tmp); pg.evaluate('window.ready'); pg.wait_for_timeout(300)
        for t in times:
            pg.evaluate(f'setT({t})')
            pg.evaluate('new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))')
            out = f'{prefix}_{t:.2f}.png'
            pg.screenshot(path=out, omit_background=True)
            layouts[f'{t:.2f}'] = pg.evaluate('layout()')
            print(out)
        b.close()
    json.dump(layouts, open(f'{prefix}_layout.json', 'w'), indent=1)
    os.remove(tmp)

if __name__ == '__main__':
    args = sys.argv[1:]
    style = None
    if '--style' in args:
        i = args.index('--style'); style = args[i + 1]; del args[i:i + 2]
    titles = '--no-titles' not in args
    args = [a for a in args if a != '--no-titles']
    render(args[0], [float(x) for x in args[1].split(',')], args[2], style, titles)
