// node --test linux/gnome-extension/test
import test from 'node:test';
import assert from 'node:assert/strict';
import * as Core from '../gnotch@christianqp4.github.io/core.js';

const T0 = Date.parse('2026-10-03T09:12:00.456Z');
const min = m => m * 60_000;

test('dates are written without milliseconds (Swift .iso8601)', () => {
    assert.equal(Core.isoDate(T0), '2026-10-03T09:12:00Z');
});

test('clock and hm match the Mac formats', () => {
    assert.equal(Core.clock(312), '05:12');
    assert.equal(Core.clock(3912), '1:05:12');
    assert.equal(Core.hm(45 * 60), '45m');
    assert.equal(Core.hm(120 * 60), '2h');
    assert.equal(Core.hm(130 * 60), '2h 10m');
});

test('a block with a drift and a sleep pause', () => {
    const t = new Core.Timer();
    t.start(T0, 50, 'Thesis');
    t.pause(T0 + min(10));             // drift
    assert.equal(t.drifts(), 1);
    t.resume(T0 + min(12));
    t.pause(T0 + min(20), true);       // sleep: not a drift
    t.resume(T0 + min(30));
    assert.equal(t.elapsed(T0 + min(40)), 28 * 60);
    assert.equal(t.display(T0 + min(40)), '22:00');
    assert.equal(t.checkGoal(T0 + min(40)), false);
    assert.equal(t.checkGoal(T0 + min(73)), true);
    assert.equal(t.checkGoal(T0 + min(74)), false);
    assert.equal(t.display(T0 + min(74)), '+12:00');
    t.finish(T0 + min(74));
    const s = t.buildSession({id: 'X', intensity: 9, tags: ['Flow'], notes: ' ok ', location: 'Library'});
    assert.equal(s.duration, 62 * 60);
    assert.equal(s.intensity, 5);
    assert.equal(s.notes, 'ok');
    assert.equal(s.plannedMinutes, 50);
    assert.deepEqual(s.pauses, [
        {start: '2026-10-03T09:22:00Z', end: '2026-10-03T09:24:00Z'},
        {start: '2026-10-03T09:32:00Z', end: '2026-10-03T09:42:00Z', auto: true},
    ]);
    const kinds = t.segments(T0 + min(74)).map(x => x[1]);
    assert.deepEqual(kinds, ['focus', 'drift', 'focus', 'sleep', 'focus']);
});

test('open-ended blocks count up and omit plannedMinutes', () => {
    const t = new Core.Timer();
    t.start(T0, null);
    assert.equal(t.display(T0 + min(3)), '03:00');
    t.finish(T0 + min(3));
    assert.equal('plannedMinutes' in t.buildSession({id: 'X', intensity: 3}), false);
});

test('snapshot survives a restart', () => {
    const t = new Core.Timer();
    t.start(T0, 25, 'A');
    t.pause(T0 + min(5));
    const r = new Core.Timer(JSON.parse(JSON.stringify(t.snapshot())));
    assert.equal(r.phase, 'paused');
    assert.equal(r.drifts(), 1);
    r.resume(T0 + min(6));
    assert.equal(r.elapsed(T0 + min(10)), 9 * 60);
});

test('sessions.json round trip keeps unknown fields and sorts newest first', () => {
    const text = JSON.stringify({version: 1, sessions: [{id: 'a', start: '2026-10-01T09:00:00Z', duration: 60, intensity: 3, futureField: 1}]});
    const list = Core.parseSessions(text);
    list.push({id: 'b', start: '2026-10-02T09:00:00Z', duration: 60, intensity: 3});
    const out = JSON.parse(Core.serializeSessions(list));
    assert.equal(out.version, 1);
    assert.deepEqual(out.sessions.map(s => s.id), ['b', 'a']);
    assert.equal(out.sessions[1].futureField, 1);
    assert.throws(() => Core.parseSessions('{"nope": true}'));
    assert.deepEqual(Core.parseSessions(''), []);
});

test('streak, totals and heatmap', () => {
    const now = new Date(2026, 9, 12, 15).getTime();
    const day = (d, mins, i = 5) => ({start: Core.isoDate(new Date(2026, 9, d, 9).getTime()), duration: mins * 60, intensity: i});
    const s = [day(12, 60), day(11, 30), day(10, 200), day(8, 10)];
    assert.equal(Core.streak(s, now), 3);
    assert.equal(Core.totalSince(s, Core.startOfDay(now)), 3600);
    assert.equal(new Date(Core.startOfWeek(now)).getDay(), 1);
    const grid = Core.heatGrid(s, now, 24);
    assert.equal(grid.length, 24);
    const last = grid[23]; // Mon 12 Oct 2026 is a Monday
    assert.equal(last[0], 2);  // 60 × 5/5 = 60 → level 2
    assert.equal(last[1], -1); // tomorrow
    assert.equal(grid[22][6], 2); // Sun 11: 30 → level 2
    assert.equal(grid[22][5], 4); // Sat 10: 200 → level 4
});

test('custom places are remembered, most recent first, built-ins skipped', () => {
    let c = Core.rememberPlace([], 'Park');
    c = Core.rememberPlace(c, 'library');
    c = Core.rememberPlace(c, 'Train');
    c = Core.rememberPlace(c, 'park');
    assert.deepEqual(c, ['park', 'Train']);
});

// GNOME 42–44 build (Ubuntu 22.04): old-style modules, where top-level vars and functions are the exports.
import vm from 'node:vm';
import fs from 'node:fs';
import {build} from '../build.mjs';

test('GNOME 42 build: core loads as an old-style module and behaves the same', () => {
    const {legacy} = build();
    const ctx = vm.createContext({});
    vm.runInContext(fs.readFileSync(`${legacy}/core.js`, 'utf8'), ctx);
    for (const name of Object.keys(Core))
        assert.ok(name in ctx, `missing export ${name}`);
    const t = new ctx.Timer();
    t.start(T0, 25, 'x');
    assert.equal(t.display(T0 + min(5)), '20:00');
    assert.equal(ctx.isoDate(T0), '2026-10-03T09:12:00Z');
});

test('GNOME 42 build: extension.js has no ES module syntax and exports init()', () => {
    const {legacy} = build();
    const src = fs.readFileSync(`${legacy}/extension.js`, 'utf8');
    new vm.Script(src); // parses as a classic script, so GNOME 42 can load it
    assert.match(src, /^function init\(\)/m);
    assert.deepEqual(JSON.parse(fs.readFileSync(`${legacy}/metadata.json`, 'utf8'))['shell-version'], ['42', '43', '44']);
});
