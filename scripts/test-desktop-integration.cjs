const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Resources/overlays/desktop-integration.js', 'utf8');
const messages = [], handlers = {};
let active = 'zh', sync, originalCalls = 0, definition;
const context = {
  locale: {
    getSnapshot: () => ({active}),
    subscribe: fn => { sync = fn; return () => {}; },
    setLocale: value => { active = value; if (sync) sync(); }
  },
  effect: fn => fn(),
  inject: (deps, callback) => callback(context),
  remote: {$on: (name, callback) => { handlers[name] = callback; }},
  sessions: {scopeOf: () => 'session-1'}
};
const window = {webkit: {messageHandlers: {dshDesktop: {postMessage: x => messages.push(x)}}}};
vm.runInNewContext(source, {window, location: {hostname: '127.0.0.1'}});
assert.equal(window.__desktopSetLanguage('en'), true, 'language changes queue before DSH initializes');
window.__ModuleLoader__ = {load: () => { throw new Error('queue loader should be replaced'); }};
window.__ModuleLoader__.load = d => { definition = d; };
window.__ModuleLoader__.load({id: '@deepseek-ai/dsh-api-session-controller', factory: () => ({apply: () => ++originalCalls})});
definition.factory().apply(context);
assert.equal(originalCalls, 1);
assert.equal(messages.shift().value, 'en');
assert.equal(window.__desktopSetLanguage('en'), true);
assert.equal(messages.shift().value, 'en');
handlers['api-session/status']('session-1', false);
assert.equal(messages.length, 0, 'baseline must not trigger a completion');
handlers['api-session/status']('session-1', true);
handlers['api-session/status']('session-1', false);
handlers['api-session/status']('session-1', false);
assert.equal(messages.length, 1, 'one notification per transition');
assert.equal(messages.shift().kind, 'completion');
for (const [event, kind] of [['approval/request', 'permission'], ['user-questions/request', 'question']]) {
  let forwarded = false;
  const result = handlers[event]({}, () => { forwarded = true; return 42; });
  assert.equal(result, 42);
  assert.equal(forwarded, true, 'must not consume a user decision');
  assert.equal(messages.shift().kind, kind);
}
console.log('PASS: language sync, completion transitions, and approval/question forwarding');
