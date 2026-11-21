import { test } from 'node:test';
import assert from 'node:assert/strict';

import { firstFrame } from '../src/stack.ts';

test('Hermes release frames', () => {
  assert.deepEqual(firstFrame('Error: boom\n    at handlePress (address at index.android.bundle:1:52331)\n    at x (native)'),
    { filename: 'index.android.bundle', line: 1, column: 52331 });
});

test('Metro dev frames drop the query', () => {
  assert.deepEqual(firstFrame('TypeError: x\n    at onPress (http://localhost:8081/index.bundle?platform=ios&dev=true:120:14)'),
    { filename: 'http://localhost:8081/index.bundle', line: 120, column: 14 });
});

test('iOS dev bundle URLs drop their parameters', () => {
  assert.deepEqual(firstFrame('TypeError: x\n    at anonymous (http://localhost:8090/index.bundle//&platform=ios&dev=true&lazy=true:86223:20)'),
    { filename: 'http://localhost:8090/index.bundle', line: 86223, column: 20 });
});

test('JSC frames', () => {
  assert.deepEqual(firstFrame('onPress@http://localhost:8081/index.bundle:7:3\nglobal code'),
    { filename: 'http://localhost:8081/index.bundle', line: 7, column: 3 });
});

test('no frame', () => {
  assert.equal(firstFrame('Error: nothing here'), null);
  assert.equal(firstFrame(undefined), null);
});
