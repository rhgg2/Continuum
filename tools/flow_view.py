#!/usr/bin/env python3
"""flow_view: write the flow viewer as one self-contained HTML file.

The page is rooted at any declaration and expands a callee *inline at its call
site*, indented under it, recursively -- so a control path reads as one
continuous document rather than as a graph you assemble in your head. Source is
rendered whole rather than reduced to a skeleton: eliding non-structural lines
buys about 60% and can silently drop the line a condition depends on, which is
the one thing a flow reader cannot afford.

Everything is inlined and the whole corpus ships in the file, so a root change
never needs a regenerate and the page works with no server and no network.
Build it fresh when you want it rather than keeping one around: a checked-in
copy is a second copy of the source, and it goes stale silently.

  flow_view.py --out flow.html            whole corpus
  flow_view.py --out flow.html trackerManager midiManager
  flow_view.py --open --root trackerManager.lua:4875
"""

from __future__ import annotations

import argparse
import json
import sys
import webbrowser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from flow_extract import build, resolve_root
from map_index import MAP_DIR

# Raw, so CSS and JS escapes reach the page as written. As an ordinary string
# this template silently ate them: `\21a9` read as an octal escape and rendered
# the wrap marker as the literal text `a9`.
PAGE = r"""<!doctype html>
<meta charset="utf-8">
<title>Continuum flow</title>
<style>
:root {
  --bg:#1b1d23; --fg:#d6d9df; --dim:#6d7480; --rule:#2c3038;
  --kw:#c98bdb; --st:#9ecb8a; --cm:#697082; --nu:#e0a468; --hd:#7fb3d5;
}
* { box-sizing:border-box }
body { margin:0; background:var(--bg); color:var(--fg);
       font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace }
header { position:sticky; top:0; z-index:9; background:var(--bg);
         border-bottom:1px solid var(--rule); padding:10px 14px;
         display:flex; gap:12px; align-items:center; flex-wrap:wrap }
input { background:#22252c; border:1px solid var(--rule); color:var(--fg);
        padding:5px 9px; border-radius:4px; font:inherit; width:340px }
input[type=checkbox] { width:auto }
button { background:#262a32; border:1px solid var(--rule); color:var(--fg);
         font:inherit; padding:3px 9px; border-radius:4px; cursor:pointer }
button:hover { background:#323742 }
#depth, #blocks { display:inline-flex; gap:4px; align-items:center }
#hits { position:absolute; top:46px; left:14px; background:#22252c;
        border:1px solid var(--rule); border-radius:4px; max-height:60vh;
        overflow:auto; display:none; z-index:20; min-width:520px }
#hits div { padding:4px 10px; cursor:pointer; white-space:nowrap }
#hits div:hover, #hits div.on { background:#323742 }
#main { padding:14px 18px 60vh }
.decl { margin:0 }
.dh { color:var(--hd); padding:3px 0 5px; border-bottom:1px solid var(--rule);
      margin-bottom:5px; display:flex; gap:10px; align-items:baseline }
.dh .loc { color:var(--dim); font-size:12px }
.dh .kind { color:var(--dim) }
.ln { display:flex; align-items:flex-start }
.ln:hover { background:#20232a }
.no { color:var(--dim); text-align:right; width:52px; flex:none;
      padding-right:10px; user-select:none; cursor:pointer }
.wf { width:12px; flex:none; color:#5b6472; user-select:none }
.ln.wrapped .wf::after { content:'\21a9' }
.fold { width:14px; flex:none; color:var(--dim); cursor:pointer; user-select:none }
.fold.on { color:var(--fg) }
/* Hanging indent: the first visual line keeps the source's own indentation and
   every continuation sits at a fixed offset, so a wrap never reads as a
   statement at that nesting level. min-width:0 is what lets the flex item
   shrink below its content width at all. */
code { white-space:pre-wrap; overflow-wrap:break-word; flex:1 1 auto; min-width:0;
       padding-left:5ch; text-indent:-5ch }
body.nowrap code { white-space:pre; overflow-wrap:normal; padding-left:0; text-indent:0 }
body.nowrap .wf::after { content:'' }
.chip { color:#8fb8d8; cursor:pointer; margin-left:10px; border-bottom:1px dotted #46586b;
        white-space:nowrap; user-select:none; flex:none; align-self:flex-start }
.chip:hover { color:#cfe6f7 }
.chip.ext { color:var(--dim); cursor:default; border-bottom:1px dotted #3a3f49 }
.chip.cyc { color:#c8a06a; }
/* Hiding a definition takes its comment block and its expansion with it: the
   nest is a sibling the row owns, and left behind it would read as belonging to
   the line above. */
body.nodefs .ln.def, body.nodefs .ln.defhide, body.nodefs .ln.blankhide,
body.nodefs .ln.def + .nest { display:none }
/* An elided perf statement takes its chip with it. A line that was nothing but
   instrumentation goes whole -- there is no residue worth a numbered row. */
body.noperf .perf { display:none }
body.noperf .ln.perfline { display:none }
/* A call is clickable where it is written. The chip on the right still works
   and still carries what the name cannot -- (external), the cycle mark. */
.cn { cursor:pointer; border-bottom:1px dotted #46586b }
.cn:hover { color:#cfe6f7 }
.nest { margin:3px 0 5px 62px; border-left:2px solid #39414e;
        padding-left:10px; background:#1e2128 }
.nest > .decl > .dh { border-bottom:1px dotted var(--rule) }
.hid { display:none }
.kw{color:var(--kw)} .st{color:var(--st)} .cm{color:var(--cm)} .nu{color:var(--nu)}
.note { color:var(--dim); padding:2px 0 0 62px; font-size:12px }
</style>
<header>
  <input id="q" placeholder="root at…  (module or function name)" autocomplete="off">
  <label class="cm"><input type="checkbox" id="wrap" checked> wrap</label>
  <label class="cm" title="show where nested local functions are defined"><input
    type="checkbox" id="defs" checked> defs</label>
  <label class="cm" title="show perf.start/perf.stop instrumentation"><input
    type="checkbox" id="perf"> perf</label>
  <span id="blocks"><span class="cm">blocks</span>
    <button data-b="0">0</button><button data-b="1">1</button
    ><button data-b="2">2</button><button data-b="3">3</button
    ><button data-b="99">all</button></span>
  <span id="depth"><span class="cm">calls</span>
    <button data-d="1">1</button><button data-d="2">2</button
    ><button data-d="3">3</button><button data-d="4">4</button
    ><button data-d="0">reset</button></span>
  <span id="where" class="cm"></span>
  <span id="status" class="cm"></span>
</header>
<div id="hits"></div>
<div id="main"></div>
<script id="payload" type="application/json">__PAYLOAD__</script>
<script>
const D = JSON.parse(document.getElementById('payload').textContent);
const KW = new Set(('and break do else elseif end false for function goto if in local nil '
  + 'not or repeat return then true until while').split(' '));
const esc = s => s.replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));

// Tokens rather than markup: a name has to become a click target, and building
// the spans from a string would mean parsing back what we just wrote.
function hl(src, masked) {
  if (masked) return [{ t: src, c: 'cm' }];
  const out = [];
  let plain = '', i = 0;
  const flush = () => { if (plain) { out.push({ t: plain, c: null }); plain = ''; } };
  const add = (t, c) => { flush(); if (t) out.push({ t, c }); };
  while (i < src.length) {
    const c = src[i];
    if (c === '-' && src[i+1] === '-') { add(src.slice(i), 'cm'); break; }
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < src.length && src[j] !== c) j += (src[j] === '\\' ? 2 : 1);
      add(src.slice(i, j+1), 'st'); i = j + 1; continue;
    }
    if (/[A-Za-z_]/.test(c)) {
      let j = i; while (j < src.length && /[A-Za-z0-9_]/.test(src[j])) j++;
      const w = src.slice(i, j);
      add(w, KW.has(w) ? 'kw' : 'id'); i = j; continue;
    }
    if (/[0-9]/.test(c)) {
      let j = i; while (j < src.length && /[0-9a-fA-FxX.]/.test(src[j])) j++;
      add(src.slice(i, j), 'nu'); i = j; continue;
    }
    plain += c; i++;
  }
  flush();
  return out;
}

const byLine = (rows, key) => {
  const m = new Map();
  for (const r of rows) { if (!m.has(r[key])) m.set(r[key], []); m.get(r[key]).push(r); }
  return m;
};

// Render one declaration. `ancestors` is the chain of decl ids already open
// above this point: re-entering one would expand forever, so it degrades to a
// jump link instead. `bare` drops the header, for the one case where it would
// restate the line directly above it: a local opened at its own definition.
function renderDecl(id, ancestors, bare) {
  const d = D.decls[id];
  const mod = D.modules[d.module];
  const maskedSet = new Set(mod.masked);
  const wrap = document.createElement('div');
  wrap.className = 'decl';

  const head = document.createElement('div');
  head.className = 'dh';
  head.innerHTML = '<span class="kind">@' + d.kind + '</span><b>' + esc(d.head) + '</b>'
                 + '<span class="loc">' + d.src + ':' + d.start + '-' + d.end + '</span>';
  if (!bare) wrap.appendChild(head);

  // The chain this rendering sits in, itself included: a directly self-recursive
  // call is a cycle at its first appearance, not at its second.
  const chain = ancestors.concat([id]);
  // A nested local's body is a declaration of its own, so its lines are not
  // rendered here: its head line stays as the stub you expand from, and its
  // substance appears wherever it is called.
  const locals = d.locals || [];
  const defAt = new Map(locals.map(h => [h.line, h]));
  const blank = (n) => !(mod.lines[n-1] || '').trim();
  const perfAt = new Map(Object.entries(mod.perf || {}).map(([n, s]) => [+n, s]));
  const perfOnly = new Set(mod.perfOnly || []);
  const folds = byLine(d.blocks, 'line');
  const calls = byLine(d.calls, 'line');
  const rows = new Map();
  const chips = [];               // this rendering's expandable chips, for expandTo
  const owners = [];              // fold spans paired with their frame state
  // Frame depth 1 is the outermost block inside the function, so `blocks 1`
  // shows one level of nesting -- which is the default the page opens at.
  const state = d.blocks.map(f => ({ f, collapsed: f.depth > 1 }));

  // A declaration's comment block is its documentation and travels with it. The
  // one exception is a local opened at its own definition: the parent is
  // already showing both the comment and the head line directly above, so the
  // fold-out starts at the body rather than restating them.
  for (let n = bare ? d.start + 1 : d.from; n <= d.end; n++) {
    if (locals.some(h => n > h.line && n <= h.end)) continue;
    const row = document.createElement('div');
    row.className = 'ln';
    if (perfOnly.has(n)) row.classList.add('perfline');
    const opens = (folds.get(n) || []).filter(f => f.end > f.line);
    const owner = opens.length ? opens.reduce((a, b) => (b.end > a.end ? b : a)) : null;

    const no = document.createElement('span');
    no.className = 'no'; no.textContent = n;
    no.title = d.src + ':' + n + ' — click to copy';
    no.onclick = () => navigator.clipboard.writeText(d.src + ':' + n);

    const fold = document.createElement('span');
    fold.className = 'fold';
    if (owner) {
      const st = state.find(s => s.f === owner);
      fold.textContent = st.collapsed ? '▸' : '▾';
      fold.classList.add('on');
      owners.push({ fold, st });
      fold.onclick = () => { st.collapsed = !st.collapsed;
        fold.textContent = st.collapsed ? '▸' : '▾'; apply(); remark(); };
    }

    const wf = document.createElement('span');
    wf.className = 'wf';

    const code = document.createElement('code');
    row.append(no, wf, fold, code);
    // One line routinely carries several calls (`perf.start(); f(); perf.stop()`),
    // so an expansion belongs to its chip, not to the row it sits on.
    row.nests = [];

    // Name in the text -> the thing that opens it. Chips and folds are built
    // first and the text is wired to them, so a name and its chip are two ways
    // into one behaviour rather than two implementations of it.
    const opener = new Map();

    for (const c of (calls.get(n) || [])) {
      const chip = document.createElement('span');
      if (!c.to) {
        const outside = c.why === 'outside';
        chip.className = 'chip ext';
        chip.textContent = '· ' + c.text + (outside ? ' (not in this build)' : ' (external)');
        chip.title = outside ? 'resolved, but its module was not included in this build'
                            : 'no map for this target — nothing to expand';
      } else if (chain.includes(c.to)) {
        chip.className = 'chip cyc';
        chip.textContent = '↺ ' + c.text;
        chip.title = 'already open above — click to re-root here';
        chip.onclick = () => root(c.to);
      } else {
        chip.className = 'chip';
        chip.textContent = '▸ ' + c.text;
        chip.target = c.to;
        chip.onclick = () => toggleNest(row, chip, c.to, chain);
        chips.push(chip);
      }
      if (c.to) opener.set(c.text.split(/[.:]/).pop(), chip);
      if (c.text.startsWith('perf.')) chip.classList.add('perf');
      row.appendChild(chip);
    }

    // A definition opens from the gutter, where a block of its own lines used to
    // fold -- the affordance stays where the reader already reaches for it. The
    // fold span drives it because a nest is toggled by whatever holds the arrow,
    // and that is the one thing the fold and a chip have in common. Deliberately
    // not in `chips`: expandTo follows the flow, and a definition is not a step
    // in it.
    if (locals.some(h => h.from <= n && n < h.line)) row.classList.add('defhide');

    const def = defAt.get(n);
    if (def) {
      row.classList.add('def');
      if (def.end > def.line) {          // a one-liner is already wholly here
        fold.textContent = '▸';
        fold.classList.add('on');
        fold.target = def.to;
        fold.title = def.name + ' — ' + (def.end - def.line + 1)
                   + ' lines, also expandable at each call site';
        fold.onclick = () => toggleNest(row, fold, def.to, chain, true);
        opener.set(def.name, fold);
      }
    }

    // The measurable inline box: an element's client rects are one per line box,
    // which is the only honest way to ask whether this line actually wrapped.
    const text = document.createElement('span');
    text.className = 't';
    // Tokens concatenate to exactly the source line, so a running offset places
    // each one against the elidable spans without hl having to carry them.
    const spans = perfAt.get(n) || [];
    let at = 0;
    for (const tok of hl(mod.lines[n-1] || '', maskedSet.has(n))) {
      const s = document.createElement('span');
      s.textContent = tok.t;
      const open = tok.c === 'id' ? opener.get(tok.t) : null;
      let cls = open ? 'cn' : (tok.c && tok.c !== 'id') ? tok.c : '';
      if (open) s.onclick = () => open.onclick();
      if (spans.some(([lo, hi]) => at >= lo && at < hi)) cls += (cls ? ' ' : '') + 'perf';
      if (cls) s.className = cls;
      at += tok.t.length;
      text.appendChild(s);
    }
    code.appendChild(text);

    rows.set(n, row);
    wrap.appendChild(row);
  }

  // With the definitions gone, the blank line above one meets the blank line
  // below the one before it. Marked here rather than left to `defs off` to
  // discover, because which blanks survive depends on what came before them
  // and CSS cannot carry that.
  let run = 0;
  for (const [n, row] of rows) {
    if (row.classList.contains('def') || row.classList.contains('defhide')) continue;
    if (!blank(n)) { run = 0; continue; }
    if (run++) row.classList.add('blankhide');
  }

  // A line is hidden when any collapsed frame encloses it. Recomputing the lot
  // is what keeps nested folds honest -- toggling an outer frame must not
  // resurrect lines an inner collapsed one owns.
  function apply() {
    for (const [n, row] of rows) {
      const hidden = state.some(s => s.collapsed && n > s.f.line && n <= s.f.end);
      row.classList.toggle('hid', hidden);
      for (const nest of row.nests) nest.classList.toggle('hid', hidden);
    }
  }
  apply();
  wrap.chips = chips;
  wrap.setFoldDepth = (n) => {
    for (const s of state) s.collapsed = s.f.depth > n;
    for (const o of owners) o.fold.textContent = o.st.collapsed ? '▸' : '▾';
    apply();
  };
  return wrap;
}

function toggleNest(row, chip, id, ancestors, bare) {
  if (chip.nest) {
    chip.nest.remove();
    row.nests.splice(row.nests.indexOf(chip.nest), 1);
    chip.nest = null;
    chip.textContent = chip.textContent.replace('▾', '▸');
    return;
  }
  const nest = document.createElement('div');
  nest.className = 'nest';
  nest.decl = nest.appendChild(renderDecl(id, ancestors, bare));
  // After the row's existing expansions, so chips open in the order clicked
  // rather than each new one jumping above the last.
  (row.nests[row.nests.length - 1] || row).after(nest);
  row.nests.push(nest);
  chip.nest = nest;
  chip.textContent = chip.textContent.replace('▸', '▾');
  remark();
}

// Wrapping is a layout fact, so it can only be read after layout: mark the rows
// whose text occupies more than one line box. Re-run on anything that changes
// available width or which rows are laid out at all.
function markWrapped() {
  const main = document.getElementById('main');
  for (const t of main.querySelectorAll('.t')) {
    const row = t.closest('.ln');
    // A hidden row has no line boxes, so measuring it would read as unwrapped
    // and would cost a forced layout per row on a large expansion. Folds call
    // back here when they open, which is when the answer becomes available.
    if (!row || !t.getClientRects || row.classList.contains('hid')) continue;
    row.classList.toggle('wrapped', t.getClientRects().length > 1);
  }
}
// Inline expansion duplicates a callee at every call site, so breadth grows
// fast: from a 63-call root, depth 3 is ~1100 expansions and ~11k rows. The cap
// counts rendered rows rather than expansions because rows are what the browser
// pays for, and reaching it is reported rather than passed over in silence.
const ROW_CAP = 25000;
let currentRoot = null;
const say = (msg) => { document.getElementById('status').textContent = msg; };
// What a declaration actually renders: a lifted local contributes its head line
// here and its body only where someone opens it.
function declRows(id) {
  const d = D.decls[id];
  let n = d.end - d.from + 1;
  for (const h of (d.locals || [])) n -= h.end - h.line;
  return n;
}

function expandTo(depth) {
  const main = document.getElementById('main');
  if (!currentRoot || !main.children[0]) return;
  let level = [main.children[0]];
  let opened = 0, rows = declRows(currentRoot), capped = false;
  for (let d = 0; d < depth && !capped; d++) {
    const next = [];
    for (const el of level) {
      for (const chip of el.chips) {
        // An already-open nest still counts toward the total: the figure is what
        // is rendered, not what this click added, or an incremental expand
        // reports a smaller page than the same depth reached in one go.
        if (chip.nest) { rows += declRows(chip.target); next.push(chip.nest.decl); continue; }
        if (rows + declRows(chip.target) > ROW_CAP) { capped = true; break; }
        rows += declRows(chip.target);
        chip.onclick();
        opened++;
        next.push(chip.nest.decl);
      }
      if (capped) break;
    }
    level = next;
  }
  say(`${opened} expanded, ~${rows} lines`
      + (capped ? ` — stopped at the ${ROW_CAP}-line cap` : ''));
  remark();
}

// Block folds across every rendering on the page, the root and each inline
// expansion alike -- otherwise setting a depth would leave the nested views at
// whatever depth they happened to open with.
function foldsTo(n) {
  let views = 0;
  const visit = (el) => {
    if (el.setFoldDepth) { el.setFoldDepth(n); views++; }
    for (const c of el.children) visit(c);
  };
  visit(document.getElementById('main'));
  say(`blocks open to ${n >= 99 ? 'every level' : 'depth ' + n} in `
      + `${views} view${views === 1 ? '' : 's'}`);
  remark();
}

let wrapTimer = null;
const remark = () => { clearTimeout(wrapTimer); wrapTimer = setTimeout(markWrapped, 60); };
addEventListener('resize', remark);

function root(spec) {
  const main = document.getElementById('main');
  main.innerHTML = '';
  // A pasted `file.lua:line` is the spelling an editor gives you, so accept it
  // alongside the full id and take the first declaration on that line.
  const id = D.decls[spec] ? spec
           : Object.keys(D.decls).find(k => k.startsWith(spec.replace(/:$/, '') + ':'));
  if (!id) { main.textContent = 'no declaration at ' + spec; return; }
  currentRoot = id;
  say('');
  main.appendChild(renderDecl(id, []));
  document.getElementById('where').textContent = id;
  history.replaceState(null, '', '#' + id);
  document.title = D.decls[id].head + ' — flow';
  remark();
  scrollTo(0, 0);
}

const ALL = Object.entries(D.decls).map(([id, d]) =>
  ({ id, label: d.module + '  ' + d.head, hay: (d.module + ' ' + d.head).toLowerCase() }));
ALL.sort((a, b) => a.label.localeCompare(b.label));

for (const b of document.getElementById('depth').children) {
  const d = b.getAttribute('data-d');       // the label span carries none
  if (d !== null) b.onclick = () => (d === '0' ? root(currentRoot) : expandTo(+d));
}
for (const b of document.getElementById('blocks').children) {
  const n = b.getAttribute('data-b');
  if (n !== null) b.onclick = () => foldsTo(+n);
}

const wrapBox = document.getElementById('wrap');
if (wrapBox) wrapBox.addEventListener('change', () => {
  document.body.classList.toggle('nowrap', !wrapBox.checked);
  markWrapped();
});

// Off by default: the reason to ask for the feature is not wanting to see it.
document.body.classList.add('noperf');
const perfBox = document.getElementById('perf');
if (perfBox) perfBox.addEventListener('change', () => {
  document.body.classList.toggle('noperf', !perfBox.checked);
  remark();
});

const defsBox = document.getElementById('defs');
if (defsBox) defsBox.addEventListener('change', () => {
  document.body.classList.toggle('nodefs', !defsBox.checked);
  remark();
});

const q = document.getElementById('q'), hits = document.getElementById('hits');
function search() {
  const terms = q.value.toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) { hits.style.display = 'none'; return; }
  const found = ALL.filter(r => terms.every(t => r.hay.includes(t))).slice(0, 200);
  hits.innerHTML = '';
  for (const r of found) {
    const el = document.createElement('div');
    el.textContent = r.label;
    el.onclick = () => { root(r.id); hits.style.display = 'none'; q.blur(); };
    hits.appendChild(el);
  }
  hits.style.display = found.length ? 'block' : 'none';
}
q.addEventListener('input', search);
q.addEventListener('keydown', e => {
  if (e.key === 'Escape') { hits.style.display = 'none'; q.blur(); }
  if (e.key === 'Enter' && hits.firstChild) hits.firstChild.click();
});
document.addEventListener('click', e => {
  if (!hits.contains(e.target) && e.target !== q) hits.style.display = 'none';
});

root(location.hash.slice(1) || __ROOT__);
</script>
"""


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('modules', nargs='*', help='map stems; default every module map')
    ap.add_argument('--out', type=Path, help='write the page here')
    ap.add_argument('--root', help='declaration id to open, e.g. trackerManager.lua:4875')
    ap.add_argument('--open', action='store_true', help='open the page in a browser')
    args = ap.parse_args(argv)

    stems = args.modules or sorted(p.stem for p in MAP_DIR.glob('*.map'))
    payload, report = build(stems)
    if not payload['decls']:
        print('no declarations found', file=sys.stderr)
        return 1

    default = (args.root and resolve_root(payload, args.root)) or next(iter(payload['decls']))
    if args.root and not resolve_root(payload, args.root):
        print(f"--root {args.root} names no declaration; opening {default}", file=sys.stderr)

    # `</script>` anywhere in the source would end the payload block early.
    blob = json.dumps(payload).replace('<', '\\u003c')
    page = PAGE.replace('__PAYLOAD__', blob).replace('__ROOT__', json.dumps(default))

    out = args.out or (Path(__file__).resolve().parents[1] / 'flow.html')
    out.write_text(page, encoding='utf-8')
    print(f"{out}  ({len(page)/1e6:.1f} MB)  "
          f"{len(payload['decls'])} declarations, {report['resolved']} calls expandable, "
          f"{report['unresolved']} external")
    if args.open:
        webbrowser.open(out.as_uri() + '#' + default)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
