const test = require('node:test');
const assert = require('node:assert');
const { add } = require('../add.js');

test('adds two positive numbers', () => {
  assert.strictEqual(add(2, 3), 5);
});

test('rejects negative numbers', () => {
  assert.throws(() => add(-1, 2));
});
