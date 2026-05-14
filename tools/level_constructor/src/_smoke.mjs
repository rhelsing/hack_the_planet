import {
  brief, newBrief, loadBrief, briefToJson,
  addCell, removeCell, updateCell, getCell, getCellAtPos,
  addPrimitive, removePrimitive, dropPrimitiveAt,
  getPrimitive, getCellOfPrimitive,
  onBriefChange,
} from './brief.js';
import { CELL_KINDS, CELL_KIND_IDS, hexString } from './kinds.js';
import { cmd, DropPrimitiveCmd, RemovePrimitiveCmd, RemoveCellCmd, UpdateCellCmd, CommandManager } from './commands.js';
import { lintBrief } from './linter.js';

let fail = 0;
function eq(actual, expected, label) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  console.log(ok ? `  PASS ${label}` : `  FAIL ${label}\n    expected ${JSON.stringify(expected)}\n    got      ${JSON.stringify(actual)}`);
  if (!ok) fail++;
}
function truthy(v, label) {
  console.log(v ? `  PASS ${label}` : `  FAIL ${label}`);
  if (!v) fail++;
}

console.log('== kinds ==');
truthy(CELL_KIND_IDS.length === 4, 'four primitive types');
truthy('level_start' in CELL_KINDS, 'level_start');
truthy('level_end' in CELL_KINDS, 'level_end');
truthy('checkpoint' in CELL_KINDS, 'checkpoint');
truthy('structure' in CELL_KINDS, 'structure');
eq(hexString(0x4ade80), '#4ade80', 'hex format');

console.log('== bag basics ==');
newBrief();
const r1 = dropPrimitiveAt([0, 0, 0], 'level_start');
eq(r1.createdCell, true, 'drop to empty pos creates cell');
eq(brief().cells.length, 1, 'one cell after first drop');
eq(brief().cells[0].primitives.length, 1, 'cell has 1 primitive');

const r2 = dropPrimitiveAt([0, 0, 0], 'checkpoint');
eq(r2.createdCell, false, 'drop to occupied pos merges into bag');
eq(brief().cells.length, 1, 'still one cell');
eq(brief().cells[0].primitives.length, 2, 'cell now has 2 primitives');
eq(r2.cell.id, r1.cell.id, 'merged into same cell');

const r3 = dropPrimitiveAt([3, 0, 0], 'level_end');
eq(brief().cells.length, 2, 'second drop at new pos creates second cell');

console.log('== getters ==');
eq(getCell(r1.cell.id).primitives.length, 2, 'getCell finds cell');
eq(getCellAtPos([0,0,0]).id, r1.cell.id, 'getCellAtPos finds by position');
eq(getCellAtPos([99,0,0]), null, 'getCellAtPos returns null for empty');
eq(getPrimitive(r2.primitive.id).type, 'checkpoint', 'getPrimitive');
eq(getCellOfPrimitive(r2.primitive.id).id, r1.cell.id, 'getCellOfPrimitive');

console.log('== removePrimitive auto-cleans empty cell ==');
newBrief();
const a = dropPrimitiveAt([0,0,0], 'level_start');
const b = dropPrimitiveAt([0,0,0], 'checkpoint');
const removeFirst = removePrimitive(a.primitive.id);
eq(brief().cells.length, 1, 'cell still exists with 1 primitive remaining');
eq(removeFirst.removedCell, null, 'removePrimitive did NOT auto-remove cell');

const removeLast = removePrimitive(b.primitive.id);
eq(brief().cells.length, 0, 'cell auto-removed when bag empty');
truthy(removeLast.removedCell !== null, 'removePrimitive returned removedCell snapshot');

console.log('== load rejects bad input ==');
let threw = false;
try { loadBrief('{}'); } catch { threw = true; }
truthy(threw, 'rejects no cells');

threw = false;
try { loadBrief(JSON.stringify({ cells: [{ id: 'c1', pos: [0,0,0] }] })); } catch { threw = true; }
truthy(threw, 'rejects cell missing primitives');

threw = false;
try { loadBrief(JSON.stringify({ cells: [{ id: 'c1', pos: [0,0,0], primitives: [{ id: 'p1', type: 'unknown_type' }] }] })); } catch { threw = true; }
truthy(threw, 'rejects unknown primitive type');

