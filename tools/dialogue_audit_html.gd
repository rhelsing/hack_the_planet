extends SceneTree

## Generates dialogue_audit.html — an annotatable report of the E.7
## menu-size findings from DialogueLinter. Open it in a browser, type a
## comment under any finding (persists in localStorage), then click
## "Download markdown" to get a .md of your comments + locations.
##
## Run:
##   godot --headless --script res://tools/dialogue_audit_html.gd --quit
##
## Re-running overwrites the HTML with fresh findings; comments live in
## the browser's localStorage keyed by file+line+menu, so they survive a
## regenerate as long as the menu hasn't moved.

const Linter = preload("res://tools/dialogue_linter.gd")
const DIALOGUE_DIR: String = "res://dialogue/"
const OUT_PATH: String = "res://dialogue_audit.html"
## Report only menus with at least this many total options. The linter
## itself warns above MAX_MENU_OPTIONS (3); this trims the HTML to the
## menus worth triaging first.
const MIN_TOTAL: int = 5


func _init() -> void:
	var paths: Array[String] = []
	var dir := DirAccess.open(DIALOGUE_DIR)
	if dir == null:
		printerr("cannot open %s" % DIALOGUE_DIR)
		quit(1); return
	for f in dir.get_files():
		if f.ends_with(".dialogue"):
			paths.append(DIALOGUE_DIR + f)
	paths.sort()

	var linter := Linter.new()
	# Menu-size check only needs the dialogue scan; skip gd/tscn/StoryVec.
	var report = linter.analyze(paths, [], "")

	var findings: Array = []
	for w in report.warnings:
		if not (w.ctx is Dictionary and w.ctx.has("menu")):
			continue
		if int(w.ctx.total) < MIN_TOTAL:
			continue
		var file: String = w.file
		findings.append({
			"file": file.trim_prefix("res://"),
			"menu": w.ctx.menu,
			"line": w.ctx.line,
			"total": w.ctx.total,
			"gated": w.ctx.gated,
			"exits": w.ctx.exits,
			"options": _extract_options(file, int(w.ctx.line)),
		})

	var html := _TEMPLATE.replace("__FINDINGS_JSON__", JSON.stringify(findings))
	var out := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if out == null:
		printerr("cannot write %s" % OUT_PATH)
		quit(1); return
	out.store_string(html)
	out.close()
	print("wrote %s — %d oversized menus" % [OUT_PATH, findings.size()])
	quit(0)


## Collect the option texts of the menu whose first option is at line_no.
## Mirrors the linter's run semantics: same-depth options collect, deeper
## lines are option bodies, anything at the menu's depth or shallower
## (or a new ~ section) ends the run.
func _extract_options(path: String, line_no: int) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var lines := f.get_as_text().split("\n")
	f.close()
	if line_no < 1 or line_no > lines.size():
		return []
	var first := String(lines[line_no - 1])
	var menu_depth := _tab_depth(first)
	var out: Array = []
	for i in range(line_no - 1, lines.size()):
		var raw := String(lines[i])
		var stripped := raw.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		if stripped.begins_with("~ "):
			break
		var depth := _tab_depth(raw)
		if stripped.begins_with("- "):
			if depth == menu_depth:
				out.append(stripped.substr(2).strip_edges())
			elif depth < menu_depth:
				break
			continue
		if depth <= menu_depth:
			break
	return out


func _tab_depth(raw: String) -> int:
	var d := 0
	while d < raw.length() and raw[d] == "\t":
		d += 1
	return d


