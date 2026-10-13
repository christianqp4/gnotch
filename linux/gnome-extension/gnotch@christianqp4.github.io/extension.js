// GNotch for GNOME Shell: the deep-work timer in the top bar.
// Same sessions.json format as the Mac app (see core.js), stored in ~/.local/share/gnotch/.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

import * as Core from './core.js';

const BAR_WIDTH = 300;

// MARK: Storage

class Storage {
    constructor() {
        this.dir = GLib.build_filenamev([GLib.get_user_data_dir(), 'gnotch']);
        GLib.mkdir_with_parents(this.dir, 0o755);
        this.sessionsPath = GLib.build_filenamev([this.dir, 'sessions.json']);
        this.statePath = GLib.build_filenamev([this.dir, 'state.json']);
        this.sessions = [];
        this.loadSessions();
        this.state = this._readJSON(this.statePath) ?? {};
    }

    _readText(path) {
        try {
            const [ok, bytes] = GLib.file_get_contents(path);
            return ok ? new TextDecoder().decode(bytes) : null;
        } catch {
            return null; // missing file
        }
    }

    _readJSON(path) {
        try {
            return JSON.parse(this._readText(path) ?? 'null');
        } catch {
            return null;
        }
    }

    _write(path, text) {
        const file = Gio.File.new_for_path(path);
        file.replace_contents(new TextEncoder().encode(text), null, false,
            Gio.FileCreateFlags.REPLACE_DESTINATION, null);
    }

    /// Reads sessions.json. A file we can't read is copied aside, never silently overwritten.
    loadSessions() {
        const text = this._readText(this.sessionsPath);
        try {
            this.sessions = Core.parseSessions(text);
        } catch (e) {
            const backup = GLib.build_filenamev([this.dir, `sessions.unreadable-${Math.floor(Date.now() / 1000)}.json`]);
            this._write(backup, text);
            console.warn(`GNotch: unreadable sessions.json, backed up to ${backup}: ${e}`);
            this.sessions = [];
        }
    }

    /// Re-reads first so blocks another client appended in the meantime survive.
    addSession(session) {
        this.loadSessions();
        this.sessions.push(session);
        this._write(this.sessionsPath, Core.serializeSessions(this.sessions));
    }

    saveState() {
        this._write(this.statePath, `${JSON.stringify(this.state, null, 2)}\n`);
    }
}

// MARK: Small widgets

function button(label, {primary = false, onClick, style = ''} = {}) {
    const b = new St.Button({
        label, can_focus: true, x_expand: false,
        style_class: primary ? 'gnotch-button gnotch-primary' : 'gnotch-button',
        style,
    });
    if (onClick)
        b.connect('clicked', onClick);
    return b;
}

function chip(label, on, onClick) {
    const b = new St.Button({label, can_focus: true, style_class: on ? 'gnotch-chip gnotch-chip-on' : 'gnotch-chip'});
    b.connect('clicked', onClick);
    return b;
}

function row(children, style = 'spacing: 6px;') {
    const box = new St.BoxLayout({style});
    children.forEach(c => box.add_child(c));
    return box;
}

function label(text, styleClass = 'gnotch-muted') {
    return new St.Label({text, style_class: styleClass, y_align: Clutter.ActorAlign.CENTER});
}

function entry(hint, text, onActivate) {
    const e = new St.Entry({hint_text: hint, text, can_focus: true, x_expand: true, style_class: 'gnotch-entry'});
    if (onActivate)
        e.clutter_text.connect('activate', onActivate);
    return e;
}

