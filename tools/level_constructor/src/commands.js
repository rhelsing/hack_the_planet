import {
  addCell, removeCell, updateCell, getCell,
  addPrimitive, removePrimitive, dropPrimitiveAt, getCellAtPos, getCellOfPrimitive,
} from './brief.js';

export class CommandManager {
  constructor(maxHistory = 100) {
    this.undoStack = [];
    this.redoStack = [];
    this.maxHistory = maxHistory;
    this._listeners = new Set();
  }
  on(fn) { this._listeners.add(fn); return () => this._listeners.delete(fn); }
  _emit() { for (const fn of this._listeners) fn(this); }

  exec(command) {
    const result = command.do();
    this.undoStack.push(command);
    this.redoStack.length = 0;
    if (this.undoStack.length > this.maxHistory) this.undoStack.shift();
    this._emit();
    return result;
  }

  undo() {
    const c = this.undoStack.pop();
    if (!c) return false;
    c.undo();
    this.redoStack.push(c);
    this._emit();
    return true;
  }

  redo() {
    const c = this.redoStack.pop();
    if (!c) return false;
    c.do();
    this.undoStack.push(c);
    this._emit();
    return true;
  }

  clear() {
    this.undoStack.length = 0;
    this.redoStack.length = 0;
    this._emit();
  }

  get canUndo() { return this.undoStack.length > 0; }
  get canRedo() { return this.redoStack.length > 0; }
  get undoLabel() { return this.undoStack.at(-1)?.label ?? null; }
  get redoLabel() { return this.redoStack.at(-1)?.label ?? null; }
}

export const cmd = new CommandManager();

/**
 * DropPrimitiveCmd — places a primitive at a grid position.
 * If a cell exists there, primitive joins the bag.
 * If no cell, creates one and adds the primitive.
 * Tracks both states so undo works in either case.
 */
export class DropPrimitiveCmd {
  constructor({ pos, type }) {
    this.pos = [pos[0], pos[1], pos[2]];
    this.type = type;
    this.cellId = null;
    this.primId = null;
    this.createdCell = false;
    this.label = `add ${type}`;
  }
  do() {
    if (this.cellId === null) {
      const r = dropPrimitiveAt(this.pos, this.type);
      this.cellId = r.cell.id;
      this.primId = r.primitive.id;
      this.createdCell = r.createdCell;
      return r;
    }
    if (this.createdCell) {
      addCell({ pos: this.pos, size: [1, 1, 1], primitives: [{ id: this.primId, type: this.type }], id: this.cellId });
    } else {
      addPrimitive(this.cellId, { type: this.type, id: this.primId });
    }
    return { cell: getCell(this.cellId), primitive: { id: this.primId, type: this.type }, createdCell: this.createdCell };
  }
  undo() {
    if (this.createdCell) {
      removeCell(this.cellId);
    } else {
      removePrimitive(this.primId);
    }
  }
}

/**
 * RemovePrimitiveCmd — removes a primitive. If the cell becomes empty,
 * the cell is auto-removed. undo restores both.
 */
export class RemovePrimitiveCmd {
  constructor(primId) {
    this.primId = primId;
    this.snapshot = null;
    this.label = 'remove primitive';
  }
  do() {
    if (!this.snapshot) {
      const cell = getCellOfPrimitive(this.primId);
      if (!cell) return;
      const idx = cell.primitives.findIndex(p => p.id === this.primId);
      const prim = cell.primitives[idx];
      this.snapshot = {
        cellId: cell.id,
        cellWasRemoved: cell.primitives.length === 1,
        cellPos: [cell.pos[0], cell.pos[1], cell.pos[2]],
        cellSize: [cell.size[0], cell.size[1], cell.size[2]],
        primitive: { id: prim.id, type: prim.type },
        primIndex: idx,
        siblingPrims: cell.primitives.length === 1 ? [] : cell.primitives.filter(p => p.id !== prim.id).map(p => ({ id: p.id, type: p.type })),
      };
    }
    removePrimitive(this.primId);
  }
  undo() {
    if (!this.snapshot) return;
    if (this.snapshot.cellWasRemoved) {
      addCell({
        id: this.snapshot.cellId,
        pos: this.snapshot.cellPos,
        size: this.snapshot.cellSize,
        primitives: [this.snapshot.primitive],
      });
    } else {
      addPrimitive(this.snapshot.cellId, {
        type: this.snapshot.primitive.type,
        id: this.snapshot.primitive.id,
        atIndex: this.snapshot.primIndex,
      });
    }
  }
}

/**
 * RemoveCellCmd — removes whole cell with all primitives. undo restores all.
 */
export class RemoveCellCmd {
  constructor(cellId) {
    this.cellId = cellId;
    this.snapshot = null;
    this.label = 'delete cell';
  }
  do() {
    if (!this.snapshot) {
      const c = getCell(this.cellId);
      if (c) {
        this.snapshot = {
          id: c.id,
          pos: [c.pos[0], c.pos[1], c.pos[2]],
          size: [c.size[0], c.size[1], c.size[2]],
          primitives: c.primitives.map(p => ({ id: p.id, type: p.type })),
        };
      }
    }
    removeCell(this.cellId);
  }
  undo() {
    if (this.snapshot) {
      addCell({
        id: this.snapshot.id,
        pos: this.snapshot.pos,
        size: this.snapshot.size,
        primitives: this.snapshot.primitives,
      });
    }
  }
}

/**
 * UpdateCellCmd — patches pos/size on a cell.
 */
export class UpdateCellCmd {
  constructor(cellId, patch, label = 'edit cell') {
    this.cellId = cellId;
    this.patch = patch;
    this.before = null;
    this.label = label;
  }
  do() {
    if (!this.before) {
      const c = getCell(this.cellId);
      if (!c) return;
      this.before = {};
      if ('pos'  in this.patch) this.before.pos  = [c.pos[0],  c.pos[1],  c.pos[2]];
      if ('size' in this.patch) this.before.size = [c.size[0], c.size[1], c.size[2]];
    }
    updateCell(this.cellId, this.patch);
  }
  undo() {
    if (this.before) updateCell(this.cellId, this.before);
  }
}