const _TEMPLATE: String = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Dialogue menu audit</title>
<style>
  :root { color-scheme: dark; }
  body { background: #0d1117; color: #e6edf3; font: 15px/1.5 -apple-system, "Segoe UI", sans-serif;
         max-width: 900px; margin: 2rem auto; padding: 0 1rem; }
  h1 { font-size: 1.3rem; color: #00ffff; }
  .sub { color: #8b949e; margin-bottom: 1.5rem; }
  .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px;
          padding: 1rem 1.2rem; margin-bottom: 1rem; }
  .card.commented { border-color: #a673f2; }
  .loc { font-family: ui-monospace, monospace; font-size: 0.9rem; color: #00ffff; }
  .loc a { color: inherit; }
  .badges { margin: 0.4rem 0 0.6rem; }
  .badge { display: inline-block; font-size: 0.78rem; padding: 0.1rem 0.55rem;
           border-radius: 10px; margin-right: 0.4rem; border: 1px solid #30363d; color: #8b949e; }
  .badge.total { color: #ff5478; border-color: #ff5478; }
  ul.opts { margin: 0.3rem 0 0.8rem; padding-left: 1.3rem; color: #c9d1d9; }
  ul.opts li { margin: 0.1rem 0; }
  ul.opts .gate { color: #d29922; font-size: 0.85em; }
  ul.opts .exit { color: #3fb950; font-size: 0.85em; }
  textarea { width: 100%; box-sizing: border-box; min-height: 3.2rem; resize: vertical;
             background: #0d1117; color: #e6edf3; border: 1px solid #30363d; border-radius: 6px;
             padding: 0.5rem 0.7rem; font: inherit; }
  textarea:focus { outline: none; border-color: #a673f2; }
  .toolbar { position: sticky; top: 0; background: #0d1117; padding: 0.8rem 0;
             display: flex; gap: 0.8rem; align-items: center; z-index: 2; }
  button { background: #a673f2; color: #0d1117; font-weight: 600; border: 0;
           border-radius: 6px; padding: 0.5rem 1rem; cursor: pointer; font: inherit; }
  button:hover { filter: brightness(1.1); }
  .count { color: #8b949e; font-size: 0.9rem; }
</style>
</head>
<body>
<h1>Dialogue menu audit — moments with &gt; 3 options</h1>
<div class="sub">Comment on what to change under each finding. Comments save
automatically in this browser. Regenerate the file with
<code>godot --headless --script res://tools/dialogue_audit_html.gd --quit</code>.</div>
<div class="toolbar">
  <button onclick="downloadMd()">Download markdown</button>
  <span class="count" id="count"></span>
</div>
<div id="cards"></div>
<script>
const FINDINGS = __FINDINGS_JSON__;
const key = f => `dlg_audit::${f.file}::${f.line}::${f.menu}`;

function render() {
  const root = document.getElementById('cards');
  FINDINGS.forEach((f, i) => {
    const saved = localStorage.getItem(key(f)) || '';
    const card = document.createElement('div');
    card.className = 'card' + (saved ? ' commented' : '');
    const opts = f.options.map(o => {
      let cls = '', txt = o;
      if (o.includes('[#exit]')) cls = 'exit';
      else if (o.startsWith('[if ')) cls = 'gate';
      return `<li class="${cls}">${txt.replace(/&/g,'&amp;').replace(/</g,'&lt;')}</li>`;
    }).join('');
    card.innerHTML = `
      <div class="loc">${f.file} :: ~${f.menu} <span style="color:#8b949e">(line ${f.line})</span></div>
      <div class="badges">
        <span class="badge total">${f.total} options</span>
        <span class="badge">${f.total - f.gated} always-on</span>
        <span class="badge">${f.gated} [if]-gated</span>
        <span class="badge">${f.exits} exit</span>
      </div>
      <ul class="opts">${opts}</ul>
      <textarea placeholder="What should change here?" data-i="${i}">${saved}</textarea>`;
    root.appendChild(card);
  });
  root.addEventListener('input', e => {
    if (e.target.tagName !== 'TEXTAREA') return;
    const f = FINDINGS[+e.target.dataset.i];
    const v = e.target.value.trim();
    v ? localStorage.setItem(key(f), e.target.value)
      : localStorage.removeItem(key(f));
    e.target.closest('.card').classList.toggle('commented', !!v);
    updateCount();
  });
  updateCount();
}

function updateCount() {
  const n = FINDINGS.filter(f => (localStorage.getItem(key(f)) || '').trim()).length;
  document.getElementById('count').textContent =
    `${FINDINGS.length} findings — ${n} commented`;
}

function downloadMd() {
  const lines = ['# Dialogue menu audit — comments', '',
    `Exported: ${new Date().toISOString().slice(0,16).replace('T',' ')}`, ''];
  let n = 0;
  FINDINGS.forEach(f => {
    const c = (localStorage.getItem(key(f)) || '').trim();
    if (!c) return;
    n++;
    lines.push(`## ${f.file} :: ~${f.menu} (line ${f.line})`, '',
      `${f.total} options (${f.total - f.gated} always-on, ${f.gated} gated, ${f.exits} exit)`, '',
      ...f.options.map(o => `- ${o}`), '',
      `**Change:** ${c}`, '');
  });
  if (!n) { alert('No comments yet.'); return; }
  const blob = new Blob([lines.join('\\n')], {type: 'text/markdown'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'dialogue_audit_comments.md';
  a.click();
  URL.revokeObjectURL(a.href);
}

render();
</script>
</body>
</html>
"""
