// Bundles src/engine.js + @pkmn/sim into one script for JavaScriptCore.
//   npm run build   -> ../App/Resources/battle-engine.js
import { build } from 'esbuild';

await build({
  entryPoints: ['src/engine.js'],
  bundle: true,
  format: 'iife',
  platform: 'neutral',
  mainFields: ['module', 'main'],
  target: 'es2020',
  minify: true,
  legalComments: 'eof', // keeps the MIT notices from Showdown/@pkmn in the bundle
  outfile: '../App/Resources/battle-engine.js',
  logLevel: 'info',
});
