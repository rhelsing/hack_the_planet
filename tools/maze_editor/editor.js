// Maze editor — DOM grid, h/v matrix state, JSON export.
// Format (.maze file):
//   { version: 1, cols, rows, start: [x,y], end: [x,y],
//     time_limit: number (seconds; 0 = untimed),
//     h: rows × (cols-1) of 0/1,        // h[y][x] = edge open (x,y)↔(x+1,y)
//     v: (rows-1) × cols of 0/1,        // v[y][x] = edge open (x,y)↔(x,y+1)
//     cells: (rows-1) × (cols-1) of     // cell markers (Witness-style
//       0|1|2 }                          // separation): 0=none, 1=water,
//                                        // 2=oil. Optional — defaults to
//                                        // all-zero (no separation rule).

const NODE_PX = 22;
const EDGE_PX = 56;
const MARKER_NONE = 0;
const MARKER_WATER = 1;
const MARKER_OIL = 2;

const state = {
	cols: 5, rows: 5,
	h: [], v: [],
	cells: [],   // (rows-1) × (cols-1) of int
	start: null, end: null,
	mode: "edges",
	time_limit: 0, // 0 = untimed
};
let painting = null; // null | 0 | 1 — drag-paint target value

// --- Helpers --------------------------------------------------------------

function makeMatrix(w, h) {
	const m = [];
	for (let y = 0; y < h; y++) {
		const row = new Array(w).fill(0);
		m.push(row);
	}
	return m;
}

function isPerimeter(x, y) {
	return x === 0 || x === state.cols - 1 || y === 0 || y === state.rows - 1;
}

function setStatus(text, kind) {
	const el = document.getElementById("status");
	el.textContent = text;
	el.className = "status" + (kind ? " " + kind : "");
}

// --- BFS verify -----------------------------------------------------------

function verify() {
	if (!state.start || !state.end) return false;
	const seen = new Set();
	const key = (x, y) => x + "," + y;
	const queue = [state.start];
	seen.add(key(state.start[0], state.start[1]));
	while (queue.length) {
		const [x, y] = queue.shift();
		if (x === state.end[0] && y === state.end[1]) return true;
		const nbrs = [];
		if (x > 0 && state.h[y][x - 1]) nbrs.push([x - 1, y]);
		if (x < state.cols - 1 && state.h[y][x]) nbrs.push([x + 1, y]);
		if (y > 0 && state.v[y - 1][x]) nbrs.push([x, y - 1]);
		if (y < state.rows - 1 && state.v[y][x]) nbrs.push([x, y + 1]);
		for (const [nx, ny] of nbrs) {
			const k = key(nx, ny);
			if (!seen.has(k)) {
				seen.add(k);
				queue.push([nx, ny]);
			}
		}
	}
	return false;
}

function refreshStatus() {
	const dl = document.getElementById("download");
	if (!state.start) {
		setStatus("set start (perimeter only)", "");
		dl.disabled = true;
		return;
	}
	if (!state.end) {
		setStatus("set end (perimeter only)", "");
		dl.disabled = true;
		return;
	}
	const ok = verify();
	if (ok) {
		setStatus("verify ✓ — solvable", "ok");
		dl.disabled = false;
	} else {
		setStatus("verify ✗ — no path from S to E", "err");
		dl.disabled = true;
	}
}

// --- Render ---------------------------------------------------------------

function render() {
	const grid = document.getElementById("grid");
	const W = 2 * state.cols - 1;
	const H = 2 * state.rows - 1;
	let colT = "", rowT = "";
	for (let i = 0; i < W; i++) colT += (i % 2 === 0 ? NODE_PX : EDGE_PX) + "px ";
	for (let i = 0; i < H; i++) rowT += (i % 2 === 0 ? NODE_PX : EDGE_PX) + "px ";
	grid.style.gridTemplateColumns = colT;
	grid.style.gridTemplateRows = rowT;
	grid.innerHTML = "";

	for (let r = 0; r < H; r++) {
		for (let c = 0; c < W; c++) {
			const cell = document.createElement("div");
			cell.classList.add("cell");
			const isNodeRow = r % 2 === 0;
			const isNodeCol = c % 2 === 0;
			const x = (c / 2) | 0;
			const y = (r / 2) | 0;

			if (isNodeRow && isNodeCol) {
				cell.classList.add("node");
				cell.dataset.x = x;
				cell.dataset.y = y;
				if (isPerimeter(x, y)) cell.classList.add("perimeter");
				if (state.start && state.start[0] === x && state.start[1] === y) {
					cell.classList.add("start");
					cell.dataset.label = "S";
				} else if (state.end && state.end[0] === x && state.end[1] === y) {
					cell.classList.add("end");
					cell.dataset.label = "E";
				}
				cell.addEventListener("click", () => onNodeClick(x, y));
			} else if (isNodeRow && !isNodeCol) {
				cell.classList.add("edge", "h");
				if (state.h[y][x]) cell.classList.add("open");
				attachEdgeHandlers(cell, "h", x, y);
			} else if (!isNodeRow && isNodeCol) {
				cell.classList.add("edge", "v");
				if (state.v[y][x]) cell.classList.add("open");
				attachEdgeHandlers(cell, "v", x, y);
			} else {
				// Corner / cell-interior: doubles as a marker slot in
				// water/oil modes. (cx, cy) is the cell index; CSS grid
				// position is (2*cx+1, 2*cy+1).
				cell.classList.add("corner");
				const cx = (c - 1) / 2;
				const cy = (r - 1) / 2;
				cell.dataset.cx = cx;
				cell.dataset.cy = cy;
				const marker = state.cells[cy][cx];
				if (marker === MARKER_WATER) cell.classList.add("water");
				else if (marker === MARKER_OIL) cell.classList.add("oil");
				cell.addEventListener("click", () => onCellClick(cx, cy));
			}
			grid.appendChild(cell);
		}
	}
}

