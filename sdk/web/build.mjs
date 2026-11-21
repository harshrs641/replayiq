// Builds the npm entry points (ESM + CJS, rrweb imported lazily so the
// app's bundler splits it out) and the script-tag/CDN build (IIFE that
// sets window.ReplayIQ and loads dist/rrweb.min.js from next to itself).
// The script-tag build is also copied to ../replayiq.js, which the ReplayIQ
// server serves at /sdk/replayiq.js for self-hosted installs.
import { build } from 'esbuild';
import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url)));
const define = (umd) => ({ __SDK_VERSION__: JSON.stringify(pkg.version), __UMD__: String(umd) });
const banner = { js: `/*! @replayiq/web ${pkg.version} | Apache-2.0 */` };
mkdirSync('dist', { recursive: true });

await build({ entryPoints: ['src/index.js'], outfile: 'dist/index.mjs', format: 'esm', bundle: true,
  external: ['rrweb'], define: define(false), target: 'es2019', banner });
await build({ entryPoints: ['src/index.js'], outfile: 'dist/index.cjs', format: 'cjs', bundle: true,
  external: ['rrweb'], define: define(false), target: 'es2019', banner, footer: { js: 'module.exports = module.exports.default;' } });
for (const minify of [false, true]) {
  await build({ entryPoints: ['src/index.js'], outfile: minify ? 'dist/replayiq.min.js' : 'dist/replayiq.js',
    format: 'iife', globalName: '__riq', bundle: true, minify, external: ['rrweb'], define: define(true), target: 'es2019', banner,
    footer: { js: 'window.ReplayIQ = __riq.default;' } });
}

const rrweb = createRequire(import.meta.url).resolve('rrweb/dist/rrweb.min.js');
copyFileSync(rrweb, 'dist/rrweb.min.js');
copyFileSync('dist/replayiq.js', '../replayiq.js');
copyFileSync('dist/rrweb.min.js', '../rrweb.min.js');
console.log(`built @replayiq/web ${pkg.version}`);
