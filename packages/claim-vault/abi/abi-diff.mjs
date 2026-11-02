// Compares two ABIs entry-by-entry on every field that affects encoding or
// client behaviour: type, name, input/output names+types+components, indexed,
// anonymous, stateMutability. internalType is ignored (compiler metadata only).
// usage: node abi-diff.mjs <reference.json> <candidate.json>
import { readFileSync } from 'node:fs';
const [ref, cand] = process.argv.slice(2).map((p) => JSON.parse(readFileSync(p, 'utf8')));
const p = (x) => ({ name: x.name ?? '', type: x.type, ...(x.indexed !== undefined ? { indexed: !!x.indexed } : {}), ...(x.components ? { components: x.components.map(p) } : {}) });
const norm = (e) => JSON.stringify({ type: e.type, name: e.name ?? '', inputs: (e.inputs ?? []).map(p), outputs: (e.outputs ?? []).map(p), stateMutability: e.stateMutability ?? '', anonymous: e.type === 'event' ? !!e.anonymous : undefined });
const key = (e) => `${e.type}:${e.name ?? ''}(${(e.inputs ?? []).map((i) => i.type).join(',')})`;
const R = new Map(ref.map((e) => [key(e), e])), C = new Map(cand.map((e) => [key(e), e]));
let diff = 0;
for (const [k, e] of R) {
  if (!C.has(k)) { console.log(`MISSING  ${k}`); diff++; continue; }
  if (norm(e) !== norm(C.get(k))) { console.log(`CHANGED  ${k}\n  ref : ${norm(e)}\n  cand: ${norm(C.get(k))}`); diff++; }
}
for (const k of C.keys()) if (!R.has(k)) console.log(`ADDED    ${k}`);
console.log(diff === 0 ? 'OK: every reference entry is present and identical' : `${diff} reference entries missing/changed`);
process.exit(diff === 0 ? 0 : 1);
