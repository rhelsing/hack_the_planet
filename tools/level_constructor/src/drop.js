import * as THREE from 'three';
import { CELL_SIZE } from './config.js';
import { CELL_KINDS } from './kinds.js';
import { cmd, DropPrimitiveCmd } from './commands.js';
import { selectPrimitive } from './cells.js';

let _scene, _camera, _canvas;
let _ghost = null;
let _type = null;
let _hasValidPos = false;

const _floor = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);

export function initDrop({ scene, camera, canvas }) {
  _scene = scene;
  _camera = camera;
  _canvas = canvas;
}

export function startDrag(typeId, initialEvent) {
  if (_ghost) _cleanup();
  _type = typeId;
  const def = CELL_KINDS[typeId];
  if (!def) return;

  const mat = new THREE.MeshStandardMaterial({
    color: def.color, transparent: true, opacity: 0.4, depthWrite: false,
  });
  const ghostGeo = new THREE.BoxGeometry(CELL_SIZE, CELL_SIZE, CELL_SIZE);
  ghostGeo.translate(CELL_SIZE / 2, CELL_SIZE / 2, CELL_SIZE / 2);
  _ghost = new THREE.Mesh(ghostGeo, mat);
  _ghost.visible = false;
  _scene.add(_ghost);

  window.addEventListener('mousemove', _onMouseMove);
  window.addEventListener('mouseup', _onMouseUp);
  window.addEventListener('keydown', _onKeyDown);

  if (initialEvent) _onMouseMove(initialEvent);
}

function _onMouseMove(e) {
  if (!_ghost) return;
  const rect = _canvas.getBoundingClientRect();
  const ndc = new THREE.Vector2(
    ((e.clientX - rect.left) / rect.width) * 2 - 1,
    -((e.clientY - rect.top) / rect.height) * 2 + 1,
  );
  const ray = new THREE.Raycaster();
  ray.setFromCamera(ndc, _camera);
  const point = new THREE.Vector3();
  const hit = ray.ray.intersectPlane(_floor, point);
  if (!hit) {
    _ghost.visible = false;
    _hasValidPos = false;
    return;
  }
  const cx = Math.floor(point.x / CELL_SIZE);
  const cz = Math.floor(point.z / CELL_SIZE);
  _ghost.position.set(cx * CELL_SIZE, 0, cz * CELL_SIZE);
  _ghost.userData.gridPos = [cx, 0, cz];
  _ghost.visible = true;
  _hasValidPos = true;
}

function _onMouseUp(e) {
  if (e.button !== 0) return;
  if (_hasValidPos && _ghost?.userData.gridPos) {
    const r = cmd.exec(new DropPrimitiveCmd({ pos: _ghost.userData.gridPos, type: _type }));
    selectPrimitive(r.primitive.id);
  }
  _cleanup();
}

function _onKeyDown(e) {
  if (e.code === 'Escape') _cleanup();
}

function _cleanup() {
  window.removeEventListener('mousemove', _onMouseMove);
  window.removeEventListener('mouseup', _onMouseUp);
  window.removeEventListener('keydown', _onKeyDown);
  if (_ghost) {
    _scene.remove(_ghost);
    _ghost.geometry.dispose();
    _ghost.material.dispose();
    _ghost = null;
  }
  _type = null;
  _hasValidPos = false;
}

export const isDragging = () => _ghost !== null;