// MARK: Indicator

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(ext) {
        super._init(0.5, 'GNotch');
        this._ext = ext;
        this._store = new Storage();
        this._timer = new Core.Timer(this._store.state.timer);
        this._form = null;

        const box = new St.BoxLayout({style_class: 'panel-status-menu-box gnotch-panel'});
        this._icon = new St.Icon({
            gicon: Gio.icon_new_for_string(`${ext.path}/icons/gnotch-symbolic.svg`),
            style_class: 'system-status-icon',
        });
        this._time = new St.Label({y_align: Clutter.ActorAlign.CENTER, style_class: 'gnotch-panel-time'});
        this._dots = new St.Label({y_align: Clutter.ActorAlign.CENTER, style_class: 'gnotch-panel-dots'});
        box.add_child(this._icon);
        box.add_child(this._time);
        box.add_child(this._dots);
        this.add_child(box);

        this._card = new St.BoxLayout({vertical: true, style_class: 'gnotch-card'});
        const item = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        item.add_child(this._card);
        this.menu.addMenuItem(item);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this.menu.addAction('Open data folder', () =>
            Gio.AppInfo.launch_default_for_uri(`file://${this._store.dir}`, null));

        this.menu.connect('open-state-changed', (_m, open) => {
            if (open) {
                this._store.loadSessions();
                this._render();
            }
        });

        this._watchSleep();
        this._render();
        this._tick();
        this._tickId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
            this._tick();
            return GLib.SOURCE_CONTINUE;
        });
    }

    // MARK: State

    _persist() {
        this._store.state.timer = this._timer.snapshot();
        this._store.saveState();
    }

    _act(fn) {
        if (fn(Date.now())) {
            this._persist();
            this._render();
            this._tick();
        }
    }

    start() {
        const task = this._taskEntry?.get_text() ?? '';
        this._act(now => this._timer.start(now, this._timer.plannedMinutes, task.trim()));
        this._sound('message');
    }

    togglePause() { this._act(now => this._timer.toggle(now)); }

    finish() {
        this._form = {
            task: this._timer.task, intensity: 3, tags: new Set(), notes: '',
            location: this._store.state.lastPlace ?? '',
        };
        this._act(now => this._timer.finish(now));
        this.menu.open();
    }

    save() {
        const f = this._form;
        const session = this._timer.buildSession({
            id: GLib.uuid_string_random().toUpperCase(),
            task: this._taskEntry?.get_text() ?? f.task,
            intensity: f.intensity, tags: [...f.tags],
            notes: this._notesEntry?.get_text() ?? '',
            location: f.location,
        });
        if (!session)
            return;
        try {
            this._store.addSession(session);
        } catch (e) {
            Main.notifyError('GNotch couldn’t save the block', String(e));
            return; // keep the form so nothing is lost
        }
        if (session.location) {
            this._store.state.lastPlace = session.location;
            this._store.state.customPlaces = Core.rememberPlace(this._store.state.customPlaces ?? [], session.location);
        }
        this._form = null;
        this._timer.discard();
        this._persist();
        this._sound('complete');
        this._render();
        this._tick();
    }

    discard() {
        this._form = null;
        this._timer.discard();
        this._persist();
        this._render();
        this._tick();
    }

    _sound(name) {
        try {
            global.display.get_sound_player().play_from_theme(name, 'GNotch', null);
        } catch {}
    }

    /// The computer going to sleep pauses the block, but it isn't counted as a drift.
    _watchSleep() {
        this._sleepId = Gio.DBus.system.signal_subscribe(
            'org.freedesktop.login1', 'org.freedesktop.login1.Manager', 'PrepareForSleep',
            '/org/freedesktop/login1', null, Gio.DBusSignalFlags.NONE,
            (_c, _s, _p, _i, _n, params) => {
                const [sleeping] = params.deep_unpack();
                if (sleeping)
                    this._act(now => this._timer.pause(now, true));
            });
    }

    // MARK: Ticking

    _tick() {
        const now = Date.now();
        const t = this._timer;
        if (t.checkGoal(now)) {
            this._persist();
            this._sound('complete');
            Main.notify('GNotch', `Goal reached: ${t.plannedMinutes} min. Keep going or finish the block.`);
        }

        const active = t.isActive;
        this._time.visible = active || t.phase === 'finishing';
        this._time.text = t.phase === 'finishing' ? 'Log block' : t.display(now);
        this._time.style = t.phase === 'paused' ? `color: ${Core.ORANGE};` : '';
        const drifts = active ? t.drifts() : 0;
        this._dots.visible = drifts > 0;
        this._dots.text = '•'.repeat(Math.min(drifts, 5));

        if (this._bigTime)
            this._bigTime.text = t.display(now);
        if (this._bar)
            this._fillBar(now);
        if (this._breath)
            this._breathe(now);
    }

    _fillBar(now) {
        this._bar.destroy_all_children();
        const colors = {focus: Core.GREEN, drift: Core.ORANGE, sleep: 'rgba(255,255,255,0.25)'};
        for (const [frac, kind] of this._timer.segments(now)) {
            const w = Math.max(1, Math.round(frac * BAR_WIDTH));
            this._bar.add_child(new St.Widget({style: `width: ${w}px; height: 6px; background-color: ${colors[kind]};`}));
        }
    }

    /// 4 s in, 6 s out.
    _breathe(now) {
        const t = ((now - (this._timer.pauseStart ?? now)) / 1000) % 10;
        const inhale = t < 4;
        if (this._breathIn === inhale)
            return;
        this._breathIn = inhale;
        this._breathLabel.text = inhale ? 'Breathe in…' : 'Breathe out…';
        this._breath.remove_all_transitions();
        this._breath.ease({
            scale_x: inhale ? 1.0 : 0.55, scale_y: inhale ? 1.0 : 0.55,
            duration: (inhale ? 4 - t : 10 - t) * 1000,
            mode: Clutter.AnimationMode.EASE_IN_OUT_SINE,
        });
    }

    // MARK: Views

    _render() {
        this._card.destroy_all_children();
        this._bigTime = this._bar = this._breath = this._taskEntry = this._notesEntry = null;
        this._breathIn = null;
        const phase = this._timer.phase;
        if (phase === 'idle')
            this._renderIdle();
        else if (phase === 'finishing')
            this._renderFinish();
        else
            this._renderActive();
    }

    _renderIdle() {
        const t = this._timer;
        this._taskEntry = entry('What are you working on?', t.task, () => this.start());
        this._card.add_child(this._taskEntry);

        this._card.add_child(row(Core.LENGTHS.map(m => chip(m ? `${m}` : '∞', t.plannedMinutes === m, () => {
            t.plannedMinutes = m;
            this._persist();
            this._render();
        }))));
        this._card.add_child(button('Start block', {primary: true, onClick: () => this.start()}));
        this._renderHeatmap();
    }

    _renderActive() {
        const t = this._timer;
        const now = Date.now();
        this._card.add_child(row([
            label(t.task || 'Deep work', 'gnotch-task'),
            new St.Widget({x_expand: true}),
            label(t.plannedMinutes ? `${t.plannedMinutes} min block` : 'Open-ended'),
        ], ''));

        this._bigTime = new St.Label({text: t.display(now), style_class: 'gnotch-big-time'});
        if (t.phase === 'paused')
            this._bigTime.add_style_class_name('gnotch-paused');
        this._card.add_child(this._bigTime);

        this._bar = new St.BoxLayout({style_class: 'gnotch-bar', style: `width: ${BAR_WIDTH}px;`});
        this._card.add_child(this._bar);
        this._fillBar(now);

        if (t.phase === 'paused') {
            const wrap = new St.BoxLayout({vertical: true, x_align: Clutter.ActorAlign.CENTER, style: 'spacing: 8px; padding: 10px 0;'});
            this._breath = new St.Widget({style_class: 'gnotch-breath', x_align: Clutter.ActorAlign.CENTER});
            this._breath.set_pivot_point(0.5, 0.5);
            this._breathLabel = label('', 'gnotch-muted');
            this._breathLabel.x_align = Clutter.ActorAlign.CENTER;
            wrap.add_child(this._breath);
            wrap.add_child(this._breathLabel);
            this._card.add_child(wrap);
            this._breathe(now);
        }

        this._card.add_child(row([
            button(t.phase === 'paused' ? 'Back to focus' : 'I drifted', {primary: t.phase === 'paused', onClick: () => this.togglePause()}),
            button('Finish', {onClick: () => this.finish()}),
            new St.Widget({x_expand: true}),
            label(`${t.drifts()} drift${t.drifts() === 1 ? '' : 's'}`),
        ]));
    }

    _renderFinish() {
        const t = this._timer;
        const f = this._form ??= {task: t.task, intensity: 3, tags: new Set(), notes: '', location: this._store.state.lastPlace ?? ''};
        const keep = () => {
            f.task = this._taskEntry.get_text();
            f.notes = this._notesEntry.get_text();
        };

        this._card.add_child(label(`${Core.hm(t.accumulated)} of deep work · ${t.drifts()} drift${t.drifts() === 1 ? '' : 's'}`, 'gnotch-task'));
        this._taskEntry = entry('Task', f.task);
        this._card.add_child(this._taskEntry);

        this._card.add_child(label(`Intensity: ${Core.INTENSITY_LABELS[f.intensity - 1]}`));
        this._card.add_child(row([1, 2, 3, 4, 5].map(i => {
            const b = chip(`${i}`, f.intensity === i, () => {
                keep();
                f.intensity = i;
                this._render();
            });
            if (f.intensity === i)
                b.style = `background-color: ${Core.INTENSITY_COLORS[i - 1]}; color: #000;`;
            return b;
        })));

        const tagChip = tag => chip(tag, f.tags.has(tag), () => {
            keep();
            f.tags.has(tag) ? f.tags.delete(tag) : f.tags.add(tag);
            this._render();
        });
        this._card.add_child(label('How did it feel?'));
        this._card.add_child(row(Core.TAGS.slice(0, 4).map(tagChip)));
        this._card.add_child(row(Core.TAGS.slice(4).map(tagChip)));

        const places = [...Core.PLACES, ...(this._store.state.customPlaces ?? [])];
        if (f.location && !places.includes(f.location))
            places.push(f.location);
        const placeChip = p => chip(p, f.location === p, () => {
            keep();
            f.location = f.location === p ? '' : p;
            this._render();
        });
        this._card.add_child(label('Where?'));
        for (let i = 0; i < places.length; i += 4)
            this._card.add_child(row(places.slice(i, i + 4).map(placeChip)));
        const other = entry('Other place… (Enter)', '', () => {
            keep();
            f.location = other.get_text().trim();
            this._render();
        });
        this._card.add_child(other);

        this._notesEntry = entry('Notes: what helped, what pulled you out', f.notes, () => this.save());
        this._card.add_child(this._notesEntry);
        this._card.add_child(row([
            button('Save', {primary: true, onClick: () => this.save()}),
            button('Discard', {onClick: () => this.discard()}),
        ]));
    }

    _renderHeatmap() {
        const now = Date.now();
        const s = this._store.sessions;
        const grid = Core.heatGrid(s, now, 24);
        const heat = new St.BoxLayout({style_class: 'gnotch-heat'});
        for (const week of grid) {
            const col = new St.BoxLayout({vertical: true, style: 'spacing: 2px;'});
            for (const level of week) {
                col.add_child(new St.Widget({
                    style_class: 'gnotch-cell',
                    style: level < 0 ? 'background-color: transparent;' : `background-color: ${Core.HEAT[level]};`,
                }));
            }
            heat.add_child(col);
        }
        const st = Core.streak(s, now);
        this._card.add_child(label(
            `Today ${Core.hm(Core.totalSince(s, Core.startOfDay(now)))} · this week ${Core.hm(Core.totalSince(s, Core.startOfWeek(now)))} · streak ${st} day${st === 1 ? '' : 's'}`));
        this._card.add_child(heat);
    }

    destroy() {
        if (this._tickId)
            GLib.source_remove(this._tickId);
        if (this._sleepId)
            Gio.DBus.system.signal_unsubscribe(this._sleepId);
        this._tickId = this._sleepId = null;
        super.destroy();
    }
});

