// GNotch for GNOME Shell: the notch app in the top bar. Three pages like on the Mac (timer, clipboard,
// vision board), a compact and a big layout (⤢), and the block's progress traced around the indicator.
// Data in ~/.local/share/gnotch/ (see store.js), same formats as the Mac app.

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
import * as Store from './store.js';
import * as UI from './ui.js';

const BAR_WIDTH = 300;
const WIDTH = {compact: 340, large: 720};
const PAGES = [
    {id: 'timer', icon: 'alarm-symbolic', name: 'Timer'},
    {id: 'clipboard', icon: 'edit-paste-symbolic', name: 'Clipboard'},
    {id: 'vision', icon: 'image-x-generic-symbolic', name: 'Vision board'},
];
const CLIPBOARD = St.ClipboardType.CLIPBOARD;
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const clockTime = ms => new Date(ms).toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'});

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(ext) {
        super._init(0.5, 'GNotch');
        this._ext = ext;
        this._store = new Store.Storage();
        this._vision = new Store.VisionBoard();
        this._clips = new Store.ClipHistory();
        this._timer = new Core.Timer(this._store.state.timer);
        this._form = null;
        this._page = 'timer';
        this._filter = 'All';
        this._query = '';
        this._selected = null; // vision widget
        this._timeouts = new Set();

        // Panel: icon, countdown and drift dots, with the progress outline drawn around them.
        const box = new St.BoxLayout({style_class: 'gnotch-panel', y_align: Clutter.ActorAlign.CENTER});
        this._icon = new St.Icon({
            gicon: Gio.icon_new_for_string(`${ext.path}/icons/gnotch-symbolic.svg`),
            style_class: 'system-status-icon',
        });
        this._time = new St.Label({y_align: Clutter.ActorAlign.CENTER, style_class: 'gnotch-panel-time'});
        this._dots = new St.Label({y_align: Clutter.ActorAlign.CENTER, style_class: 'gnotch-panel-dots'});
        box.add_child(this._icon);
        box.add_child(this._time);
        box.add_child(this._dots);
        const wrap = new St.Widget({layout_manager: new Clutter.BinLayout(), y_expand: true});
        wrap.add_child(box);
        this._outline = UI.outlineArea(() => this._outlineState());
        wrap.add_child(this._outline);
        this.add_child(wrap);

        this._card = new St.BoxLayout({vertical: true, style_class: 'gnotch-card'});
        const item = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        item.add_child(this._card);
        this.menu.addMenuItem(item);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const center = new PopupMenu.PopupSwitchMenuItem('Next to the clock', this.placement === 'center');
        center.connect('toggled', (_i, on) => ext.setPosition(on ? 'center' : 'right'));
        this.menu.addMenuItem(center);
        const paused = new PopupMenu.PopupSwitchMenuItem('Pause clipboard history', !!this._store.state.clipboardPaused);
        paused.connect('toggled', (_i, on) => {
            this._store.state.clipboardPaused = on;
            this._store.saveState();
        });
        this.menu.addMenuItem(paused);
        this.menu.addAction('Clear clipboard history (keeps pins)', () => this._clips.clear());
        this.menu.addAction('Open data folder', () =>
            Gio.AppInfo.launch_default_for_uri(`file://${this._store.dir}`, null));

        this.menu.connect('open-state-changed', (_m, open) => {
            if (open) {
                this._store.loadSessions();
                this._vision.load();
                this._render();
            } else {
                this._stopBreath();
                this._selected = null;
            }
        });

        this._watchSleep();
        this._watchClipboard();
        this._render();
        this._tick();
        this._tickId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
            this._tick();
            return GLib.SOURCE_CONTINUE;
        });
    }

    /// 'center' (beside the clock, where the notch would be) or 'right' (with the system icons).
    get placement() { return this._store.state.position === 'right' ? 'right' : 'center'; }

    set placement(p) {
        this._store.state.position = p;
        this._store.saveState();
    }

    get _large() { return !!this._store.state.large; }

    _later(ms, fn) {
        const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            this._timeouts.delete(id);
            if (!this._destroyed)
                fn();
            return GLib.SOURCE_REMOVE;
        });
        this._timeouts.add(id);
    }

    // MARK: Pages and size

    /// Opens a page (⌃⌥D / ⌃⌥V / ⌃⌥B). The same shortcut again tucks it away.
    showPage(page) {
        if (this.menu.isOpen && this._page === page) {
            this.menu.close();
            return;
        }
        this._page = page;
        this._selected = null;
        if (this.menu.isOpen)
            this._render();
        else
            this.menu.open();
        this._focusLater();
    }

    toggleLarge() {
        this._store.state.large = !this._large;
        this._store.saveState();
        this._render();
        this._focusLater();
    }

    _focusLater() {
        this._later(50, () => (this._page === 'clipboard' ? this._search : this._taskEntry)?.grab_key_focus());
    }

    // MARK: Timer state

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
        this._page = 'timer';
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

    /// Green while running, orange when paused, pulsing once past the goal. Like the Mac notch outline.
    _outlineState() {
        const t = this._timer;
        if (!t.isActive)
            return null;
        const now = Date.now();
        const paused = t.phase === 'paused';
        const pulse = !paused && t.isOvertime(now) && Math.floor(t.elapsed(now)) % 2 === 0;
        return {fraction: Core.outlineProgress(t, now), color: paused ? Core.ORANGE : Core.GREEN, alpha: pulse ? 0.45 : 1};
    }

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
        this._outline.queue_repaint();

        if (this._bigTime)
            this._bigTime.text = t.display(now);
        if (this._bar)
            this._fillBar(now);
        this._ring?.queue_repaint();
    }

    _fillBar(now) {
        this._bar.destroy_all_children();
        const colors = {focus: Core.GREEN, drift: Core.ORANGE, sleep: 'rgba(255,255,255,0.25)'};
        for (const [frac, kind] of this._timer.segments(now)) {
            const w = Math.max(1, Math.round(frac * BAR_WIDTH));
            this._bar.add_child(new St.Widget({style: `width: ${w}px; height: 6px; background-color: ${colors[kind]};`}));
        }
    }

    // MARK: Breathing guide

    /// Driven frame by frame (not with Clutter transitions, which GNOME 42 skips while the menu is
    /// closed or re-rendering), so it always moves: 4 s in, 6 s out.
    _startBreath() {
        this._stopBreath();
        this._breathFrame();
        this._breathId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 40, () => {
            this._breathFrame();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _stopBreath() {
        if (this._breathId)
            GLib.source_remove(this._breathId);
        this._breathId = null;
    }

    _breathFrame() {
        if (!this._breath)
            return;
        const b = Core.breath(Date.now() - (this._timer.pauseStart ?? Date.now()));
        this._breath.set_scale(b.scale, b.scale);
        this._breathLabel.text = `${b.inhale ? 'Breathe in' : 'Breathe out'} · ${b.secondsLeft}`;
    }

    _breathCircle(large) {
        this._breath = new St.Widget({
            style_class: large ? 'gnotch-breath gnotch-breath-large' : 'gnotch-breath',
            x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER,
        });
        this._breath.set_pivot_point(0.5, 0.5);
        this._breathLabel = UI.label('', 'gnotch-muted');
        this._breathLabel.x_align = Clutter.ActorAlign.CENTER;
        return this._breath;
    }

    // MARK: Render

    _render() {
        this._stopBreath();
        this._card.destroy_all_children();
        this._bigTime = this._bar = this._breath = this._ring = null;
        this._taskEntry = this._notesEntry = this._search = this._clipBox = this._heatInfo = null;
        this._card.style = `width: ${this._large ? WIDTH.large : WIDTH.compact}px;`;

        // Finishing a block always shows the form.
        const page = this._timer.phase === 'finishing' ? 'timer' : this._page;
        this._card.add_child(this._header(page));
        if (page === 'clipboard')
            this._renderClipboard();
        else if (page === 'vision')
            this._renderVision();
        else if (this._timer.phase === 'finishing')
            this._renderFinish();
        else if (this._large)
            this._renderTimerLarge();
        else if (this._timer.phase === 'idle')
            this._renderIdle();
        else
            this._renderActive();
        if (this._breath)
            this._startBreath();
    }

    /// Page tabs on the left; ⤢ (bigger / smaller) and ⌃ (tuck away) on the right, like the Mac notch.
    _header(page) {
        const tabs = PAGES.map(p => UI.iconButton(p.icon, () => this.showPage(p.id), {on: p.id === page, tooltip: p.name}));
        const large = this._large;
        return UI.row([
            ...tabs,
            UI.spacer(),
            UI.iconButton(large ? 'view-restore-symbolic' : 'view-fullscreen-symbolic', () => this.toggleLarge(),
                {tooltip: large ? 'Smaller' : 'Bigger'}),
            UI.iconButton('go-up-symbolic', () => this.menu.close(), {tooltip: 'Tuck away'}),
        ], 'spacing: 4px;');
    }

    // MARK: Timer page

    _lengthChips() {
        const t = this._timer;
        return UI.row(Core.LENGTHS.map(m => UI.chip(m ? `${m}` : '∞', t.plannedMinutes === m, () => {
            t.plannedMinutes = m;
            this._persist();
            this._render();
        })));
    }

    _statsLine() {
        const now = Date.now();
        const s = this._store.sessions;
        const st = Core.streak(s, now);
        return UI.label(`Today ${Core.hm(Core.totalSince(s, Core.startOfDay(now)))} · this week ${
            Core.hm(Core.totalSince(s, Core.startOfWeek(now)))} · streak ${plural(st, 'day')}`);
    }

    _renderIdle() {
        this._taskEntry = UI.entry('What are you working on?', this._timer.task, () => this.start());
        this._card.add_child(this._taskEntry);
        this._card.add_child(this._lengthChips());
        this._card.add_child(UI.button('Start block', {primary: true, onClick: () => this.start()}));
        this._card.add_child(this._heatSection(false));
    }

    // MARK: Heatmap

    /// Year (GitHub, zoomed out) or calendar (months, zoomed in) view, with week numbers and a
    /// detail area that shows the hovered day's blocks.
    _heatSection(large) {
        const now = Date.now();
        const s = this._store.sessions;
        const style = this._store.state.heatStyle === 'calendar' ? 'calendar' : 'year';
        const setStyle = st => {
            this._store.state.heatStyle = st;
            this._store.saveState();
            this._render();
        };
        const header = UI.row([
            UI.label(large ? `Last 12 months · ${Core.weekLabel(now)}` : Core.weekLabel(now)),
            UI.spacer(),
            UI.chip('Year', style === 'year', () => setStyle('year')),
            UI.chip('Calendar', style === 'calendar', () => setStyle('calendar')),
        ]);
        const onHover = ms => this._showDay(ms);
        const grid = style === 'calendar'
            ? UI.heatCalendar(Core.heatMonths(s, now, large ? 12 : 3), large ? 9 : 8, large ? 6 : 3, onHover)
            : UI.heatYear(Core.heatYear(s, now, large ? 53 : 24), 9, onHover, {weekdays: large});
        this._heatLarge = large;
        this._heatInfo = UI.column([], `spacing: 3px; min-height: ${large ? 58 : 76}px;`);
        this._showDay(null);
        return UI.column([header, grid, this._heatInfo], 'spacing: 6px;');
    }

    _showDay(ms) {
        const box = this._heatInfo;
        if (!box)
            return;
        box.destroy_all_children();
        if (ms === null) {
            if (!this._heatLarge)
                box.add_child(this._statsLine());
            box.add_child(UI.label('Point at a day to see its blocks.'));
            return;
        }
        const b = Core.dayBrief(this._store.sessions, ms);
        box.add_child(UI.row([UI.label(b.title, 'gnotch-task'), UI.label(b.summary)], 'spacing: 8px;'));
        for (const x of b.blocks.slice(0, 3)) {
            box.add_child(UI.row([
                new St.Widget({style: `width: 7px; height: 7px; border-radius: 4px; background-color: ${x.color};`, y_align: Clutter.ActorAlign.CENTER}),
                UI.label(x.time, 'gnotch-text'),
                new St.Label({text: x.intensity, style: `color: ${x.color};`, y_align: Clutter.ActorAlign.CENTER}),
                UI.label(x.task),
            ], 'spacing: 6px;'));
        }
        if (b.blocks.length > 3)
            box.add_child(UI.label(`+${b.blocks.length - 3} more`));
    }

    _controls() {
        const t = this._timer;
        return UI.row([
            UI.button(t.phase === 'paused' ? 'Back to focus' : 'I drifted', {primary: t.phase === 'paused', onClick: () => this.togglePause()}),
            UI.button('Finish', {onClick: () => this.finish()}),
            UI.spacer(),
            UI.label(plural(t.drifts(), 'drift')),
        ]);
    }

    _driftBar() {
        this._bar = new St.BoxLayout({style_class: 'gnotch-bar', style: `width: ${BAR_WIDTH}px;`});
        this._fillBar(Date.now());
        return this._bar;
    }

    _renderActive() {
        const t = this._timer;
        this._card.add_child(UI.row([
            UI.label(t.task || 'Deep work', 'gnotch-task'),
            UI.spacer(),
            UI.label(t.plannedMinutes ? `${t.plannedMinutes} min block` : 'Open-ended'),
        ], ''));
        this._bigTime = new St.Label({text: t.display(Date.now()), style_class: 'gnotch-big-time'});
        if (t.phase === 'paused')
            this._bigTime.add_style_class_name('gnotch-paused');
        this._card.add_child(this._bigTime);
        this._card.add_child(this._driftBar());
        if (t.phase === 'paused') {
            const circle = this._breathCircle(false);
            this._card.add_child(UI.column([circle, this._breathLabel], 'spacing: 8px; padding: 10px 0;'));
        }
        this._card.add_child(this._controls());
    }

    /// Big mode: progress ring with the time inside, today's blocks and stats beside it, the year below.
    _renderTimerLarge() {
        const t = this._timer;
        const now = Date.now();
        const active = t.isActive;

        const stack = new St.Widget({layout_manager: new Clutter.BinLayout()});
        this._ring = UI.ringArea(230, () => this._outlineState());
        stack.add_child(this._ring);
        if (t.phase === 'paused')
            stack.add_child(this._breathCircle(true));
        const timeText = active ? t.display(now) : t.plannedMinutes ? `${t.plannedMinutes}:00` : '∞';
        const time = new St.Label({text: timeText, style_class: 'gnotch-huge-time', x_align: Clutter.ActorAlign.CENTER});
        if (t.phase === 'paused')
            time.add_style_class_name('gnotch-paused');
        if (active)
            this._bigTime = time;
        const sub = UI.label(active ? t.task || 'Deep work' : 'Ready when you are');
        sub.x_align = Clutter.ActorAlign.CENTER;
        const inner = UI.column([time, sub], 'spacing: 2px;');
        inner.x_align = inner.y_align = Clutter.ActorAlign.CENTER;
        stack.add_child(inner);

        const left = UI.column([stack], 'spacing: 12px; width: 260px;');
        if (active) {
            if (t.phase === 'paused')
                left.add_child(this._breathLabel);
            left.add_child(this._controls());
        } else {
            this._taskEntry = UI.entry('What are you working on?', t.task, () => this.start());
            left.add_child(this._taskEntry);
            left.add_child(this._lengthChips());
            left.add_child(UI.button('Start block', {primary: true, onClick: () => this.start()}));
        }

        const s = this._store.sessions;
        const right = UI.column([], 'spacing: 10px;');
        right.x_expand = true;
        if (active)
            right.add_child(this._driftBar());
        right.add_child(UI.label('Today', 'gnotch-task'));
        const today = Core.todaysBlocks(s, now);
        if (!today.length)
            right.add_child(UI.label('No blocks yet today.'));
        for (const b of today.slice(-6)) {
            const level = Core.clampIntensity(b.intensity);
            const bits = [clockTime(Core.parseDate(b.start)), Core.hm(b.duration ?? 0), Core.INTENSITY_LABELS[level - 1], b.location].filter(Boolean);
            right.add_child(UI.row([
                new St.Widget({style: `width: 8px; height: 8px; border-radius: 4px; background-color: ${Core.INTENSITY_COLORS[level - 1]};`, y_align: Clutter.ActorAlign.CENTER}),
                UI.label(b.task || 'Deep work', 'gnotch-text'), UI.spacer(), UI.label(bits.join(' · ')),
            ], 'spacing: 8px;'));
        }
        const dph = Core.driftsPerHour(s, now);
        right.add_child(UI.row([
            UI.stat('Today', Core.hm(Core.totalSince(s, Core.startOfDay(now)))),
            UI.stat('This week', Core.hm(Core.totalSince(s, Core.startOfWeek(now)))),
            UI.stat('Streak', plural(Core.streak(s, now), 'day')),
            UI.stat('Drifts / hour', dph === null ? '–' : dph.toFixed(1)),
        ], 'spacing: 24px; padding-top: 8px;'));

        this._card.add_child(UI.row([left, right], 'spacing: 28px;'));
        this._card.add_child(this._heatSection(true));
    }

    _renderFinish() {
        const t = this._timer;
        const f = this._form ??= {task: t.task, intensity: 3, tags: new Set(), notes: '', location: this._store.state.lastPlace ?? ''};
        const keep = () => {
            f.task = this._taskEntry.get_text();
            f.notes = this._notesEntry.get_text();
        };
        const perRow = this._large ? 8 : 4;

        this._card.add_child(UI.label(`${Core.hm(t.accumulated)} of deep work · ${plural(t.drifts(), 'drift')}`, 'gnotch-task'));
        this._taskEntry = UI.entry('Task', f.task);
        this._card.add_child(this._taskEntry);

        this._card.add_child(UI.label(`Intensity: ${Core.INTENSITY_LABELS[f.intensity - 1]}`));
        this._card.add_child(UI.row([1, 2, 3, 4, 5].map(i => {
            const b = UI.chip(`${i}`, f.intensity === i, () => {
                keep();
                f.intensity = i;
                this._render();
            });
            if (f.intensity === i)
                b.style = `background-color: ${Core.INTENSITY_COLORS[i - 1]}; color: #000;`;
            return b;
        })));

        const tagChip = tag => UI.chip(tag, f.tags.has(tag), () => {
            keep();
            f.tags.has(tag) ? f.tags.delete(tag) : f.tags.add(tag);
            this._render();
        });
        this._card.add_child(UI.label('How did it feel?'));
        for (let i = 0; i < Core.TAGS.length; i += perRow)
            this._card.add_child(UI.row(Core.TAGS.slice(i, i + perRow).map(tagChip)));

        const places = [...Core.PLACES, ...(this._store.state.customPlaces ?? [])];
        if (f.location && !places.includes(f.location))
            places.push(f.location);
        const placeChip = p => UI.chip(p, f.location === p, () => {
            keep();
            f.location = f.location === p ? '' : p;
            this._render();
        });
        this._card.add_child(UI.label('Where?'));
        for (let i = 0; i < places.length; i += perRow)
            this._card.add_child(UI.row(places.slice(i, i + perRow).map(placeChip)));
        const other = UI.entry('Other place… (Enter)', '', () => {
            keep();
            f.location = other.get_text().trim();
            this._render();
        });
        this._card.add_child(other);

        this._notesEntry = UI.entry('Notes: what helped, what pulled you out', f.notes, () => this.save());
        this._card.add_child(this._notesEntry);
        this._card.add_child(UI.row([
            UI.button('Save', {primary: true, onClick: () => this.save()}),
            UI.button('Discard', {onClick: () => this.discard()}),
        ]));
    }

    // MARK: Clipboard page

    /// Records what you copy. Password managers are skipped: KeePassXC & co. mark their copies with
    /// x-kde-passwordManagerHint, and nothing is kept while a password manager window is focused.
    _watchClipboard() {
        const selection = global.display.get_selection();
        this._selection = selection;
        this._selectionId = selection.connect('owner-changed', (_s, type, source) => {
            if (type !== Meta.SelectionType.SELECTION_CLIPBOARD || !source || this._store.state.clipboardPaused)
                return;
            const mimes = source.get_mimetypes?.() ?? [];
            const wmClass = global.display.focus_window?.get_wm_class?.() ?? '';
            if (Core.isSecret(mimes, wmClass))
                return;
            const app = Shell.WindowTracker.get_default().focus_app?.get_name() ?? wmClass;
            this._later(120, () => this._readClipboard(mimes, app));
        });
    }

    _readClipboard(mimes, app) {
        const cb = St.Clipboard.get_default();
        const done = () => {
            if (this.menu.isOpen && this._clipBox)
                this._fillClips();
        };
        const canContent = typeof cb.get_content === 'function';
        if (canContent && mimes.includes('x-special/gnome-copied-files')) {
            cb.get_content(CLIPBOARD, 'x-special/gnome-copied-files', (_c, bytes) => {
                const paths = bytes && Core.parseCopiedFiles(new TextDecoder().decode(bytes.get_data()));
                if (paths && !this._destroyed) {
                    this._clips.addFiles(paths, app);
                    done();
                }
            });
            return;
        }
        if (canContent && mimes.includes('image/png')) {
            cb.get_content(CLIPBOARD, 'image/png', (_c, bytes) => {
                if (bytes && bytes.get_size() > 0 && bytes.get_size() < 25_000_000 && !this._destroyed) {
                    this._clips.addImage(bytes, app);
                    done();
                }
            });
            return;
        }
        cb.get_text(CLIPBOARD, (_c, text) => {
            if (text && !this._destroyed) {
                this._clips.addText(text, app);
                done();
            }
        });
    }

    _renderClipboard() {
        this._search = UI.entry('Search everything you copied', this._query, () => {
            const top = this._visibleClips()[0];
            if (top)
                this._copy(top);
        });
        this._search.clutter_text.connect('text-changed', () => {
            this._query = this._search.get_text();
            this._fillClips();
        });
        this._card.add_child(this._search);
        this._card.add_child(UI.row(Core.CLIP_FILTERS.map(f => UI.chip(f, this._filter === f, () => {
            this._filter = f;
            this._render();
            this._focusLater();
        }))));
        if (this._store.state.clipboardPaused)
            this._card.add_child(UI.label('History is paused (switch below).'));
        this._clipBox = new St.BoxLayout({style: 'spacing: 8px;'});
        this._card.add_child(UI.scroll(this._clipBox, this._large ? 470 : 320));
        this._fillClips();
    }

    _visibleClips() {
        if (this._filter === 'Screenshots') {
            const q = this._query.trim().toLowerCase();
            return Store.listScreenshots(this._large ? 40 : 12)
                .filter(s => !q || s.name.toLowerCase().includes(q))
                .map(s => ({id: s.path, kind: 'screenshot', path: s.path, name: s.name, mtime: s.mtime * 1000}));
        }
        return Core.clipVisible(this._clips.items, this._filter, this._query).slice(0, this._large ? 60 : 12);
    }

    _fillClips() {
        const box = this._clipBox;
        box.destroy_all_children();
        const cols = this._large ? 2 : 1;
        const columns = Array.from({length: cols}, () => UI.column([], 'spacing: 6px;'));
        columns.forEach(c => {
            c.x_expand = true;
            box.add_child(c);
        });
        const items = this._visibleClips();
        if (!items.length) {
            columns[0].add_child(UI.label(this._filter === 'Screenshots'
                ? 'No screenshots in ~/Pictures/Screenshots yet. Press Print Screen.'
                : this._query ? 'Nothing matches.' : 'Copy something and it shows up here.'));
        }
        items.forEach((item, i) => columns[i % cols].add_child(this._clipRow(item)));
    }

    _clipRow(item) {
        const large = this._large;
        const now = Date.now();
        let content;
        if (item.kind === 'image' || item.kind === 'screenshot') {
            const path = item.kind === 'image' ? this._clips.imagePath(item) : item.path;
            const caption = item.kind === 'image' ? Core.clipPreview(item) : item.name;
            content = UI.row([UI.imageTile(path, large ? 96 : 72, large ? 64 : 48), UI.wrapLabel(caption, 'gnotch-text', 2)], 'spacing: 8px;');
        } else {
            content = UI.wrapLabel(Core.clipPreview(item), 'gnotch-text', large ? 3 : 2);
        }
        const when = item.kind === 'screenshot' ? item.mtime : Core.parseDate(item.date);
        const meta = [Core.relativeTime(when, now), item.sourceApp].filter(Boolean).join(' · ');
        const main = new St.Button({
            child: UI.column([content, UI.label(meta)], 'spacing: 2px;'),
            style_class: item.pinned ? 'gnotch-clip gnotch-clip-pinned' : 'gnotch-clip',
            x_expand: true, can_focus: true,
        });
        main.connect('clicked', () => this._copy(item));
        if (item.kind === 'screenshot')
            return main;
        const pin = UI.iconButton(item.pinned ? 'starred-symbolic' : 'non-starred-symbolic', () => {
            this._clips.togglePin(item.id);
            this._fillClips();
        }, {tooltip: item.pinned ? 'Unpin' : 'Pin'});
        const del = UI.iconButton('edit-delete-symbolic', () => {
            this._clips.remove(item.id);
            this._fillClips();
        }, {tooltip: 'Delete'});
        return UI.row([main, UI.column([pin, del], 'spacing: 2px;')], 'spacing: 4px;');
    }

    /// Puts an item back on the clipboard and tucks the menu away, so you can paste right away.
    _copy(item) {
        const cb = St.Clipboard.get_default();
        const bytesOf = path => new GLib.Bytes(GLib.file_get_contents(path)[1]);
        try {
            if (item.kind === 'text') {
                cb.set_text(CLIPBOARD, item.text);
            } else if (item.kind === 'image') {
                cb.set_content(CLIPBOARD, 'image/png', bytesOf(this._clips.imagePath(item)));
            } else if (item.kind === 'screenshot') {
                const mime = /\.jpe?g$/i.test(item.path) ? 'image/jpeg' : 'image/png';
                cb.set_content(CLIPBOARD, mime, bytesOf(item.path));
            } else if (item.kind === 'file') {
                const uris = item.paths.map(p => `file://${encodeURI(p)}`).join('\n');
                cb.set_content(CLIPBOARD, 'x-special/gnome-copied-files', new GLib.Bytes(new TextEncoder().encode(`copy\n${uris}`)));
            }
        } catch (e) {
            Main.notifyError('GNotch couldn’t copy that', String(e));
            return;
        }
        this.menu.close();
    }

    // MARK: Vision board page

    _renderVision() {
        const large = this._large;
        const cell = large ? 104 : 46;
        const gap = 6;

        this._card.add_child(UI.row([
            UI.button('Paste', {onClick: () => this._pasteToVision()}),
            UI.button('Add images…', {onClick: () => this._pickImages()}),
            UI.button('Tidy', {onClick: () => {
                this._vision.tidy();
                this._render();
            }}),
        ]));
        const note = UI.entry('Add a goal or a quote (Enter)', '', () => {
            if (this._vision.addText(note.get_text()))
                this._render();
        });
        this._card.add_child(note);

        const items = this._vision.ordered;
        if (!items.length) {
            this._card.add_child(UI.label('Paste or add images, goals and quotes. They show up here as widgets.'));
            return;
        }
        const {slots, rows} = Core.packGrid(items);
        const span = n => n * cell + (n - 1) * gap;
        const grid = new St.Widget({style: `width: ${span(Core.VISION_COLUMNS)}px; height: ${span(Math.max(1, rows))}px;`});
        for (const item of items) {
            const s = slots.get(item.id);
            const w = span(s.cols), h = span(s.rows);
            const on = this._selected === item.id;
            // St adds borders (2px) and padding (notes: 10/8px) around the given size.
            const note = item.kind === 'text';
            const tile = new St.Button({
                style_class: `gnotch-tile${note ? ' gnotch-note' : ''}${on ? ' gnotch-tile-on' : ''}`,
                style: `width: ${w - 4 - (note ? 20 : 0)}px; height: ${h - 4 - (note ? 16 : 0)}px;`, can_focus: true,
            });
            if (!note)
                tile.set_child(UI.imageTile(this._vision.imagePath(item), w - 4, h - 4));
            else
                tile.set_child(UI.wrapLabel(item.text ?? '', large ? 'gnotch-note-text-large' : 'gnotch-note-text', Math.max(2, s.rows * (large ? 4 : 2))));
            tile.connect('clicked', () => {
                this._selected = on ? null : item.id;
                this._render();
            });
            tile.set_position(s.col * (cell + gap), s.row * (cell + gap));
            grid.add_child(tile);
        }
        this._card.add_child(UI.scroll(grid, large ? 480 : 330));

        const sel = items.find(it => it.id === this._selected);
        if (sel) {
            const redo = fn => () => {
                fn();
                this._render();
            };
            this._card.add_child(UI.row([
                UI.button(`Size ${sel.cols}×${sel.rows}`, {onClick: redo(() => this._vision.resize(sel.id))}),
                UI.iconButton('go-previous-symbolic', redo(() => this._vision.move(sel.id, -1)), {tooltip: 'Earlier'}),
                UI.iconButton('go-next-symbolic', redo(() => this._vision.move(sel.id, 1)), {tooltip: 'Later'}),
                ...(sel.kind === 'image' ? [UI.button('Open', {onClick: () => {
                    Gio.AppInfo.launch_default_for_uri(`file://${encodeURI(this._vision.imagePath(sel))}`, null);
                    this.menu.close();
                }})] : []),
                UI.spacer(),
                UI.button('Remove', {onClick: redo(() => {
                    this._vision.remove(sel.id);
                    this._selected = null;
                })}),
            ]));
        } else {
            this._card.add_child(UI.label('Click a widget to resize, move or remove it.'));
        }
    }

    /// Paste what's on the clipboard: an image or a line of text.
    _pasteToVision() {
        const cb = St.Clipboard.get_default();
        const mimes = cb.get_mimetypes?.(CLIPBOARD) ?? [];
        if (mimes.includes('image/png') && cb.get_content) {
            cb.get_content(CLIPBOARD, 'image/png', (_c, bytes) => {
                if (bytes && bytes.get_size() > 0) {
                    this._vision.addImageBytes(bytes.get_data());
                    this._render();
                }
            });
            return;
        }
        cb.get_text(CLIPBOARD, (_c, text) => {
            if (this._vision.addText(text))
                this._render();
        });
    }

    /// GNOME Shell has no file picker of its own, so this asks zenity (installed with Ubuntu's desktop).
    _pickImages() {
        this.menu.close();
        let proc;
        try {
            proc = Gio.Subprocess.new(['zenity', '--file-selection', '--multiple', '--separator=\n',
                '--title=Add images to your vision board', '--file-filter=Images | *.png *.jpg *.jpeg *.gif *.webp *.bmp *.PNG *.JPG *.JPEG'],
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
        } catch {
            Main.notify('GNotch', 'Adding images needs zenity: sudo apt install zenity. Or copy an image and use Paste.');
            return;
        }
        proc.communicate_utf8_async(null, null, (p, res) => {
            try {
                const [, out] = p.communicate_utf8_finish(res);
                const paths = (out ?? '').split('\n').map(s => s.trim()).filter(Boolean);
                const added = paths.filter(path => this._vision.addImageFile(path)).length;
                if (added && !this._destroyed)
                    this.showPage('vision');
            } catch (e) {
                console.warn(`GNotch: picking images failed: ${e}`);
            }
        });
    }

    destroy() {
        this._destroyed = true;
        this._stopBreath();
        if (this._tickId)
            GLib.source_remove(this._tickId);
        for (const id of this._timeouts)
            GLib.source_remove(id);
        this._timeouts.clear();
        if (this._sleepId)
            Gio.DBus.system.signal_unsubscribe(this._sleepId);
        if (this._selectionId)
            this._selection.disconnect(this._selectionId);
        this._tickId = this._sleepId = this._selectionId = null;
        super.destroy();
    }
});

// MARK: Extension

export default class GNotchExtension extends Extension {
    enable() {
        this._addIndicator();

        // Same shortcuts as the Mac app. Pressing a page's shortcut again tucks it away.
        this._accels = new Map();
        this._grab('<Control><Alt>d', () => this._indicator.showPage('timer'));
        this._grab('<Control><Alt>v', () => this._indicator.showPage('clipboard'));
        this._grab('<Control><Alt>b', () => this._indicator.showPage('vision'));
        this._grab('<Control><Alt>p', () => this._indicator.togglePause());
        this._accelId = global.display.connect('accelerator-activated', (_d, action) => this._accels.get(action)?.());
    }

    /// Center by default: right after the clock, the closest thing Ubuntu has to the notch.
    _addIndicator() {
        this._indicator = new Indicator(this);
        const pos = this._indicator.placement;
        Main.panel.addToStatusArea(this.uuid, this._indicator, pos === 'center' ? 1 : 0, pos);
    }

    /// Rebuilt on idle so the switch that triggered it isn't destroyed mid-signal. The timer is saved, so nothing is lost.
    setPosition(pos) {
        this._indicator.placement = pos;
        GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            this._indicator?.destroy();
            this._addIndicator();
            return GLib.SOURCE_REMOVE;
        });
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