function attachEdgeHandlers(el, kind, x, y) {
	el.addEventListener("mousedown", (e) => {
		if (state.mode !== "edges") return;
		e.preventDefault();
		const m = kind === "h" ? state.h : state.v;
		const next = m[y][x] ? 0 : 1;
		painting = next;
		m[y][x] = next;
		el.classList.toggle("open", next === 1);
		refreshStatus();
	});
	el.addEventListener("mouseenter", () => {
		if (painting === null || state.mode !== "edges") return;
		const m = kind === "h" ? state.h : state.v;
		if (m[y][x] !== painting) {
			m[y][x] = painting;
			el.classList.toggle("open", painting === 1);
			refreshStatus();
		}
	});
}

// global mouseup ends drag-paint
document.addEventListener("mouseup", () => { painting = null; });
document.addEventListener("mouseleave", () => { painting = null; });

// --- Node click (S/E placement) ------------------------------------------

function onCellClick(cx, cy) {
	if (state.mode !== "water" && state.mode !== "oil") return;
	const target = state.mode === "water" ? MARKER_WATER : MARKER_OIL;
	state.cells[cy][cx] = state.cells[cy][cx] === target ? MARKER_NONE : target;
	render();
	refreshStatus();
}


function onNodeClick(x, y) {
	if (state.mode !== "start" && state.mode !== "end") return;
	if (!isPerimeter(x, y)) {
		setStatus("S/E must be on the perimeter", "err");
		return;
	}
	if (state.mode === "start") {
		if (state.end && state.end[0] === x && state.end[1] === y) state.end = null;
		state.start = [x, y];
	} else {
		if (state.start && state.start[0] === x && state.start[1] === y) state.start = null;
		state.end = [x, y];
	}
	render();
	refreshStatus();
}

// --- Resize / clear -------------------------------------------------------

function resize(newCols, newRows) {
	const newH = makeMatrix(newCols - 1, newRows);
	const newV = makeMatrix(newCols, newRows - 1);
	const newCells = makeMatrix(newCols - 1, newRows - 1);
	for (let y = 0; y < newRows; y++) {
		for (let x = 0; x < newCols - 1; x++) {
			if (state.h[y] && state.h[y][x] !== undefined) newH[y][x] = state.h[y][x];
		}
	}
	for (let y = 0; y < newRows - 1; y++) {
		for (let x = 0; x < newCols; x++) {
			if (state.v[y] && state.v[y][x] !== undefined) newV[y][x] = state.v[y][x];
		}
	}
	for (let y = 0; y < newRows - 1; y++) {
		for (let x = 0; x < newCols - 1; x++) {
			if (state.cells[y] && state.cells[y][x] !== undefined) newCells[y][x] = state.cells[y][x];
		}
	}
	state.h = newH; state.v = newV; state.cells = newCells;
	state.cols = newCols; state.rows = newRows;
	if (state.start && (state.start[0] >= newCols || state.start[1] >= newRows
			|| !isPerimeter(state.start[0], state.start[1]))) state.start = null;
	if (state.end && (state.end[0] >= newCols || state.end[1] >= newRows
			|| !isPerimeter(state.end[0], state.end[1]))) state.end = null;
	render();
	refreshStatus();
}

function clearAll() {
	state.h = makeMatrix(state.cols - 1, state.rows);
	state.v = makeMatrix(state.cols, state.rows - 1);
	state.cells = makeMatrix(state.cols - 1, state.rows - 1);
	state.start = null; state.end = null;
	render();
	refreshStatus();
}

