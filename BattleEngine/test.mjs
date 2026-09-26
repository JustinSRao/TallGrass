// Runs the *bundled* engine in a bare VM context with no Node globals, the
// same way JavaScriptCore will, and checks two things:
//   1. a full 6v6 level-50 battle finishes, and
//   2. the same seed + same choices give byte-identical logs (lockstep safety).
//   npm test
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const code = readFileSync(new URL('../App/Resources/battle-engine.js', import.meta.url), 'utf8');

function freshEngine() {
  const ctx = vm.createContext({}); // no require, process, Buffer, crypto, setTimeout
  vm.runInContext(code, ctx);
  return ctx.TallGrassBattle;
}

const teamA = [
  { species: 'Pikachu', ability: 'Static', moves: ['Thunderbolt', 'Quick Attack', 'Iron Tail', 'Thunder Wave'] },
  { species: 'Pawmot', ability: 'Volt Absorb', moves: ['Double Shock', 'Close Combat', 'Revival Blessing', 'Nuzzle'] },
  { species: 'Garchomp', ability: 'Rough Skin', moves: ['Earthquake', 'Dragon Claw', 'Swords Dance', 'Stone Edge'] },
  { species: 'Gholdengo', ability: 'Good as Gold', moves: ['Make It Rain', 'Shadow Ball', 'Nasty Plot', 'Recover'] },
  { species: 'Tinkaton', ability: 'Mold Breaker', moves: ['Gigaton Hammer', 'Play Rough', 'Stealth Rock', 'Encore'] },
  { species: 'Meowscarada', ability: 'Protean', moves: ['Flower Trick', 'Knock Off', 'U-turn', 'Sucker Punch'] },
];
const teamB = [
  { species: 'Skeledirge', ability: 'Unaware', moves: ['Torch Song', 'Shadow Ball', 'Slack Off', 'Will-O-Wisp'] },
  { species: 'Quaquaval', ability: 'Moxie', moves: ['Aqua Step', 'Close Combat', 'Ice Spinner', 'Rapid Spin'] },
  { species: 'Dragonite', ability: 'Multiscale', moves: ['Extreme Speed', 'Dragon Dance', 'Earthquake', 'Fire Punch'] },
  { species: 'Kingambit', ability: 'Supreme Overlord', moves: ['Kowtow Cleave', 'Iron Head', 'Sucker Punch', 'Swords Dance'] },
  { species: 'Clodsire', ability: 'Water Absorb', moves: ['Earthquake', 'Toxic', 'Recover', 'Haze'] },
  { species: 'Annihilape', ability: 'Defiant', moves: ['Rage Fist', 'Drain Punch', 'Bulk Up', 'Taunt'] },
];

// Deterministic "AI": always the first legal option, so replays match.
function firstChoice(req) {
  if (req.forceSwitch) {
    const i = req.side.pokemon.findIndex(p => !p.active && !p.condition.endsWith(' fnt'));
    return `switch ${i + 1}`;
  }
  if (req.active) {
    const moves = req.active[0].moves;
    const m = moves.findIndex(x => !x.disabled && (x.pp === undefined || x.pp > 0));
    return m >= 0 ? `move ${m + 1}` : 'move 1';
  }
  return 'default';
}

function play(seed) {
  const engine = freshEngine();
  let r = JSON.parse(engine.start(JSON.stringify({
    seed, p1: { name: 'You', team: teamA }, p2: { name: 'Friend', team: teamB },
  })));
  const id = r.id;
  const log = [...r.events];
  let requests = r.requests;
  for (let turn = 0; turn < 500 && r.winner === null; turn++) {
    for (const side of ['p1', 'p2']) {
      const req = requests[side];
      if (!req || req.wait) continue;
      r = JSON.parse(engine.choose(id, side, firstChoice(req)));
      if (r.error) throw new Error(r.error);
      log.push(...r.events);
      requests = r.requests;
      if (r.winner !== null) break;
    }
  }
  engine.end(id);
  return { log, winner: r.winner };
}

const a = play([1, 2, 3, 4]);
const b = play([1, 2, 3, 4]);
const c = play([9, 9, 9, 9]);
const turns = a.log.filter(l => l.startsWith('|turn|')).length;

if (a.winner === null) throw new Error('battle did not finish');
const diff = a.log.findIndex((line, i) => line !== b.log[i]);
if (diff >= 0 || a.log.length !== b.log.length) {
  throw new Error(`same seed diverged at line ${diff}: ${a.log[diff]} vs ${b.log[diff]}`);
}
console.log(`ok  finished in ${turns} turns, winner: ${a.winner || '(tie)'}`);
console.log(`ok  same seed -> identical ${a.log.length}-line log`);
console.log(`ok  different seed -> ${a.log.join() === c.log.join() ? 'SAME (suspicious)' : 'different'} log`);
const engine = freshEngine();
console.log('ok  species lookup:', engine.species('Pawmot'));

const bad = JSON.parse(engine.choose(JSON.parse(engine.start(JSON.stringify({
  seed: [1, 1, 1, 1], p1: { name: 'You', team: teamA }, p2: { name: 'Friend', team: teamB },
}))).id, 'p1', 'move 9'));
if (!bad.error) throw new Error('illegal choice was not reported');
console.log('ok  illegal choice reported:', bad.error.slice(0, 60));

const eff = (m, s) => JSON.parse(engine.effectiveness(m, s));
if (eff('Thunderbolt', 'Gyarados') !== 4) throw new Error('Thunderbolt vs Gyarados should be 4x');
if (eff('Earthquake', 'Dragonite') !== 0) throw new Error('Earthquake vs Dragonite should be 0x');
if (eff('Flamethrower', 'Quaxly') !== 0.5) throw new Error('Flamethrower vs Quaxly should be 0.5x');
if (eff('Swords Dance', 'Pikachu') !== null) throw new Error('status moves have no effectiveness');
const info = JSON.parse(engine.moveInfo('Thunderbolt'));
if (info.type !== 'Electric' || info.category !== 'Special' || info.basePower !== 90) throw new Error('moveInfo wrong');
console.log('ok  type effectiveness + move info');
