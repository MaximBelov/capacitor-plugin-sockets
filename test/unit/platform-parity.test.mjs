// Every method of the TypeScript API has its native method on both platforms and its section in the README, and neither
// platform has a method the API does not declare. A miss on either side compiles fine and fails only on a phone. Plain
// Node, no install. addListener and removeAllListeners come from Capacitor's base classes and are left out.
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');
const inherited = new Set(['addListener', 'removeAllListeners']);

const api = [...read('src/definitions.ts').matchAll(/^\s+(\w+)\([^)]*\):\s*Promise</gm)]
  .map((m) => m[1])
  .filter((name) => !inherited.has(name))
  .sort();
const swift = read('ios/Sources/SocketsPlugin/SocketsPlugin.swift');
const kotlin = read('android/src/main/kotlin/io/github/maximbelov/sockets/SocketsPlugin.kt');
const ios = [...swift.matchAll(/CAPPluginMethod\(name:\s*"(\w+)"/g)].map((m) => m[1]).sort();
const iosFunctions = [...swift.matchAll(/@objc func (\w+)\(_ call: CAPPluginCall\)/g)].map((m) => m[1]).sort();
const android = [...kotlin.matchAll(/@PluginMethod\s+fun (\w+)\(/g)].map((m) => m[1]).sort();

test('the API declares its methods', () => {
  assert.deepEqual(api, [
    'bind',
    'close',
    'closeAll',
    'connect',
    'create',
    'disconnect',
    'getInfo',
    'getSockets',
    'send',
    'setBroadcast',
  ]);
});

test('iOS registers exactly the methods of the API', () => {
  assert.deepEqual(ios, api);
});

test('iOS has an @objc function for every registered method', () => {
  assert.deepEqual(iosFunctions, api);
});

test('Android annotates exactly the methods of the API', () => {
  assert.deepEqual(android, api);
});

test('the plugin has the same name in JavaScript, Swift and Kotlin', () => {
  assert.match(read('src/index.ts'), /registerPlugin<SocketsPlugin>\('Sockets'/);
  assert.match(swift, /jsName = "Sockets"/);
  assert.match(kotlin, /@CapacitorPlugin\(name = "Sockets"\)/);
});

test('both platforms emit the events the API declares, with the same fields', () => {
  for (const event of ['receive', 'receiveError']) {
    assert.match(read('src/definitions.ts'), new RegExp(`eventName: '${event}'`));
    assert.match(swift, new RegExp(`notifyListeners\\("${event}"`));
    assert.match(kotlin, new RegExp(`"${event}"`));
  }
  for (const field of ['socketId', 'protocol', 'data', 'remoteAddress', 'remotePort', 'code', 'message']) {
    assert.match(swift, new RegExp(`"${field}":`), `iOS sends no ${field}`);
    assert.match(kotlin, new RegExp(`"${field}"`), `Android sends no ${field}`);
  }
});

test('both platforms reject with the same error codes, and only codes the API declares', () => {
  const declared = [...read('src/definitions.ts').matchAll(/\|\s*'([A-Z_]+)'/g)].map((m) => m[1]).sort();
  const swiftCore = read('ios/Sources/SocketsCore/SocketRegistry.swift');
  const kotlinCore = read('android/src/main/kotlin/io/github/maximbelov/sockets/SocketRegistry.kt');
  const iosCodes = [...swiftCore.matchAll(/static let \w+ = "([A-Z_]+)"/g)].map((m) => m[1]).sort();
  const androidCodes = [...kotlinCore.matchAll(/const val \w+ = "([A-Z_]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual(iosCodes, declared);
  assert.deepEqual(androidCodes, declared);
});

test('the README documents every method', () => {
  const readme = read('README.md');
  for (const method of api) {
    assert.match(readme, new RegExp(`### ${method}\\(`), `README.md has no section for ${method}()`);
  }
});
