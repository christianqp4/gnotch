// Small St building blocks shared by the pages.

import Clutter from 'gi://Clutter';
import Cairo from 'cairo';
import St from 'gi://St';

import * as Core from './core.js';

export function button(label, {primary = false, onClick, style = ''} = {}) {
    const b = new St.Button({
        label, can_focus: true,
        style_class: primary ? 'gnotch-button gnotch-primary' : 'gnotch-button',
        style,
    });
    if (onClick)
        b.connect('clicked', onClick);
    return b;
}

export function iconButton(iconName, onClick, {on = false, tooltip = ''} = {}) {
    const b = new St.Button({
        child: new St.Icon({icon_name: iconName, icon_size: 16}),
        can_focus: true, accessible_name: tooltip,
        style_class: on ? 'gnotch-icon-button gnotch-icon-on' : 'gnotch-icon-button',
    });
    b.connect('clicked', onClick);
    return b;
}

export function chip(label, on, onClick) {
    const b = new St.Button({label, can_focus: true, style_class: on ? 'gnotch-chip gnotch-chip-on' : 'gnotch-chip'});
    b.connect('clicked', onClick);
    return b;
}

export function row(children, style = 'spacing: 6px;') {
    const box = new St.BoxLayout({style});
    children.forEach(c => box.add_child(c));
    return box;
}

export function column(children, style = 'spacing: 10px;') {
    const box = new St.BoxLayout({vertical: true, style});
    children.forEach(c => box.add_child(c));
    return box;
}

export const spacer = () => new St.Widget({x_expand: true});

export function label(text, styleClass = 'gnotch-muted') {
    return new St.Label({text, style_class: styleClass, y_align: Clutter.ActorAlign.CENTER});
}

/// Wrapped text of a fixed width. The text is cut to roughly `lines` lines first: a wrapped label
/// without a width, or with a huge text, makes the shell re-measure it over and over.
export function wrapLabel(text, styleClass, lines = 3, width = 240) {
    const max = Math.max(20, Math.round(lines * width / 7));
    const t = text.length > max ? `${text.slice(0, max - 1).trimEnd()}…` : text;
    const l = new St.Label({text: t, style_class: styleClass, style: `width: ${width}px;`});
    l.clutter_text.line_wrap = true;
    l.clutter_text.line_wrap_mode = 2; // Pango.WrapMode.WORD_CHAR: long URLs wrap too
    return l;
}

export function entry(hint, text, onActivate) {
    const e = new St.Entry({hint_text: hint, text: text ?? '', can_focus: true, x_expand: true, style_class: 'gnotch-entry'});
    if (onActivate)
        e.clutter_text.connect('activate', onActivate);
    return e;
}

/// Wraps `child` in a scroll view of at most `height` px. A scroll view needs a scrollable child
/// (hence the box), and it must be attached the way each GNOME version expects: on GNOME 42–45
/// only add_actor() wires it up (set_child() leaves it unallocated, which can hang the shell);
/// GNOME 46 removed add_actor() and uses set_child().
export function scroll(child, height) {
    const sv = new St.ScrollView({
        hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC,
        overlay_scrollbars: true, style: `max-height: ${height}px;`, x_expand: true,
    });
    const box = new St.BoxLayout({vertical: true, x_expand: true});
    box.add_child(child);
    if (typeof sv.add_actor === 'function')
        sv.add_actor(box);
    else
        sv.set_child(box);
    return sv;
}

/// An image as a rounded tile. `thumb(path, size, done)` (Store.thumbnail) supplies a small copy;
/// until it's ready the tile is a grey placeholder. Full-size images are never handed to St:
/// it decodes CSS background images in the shell's main thread, at full size.
export function imageTile(path, w, h, thumb) {
    const tile = new St.Widget({style_class: 'gnotch-image', style: `width: ${w}px; height: ${h}px;`});
    let alive = true;
    tile.connect('destroy', () => {
        alive = false;
    });
    thumb(path, Math.max(w, h) * 2, small => {
        if (alive && small)
            tile.style = `width: ${w}px; height: ${h}px; background-image: url("file://${encodeURI(small)}");`;
    });
    return tile;
}

