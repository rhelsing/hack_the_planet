import { CELL_KINDS, hexString } from './kinds.js';
import { getCellOfPrimitive, getPrimitive, onBriefChange } from './brief.js';
import { cmd, RemovePrimitiveCmd } from './commands.js';

let _root, _selectedPrimId = null, _onSelect = () => {};

export function initAttributes({ root, onSelectPrim }) {
  _root = root;
  _onSelect = onSelectPrim ?? (() => {});
  onBriefChange(render);
  render();
}

export function setSelected(primId) {
  _selectedPrimId = primId;
  render();
}

function render() {
  if (!_root) return;
  _root.innerHTML = '';

  const prim = _selectedPrimId ? getPrimitive(_selectedPrimId) : null;
  const cell = prim ? getCellOfPrimitive(_selectedPrimId) : null;
  if (!prim || !cell) {
    _root.style.display = 'none';
    return;
  }
  _root.style.display = '';

  const heading = document.createElement('h3');
  heading.textContent = `Block [${cell.pos.join(', ')}] · ${cell.primitives.length} primitive${cell.primitives.length === 1 ? '' : 's'}`;
  _root.appendChild(heading);

  for (const p of cell.primitives) {
    _root.appendChild(_primitiveSection(cell, p));
  }
}

function _primitiveSection(cell, prim) {
  const def = CELL_KINDS[prim.type] ?? { color: 0x808080, label: prim.type };
  const sec = document.createElement('div');
  sec.className = 'cell-section' + (prim.id === _selectedPrimId ? ' selected' : '');
  sec.dataset.primId = prim.id;

  const hdr = document.createElement('div');
  hdr.className = 'cell-header';

  const swatch = document.createElement('span');
  swatch.className = 'swatch';
  swatch.style.background = hexString(def.color);

  const label = document.createElement('span');
  label.className = 'prim-label';
  label.textContent = def.label;

  const idEl = document.createElement('span');
  idEl.className = 'id';
  idEl.textContent = prim.id;

  const trash = document.createElement('button');
  trash.type = 'button';
  trash.className = 'trash-btn';
  trash.title = 'Remove primitive (cell auto-removed if last)';
  trash.textContent = '✕';
  trash.addEventListener('click', e => {
    e.stopPropagation();
    cmd.exec(new RemovePrimitiveCmd(prim.id));
  });

  hdr.appendChild(swatch);
  hdr.appendChild(label);
  hdr.appendChild(idEl);
  hdr.appendChild(trash);
  hdr.addEventListener('click', e => {
    if (e.target === trash) return;
    _onSelect(prim.id);
  });

  sec.appendChild(hdr);
  return sec;
}
