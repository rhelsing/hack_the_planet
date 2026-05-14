import * as THREE from 'three';
import { TransformControls } from 'three/addons/controls/TransformControls.js';
import { CELL_SIZE } from './config.js';
import { CELL_KINDS } from './kinds.js';
import { brief, getCell, getCellOfPrimitive, onBriefChange } from './brief.js';
import { cmd, UpdateCellCmd, RemoveCellCmd } from './commands.js';

let _scene, _root, _outline, _camera, _renderer;
let _onSelectionChanged = () => {};
let _selectedPrimId = null;
const _byCellId = new Map();

let _xform = null;
let _xformMode = 'translate';
let _xformWasDragging = false;

export function initCells({ scene, camera, renderer, onSelectionChanged }) {
  _scene = scene;
  _camera = camera;
  _renderer = renderer;
  _onSelectionChanged = onSelectionChanged ?? (() => {});

  _root = new THREE.Group();
  _root.name = 'cells';
  _scene.add(_root);

  _outline = new THREE.LineSegments(
    new THREE.EdgesGeometry(new THREE.BoxGeometry(1, 1, 1)),
    new THREE.LineBasicMaterial({ color: 0xffffff, depthTest: false, transparent: true, opacity: 0.95 })
  );
  _outline.renderOrder = 999;
  _outline.visible = false;
  _scene.add(_outline);

  _xform = new TransformControls(_camera, _renderer.domElement);
  _xform.setMode('translate');
  _xform.setTranslationSnap(CELL_SIZE);
  _xform.setScaleSnap(1.0);
  _xform.setSize(0.9);
  _xform.addEventListener('dragging-changed', e => {
    if (e.value) _xformWasDragging = true;
    else _commitXform();
  });
  _scene.add(_xform);

  onBriefChange(rebuildAll);
  rebuildAll();
}

export function rebuildAll() {
  for (const { mesh, edges } of _byCellId.values()) {
    _root.remove(mesh);
    _root.remove(edges);
    mesh.geometry.dispose(); mesh.material.dispose();
    edges.geometry.dispose(); edges.material.dispose();
  }
  _byCellId.clear();
  for (const cell of brief().cells) _addMesh(cell);

  if (_selectedPrimId && !getCellOfPrimitive(_selectedPrimId)) _selectedPrimId = null;
  _refreshOutline();
  _refreshXform();
}

function _cornerAnchoredBox(sx, sy, sz) {
  const g = new THREE.BoxGeometry(sx, sy, sz);
  g.translate(sx / 2, sy / 2, sz / 2);
  return g;
}

function _addMesh(cell) {
  const firstType = cell.primitives[0]?.type;
  const def = CELL_KINDS[firstType] ?? { color: 0x808080 };

  const sx = (cell.size?.[0] ?? 1) * CELL_SIZE;
  const sy = (cell.size?.[1] ?? 1) * CELL_SIZE;
  const sz = (cell.size?.[2] ?? 1) * CELL_SIZE;

  const mat = new THREE.MeshStandardMaterial({
    color: def.color, transparent: true, opacity: 0.42,
    roughness: 0.7, metalness: 0.0,
  });
  const mesh = new THREE.Mesh(_cornerAnchoredBox(sx, sy, sz), mat);
  mesh.position.set(cell.pos[0] * CELL_SIZE, cell.pos[1] * CELL_SIZE, cell.pos[2] * CELL_SIZE);
  mesh.userData.cellId = cell.id;
  _root.add(mesh);

  const edges = new THREE.LineSegments(
    new THREE.EdgesGeometry(mesh.geometry),
    new THREE.LineBasicMaterial({ color: def.color, transparent: true, opacity: 0.9 })
  );
  edges.position.copy(mesh.position);
  edges.userData.cellId = cell.id;
  _root.add(edges);

  _byCellId.set(cell.id, { mesh, edges });
}

export function pickPrimitiveAt(camera, ndc) {
  const ray = new THREE.Raycaster();
  ray.setFromCamera(ndc, camera);
  const candidates = [];
  for (const { mesh } of _byCellId.values()) candidates.push(mesh);
  const hits = ray.intersectObjects(candidates, false);
  if (hits.length === 0) return null;
  const cellId = hits[0].object.userData.cellId;
  const cell = getCell(cellId);
  return cell?.primitives[0]?.id ?? null;
}

export function selectPrimitive(primId) {
  if (primId && !getCellOfPrimitive(primId)) primId = null;
  _selectedPrimId = primId;
  _refreshOutline();
  _refreshXform();
  _onSelectionChanged(_selectedPrimId);
}

export function selectedPrimId() { return _selectedPrimId; }

export function selectedCell() {
  return _selectedPrimId ? getCellOfPrimitive(_selectedPrimId) : null;
}

function _refreshOutline() {
  const cell = selectedCell();
  if (!cell) { _outline.visible = false; return; }
  const entry = _byCellId.get(cell.id);
  if (!entry) { _outline.visible = false; return; }
  if (_outline.geometry) _outline.geometry.dispose();
  _outline.geometry = new THREE.EdgesGeometry(entry.mesh.geometry);
  _outline.position.copy(entry.mesh.position);
  _outline.visible = true;
}

function _refreshXform() {
  if (!_xform) return;
  const cell = selectedCell();
  if (!cell) { _xform.detach(); return; }
  const entry = _byCellId.get(cell.id);
  if (!entry) { _xform.detach(); return; }
  _xform.attach(entry.mesh);
}

function _commitXform() {
  const cell = selectedCell();
  if (!cell) return;
  const entry = _byCellId.get(cell.id);
  if (!entry) return;
  const m = entry.mesh;
  const pos = [
    Math.round(m.position.x / CELL_SIZE),
    Math.round(m.position.y / CELL_SIZE),
    Math.round(m.position.z / CELL_SIZE),
  ];
  const size = [
    Math.max(1, Math.round(m.scale.x * cell.size[0])),
    Math.max(1, Math.round(m.scale.y * cell.size[1])),
    Math.max(1, Math.round(m.scale.z * cell.size[2])),
  ];
  _xform.detach();
  const posChanged  = pos[0]  !== cell.pos[0]  || pos[1]  !== cell.pos[1]  || pos[2]  !== cell.pos[2];
  const sizeChanged = size[0] !== cell.size[0] || size[1] !== cell.size[1] || size[2] !== cell.size[2];
  if (!posChanged && !sizeChanged) {
    m.scale.set(1, 1, 1);
    _refreshXform();
    return;
  }
  const patch = {};
  if (posChanged)  patch.pos  = pos;
  if (sizeChanged) patch.size = size;
  cmd.exec(new UpdateCellCmd(cell.id, patch, sizeChanged ? 'scale' : 'translate'));
}

export function cycleXformMode() {
  if (!_xform) return _xformMode;
  _xformMode = _xformMode === 'translate' ? 'scale' : 'translate';
  _xform.setMode(_xformMode);
  return _xformMode;
}

export function xformMode() { return _xformMode; }

export function consumeXformDragFlag() {
  const v = _xformWasDragging;
  _xformWasDragging = false;
  return v;
}

export function deleteSelectedCell() {
  const cell = selectedCell();
  if (!cell) return false;
  _selectedPrimId = null;
  _xform?.detach();
  cmd.exec(new RemoveCellCmd(cell.id));
  _onSelectionChanged(null);
  return true;
}
