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

test('GNOME 42 build: every module parses as a classic script; extension.js exports init()', () => {
    const {legacy} = build();
    for (const f of fs.readdirSync(legacy).filter(n => n.endsWith('.js')))
        new vm.Script(fs.readFileSync(`${legacy}/${f}`, 'utf8'), {filename: f});
    const src = fs.readFileSync(`${legacy}/extension.js`, 'utf8');
    assert.match(src, /^function init\(\)/m);
    assert.match(src, /^const Store = Me\.imports\.store;/m);
    assert.match(fs.readFileSync(`${legacy}/ui.js`, 'utf8'), /^const Cairo = imports\.cairo;/m);
    assert.deepEqual(JSON.parse(fs.readFileSync(`${legacy}/metadata.json`, 'utf8'))['shell-version'], ['42', '43', '44']);
});

test('progress outline: a U whose trimmed length follows the fraction', () => {
    const u = Core.uOutline(100, 30, 2);
    const total = u.reduce((t, p) => t + p.len, 0);
    assert.ok(Math.abs(total - (2 * Math.PI * 13 + (100 - 4 - 26))) < 1e-9);
    const half = Core.trimOutline(u, 0.5);
    assert.ok(Math.abs(half.reduce((t, p) => t + p.len, 0) - total / 2) < 1e-9);
    assert.equal(Core.trimOutline(u, 0).length, 0);
    // The first piece starts at the top of the left end, like the notch line starts at its top-left.
    assert.equal(u[0].a0, -Math.PI / 2);
    const t = new Core.Timer();
    t.start(T0, 50);
    assert.equal(Core.outlineProgress(t, T0 + min(25)), 0.5);
    assert.equal(Core.outlineProgress(t, T0 + min(80)), 1);
    const o = new Core.Timer();
    o.start(T0, null);
    assert.equal(Core.outlineProgress(o, T0 + min(90)), 0.5);
});

test('breathing: 4 s in, 6 s out, always moving', () => {
    assert.deepEqual(Core.breath(0), {inhale: true, scale: 0.55, secondsLeft: 4});
    assert.equal(Core.breath(4000).inhale, false);
    assert.ok(Math.abs(Core.breath(4000).scale - 1) < 1e-9);
    assert.ok(Core.breath(2000).scale > 0.7 && Core.breath(2000).scale < 0.85);
    assert.ok(Core.breath(7000).scale < Core.breath(5000).scale);
    assert.equal(Core.breath(10_000).inhale, true);
});

test('vision board: defaults, packing without overlap, move and tidy', () => {
    assert.deepEqual(Core.visionDefaultSize({kind: 'image', aspect: 1.8}), [3, 2]);
    assert.deepEqual(Core.visionDefaultSize({kind: 'image', aspect: 0.5}), [2, 3]);
    assert.deepEqual(Core.visionDefaultSize({kind: 'text', text: 'Ship it'}), [2, 1]);
    const items = [
        {id: 'a', cols: 3, rows: 2}, {id: 'b', cols: 2, rows: 3}, {id: 'c', cols: 2, rows: 1},
        {id: 'd', cols: 6, rows: 1}, {id: 'e', cols: 1, rows: 1},
    ];
    const {slots, rows} = Core.packGrid(items);
    assert.deepEqual(slots.get('a'), {col: 0, row: 0, cols: 3, rows: 2});
    assert.deepEqual(slots.get('b'), {col: 3, row: 0, cols: 2, rows: 3});
    assert.deepEqual(slots.get('c'), {col: 0, row: 2, cols: 2, rows: 1});
    assert.deepEqual(slots.get('e'), {col: 5, row: 0, cols: 1, rows: 1});
    assert.deepEqual(slots.get('d'), {col: 0, row: 3, cols: 6, rows: 1});
    assert.equal(rows, 4);
    const cells = new Set();
    for (const s of slots.values()) {
        for (let r = s.row; r < s.row + s.rows; r++) {
            for (let c = s.col; c < s.col + s.cols; c++) {
                assert.ok(!cells.has(`${r},${c}`), 'overlap');
                cells.add(`${r},${c}`);
            }
        }
    }
    const ordered = items.map((it, i) => ({...it, order: i}));
    assert.deepEqual(Core.visionMove(ordered, 'c', -1).map(i => i.id), ['a', 'c', 'b', 'd', 'e']);
    assert.deepEqual(Core.visionMove(ordered, 'a', -1).map(i => i.id), ['a', 'b', 'c', 'd', 'e']);
    assert.deepEqual(Core.nextVisionSize({cols: 2, rows: 2}), [3, 2]);
    assert.deepEqual(Core.nextVisionSize({cols: 6, rows: 3}), [1, 1]);
    const tidy = Core.visionTidy([
        {id: 'old', kind: 'text', text: 'x', date: '2026-01-01T00:00:00Z', cols: 6, rows: 4},
        {id: 'new', kind: 'image', aspect: 1, date: '2026-02-01T00:00:00Z', cols: 1, rows: 1},
    ]);
    assert.deepEqual(tidy.map(i => [i.id, i.order, i.cols, i.rows]), [['new', 0, 2, 2], ['old', 1, 2, 1]]);
});

