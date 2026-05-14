import * as THREE from 'three';
import { CELL_SIZE, GRID_CELLS, FLY_SPEED, FLY_FAST_MULT, LOOK_SENS } from './config.js';

let _renderer, _scene, _camera, _canvas;
const _keys = new Set();
let _yaw = -Math.PI / 4;
let _pitch = -0.5;
let _looking = false;
let _lastT = 0;

export function initView(canvas) {
  _canvas = canvas;
  _scene = new THREE.Scene();
  _scene.background = new THREE.Color(0x0c0e14);
  _scene.fog = new THREE.Fog(0x0c0e14, 600, 2000);

  _camera = new THREE.PerspectiveCamera(60, window.innerWidth / window.innerHeight, 1, 4000);
  _camera.position.set(120, 140, 200);
  _applyLook();

  _renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  _renderer.setSize(window.innerWidth, window.innerHeight);
  _renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));

  _scene.add(new THREE.HemisphereLight(0xa0c4ff, 0x1f2937, 0.65));
  const sun = new THREE.DirectionalLight(0xffffff, 1.0);
  sun.position.set(300, 500, 250);
  _scene.add(sun);

  const total = CELL_SIZE * GRID_CELLS;
  const grid = new THREE.GridHelper(total, GRID_CELLS, 0x3b4456, 0x1a1f2c);
  grid.position.y = 0;
  _scene.add(grid);

  _scene.add(new THREE.AxesHelper(CELL_SIZE * 1.5));

  window.addEventListener('resize', _onResize);
  window.addEventListener('keydown', _onKeyDown);
  window.addEventListener('keyup', _onKeyUp);
  canvas.addEventListener('contextmenu', e => e.preventDefault());
  canvas.addEventListener('mousedown', _onMouseDown);
  window.addEventListener('mouseup', _onMouseUp);
  window.addEventListener('mousemove', _onMouseMove);
  window.addEventListener('blur', () => { _keys.clear(); _looking = false; });

  requestAnimationFrame(_loop);
  return { scene: _scene, camera: _camera, renderer: _renderer };
}

function _applyLook() {
  const e = new THREE.Euler(_pitch, _yaw, 0, 'YXZ');
  _camera.quaternion.setFromEuler(e);
}

function _onResize() {
  _camera.aspect = window.innerWidth / window.innerHeight;
  _camera.updateProjectionMatrix();
  _renderer.setSize(window.innerWidth, window.innerHeight);
}

function _isTypingTarget(t) {
  return t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable);
}

function _onKeyDown(e) {
  if (_isTypingTarget(e.target)) return;
  _keys.add(e.code);
}
function _onKeyUp(e) { _keys.delete(e.code); }

function _onMouseDown(e) {
  if (e.button === 2) { _looking = true; e.preventDefault(); }
}
function _onMouseUp(e) {
  if (e.button === 2) _looking = false;
}
function _onMouseMove(e) {
  if (!_looking) return;
  _yaw   -= e.movementX * LOOK_SENS;
  _pitch -= e.movementY * LOOK_SENS;
  const lim = Math.PI / 2 - 0.01;
  if (_pitch > lim) _pitch = lim;
  if (_pitch < -lim) _pitch = -lim;
  _applyLook();
}

function _loop(t) {
  const dt = _lastT ? Math.min(0.1, (t - _lastT) / 1000) : 0;
  _lastT = t;
  _move(dt);
  _renderer.render(_scene, _camera);
  requestAnimationFrame(_loop);
}

function _move(dt) {
  const fast = _keys.has('ShiftLeft') || _keys.has('ShiftRight');
  const speed = FLY_SPEED * (fast ? FLY_FAST_MULT : 1);
  const fwd = new THREE.Vector3();
  _camera.getWorldDirection(fwd);
  const right = new THREE.Vector3().crossVectors(fwd, _camera.up).normalize();
  const v = new THREE.Vector3();
  if (_keys.has('KeyW')) v.add(fwd);
  if (_keys.has('KeyS')) v.sub(fwd);
  if (_keys.has('KeyD')) v.add(right);
  if (_keys.has('KeyA')) v.sub(right);
  if (_keys.has('KeyE')) v.y += 1;
  if (_keys.has('KeyQ')) v.y -= 1;
  if (v.lengthSq() > 0) v.normalize().multiplyScalar(speed * dt);
  _camera.position.add(v);
}

export const scene = () => _scene;
export const camera = () => _camera;
export const renderer = () => _renderer;
