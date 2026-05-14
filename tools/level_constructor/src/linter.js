import { brief } from './brief.js';

export function lintBrief() {
  const counts = {};
  for (const cell of brief().cells) {
    for (const p of cell.primitives) {
      counts[p.type] = (counts[p.type] ?? 0) + 1;
    }
  }
  const issues = [];
  const startCount = counts.level_start ?? 0;
  const endCount = counts.level_end ?? 0;
  if (startCount !== 1) {
    issues.push(`level_start: ${startCount} (need 1)`);
  }
  if (endCount !== 1) {
    issues.push(`level_end: ${endCount} (need 1)`);
  }
  return { ok: issues.length === 0, issues, counts };
}