test('clipboard: dedupe to top, pins survive limits, filters and search', () => {
    let items = [];
    const add = (id, extra = {}) => {
        const r = Core.clipAdd(items, {id, kind: 'text', text: id, signature: id, pinned: false, date: Core.isoDate(T0 + items.length * 1000), ...extra}, 3, 1);
        items = r.items;
        return r.dropped.map(d => d.id);
    };
    add('a', {pinned: true});
    add('b');
    add('c');
    add('img1', {kind: 'image'});
    assert.deepEqual(add('img2', {kind: 'image'}), ['img1']); // one image max
    assert.deepEqual(add('d'), ['b']); // three unpinned max; the pin stays
    assert.deepEqual(items.map(i => i.id), ['d', 'img2', 'c', 'a']);
    add('c');
    assert.equal(items[0].id, 'c');
    assert.equal(items.length, 4);
    assert.equal(Core.clipVisible(items)[0].id, 'a'); // pinned first
    assert.deepEqual(Core.clipVisible(items, 'Images').map(i => i.id), ['img2']);
    assert.deepEqual(Core.clipVisible(items, 'All', 'D').map(i => i.id), ['d']);
    assert.equal(Core.clipPreview({kind: 'text', text: 'a\n  b'}), 'a ⏎ b');
    assert.equal(Core.clipPreview({kind: 'file', paths: ['/x/a.txt']}), 'a.txt');
    assert.deepEqual(Core.parseCopiedFiles('copy\nfile:///home/me/My%20File.txt\nfile:///tmp/b'), ['/home/me/My File.txt', '/tmp/b']);
    assert.equal(Core.parseCopiedFiles('hello'), null);
});

test('clipboard: password managers are never recorded', () => {
    assert.ok(Core.isSecret(['text/plain', 'x-kde-passwordManagerHint'], 'gedit'));
    assert.ok(Core.isSecret(['text/plain'], 'KeePassXC'));
    assert.ok(Core.isSecret(['text/plain'], 'Bitwarden'));
    assert.ok(Core.isSecret(['text/plain'], 'org.gnome.World.Secrets'));
    assert.ok(!Core.isSecret(['text/plain'], 'firefox'));
    assert.ok(!Core.isSecret(['text/plain'], ''));
});

test('drifts per hour and today\'s blocks', () => {
    const now = new Date(2026, 9, 12, 15).getTime();
    const at = h => Core.isoDate(new Date(2026, 9, 12, h).getTime());
    const s = [
        {start: at(9), duration: 3600, pauses: [{start: at(9), end: at(9)}, {start: at(9), end: at(9), auto: true}]},
        {start: at(11), duration: 3600, pauses: [{start: at(11), end: at(11)}]},
        {start: Core.isoDate(new Date(2026, 9, 11, 9).getTime()), duration: 3600},
    ];
    assert.equal(Core.driftsPerHour(s, now), 1);
    assert.deepEqual(Core.todaysBlocks(s, now).map(b => b.start), [at(9), at(11)]);
});