// --- Download / Load ------------------------------------------------------

function download() {
	if (!verify()) return; // gated, but defensive
	const data = {
		version: 1,
		cols: state.cols, rows: state.rows,
		start: state.start, end: state.end,
		time_limit: state.time_limit,
		h: state.h, v: state.v,
		cells: state.cells,
	};
	const text = JSON.stringify(data);
	const blob = new Blob([text], { type: "application/json" });
	const url = URL.createObjectURL(blob);
	const a = document.createElement("a");
	a.href = url;
	a.download = `maze_${state.cols}x${state.rows}.maze`;
	document.body.appendChild(a);
	a.click();
	a.remove();
	URL.revokeObjectURL(url);
}

function loadFile(file) {
	const reader = new FileReader();
	reader.onload = () => {
		try {
			const d = JSON.parse(reader.result);
			if (typeof d.cols !== "number" || typeof d.rows !== "number") throw new Error("missing cols/rows");
			if (!Array.isArray(d.h) || !Array.isArray(d.v)) throw new Error("missing h/v");
			state.cols = d.cols;
			state.rows = d.rows;
			state.h = d.h.map(row => row.slice());
			state.v = d.v.map(row => row.slice());
			// cells optional — backward-compat with v1 mazes that pre-date markers.
			if (Array.isArray(d.cells) && d.cells.length === state.rows - 1) {
				state.cells = d.cells.map(row => row.slice());
			} else {
				state.cells = makeMatrix(state.cols - 1, state.rows - 1);
			}
			state.start = Array.isArray(d.start) ? [d.start[0], d.start[1]] : null;
			state.end = Array.isArray(d.end) ? [d.end[0], d.end[1]] : null;
			state.time_limit = (typeof d.time_limit === "number" && d.time_limit > 0) ? d.time_limit : 0;
			document.getElementById("cols").value = state.cols;
			document.getElementById("rows").value = state.rows;
			document.getElementById("timed").checked = state.time_limit > 0;
			document.getElementById("time_seconds").value = state.time_limit > 0 ? state.time_limit : 60;
			document.getElementById("time_seconds").disabled = state.time_limit === 0;
			render();
			refreshStatus();
		} catch (e) {
			setStatus("load failed: " + e.message, "err");
		}
	};
	reader.readAsText(file);
}

// --- Mode + body class ----------------------------------------------------

function setMode(mode) {
	state.mode = mode;
	document.body.classList.remove("mode-edges", "mode-start", "mode-end");
	document.body.classList.add("mode-" + mode);
	if (mode === "start") setStatus("click a perimeter node to set start", "");
	else if (mode === "end") setStatus("click a perimeter node to set end", "");
	else if (mode === "water") setStatus("click cells to place water (blue circle)", "");
	else if (mode === "oil") setStatus("click cells to place oil (purple square)", "");
	else refreshStatus();
}

// --- Init -----------------------------------------------------------------

function init() {
	state.h = makeMatrix(state.cols - 1, state.rows);
	state.v = makeMatrix(state.cols, state.rows - 1);
	state.cells = makeMatrix(state.cols - 1, state.rows - 1);
	render();
	setMode("edges");
	refreshStatus();

	document.getElementById("cols").addEventListener("change", (e) => {
		const v = Math.max(3, Math.min(15, parseInt(e.target.value) || 5));
		e.target.value = v;
		resize(v, state.rows);
	});
	document.getElementById("rows").addEventListener("change", (e) => {
		const v = Math.max(3, Math.min(15, parseInt(e.target.value) || 5));
		e.target.value = v;
		resize(state.cols, v);
	});
	document.querySelectorAll('input[name="mode"]').forEach(r => {
		r.addEventListener("change", (e) => setMode(e.target.value));
	});
	document.getElementById("clear").addEventListener("click", clearAll);
	document.getElementById("verify").addEventListener("click", refreshStatus);
	document.getElementById("download").addEventListener("click", download);
	document.getElementById("timed").addEventListener("change", (e) => {
		const secInput = document.getElementById("time_seconds");
		secInput.disabled = !e.target.checked;
		state.time_limit = e.target.checked ? Math.max(5, Math.min(600, parseInt(secInput.value) || 60)) : 0;
	});
	document.getElementById("time_seconds").addEventListener("change", (e) => {
		const v = Math.max(5, Math.min(600, parseInt(e.target.value) || 60));
		e.target.value = v;
		if (document.getElementById("timed").checked) state.time_limit = v;
	});
	document.getElementById("loadfile").addEventListener("change", (e) => {
		const f = e.target.files[0];
		if (f) loadFile(f);
		e.target.value = ""; // allow re-loading the same file
	});
}

init();
