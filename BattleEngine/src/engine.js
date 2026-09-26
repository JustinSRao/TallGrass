// TallGrass battle engine: a thin, synchronous wrapper around @pkmn/sim
// (Pokémon Showdown's simulator, MIT). It is bundled into one file and run
// inside JavaScriptCore on iOS, so it must not touch any Node API.
//
// Contract with the app (see Packages/TallGrassKit/.../BattleBridge.swift):
//   TallGrassBattle.start(json)          -> JSON { id, events, requests }
//   TallGrassBattle.choose(id, side, c)  -> JSON { events, requests, winner }
//   TallGrassBattle.end(id)
// Everything crosses the bridge as JSON strings so Swift never holds JS objects.
//
// Determinism: both phones run the same battle from the same seed and feed
// in the same choices in the same order, so they reach identical states
// without a server. Only choices ever travel over the network.

import { Battle, Dex } from '@pkmn/sim';

const FORMAT = 'gen9customgame';
const battles = new Map();
let nextId = 1;

// "gen5,<4 x 16-bit hex>" selects the Gen 5 PRNG, which is pure arithmetic.
// (Showdown's default "sodium" PRNG would pull in a crypto dependency.)
function seedFrom(numbers) {
  if (!Array.isArray(numbers) || numbers.length !== 4) {
    throw new Error('seed must be four integers');
  }
  const hex = numbers.map(n => (n & 0xffff).toString(16).padStart(4, '0')).join('');
  return `gen5,${hex}`;
}

function toSet(mon) {
  return {
    name: mon.nickname || mon.species,
    species: mon.species,
    item: mon.item || '',
    ability: mon.ability,
    moves: mon.moves,
    nature: mon.nature || 'Hardy',
    gender: mon.gender || '',
    evs: { hp: 0, atk: 0, def: 0, spa: 0, spd: 0, spe: 0 },
    ivs: mon.ivs || { hp: 31, atk: 31, def: 31, spa: 31, spd: 31, spe: 31 },
    level: mon.level || 50,
    shiny: !!mon.shiny,
    teraType: mon.teraType || undefined,
  };
}

// Any unseeded randomness would silently desync the two phones, so make it
// fail loudly instead. The sim only reaches Math.random when no seed is given.
Math.random = () => { throw new Error('unseeded Math.random() in battle engine'); };

// Showdown stamps each turn with "|t:|<wall-clock seconds>"; drop it so logs
// depend only on seed + choices.
const isTimestamp = line => line.startsWith('|t:|');

// Showdown writes "|split|p1" followed by an exact-HP line for that player and
// a percentage line for everyone else. Both phones already know both teams,
// so keep the exact one and drop the duplicate.
function resolveSplits(lines) {
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('|split|')) {
      out.push(lines[i + 1]);
      i += 2;
    } else {
      out.push(lines[i]);
    }
  }
  return out;
}

function drain(entry) {
  const events = resolveSplits(entry.battle.log.slice(entry.cursor)).filter(l => !isTimestamp(l));
  entry.cursor = entry.battle.log.length;
  const requests = {};
  for (const side of entry.battle.sides) {
    requests[side.id] = side.activeRequest || null;
  }
  return { events, requests, winner: entry.battle.ended ? (entry.battle.winner || '') : null };
}

function start(json) {
  const opts = JSON.parse(json);
  const battle = new Battle({ formatid: FORMAT, seed: seedFrom(opts.seed), strictChoices: true });
  battle.setPlayer('p1', { name: opts.p1.name, team: opts.p1.team.map(toSet) });
  battle.setPlayer('p2', { name: opts.p2.name, team: opts.p2.team.map(toSet) });
  const id = nextId++;
  const entry = { battle, cursor: 0 };
  battles.set(id, entry);
  return JSON.stringify({ id, ...drain(entry) });
}

function choose(id, side, choice) {
  const entry = battles.get(id);
  if (!entry) throw new Error(`no battle ${id}`);
  // With strictChoices Showdown throws on an illegal choice; report it as data
  // so a bad tap (or a desynced peer) never crashes the bridge.
  let ok;
  try {
    ok = entry.battle.choose(side, choice);
  } catch (err) {
    return JSON.stringify({ error: String(err.message || err), ...drain(entry) });
  }
  if (!ok) return JSON.stringify({ error: `rejected ${side}: ${choice}`, ...drain(entry) });
  return JSON.stringify(drain(entry));
}

function end(id) {
  const entry = battles.get(id);
  if (entry) entry.battle.destroy();
  battles.delete(id);
}

// Data lookups the app needs at catch time (legal abilities, level-up moves),
// so Swift doesn't carry a second copy of the Pokédex.
function species(name) {
  const s = Dex.forGen(9).species.get(name);
  if (!s.exists) return JSON.stringify(null);
  return JSON.stringify({
    name: s.name, num: s.num, types: s.types, baseStats: s.baseStats,
    abilities: s.abilities, tier: s.tier, isNonstandard: s.isNonstandard || null,
    tags: s.tags,
  });
}

function moveInfo(name) {
  const m = Dex.forGen(9).moves.get(name);
  if (!m.exists) return JSON.stringify(null);
  return JSON.stringify({
    name: m.name, type: m.type, category: m.category, basePower: m.basePower,
    accuracy: m.accuracy, pp: m.pp, priority: m.priority, isNonstandard: m.isNonstandard || null,
  });
}

// Type-chart multiplier of a move against a species' types (0, 0.25 … 4).
// A hint for the move buttons only: it ignores abilities, items and Tera.
function effectiveness(moveName, speciesName) {
  const dex = Dex.forGen(9);
  const m = dex.moves.get(moveName);
  const s = dex.species.get(speciesName);
  if (!m.exists || !s.exists || m.category === 'Status') return JSON.stringify(null);
  if (!dex.getImmunity(m.type, s.types)) return JSON.stringify(0);
  return JSON.stringify(Math.pow(2, dex.getEffectiveness(m.type, s.types)));
}

globalThis.TallGrassBattle = { start, choose, end, species, moveInfo, effectiveness, format: FORMAT };
