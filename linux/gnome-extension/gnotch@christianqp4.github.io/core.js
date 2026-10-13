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
