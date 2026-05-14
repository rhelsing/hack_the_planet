import * as THREE from 'three';
import { CELL_SIZE } from './config.js';
import { CELL_KINDS, hexString } from './kinds.js';
import { brief, onBriefChange } from './brief.js';

let _root, _camera;
let _onSelect = () => {};
let _selectedPrimId = null;
const _stacks = new Map();

export function initTags({ root, camera, onSelectPrim }) {
  _root = root;
  _camera = camera;
  _onSelect = onSelectPrim ?? (() => {});
  onBriefChange(_rebuild);
  _rebuild();
  requestAnimationFrame(_loop);
}

export function setSelected(primId) {
  if (_selectedPrimId === primId) return;
  _selectedPrimId = primId;
  for (const stack of _stacks.values()) {
    for (const chip of stack.children) {
      chip.classList.toggle('selected', chip.dataset.primId === primId);
    }
  }
}

function _rebuild() {
  _root.innerHTML = '';
  _stacks.clear();
  for (const cell of brief().cells) {
    if (cell.primitives.length === 0) continue;
    const stack = document.createElement('div');
    stack.className = 'tag-stack';
    stack._pos = [cell.pos[0], cell.pos[1], cell.pos[2]];
    stack._size = [cell.size[0], cell.size[1], cell.size[2]];
    for (const prim of cell.primitives) {
      const def = CELL_KINDS[prim.type] ?? { color: 0x808080, label: prim.type };
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'tag-chip' + (prim.id === _selectedPrimId ? ' selected' : '');
      chip.dataset.primId = prim.id;
      chip.style.background = hexString(def.color);
      chip.textContent = def.label;
      chip.addEventListener('click', e => { e.stopPropagation(); _onSelect(prim.id); });
      stack.appendChild(chip);
    }
    _root.appendChild(stack);
    _stacks.set(cell.id, stack);
  }
}

const _v = new THREE.Vector3();
function _loop() {
  const W = window.innerWidth;
  const H = window.innerHeight;
  for (const el of _stacks.values()) {
    const [cx, cy, cz] = el._pos;
    const [sx, sy, sz] = el._size;
    _v.set(
      cx * CELL_SIZE + (sx * CELL_SIZE) / 2,
      cy * CELL_SIZE + sy * CELL_SIZE + CELL_SIZE * 0.1,
      cz * CELL_SIZE + (sz * CELL_SIZE) / 2,
    );
    _v.project(_camera);
    const screenX = (_v.x * 0.5 + 0.5) * W;
    const screenY = (1 - (_v.y * 0.5 + 0.5)) * H;
    if (_v.z > 1 || screenX < -120 || screenX > W + 120 || screenY < -120 || screenY > H + 120) {
      el.style.display = 'none';
      continue;
    }
    el.style.display = '';
    el.style.left = `${screenX}px`;
    el.style.top = `${screenY}px`;
  }
  requestAnimationFrame(_loop);
}