function rgba(cr, hex, alpha = 1) {
    const n = parseInt(hex.slice(1), 16);
    cr.setSourceRGBA((n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255, alpha);
}

/// Strokes the pieces from Core.uOutline / trimOutline.
function strokePieces(cr, pieces) {
    for (const p of pieces) {
        if (p.len <= 0)
            continue;
        if (p.kind === 'line') {
            cr.moveTo(p.x0, p.y0);
            cr.lineTo(p.x1, p.y1);
        } else {
            cr.arcNegative(p.cx, p.cy, p.r, p.a0, p.a1);
        }
    }
    cr.stroke();
}

/// The notch outline, top bar edition: a "U" around the indicator, traced as the block runs.
/// `state()` returns {fraction, color, alpha} or null to draw nothing.
export function outlineArea(state) {
    const area = new St.DrawingArea({x_expand: true, y_expand: true, reactive: false});
    area.connect('repaint', a => {
        const cr = a.get_context();
        const [w, h] = a.get_surface_size();
        const s = state();
        if (s) {
            const width = 2.5;
            const u = Core.uOutline(w, h, width / 2 + 1.5);
            cr.setLineCap(Cairo.LineCap.ROUND);
            cr.setLineWidth(width);
            cr.setSourceRGBA(1, 1, 1, 0.12);
            strokePieces(cr, u);
            rgba(cr, s.color, s.alpha);
            strokePieces(cr, Core.trimOutline(u, Math.max(0.01, s.fraction)));
        }
        cr.$dispose();
    });
    return area;
}

/// The big timer ring: a track and the progress arc from 12 o'clock, clockwise.
export function ringArea(size, state) {
    const area = new St.DrawingArea({style: `width: ${size}px; height: ${size}px;`});
    area.connect('repaint', a => {
        const cr = a.get_context();
        const [w, h] = a.get_surface_size();
        const s = state();
        const lw = 10;
        const r = Math.min(w, h) / 2 - lw;
        cr.setLineCap(Cairo.LineCap.ROUND);
        cr.setLineWidth(lw);
        cr.setSourceRGBA(1, 1, 1, 0.08);
        cr.arc(w / 2, h / 2, r, 0, 2 * Math.PI);
        cr.stroke();
        if (s && s.fraction > 0) {
            rgba(cr, s.color, s.alpha);
            cr.arc(w / 2, h / 2, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.min(1, s.fraction));
            cr.stroke();
        }
        cr.$dispose();
    });
    return area;
}

const HEAT_GAP = 2;

/// One day: colour only (no number inside). Hovering reports the day; days ahead are outlined.
/// Sizes and colours come from stylesheet classes (one theme node shared by many cells, instead
/// of parsing an inline style for each of ~400 cells).
function heatCell(day, cell, onHover) {
    if (!day)
        return new St.Widget({style_class: `gnotch-cell gnotch-cell-${cell} gnotch-heat-none`});
    const state = day.level < 0 ? 'gnotch-heat-future' : `gnotch-heat-${day.level}`;
    const w = new St.Widget({
        style_class: `gnotch-cell gnotch-cell-${cell} ${state}${day.today ? ' gnotch-heat-today' : ''}`,
        reactive: !!onHover, track_hover: !!onHover,
    });
    if (onHover) {
        w.connect('enter-event', () => onHover(day.ms));
        w.connect('leave-event', () => onHover(null));
    }
    return w;
}

/// Labels at column positions (month names above the year grid, week numbers below).
function labelRow(labels, cell, width) {
    const rowW = new St.Widget({style: `width: ${width}px; height: 14px;`});
    for (const l of labels) {
        const t = new St.Label({text: l.text, style_class: l.current ? 'gnotch-heat-label gnotch-heat-now' : 'gnotch-heat-label'});
        t.set_position(l.col * (cell + HEAT_GAP), 0);
        rowW.add_child(t);
    }
    return rowW;
}

/// The year (GitHub) view: weeks as columns, Monday on top. `data` comes from Core.heatYear.
export function heatYear(data, cell, onHover, {weekdays = true} = {}) {
    const width = data.columns.length * (cell + HEAT_GAP);
    const grid = new St.BoxLayout({style: `spacing: ${HEAT_GAP}px;`});
    for (const col of data.columns) {
        const c = new St.BoxLayout({vertical: true, style: `spacing: ${HEAT_GAP}px;`});
        col.days.forEach(d => c.add_child(heatCell(d.level < 0 ? null : d, cell, onHover))); // the year view hides days ahead
        grid.add_child(c);
    }
    const body = column([labelRow(data.monthLabels, cell, width), grid, labelRow(data.weekLabels, cell, width)], 'spacing: 2px;');
    if (!weekdays)
        return body;
    const days = new St.BoxLayout({vertical: true, style: `spacing: ${HEAT_GAP}px; padding-top: 16px;`});
    Core.DAY_NAMES.forEach((n, i) => days.add_child(new St.Label({
        text: i % 2 === 0 ? n : '', style_class: 'gnotch-heat-label', style: `height: ${cell}px; font-size: ${Math.max(7, cell * 0.8)}px;`,
    })));
    return row([days, body], 'spacing: 6px;');
}

/// The calendar view: month blocks side by side, days left to right, a week number on every row.
/// `months` comes from Core.heatMonths.
export function heatCalendar(months, cell, perRow, onHover) {
    const numW = Math.round(cell * 1.6);
    const out = column([], `spacing: ${cell}px;`);
    for (let i = 0; i < months.length; i += perRow) {
        const line = row([], `spacing: ${Math.round(cell * 1.3)}px;`);
        for (const m of months.slice(i, i + perRow)) {
            const block = column([], `spacing: ${HEAT_GAP}px;`);
            block.add_child(new St.Label({
                text: m.title, style_class: m.current ? 'gnotch-heat-month gnotch-heat-now' : 'gnotch-heat-month',
                style: `padding-left: ${numW + HEAT_GAP}px;`,
            }));
            const head = row([new St.Widget({style: `width: ${numW}px;`})], `spacing: ${HEAT_GAP}px;`);
            for (const n of Core.DAY_NAMES)
                head.add_child(new St.Label({text: n[0], style_class: 'gnotch-heat-label', style: `width: ${cell}px; text-align: center;`}));
            block.add_child(head);
            for (const w of m.weeks) {
                const r = row([new St.Label({
                    text: `${w.week}`, style_class: w.current ? 'gnotch-heat-label gnotch-heat-now' : 'gnotch-heat-label',
                    style: `width: ${numW}px; height: ${cell}px; text-align: right;`,
                })], `spacing: ${HEAT_GAP}px;`);
                w.days.forEach(d => r.add_child(heatCell(d, cell, onHover)));
                block.add_child(r);
            }
            line.add_child(block);
        }
        out.add_child(line);
    }
    return out;
}

/// A small stat tile for the big timer page.
export function stat(title, value) {
    return column([label(title), new St.Label({text: value, style_class: 'gnotch-stat'})], 'spacing: 2px;');
}
