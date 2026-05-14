import * as THREE from 'three';
import { initView, scene, camera, renderer } from './view.js';
import {
  initCells, pickPrimitiveAt, selectPrimitive, deleteSelectedCell, selectedPrimId, selectedCell,
  cycleXformMode, xformMode, consumeXformDragFlag,
} from './cells.js';
import { initPalette } from './palette.js';
import { initDrop, startDrag, isDragging } from './drop.js';
import { initAttributes, setSelected as setAttrSelected } from './attributes.js';
import { initTags, setSelected as setTagSelected } from './tags.js';
import { brief, downloadBrief, loadBrief, newBrief, onBriefChange } from './brief.js';
import { cmd, UpdateCellCmd } from './commands.js';
import { lintBrief } from './linter.js';

const canvas = document.getElementById('canvas');
const statusEl = document.getElementById('status');
const linterEl = document.getElementById('linter');
const countsEl = document.getElementById('counts');
const titleEl = document.getElementById('title');
const fileInput = document.getElementById('file');

initView(canvas);
initCells({
  scene: scene(),
  camera: camera(),
  renderer: renderer(),
  onSelectionChanged: id => {
    statusEl.textContent = id ? `${id} · ${xformMode()}` : '';
    setAttrSelected(id);
    setTagSelected(id);
  },
});
initDrop({ scene: scene(), camera: camera(), canvas });
initPalette({
  root: document.getElementById('palette'),
  onDragStart: (kind, e) => startDrag(kind, e),
});
initAttributes({
  root: document.getElementById('attributes'),
  onSelectPrim: id => selectPrimitive(id),
});
initTags({
  root: document.getElementById('tags'),
  camera: camera(),
  onSelectPrim: id => selectPrimitive(id),
});

onBriefChange(_refreshHud);
cmd.on(_refreshHud);

canvas.addEventListener('click', e => {
  if (isDragging()) return;
  if (consumeXformDragFlag()) return;
  const rect = canvas.getBoundingClientRect();
  const ndc = new THREE.Vector2(
    ((e.clientX - rect.left) / rect.width) * 2 - 1,
    -((e.clientY - rect.top) / rect.height) * 2 + 1,
  );
  selectPrimitive(pickPrimitiveAt(camera(), ndc));
});

window.addEventListener('keydown', e => {
  const t = e.target;
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;

  const meta = e.metaKey || e.ctrlKey;
  if (meta && e.code === 'KeyZ' && !e.shiftKey) {
    e.preventDefault();
    if (cmd.undo()) statusEl.textContent = `undo · ${cmd.undoStack.length} more`;
    else statusEl.textContent = 'nothing to undo';
    return;
  }
  if (meta && (e.code === 'KeyY' || (e.code === 'KeyZ' && e.shiftKey))) {
    e.preventDefault();
    if (cmd.redo()) statusEl.textContent = `redo · ${cmd.redoStack.length} more`;
    else statusEl.textContent = 'nothing to redo';
    return;
  }

  const id = selectedPrimId();

  if (e.code === 'Space' && id) {
    e.preventDefault();
    const m = cycleXformMode();
    statusEl.textContent = `${id} · ${m}`;
    return;
  }

  if ((e.code === 'Backspace' || e.code === 'Delete') && id) {
    e.preventDefault();
    deleteSelectedCell();
    return;
  }

  const NUDGE = {
    ArrowLeft:  [-1, 0, 0],
    ArrowRight: [+1, 0, 0],
    ArrowUp:    [0, 0, -1],
    ArrowDown:  [0, 0, +1],
  };
  const NUDGE_Y = {
    ArrowUp:   [0, +1, 0],
    ArrowDown: [0, -1, 0],
  };
  if (id && (e.code in NUDGE)) {
    e.preventDefault();
    const cell = selectedCell();
    if (!cell) return;
    const delta = e.shiftKey && e.code in NUDGE_Y ? NUDGE_Y[e.code] : NUDGE[e.code];
    cmd.exec(new UpdateCellCmd(
      cell.id,
      { pos: [cell.pos[0] + delta[0], cell.pos[1] + delta[1], cell.pos[2] + delta[2]] },
      'nudge',
    ));
  }
});

document.getElementById('btn-new').addEventListener('click', () => {
  if (brief().cells.length > 0 && !confirm('Discard current brief?')) return;
  newBrief();
  cmd.clear();
  selectPrimitive(null);
  titleEl.textContent = 'untitled.json';
  statusEl.textContent = 'new brief';
});

document.getElementById('btn-save').addEventListener('click', () => {
  const fname = (titleEl.textContent || 'level.json').replace(/\.json$/i, '') + '.json';
  downloadBrief(fname);
  statusEl.textContent = `saved ${fname}`;
});

document.getElementById('btn-load').addEventListener('click', () => fileInput.click());
fileInput.addEventListener('change', async e => {
  const file = e.target.files[0];
  if (!file) return;
  try {
    loadBrief(await file.text());
    cmd.clear();
    selectPrimitive(null);
    titleEl.textContent = file.name;
    statusEl.textContent = `loaded ${file.name}`;
  } catch (err) {
    console.error(err);
    statusEl.textContent = `load failed: ${err.message}`;
  }
  fileInput.value = '';
});

function _refreshHud() {
  const cellCount = brief().cells.length;
  let primCount = 0;
  for (const c of brief().cells) primCount += c.primitives.length;
  const u = cmd.undoStack.length;
  const r = cmd.redoStack.length;
  countsEl.textContent = `${cellCount} cell${cellCount === 1 ? '' : 's'} · ${primCount} primitive${primCount === 1 ? '' : 's'} · ↶${u} ↷${r}`;
  const lint = lintBrief();
  if (lint.ok) {
    linterEl.textContent = '✓ valid';
    linterEl.classList.add('ok');
  } else {
    linterEl.textContent = '⚠ ' + lint.issues.join(' · ');
    linterEl.classList.remove('ok');
  }
}

(async function bootStarter() {
  try {
    const r = await fetch('/level_1_starter.json');
    if (!r.ok) return;
    loadBrief(await r.text());
    cmd.clear();
    titleEl.textContent = 'level_1_starter.json';
    statusEl.textContent = 'starter loaded';
  } catch {
  }
})();

_refreshHud();