// MARK: Extension

export default class GNotchExtension extends Extension {
    enable() {
        this._indicator = new Indicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator, 0, 'right');

        // Same shortcuts as the Mac app: ⌃⌥D opens the timer, ⌃⌥P is "I drifted" (again to resume).
        this._accels = new Map();
        this._grab('<Control><Alt>d', () => this._indicator.menu.toggle());
        this._grab('<Control><Alt>p', () => this._indicator.togglePause());
        this._accelId = global.display.connect('accelerator-activated', (_d, action) => this._accels.get(action)?.());
    }

    _grab(accel, fn) {
        const action = global.display.grab_accelerator(accel, Meta.KeyBindingFlags.NONE);
        if (action === Meta.KeyBindingAction.NONE) {
            console.warn(`GNotch: ${accel} is taken by something else`);
            return;
        }
        Main.wm.allowKeybinding(Meta.external_binding_name_for_action(action), Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW);
        this._accels.set(action, fn);
    }

    disable() {
        if (this._accelId)
            global.display.disconnect(this._accelId);
        for (const action of this._accels?.keys() ?? []) {
            Main.wm.allowKeybinding(Meta.external_binding_name_for_action(action), Shell.ActionMode.NONE);
            global.display.ungrab_accelerator(action);
        }
        this._accels = null;
        this._accelId = null;
        this._indicator?.destroy();
        this._indicator = null;
    }
}
