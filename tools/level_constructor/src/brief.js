import { CELL_KINDS } from './kinds.js';

const DEFAULT_BRIEF = () => ({
  level_num: 1,
  biome: { primary: '#4ade80', accent: '#facc15' },
  seed: 1,
  cells: [],
});

let _brief = DEFAULT_BRIEF();
let _cellCounter = 1;
let _primCounter = 1;

const _listeners = new Set();
function _emit() { for (const fn of _listeners) fn(_brief); }
export function onBriefChange(fn) { _listeners.add(fn); return () => _listeners.delete(fn); }

export function brief() { return _brief; }

export function newBrief() {
  _brief = DEFAULT_BRIEF();
  _cellCounter = 1;
  _primCounter = 1;
  _emit();
}

function _coerceSize(s) {
  if (!Array.isArray(s)) return [1, 1, 1];
  return [Math.max(1, s[0] | 0), Math.max(1, s[1] | 0), Math.max(1, s[2] | 0)];
}

function _coercePos(p) {
  return [p[0] | 0, p[1] | 0, p[2] | 0];
}

function _bumpCellCounter(id) {
  const n = parseInt(String(id).replace(/^c/, ''), 10);
  if (Number.isFinite(n) && n >= _cellCounter) _cellCounter = n + 1;
}

function _bumpPrimCounter(id) {
  const n = parseInt(String(id).replace(/^p/, ''), 10);
  if (Number.isFinite(n) && n >= _primCounter) _primCounter = n + 1;
}

export function loadBrief(input) {
  const data = typeof input === 'string' ? JSON.parse(input) : input;
  if (!data || !Array.isArray(data.cells)) {
    throw new Error('invalid brief: missing cells array');
  }
  for (const c of data.cells) {
    c.size = _coerceSize(c.size);
    c.pos = _coercePos(c.pos);
    if (!Array.isArray(c.primitives) || c.primitives.length === 0) {
      throw new Error(`invalid brief: cell ${c.id ?? '?'} has no primitives`);
    }
    for (const p of c.primitives) {
      if (!(p.type in CELL_KINDS)) {
        throw new Error(`invalid brief: unknown primitive type "${p.type}"`);
      }
    }
  }
  _brief = data;
  for (const c of _brief.cells) {
    _bumpCellCounter(c.id);
    for (const p of c.primitives) _bumpPrimCounter(p.id);
  }
  _emit();
}

export function briefToJson() { return JSON.stringify(_brief, null, 2); }

export function downloadBrief(filename = 'level.json') {
  const blob = new Blob([briefToJson()], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

export function getCell(cellId) {
  return _brief.cells.find(c => c.id === cellId) ?? null;
}

export function getCellAtPos(pos) {
  const ip = _coercePos(pos);
  return _brief.cells.find(c => c.pos[0] === ip[0] && c.pos[1] === ip[1] && c.pos[2] === ip[2]) ?? null;
}

export function getPrimitive(primId) {
  for (const cell of _brief.cells) {
    const p = cell.primitives.find(p => p.id === primId);
    if (p) return p;
  }
  return null;
}

export function getCellOfPrimitive(primId) {
  for (const cell of _brief.cells) {
    if (cell.primitives.some(p => p.id === primId)) return cell;
  }
  return null;
}

export function addCell({ pos, size = [1, 1, 1], primitives = [], id = null }) {
  let cellId = id;
  if (cellId == null) cellId = `c${_cellCounter++}`;
  else _bumpCellCounter(cellId);
  const cell = {
    id: cellId,
    pos: _coercePos(pos),
    size: _coerceSize(size),
    primitives: primitives.map(p => {
      if (!p.id) p.id = `p${_primCounter++}`;
      else _bumpPrimCounter(p.id);
      return p;
    }),
  };
  _brief.cells.push(cell);
  _emit();
  return cell;
}

export function removeCell(cellId) {
  const before = _brief.cells.length;
  _brief.cells = _brief.cells.filter(c => c.id !== cellId);
  if (_brief.cells.length !== before) _emit();
}

export function updateCell(cellId, patch) {
  const cell = _brief.cells.find(c => c.id === cellId);
  if (!cell) return null;
  if (patch.pos)  cell.pos  = _coercePos(patch.pos);
  if (patch.size) cell.size = _coerceSize(patch.size);
  _emit();
  return cell;
}

export function addPrimitive(cellId, { type, id = null, atIndex = -1 } = {}) {
  const cell = _brief.cells.find(c => c.id === cellId);
  if (!cell) return null;
  let primId = id;
  if (primId == null) primId = `p${_primCounter++}`;
  else _bumpPrimCounter(primId);
  const prim = { id: primId, type };
  if (atIndex >= 0 && atIndex <= cell.primitives.length) {
    cell.primitives.splice(atIndex, 0, prim);
  } else {
    cell.primitives.push(prim);
  }
  _emit();
  return prim;
}

export function removePrimitive(primId) {
  for (let i = 0; i < _brief.cells.length; i++) {
    const cell = _brief.cells[i];
    const idx = cell.primitives.findIndex(p => p.id === primId);
    if (idx < 0) continue;
    const removed = cell.primitives.splice(idx, 1)[0];
    let removedCell = null;
    if (cell.primitives.length === 0) {
      removedCell = _brief.cells.splice(i, 1)[0];
    }
    _emit();
    return { primitive: removed, primIndex: idx, removedCell };
  }
  return null;
}

export function updatePrimitive(primId, patch) {
  for (const cell of _brief.cells) {
    const prim = cell.primitives.find(p => p.id === primId);
    if (!prim) continue;
    if ('type' in patch) prim.type = patch.type;
    _emit();
    return prim;
  }
  return null;
}

export function dropPrimitiveAt(pos, type) {
  const ip = _coercePos(pos);
  let cell = getCellAtPos(ip);
  let createdCell = false;
  if (!cell) {
    cell = {
      id: `c${_cellCounter++}`,
      pos: ip,
      size: [1, 1, 1],
      primitives: [],
    };
    _brief.cells.push(cell);
    createdCell = true;
  }
  const prim = { id: `p${_primCounter++}`, type };
  cell.primitives.push(prim);
  _emit();
  return { cell, primitive: prim, createdCell };
}
