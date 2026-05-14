export const CELL_KINDS = {
  level_start: { color: 0x4ade80, label: 'Level Start' },
  level_end:   { color: 0xfacc15, label: 'Level End' },
  checkpoint:  { color: 0x60a5fa, label: 'Checkpoint' },
  structure:   { color: 0x94a3b8, label: 'Structure' },
};

export const CELL_KIND_IDS = Object.keys(CELL_KINDS);

export function hexString(color) {
  return '#' + color.toString(16).padStart(6, '0');
}
