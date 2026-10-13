// GNotch core: timer state machine, sessions.json format and stats.
// No GNOME imports here, so it runs (and is tested) under plain Node too.

export const INTENSITY_LABELS = ['Shallow', 'Light', 'Focused', 'Deep', 'Flow'];
export const INTENSITY_COLORS = ['#f2cc4d', '#faad3d', '#ff8c33', '#ff6b2e', '#fa4733'];
export const TAGS = ['Flow', 'Energized', 'Calm', 'Clear-headed', 'Distracted', 'Tired', 'Restless', 'Breakthrough'];
export const PLACES = ['Library', 'House', 'Coworking', 'Coffee'];
export const LENGTHS = [25, 50, 90, 120, null]; // null = open-ended
export const HEAT = ['rgba(255,255,255,0.08)', 'rgba(41,194,110,0.30)', 'rgba(41,194,110,0.52)', 'rgba(41,194,110,0.76)', 'rgb(41,194,110)'];
export const GREEN = '#29c26e';
export const ORANGE = '#f5a524';

export const clampIntensity = v => Math.max(1, Math.min(5, Math.round(v) || 1));

/// The Mac app decodes dates with Swift's .iso8601, which rejects milliseconds. Always write "…T09:12:00Z".
export function isoDate(ms) {
    return new Date(Math.floor(ms / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export const parseDate = s => Date.parse(s);

// MARK: Formatting

/// 05:12 or 1:05:12
export function clock(seconds) {
    const s = Math.max(0, Math.floor(seconds));
    const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60;
    const p = n => String(n).padStart(2, '0');
    return h > 0 ? `${h}:${p(m)}:${p(sec)}` : `${p(m)}:${p(sec)}`;
}

/// 45m, 2h, 2h 10m
export function hm(seconds) {
    const m = Math.round(seconds / 60);
    if (m < 60)
        return `${m}m`;
    return m % 60 === 0 ? `${m / 60}h` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

// MARK: Timer

/// idle → running ⇄ paused → finishing → idle. Times are epoch milliseconds.
/// A manual pause is a drift; an `auto` pause (the computer going to sleep) isn't.
export class Timer {
    constructor(snapshot = null) {
        this.plannedMinutes = 50;
        this._reset();
        if (snapshot)
            this.restore(snapshot);
    }

    _reset() {
        this.phase = 'idle';
        this.task = '';
        this.startMs = null;
        this.endMs = null;
        this.accumulated = 0; // active seconds before the current segment
        this.segmentStart = null;
        this.goalNotified = false;
        this.pauses = []; // [{start, end, auto}] in ms
        this.pauseStart = null;
        this.pauseIsAuto = false;
    }

    get isActive() { return this.phase === 'running' || this.phase === 'paused'; }

    elapsed(now) {
        return this.accumulated + (this.segmentStart !== null ? Math.max(0, now - this.segmentStart) / 1000 : 0);
    }

    get goal() { return this.plannedMinutes ? this.plannedMinutes * 60 : null; }

    progress(now) {
        const g = this.goal;
        return g ? Math.min(1, this.elapsed(now) / g) : 0;
    }

    isOvertime(now) {
        const g = this.goal;
        return g !== null && this.elapsed(now) >= g;
    }

    /// Countdown under the goal, "+overtime" after it, count-up when open-ended.
    display(now) {
        const g = this.goal;
        const e = this.elapsed(now);
        if (g === null)
            return clock(e);
        const remaining = g - e;
        return remaining > 0 ? clock(Math.ceil(remaining)) : `+${clock(-remaining)}`;
    }

    drifts() {
        return this.pauses.filter(p => !p.auto).length + (this.pauseStart !== null && !this.pauseIsAuto ? 1 : 0);
    }

    start(now, minutes = this.plannedMinutes, task = this.task) {
        if (this.phase !== 'idle')
            return false;
        const planned = minutes;
        this._reset();
        this.plannedMinutes = planned;
        this.task = task;
        this.startMs = now;
        this.segmentStart = now;
        this.phase = 'running';
        return true;
    }

    pause(now, auto = false) {
        if (this.phase !== 'running')
            return false;
        this.accumulated = this.elapsed(now);
        this.segmentStart = null;
        this.pauseStart = now;
        this.pauseIsAuto = auto;
        this.phase = 'paused';
        return true;
    }

    resume(now) {
        if (this.phase !== 'paused')
            return false;
        this._closePause(now);
        this.segmentStart = now;
        this.phase = 'running';
        return true;
    }

    toggle(now) {
        return this.phase === 'running' ? this.pause(now) : this.resume(now);
    }

    finish(now) {
        if (!this.isActive)
            return false;
        this.accumulated = this.elapsed(now);
        this.segmentStart = null;
        this._closePause(now);
        this.endMs = now;
        this.phase = 'finishing';
        return true;
    }

    discard() {
        const planned = this.plannedMinutes;
        this._reset();
        this.plannedMinutes = planned;
    }

    /// Returns true once, the first tick after the goal is passed.
    checkGoal(now) {
        if (this.goalNotified || this.phase !== 'running' || !this.isOvertime(now))
            return false;
        this.goalNotified = true;
        return true;
    }

    _closePause(now) {
        if (this.pauseStart === null)
            return;
        const p = {start: this.pauseStart, end: now};
        if (this.pauseIsAuto)
            p.auto = true;
        this.pauses.push(p);
        this.pauseStart = null;
        this.pauseIsAuto = false;
    }

    /// The finished block in the sessions.json format shared with the Mac app.
    buildSession({id, task, intensity, tags, notes, location}) {
        if (this.phase !== 'finishing' || this.startMs === null)
            return null;
        const s = {
            id,
            start: isoDate(this.startMs),
            end: isoDate(this.endMs ?? Date.now()),
            duration: Math.round(this.accumulated * 1000) / 1000,
            task: (task ?? this.task).trim(),
            intensity: clampIntensity(intensity),
            tags: tags ?? [],
            notes: (notes ?? '').trim(),
            pauses: this.pauses.map(p => (p.auto
                ? {start: isoDate(p.start), end: isoDate(p.end), auto: true}
                : {start: isoDate(p.start), end: isoDate(p.end)})),
        };
        if (this.plannedMinutes)
            s.plannedMinutes = this.plannedMinutes;
        const place = (location ?? '').trim();
        if (place)
            s.location = place;
        return s;
    }

    /// The block so far as [fraction, 'focus' | 'drift'] runs, for the drift bar.
    segments(now) {
        if (this.startMs === null)
            return [];
        const end = this.endMs ?? now;
        const total = Math.max(1, end - this.startMs);
        const spans = [...this.pauses];
        if (this.pauseStart !== null)
            spans.push({start: this.pauseStart, end, auto: this.pauseIsAuto});
        const out = [];
        let t = this.startMs;
        for (const p of spans.sort((a, b) => a.start - b.start)) {
            if (p.start > t)
                out.push([(p.start - t) / total, 'focus']);
            out.push([(p.end - p.start) / total, p.auto ? 'sleep' : 'drift']);
            t = p.end;
        }
        if (end > t)
            out.push([(end - t) / total, 'focus']);
        return out;
    }

    snapshot() {
        return {
            phase: this.phase, task: this.task, plannedMinutes: this.plannedMinutes,
            startMs: this.startMs, endMs: this.endMs, accumulated: this.accumulated,
            segmentStart: this.segmentStart, goalNotified: this.goalNotified,
            pauses: this.pauses, pauseStart: this.pauseStart, pauseIsAuto: this.pauseIsAuto,
        };
    }

    restore(s) {
        this.plannedMinutes = s.plannedMinutes === undefined ? 50 : s.plannedMinutes;
        if (!['running', 'paused', 'finishing'].includes(s.phase))
            return;
        Object.assign(this, {
            phase: s.phase, task: s.task ?? '', startMs: s.startMs, endMs: s.endMs ?? null,
            accumulated: s.accumulated ?? 0, segmentStart: s.segmentStart ?? null,
            goalNotified: !!s.goalNotified, pauses: s.pauses ?? [],
            pauseStart: s.pauseStart ?? null, pauseIsAuto: !!s.pauseIsAuto,
        });
    }
}

// MARK: sessions.json

/// Parses sessions.json. Throws on anything that isn't the GNotch format, so the caller can back it up
/// instead of overwriting it. Sessions are kept as raw objects so fields from other clients survive.
export function parseSessions(text) {
    if (!text || !text.trim())
        return [];
    const file = JSON.parse(text);
    if (!file || !Array.isArray(file.sessions))
        throw new Error('sessions.json has no "sessions" array');
    return file.sessions;
}

function sortKeys(v) {
    if (Array.isArray(v))
        return v.map(sortKeys);
    if (v && typeof v === 'object')
        return Object.fromEntries(Object.keys(v).sort().map(k => [k, sortKeys(v[k])]));
    return v;
}

/// Same shape the Mac app writes: version 1, newest block first, sorted keys.
export function serializeSessions(sessions) {
    const sorted = [...sessions].sort((a, b) => parseDate(b.start) - parseDate(a.start));
    return `${JSON.stringify(sortKeys({sessions: sorted, version: 1}), null, 2)}\n`;
}

// MARK: Stats

export function dayKey(ms) {
    const d = new Date(ms);
    return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
}

export function startOfDay(ms) {
    const d = new Date(ms);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
}

const addDays = (ms, n) => {
    const d = new Date(ms);
    d.setDate(d.getDate() + n);
    return d.getTime();
};

/// Monday 00:00 of the week containing `ms`.
export function startOfWeek(ms) {
    const d = new Date(startOfDay(ms));
    return addDays(d.getTime(), -((d.getDay() + 6) % 7));
}

export function dayStats(sessions) {
    const out = new Map();
    for (const s of sessions) {
        const key = dayKey(parseDate(s.start));
        const d = out.get(key) ?? {minutes: 0, weighted: 0, count: 0};
        const minutes = (s.duration ?? 0) / 60;
        d.minutes += minutes;
        d.weighted += minutes * clampIntensity(s.intensity) / 5;
        d.count += 1;
        out.set(key, d);
    }
    return out;
}

/// Deep score bucket 0 (nothing) … 4, same thresholds as the Mac heatmap.
export function heatLevel(stat) {
    if (!stat || stat.count === 0)
        return 0;
    const w = stat.weighted;
    return w < 30 ? 1 : w < 90 ? 2 : w < 180 ? 3 : 4;
}

/// weeks × 7 levels, oldest week first, Monday first. Future days are -1.
export function heatGrid(sessions, now, weeks = 24) {
    const stats = dayStats(sessions);
    const first = addDays(startOfWeek(now), -7 * (weeks - 1));
    const today = startOfDay(now);
    const grid = [];
    for (let w = 0; w < weeks; w++) {
        const col = [];
        for (let d = 0; d < 7; d++) {
            const day = addDays(first, w * 7 + d);
            col.push(day > today ? -1 : heatLevel(stats.get(dayKey(day))));
        }
        grid.push(col);
    }
    return grid;
}

/// Consecutive days with deep work, ending today (or yesterday if today has nothing yet).
export function streak(sessions, now) {
    const days = new Set(sessions.map(s => dayKey(parseDate(s.start))));
    let day = startOfDay(now);
    if (!days.has(dayKey(day)))
        day = addDays(day, -1);
    let n = 0;
    while (days.has(dayKey(day))) {
        n++;
        day = addDays(day, -1);
    }
    return n;
}

export function totalSince(sessions, ms) {
    return sessions.filter(s => parseDate(s.start) >= ms).reduce((t, s) => t + (s.duration ?? 0), 0);
}

/// Places for the picker: built-ins, then the ones you've typed (most recent first).
export function rememberPlace(custom, place) {
    const p = (place ?? '').trim();
    if (!p || PLACES.some(b => b.toLowerCase() === p.toLowerCase()))
        return custom;
    return [p, ...custom.filter(c => c.toLowerCase() !== p.toLowerCase())].slice(0, 8);
}

// MARK: Progress outline

/// How much of the outline to draw: share of the goal, or of the current hour for open-ended blocks.
export function outlineProgress(timer, now) {
    const e = timer.elapsed(now);
    const g = timer.goal;
    return g ? Math.min(1, e / g) : (e % 3600) / 3600;
}

/// The indicator's outline as an open "U", like the notch: down the left end, along the bottom,
/// up the right end. Pieces are lines {x0,y0,x1,y1} or arcs {cx,cy,r,a0,a1} (radians, clockwise in
/// screen space), each with its length.
export function uOutline(w, h, inset = 2) {
    const r = Math.max(1, (h - 2 * inset) / 2);
    const top = inset, bottom = h - inset;
    const left = inset + r, right = w - inset - r;
    const straight = Math.max(0, right - left);
    return [
        {kind: 'arc', cx: left, cy: top + r, r, a0: -Math.PI / 2, a1: -3 * Math.PI / 2, len: Math.PI * r},
        {kind: 'line', x0: left, y0: bottom, x1: right, y1: bottom, len: straight},
        {kind: 'arc', cx: right, cy: top + r, r, a0: Math.PI / 2, a1: -Math.PI / 2, len: Math.PI * r},
    ];
}

/// The pieces of `outline` covering the first `fraction` of its length (the last one cut short).
export function trimOutline(outline, fraction) {
    const total = outline.reduce((t, p) => t + p.len, 0);
    let left = Math.max(0, Math.min(1, fraction)) * total;
    const out = [];
    for (const p of outline) {
        if (left <= 0)
            break;
        const f = p.len > 0 ? Math.min(1, left / p.len) : 1;
        out.push(p.kind === 'line'
            ? {...p, x1: p.x0 + (p.x1 - p.x0) * f, y1: p.y0 + (p.y1 - p.y0) * f, len: p.len * f}
            : {...p, a1: p.a0 + (p.a1 - p.a0) * f, len: p.len * f});
        left -= p.len;
    }
    return out;
}

// MARK: Breathing guide

/// 4 s in, 6 s out. Returns the circle scale (0.55–1) and the seconds left in this half.
export function breath(msSincePause) {
    const t = (Math.max(0, msSincePause) / 1000) % 10;
    const inhale = t < 4;
    const p = inhale ? t / 4 : (t - 4) / 6;
    const eased = (1 - Math.cos(Math.PI * p)) / 2;
    const scale = inhale ? 0.55 + 0.45 * eased : 1 - 0.45 * eased;
    return {inhale, scale, secondsLeft: Math.ceil(inhale ? 4 - t : 10 - t)};
}

// MARK: Vision board (same board.json as the Mac app)

export const VISION_COLUMNS = 6;
export const VISION_MAX_ROWS = 4;

export function visionDefaultSize(item) {
    if (item.kind === 'image') {
        const a = item.aspect ?? 1;
        return a >= 1.25 ? [3, 2] : a <= 0.8 ? [2, 3] : [2, 2];
    }
    const n = (item.text ?? '').length;
    return n <= 40 ? [2, 1] : n <= 90 ? [3, 1] : [3, 2];
}

export function visionOrdered(items) {
    return [...items].sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
}

/// Places widgets in order, each in the first free spot row by row, so nothing overlaps.
/// Returns {slots: Map(id → {col, row, cols, rows}), rows}.
export function packGrid(items, columns = VISION_COLUMNS) {
    const occupied = [];
    const slots = new Map();
    const fits = (c, r, w, h) => {
        for (let rr = r; rr < r + h; rr++) {
            occupied[rr] ??= new Array(columns).fill(false);
            for (let cc = c; cc < c + w; cc++) {
                if (occupied[rr][cc])
                    return false;
            }
        }
        return true;
    };
    for (const item of items) {
        const w = Math.max(1, Math.min(columns, item.cols ?? 2));
        const h = Math.max(1, item.rows ?? 2);
        for (let r = 0, placed = false; !placed; r++) {
            for (let c = 0; c <= columns - w && !placed; c++) {
                if (fits(c, r, w, h)) {
                    for (let rr = r; rr < r + h; rr++) {
                        for (let cc = c; cc < c + w; cc++)
                            occupied[rr][cc] = true;
                    }
                    slots.set(item.id, {col: c, row: r, cols: w, rows: h});
                    placed = true;
                }
            }
        }
    }
    const rows = Math.max(0, ...[...slots.values()].map(s => s.row + s.rows));
    return {slots, rows};
}

/// Sizes the resize button steps through.
export const VISION_SIZES = [[1, 1], [2, 1], [2, 2], [3, 2], [2, 3], [3, 3], [4, 2], [6, 2], [6, 3]];

export function nextVisionSize(item) {
    const i = VISION_SIZES.findIndex(([c, r]) => c === item.cols && r === item.rows);
    return VISION_SIZES[(i + 1) % VISION_SIZES.length];
}

/// New items go first; everything is renumbered.
export function visionInsertFirst(items, newItems) {
    return [...newItems, ...visionOrdered(items)].map((it, i) => ({...it, order: i}));
}

export function visionMove(items, id, delta) {
    const list = visionOrdered(items);
    const i = list.findIndex(it => it.id === id);
    const j = Math.max(0, Math.min(list.length - 1, i + delta));
    if (i < 0 || i === j)
        return list;
    const [it] = list.splice(i, 1);
    list.splice(j, 0, it);
    return list.map((x, k) => ({...x, order: k}));
}

export function visionTidy(items) {
    return [...items].sort((a, b) => parseDate(b.date) - parseDate(a.date)).map((it, i) => {
        const [cols, rows] = visionDefaultSize(it);
        return {...it, cols, rows, order: i};
    });
}

// MARK: Clipboard history

export const CLIP_MAX_ITEMS = 500;
export const CLIP_MAX_IMAGES = 80;
export const CLIP_FILTERS = ['All', 'Text', 'Images', 'Files', 'Screenshots'];

/// Never keep what a password manager copies: KeePassXC & co. mark it with this hint,
/// and anything copied while one of these apps is focused is skipped too.
export const PASSWORD_HINT_MIMES = ['x-kde-passwordManagerHint'];
export const PASSWORD_MANAGERS = ['keepassxc', 'keepass2', 'keepass', 'bitwarden', '1password', 'enpass',
    'org.gnome.world.secrets', 'secrets', 'gnome-passwordsafe', 'seahorse', 'kwalletmanager5', 'proton pass', 'dashlane'];

export function isSecret(mimetypes, focusedApp) {
    if ((mimetypes ?? []).some(m => PASSWORD_HINT_MIMES.includes(m)))
        return true;
    const app = (focusedApp ?? '').toLowerCase();
    return app !== '' && PASSWORD_MANAGERS.some(p => app === p || app.includes(p));
}

/// Adds an item on top. Same signature = moved to the top (keeping its pin). Old unpinned items and
/// images beyond the limits are dropped; returns {items, dropped} so their image files can be deleted.
export function clipAdd(items, item, maxItems = CLIP_MAX_ITEMS, maxImages = CLIP_MAX_IMAGES) {
    const existing = items.find(i => i.signature === item.signature);
    const rest = items.filter(i => i.signature !== item.signature);
    const top = existing ? {...existing, date: item.date} : item;
    const list = [top, ...rest];
    const keep = [], dropped = [];
    let unpinned = 0, images = 0;
    for (const it of list) {
        if (!it.pinned) {
            const image = it.kind === 'image';
            if (unpinned + 1 > maxItems || (image && images + 1 > maxImages)) {
                dropped.push(it); // dropped items don't count toward the limits
                continue;
            }
            unpinned++;
            if (image)
                images++;
        }
        keep.push(it);
    }
    return {items: keep, dropped};
}

/// Pinned first, then newest first; filtered by kind and search text.
export function clipVisible(items, filter = 'All', query = '') {
    const q = query.trim().toLowerCase();
    const kind = {Text: 'text', Images: 'image', Files: 'file'}[filter];
    return items
        .filter(i => !kind || i.kind === kind)
        .filter(i => !q || [i.text, ...(i.paths ?? []), i.sourceApp].some(s => (s ?? '').toLowerCase().includes(q)))
        .sort((a, b) => (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0) || parseDate(b.date) - parseDate(a.date));
}

export function clipPreview(item) {
    if (item.kind === 'image')
        return item.imageWidth ? `Image · ${item.imageWidth}×${item.imageHeight}` : 'Image';
    if (item.kind === 'file') {
        const names = (item.paths ?? []).map(p => p.split('/').pop());
        return names.length === 1 ? names[0] : `${names.length} files: ${names.join(', ')}`;
    }
    return (item.text ?? '').trim().replace(/\s*\n\s*/g, ' ⏎ ');
}

/// Nautilus puts copied files on the clipboard as "copy\nfile:///a\nfile:///b".
export function parseCopiedFiles(text) {
    const lines = (text ?? '').split(/\r?\n/).filter(Boolean);
    if (lines[0] === 'copy' || lines[0] === 'cut')
        lines.shift();
    const uris = lines.filter(l => l.startsWith('file://'));
    return uris.length ? uris.map(u => decodeURIComponent(u.slice(7))) : null;
}

export function relativeTime(ms, now) {
    const s = Math.max(0, (now - ms) / 1000);
    if (s < 60)
        return 'now';
    if (s < 3600)
        return `${Math.floor(s / 60)}m`;
    if (s < 86400)
        return `${Math.floor(s / 3600)}h`;
    return `${Math.floor(s / 86400)}d`;
}

/// Blocks that started today, oldest first (for the big timer page).
export function todaysBlocks(sessions, now) {
    const day = startOfDay(now);
    return sessions.filter(s => parseDate(s.start) >= day).sort((a, b) => parseDate(a.start) - parseDate(b.start));
}

/// Drifts per focused hour over the last `days`, for blocks timed with drift tracking.
export function driftsPerHour(sessions, now, days = 30) {
    const since = now - days * 86400_000;
    const tracked = sessions.filter(s => parseDate(s.start) >= since && Array.isArray(s.pauses));
    const hours = tracked.reduce((t, s) => t + (s.duration ?? 0), 0) / 3600;
    if (hours < 0.25)
        return null;
    return tracked.reduce((n, s) => n + s.pauses.filter(p => !p.auto).length, 0) / hours;
}

// MARK: Heatmap views: year (GitHub) and calendar

export const MONTH_NAMES = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
export const DAY_NAMES = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
export const HEAT_STYLES = ['year', 'calendar'];

/// ISO week (Monday first; week 1 holds the year's first Thursday), local time.
export function isoWeek(ms) {
    const d = new Date(startOfDay(ms));
    d.setDate(d.getDate() + 3 - (d.getDay() + 6) % 7); // the Thursday of this week
    const jan4 = new Date(d.getFullYear(), 0, 4);
    return 1 + Math.round(((d - jan4) / 86400000 - 3 + (jan4.getDay() + 6) % 7) / 7);
}

/// 52 or 53: the ISO week of 28 December is always the last one.
export function isoWeeksInYear(ms) {
    const d = new Date(startOfDay(ms));
    d.setDate(d.getDate() + 3 - (d.getDay() + 6) % 7);
    return isoWeek(new Date(d.getFullYear(), 11, 28).getTime());
}

export const weekLabel = ms => `Week ${isoWeek(ms)}/${isoWeeksInYear(ms)}`;

/// The year labels week 1, every tenth week and this week.
export const isLandmarkWeek = (w, current) => w === 1 || w % 10 === 0 || w === current;

/// GitHub-style grid: `weeks` columns (oldest first), Monday on top. Month names where a month
/// starts, week numbers underneath (landmarks + this week). Future days have level -1.
export function heatYear(sessions, now, weeks = 53) {
    const stats = dayStats(sessions);
    const first = addDays(startOfWeek(now), -7 * (weeks - 1));
    const today = startOfDay(now);
    const current = isoWeek(now);
    const columns = [];
    for (let w = 0; w < weeks; w++) {
        const days = [];
        for (let d = 0; d < 7; d++) {
            const ms = addDays(first, w * 7 + d);
            days.push({ms, level: ms > today ? -1 : heatLevel(stats.get(dayKey(ms))), today: ms === today});
        }
        columns.push({week: isoWeek(days[3].ms), days});
    }
    const monthLabels = [], weekLabels = [];
    columns.forEach((c, w) => {
        const month = new Date(c.days[6].ms).getMonth();
        if (w > 0 && w < weeks - 1 && month !== new Date(columns[w - 1].days[6].ms).getMonth())
            monthLabels.push({col: w, text: MONTH_NAMES[month]});
        const now = w === weeks - 1;
        if (now || (c.week !== current && isLandmarkWeek(c.week, current) && Math.abs(current - c.week) > 1 &&
            (w === 0 || columns[w - 1].week !== c.week)))
            weekLabels.push({col: w, text: now ? `W${c.week}` : `${c.week}`, current: now});
    });
    return {columns, monthLabels, weekLabels};
}

/// The last `count` months as calendars, oldest first. Rows are weeks (Monday first) with their ISO
/// number; days outside the month are null; days ahead are kept (level -1) so you can plan.
export function heatMonths(sessions, now, count = 12) {
    const stats = dayStats(sessions);
    const today = startOfDay(now);
    const thisMonth = new Date(today);
    thisMonth.setDate(1);
    const months = [];
    for (let i = count - 1; i >= 0; i--) {
        const start = new Date(thisMonth.getFullYear(), thisMonth.getMonth() - i, 1);
        const end = new Date(start.getFullYear(), start.getMonth() + 1, 1).getTime();
        const weeks = [];
        for (let ws = startOfWeek(start.getTime()); ws < end; ws = addDays(ws, 7)) {
            const days = [];
            for (let d = 0; d < 7; d++) {
                const ms = addDays(ws, d);
                days.push(new Date(ms).getMonth() !== start.getMonth() ? null
                    : {ms, level: ms > today ? -1 : heatLevel(stats.get(dayKey(ms))), today: ms === today});
            }
            weeks.push({week: isoWeek(addDays(ws, 3)), current: today >= ws && today < addDays(ws, 7), days});
        }
        const first = i === count - 1;
        const title = first || start.getMonth() === 0
            ? `${MONTH_NAMES[start.getMonth()]} ${start.getFullYear()}` : MONTH_NAMES[start.getMonth()];
        months.push({title, current: i === 0, weeks});
    }
    return months;
}

const hhmm = ms => {
    const d = new Date(ms);
    return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
};

/// What hovering a day shows: date and week, total, then each block's time and intensity.
export function dayBrief(sessions, ms, now = Date.now()) {
    const day = startOfDay(ms);
    const d = new Date(day);
    const title = `${DAY_NAMES[(d.getDay() + 6) % 7]} ${d.getDate()} ${MONTH_NAMES[d.getMonth()]} · W${isoWeek(day)}`;
    const blocks = sessions.filter(s => startOfDay(parseDate(s.start)) === day)
        .sort((a, b) => parseDate(a.start) - parseDate(b.start));
    if (!blocks.length)
        return {title, summary: day > startOfDay(now) ? 'Ahead: nothing logged yet' : 'No deep work', blocks: []};
    const total = blocks.reduce((t, s) => t + (s.duration ?? 0), 0);
    const avg = Math.round(blocks.reduce((t, s) => t + (s.duration ?? 0) * clampIntensity(s.intensity), 0) / Math.max(1, total));
    return {
        title,
        summary: `${hm(total)} · ${blocks.length === 1 ? '1 block' : `${blocks.length} blocks`} · ${INTENSITY_LABELS[clampIntensity(avg) - 1]}`,
        blocks: blocks.map(s => {
            const level = clampIntensity(s.intensity);
            return {
                time: `${hhmm(parseDate(s.start))}–${hhmm(parseDate(s.end ?? s.start))}`,
                intensity: INTENSITY_LABELS[level - 1], color: INTENSITY_COLORS[level - 1], task: s.task || 'Deep work',
            };
        }),
    };
}
