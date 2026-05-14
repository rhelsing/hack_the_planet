import { CELL_KINDS, CELL_KIND_IDS, hexString } from './kinds.js';

export function initPalette({ root, onDragStart }) {
  root.innerHTML = '';
  const heading = document.createElement('h3');
  heading.textContent = 'Cell Kinds';
  root.appendChild(heading);

  for (const id of CELL_KIND_IDS) {
    const def = CELL_KINDS[id];
    const el = document.createElement('div');
    el.className = 'kind';
    el.dataset.kind = id;

    const swatch = document.createElement('span');
    swatch.className = 'swatch';
    swatch.style.background = hexString(def.color);

    const label = document.createElement('span');
    label.className = 'label';
    label.textContent = def.label;

    el.appendChild(swatch);
    el.appendChild(label);

    el.addEventListener('mousedown', e => {
      if (e.button !== 0) return;
      e.preventDefault();
      onDragStart(id, e);
    });

    root.appendChild(el);
  }
}