console.log('== load round-trip ==');
newBrief();
dropPrimitiveAt([5,0,0], 'level_start');
dropPrimitiveAt([5,0,0], 'checkpoint');
dropPrimitiveAt([10,0,0], 'level_end');
const json = briefToJson();
newBrief();
loadBrief(json);
eq(brief().cells.length, 2, 'reloaded brief has 2 cells');
eq(brief().cells[0].primitives.length, 2, 'first cell has 2 prims');

console.log('== DropPrimitiveCmd undo/redo ==');
newBrief();
cmd.clear();
const dr = cmd.exec(new DropPrimitiveCmd({ pos: [0,0,0], type: 'level_start' }));
eq(dr.createdCell, true, 'first drop created cell');
eq(brief().cells.length, 1, 'one cell');
cmd.undo();
eq(brief().cells.length, 0, 'undo removed the cell');
cmd.redo();
eq(brief().cells.length, 1, 'redo restored cell');
eq(getCell(dr.cell.id) !== null, true, 'redo restored same cell id');

const dr2 = cmd.exec(new DropPrimitiveCmd({ pos: [0,0,0], type: 'checkpoint' }));
eq(dr2.createdCell, false, 'second drop merged');
eq(getCell(dr.cell.id).primitives.length, 2, 'cell has 2 prims');
cmd.undo();
eq(getCell(dr.cell.id).primitives.length, 1, 'undo merged-drop removed just the prim');
eq(brief().cells.length, 1, 'cell still there');

console.log('== RemovePrimitiveCmd auto-cell-removal undo ==');
newBrief();
cmd.clear();
const x = cmd.exec(new DropPrimitiveCmd({ pos: [2,0,0], type: 'level_start' }));
const y = cmd.exec(new DropPrimitiveCmd({ pos: [2,0,0], type: 'checkpoint' }));
cmd.exec(new RemovePrimitiveCmd(x.primitive.id));
eq(getCell(x.cell.id).primitives.length, 1, 'one prim left');
cmd.exec(new RemovePrimitiveCmd(y.primitive.id));
eq(brief().cells.length, 0, 'cell auto-removed');
cmd.undo();
eq(brief().cells.length, 1, 'undo restored cell');
eq(getCell(x.cell.id).primitives.length, 1, 'cell has 1 prim again');
cmd.undo();
eq(getCell(x.cell.id).primitives.length, 2, 'undo restored other prim');

console.log('== RemoveCellCmd captures all primitives ==');
newBrief();
cmd.clear();
cmd.exec(new DropPrimitiveCmd({ pos: [4,0,0], type: 'level_start' }));
cmd.exec(new DropPrimitiveCmd({ pos: [4,0,0], type: 'checkpoint' }));
const cellId = brief().cells[0].id;
cmd.exec(new RemoveCellCmd(cellId));
eq(brief().cells.length, 0, 'cell deleted');
cmd.undo();
eq(brief().cells.length, 1, 'undo restored cell');
eq(getCell(cellId).primitives.length, 2, 'all primitives restored');

console.log('== UpdateCellCmd pos/size only ==');
newBrief();
cmd.clear();
cmd.exec(new DropPrimitiveCmd({ pos: [0,0,0], type: 'level_start' }));
const c = brief().cells[0];
cmd.exec(new UpdateCellCmd(c.id, { pos: [3, 0, 0] }));
eq(getCell(c.id).pos, [3,0,0], 'cell moved');
cmd.exec(new UpdateCellCmd(c.id, { size: [2, 1, 3] }));
eq(getCell(c.id).size, [2,1,3], 'cell resized');
cmd.undo();
eq(getCell(c.id).size, [1,1,1], 'undo size');
cmd.undo();
eq(getCell(c.id).pos, [0,0,0], 'undo pos');

console.log('== linter ==');
newBrief();
const lint0 = lintBrief();
eq(lint0.ok, false, 'empty brief is invalid (no level_start)');
truthy(lint0.issues.some(i => i.includes('level_start')), 'reports level_start missing');

dropPrimitiveAt([0,0,0], 'level_start');
const lint1 = lintBrief();
eq(lint1.ok, false, 'one start, no end is invalid');

dropPrimitiveAt([3,0,0], 'level_end');
const lint2 = lintBrief();
eq(lint2.ok, true, 'one start + one end is valid');

dropPrimitiveAt([5,0,0], 'level_start');
const lint3 = lintBrief();
eq(lint3.ok, false, 'two starts is invalid');

console.log(fail === 0 ? '\nALL PASS' : `\n${fail} FAIL`);
process.exit(fail === 0 ? 0 : 1);