test('ISO weeks match the Mac (week 42 of 53 on 13 Oct 2026)', () => {
    const d = (y, m, day) => new Date(y, m - 1, day, 12).getTime();
    assert.equal(Core.isoWeek(d(2026, 10, 13)), 42);
    assert.equal(Core.isoWeeksInYear(d(2026, 10, 13)), 53);
    assert.equal(Core.isoWeeksInYear(d(2025, 6, 1)), 52);
    assert.equal(Core.isoWeek(d(2026, 1, 1)), 1);
    assert.equal(Core.isoWeek(d(2025, 12, 29)), 1);
    assert.equal(Core.isoWeek(d(2027, 1, 3)), 53);
    assert.equal(Core.weekLabel(d(2026, 10, 13)), 'Week 42/53');
});

test('year view: month names and landmark week numbers (1, 10, 20 … this week), no stale W42', () => {
    const now = new Date(2026, 9, 13, 15).getTime();
    const y = Core.heatYear([], now, 53);
    assert.equal(y.columns.length, 53);
    assert.deepEqual(y.weekLabels.map(l => l.text), ['50', '1', '10', '20', '30', '40', 'W42']);
    assert.equal(y.columns[0].week, 42); // a year ago: same number, but not labelled
    assert.deepEqual(y.monthLabels.map(l => l.text), ['Nov', 'Dec', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct']);
    assert.equal(y.columns[52].days[1].today, true); // Tuesday
    assert.equal(y.columns[52].days[2].level, -1); // tomorrow
});

test('calendar view: months left to right with every week number', () => {
    const now = new Date(2026, 9, 13, 15).getTime();
    const s = [{start: Core.isoDate(new Date(2026, 9, 12, 9).getTime()), duration: 3600, intensity: 5}];
    const m = Core.heatMonths(s, now, 12);
    assert.equal(m.length, 12);
    assert.equal(m[0].title, 'Nov 2025');
    assert.equal(m[2].title, 'Jan 2026');
    const oct = m[11];
    assert.equal(oct.current, true);
    assert.deepEqual(oct.weeks.map(w => w.week), [40, 41, 42, 43, 44]);
    assert.equal(oct.weeks[2].current, true);
    assert.equal(oct.weeks[0].days[2], null); // 30 Sep is not October
    assert.equal(oct.weeks[0].days[3].ms, new Date(2026, 9, 1).getTime()); // Thu 1 Oct
    assert.equal(oct.weeks[2].days[0].level, 2); // Mon 12 Oct: 60 min at Flow
    assert.equal(oct.weeks[2].days[2].level, -1); // ahead, kept for planning
});

test('hovering a day: date, week, total and each block with its time and intensity', () => {
    const at = (h, m) => new Date(2026, 9, 11, h, m).getTime();
    const s = [
        {start: Core.isoDate(at(10, 39)), end: Core.isoDate(at(11, 54)), duration: 75 * 60, intensity: 5, task: 'Thesis'},
        {start: Core.isoDate(at(8, 39)), end: Core.isoDate(at(10, 9)), duration: 90 * 60, intensity: 4, task: ''},
    ];
    const b = Core.dayBrief(s, at(15, 0), at(20, 0));
    assert.equal(b.title, 'Sun 11 Oct · W41');
    assert.equal(b.summary, '2h 45m · 2 blocks · Deep');
    assert.deepEqual(b.blocks.map(x => [x.time, x.intensity, x.task]), [['08:39–10:09', 'Deep', 'Deep work'], ['10:39–11:54', 'Flow', 'Thesis']]);
    assert.equal(Core.dayBrief([], at(12, 0), at(9, 0) - 86400000 * 2).summary, 'Ahead: nothing logged yet');
});
