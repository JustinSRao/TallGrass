// Stage 3 (data half): join species_index.json with Showdown's Gen 9 data.
//
// The dump gives catch rate, stats and the model; Showdown (@pkmn/sim, MIT)
// gives names, types, abilities and Scarlet/Violet learnsets in the exact
// spelling the battle engine expects. Writes <work_dir>/species_data.json.
//
//   node pipeline/species_data.mjs
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const require = createRequire(new URL('../BattleEngine/package.json', import.meta.url));
const { Dex } = require('@pkmn/sim');
const dex = Dex.forGen(9);

// Minimal TOML read of the one key we need, to avoid a dependency.
const toml = readFileSync(new URL('./config.toml', import.meta.url), 'utf8');
const workDir = /^work_dir\s*=\s*'([^']+)'/m.exec(toml)[1];
const index = JSON.parse(readFileSync(join(workDir, 'species_index.json'), 'utf8'));

const MAX_LEVEL = 50; // everyone battles at level 50; later level-up moves aren't "learned"

function formeFor(national, form) {
  const base = dex.species.all().find(s => s.num === national && !s.forme) ||
               dex.species.all().find(s => s.num === national);
  if (!base) return { species: null, mapping: 'missing' };
  if (form === 0) return { species: base, mapping: 'base' };
  // Game form index N -> Showdown's Nth "other forme". Matches for the cases
  // checked (e.g. Tauros 1-3 = Combat/Blaze/Aqua) but is not proven for all.
  const name = (base.otherFormes || [])[form - 1];
  const s = name ? dex.species.get(name) : null;
  return s && s.exists ? { species: s, mapping: 'guessed' } : { species: null, mapping: 'unmapped' };
}

function movePool(species) {
  let id = species.id;
  let data = dex.species.getLearnsetData(id);
  // Formes without their own learnset inherit the base species' one.
  if (!data?.learnset && species.baseSpecies) data = dex.species.getLearnsetData(dex.species.get(species.baseSpecies).id);
  const pool = [];
  for (const [moveId, sources] of Object.entries(data?.learnset || {})) {
    const levelUp = sources.filter(s => s.startsWith('9L')).map(s => +s.slice(2));
    const learned = sources.includes('9M') || levelUp.some(l => l <= MAX_LEVEL);
    if (!learned) continue;
    const m = dex.moves.get(moveId);
    if (!m.exists || m.isNonstandard) continue;
    pool.push({ name: m.name, type: m.type, category: m.category, power: m.basePower,
                accuracy: m.accuracy === true ? 101 : m.accuracy, priority: m.priority });
  }
  return pool.sort((a, b) => a.name.localeCompare(b.name));
}

const out = [];
const problems = [];
for (const e of index) {
  const { species, mapping } = formeFor(e.national, e.form);
  if (!species) { problems.push(`${e.national}/${e.form}: ${mapping}`); continue; }
  const pool = movePool(species);
  if (pool.length < 1) { problems.push(`${species.name}: empty move pool`); continue; }
  out.push({
    id: species.id,
    name: species.name,
    national: e.national,
    form: e.form,
    formMapping: mapping,
    types: species.types,
    baseStats: species.baseStats,
    abilities: Object.values(species.abilities).filter((a, i, all) => a && all.indexOf(a) === i && a !== species.abilities.H),
    hiddenAbility: species.abilities.H || null,
    isLegendary: species.tags.includes('Restricted Legendary') || species.tags.includes('Sub-Legendary'),
    isMythical: species.tags.includes('Mythical'),
    isParadox: species.tags.includes('Paradox'),
    catchRate: e.catchRate,
    baseStatTotal: e.baseStatTotal,
    evolutionStage: e.evolutionStage,
    modelKey: `${String(e.national).padStart(4, '0')}_${String(e.form).padStart(2, '0')}`,
    movePool: pool,
  });
}

writeFileSync(join(workDir, 'species_data.json'), JSON.stringify(out, null, 1));
console.log(`species/forms with battle data: ${out.length} (${out.filter(s => s.formMapping === 'guessed').length} with guessed form mapping)`);
console.log(`problems: ${problems.length}`);
for (const p of problems.slice(0, 20)) console.log('  ', p);
