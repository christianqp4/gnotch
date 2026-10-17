// Files under ~/.local/share/gnotch/: sessions.json and state.json (timer), Clipboard/, VisionBoard/.
// Formats match the Mac app (~/Library/Application Support/GNotch/), so folders can be copied across.

import GdkPixbuf from 'gi://GdkPixbuf';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import * as Core from './core.js';

export const DATA_DIR = GLib.build_filenamev([GLib.get_user_data_dir(), 'gnotch']);

const join = (...parts) => GLib.build_filenamev(parts);

export function readText(path) {
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        return ok ? new TextDecoder().decode(bytes) : null;
    } catch {
        return null; // missing file
    }
}

function readJSON(path) {
    try {
        return JSON.parse(readText(path) ?? 'null');
    } catch {
        return null;
    }
}

export function writeBytes(path, data) {
    Gio.File.new_for_path(path).replace_contents(data, null, false, Gio.FileCreateFlags.REPLACE_DESTINATION, null);
}

const writeText = (path, text) => writeBytes(path, new TextEncoder().encode(text));

function removeFile(path) {
    try {
        Gio.File.new_for_path(path).delete(null);
    } catch {}
}

function imageSize(path) {
    try {
        const [, w, h] = GdkPixbuf.Pixbuf.get_file_info(path);
        return w > 0 && h > 0 ? [w, h] : null;
    } catch {
        return null;
    }
}

const newId = () => GLib.uuid_string_random().toUpperCase();

// MARK: Thumbnails

const THUMBS = GLib.build_filenamev([GLib.get_user_cache_dir(), 'gnotch', 'thumbs']);
const thumbWaiters = new Map(); // thumb path -> callbacks while it's being made
const thumbQueue = [];
let thumbsRunning = 0;

/// Calls `done(path)` with a copy of `path` at most `size` px on its long side (or null).
/// Decoding happens in GdkPixbuf's worker thread, one or two images at a time, and the result is
/// cached in ~/.cache/gnotch/thumbs, so a big screenshot never stalls the shell.
export function thumbnail(path, size, done) {
    const bucket = size <= 192 ? 192 : size <= 384 ? 384 : 768;
    let key;
    try {
        const info = Gio.File.new_for_path(path).query_info('time::modified,standard::size', Gio.FileQueryInfoFlags.NONE, null);
        key = `${path}|${info.get_attribute_uint64('time::modified')}|${info.get_size()}|${bucket}`;
    } catch {
        done(null);
        return;
    }
    const out = join(THUMBS, `${GLib.compute_checksum_for_string(GLib.ChecksumType.SHA1, key, -1)}.png`);
    if (GLib.file_test(out, GLib.FileTest.EXISTS)) {
        done(out);
        return;
    }
    if (thumbWaiters.has(out)) {
        thumbWaiters.get(out).push(done);
        return;
    }
    thumbWaiters.set(out, [done]);
    thumbQueue.push({path, out, bucket});
    pumpThumbs();
}

function pumpThumbs() {
    while (thumbsRunning < 2 && thumbQueue.length) {
        const job = thumbQueue.shift();
        thumbsRunning++;
        const finish = result => {
            thumbsRunning--;
            for (const cb of thumbWaiters.get(job.out) ?? [])
                cb(result);
            thumbWaiters.delete(job.out);
            pumpThumbs();
        };
        Gio.File.new_for_path(job.path).read_async(GLib.PRIORITY_LOW, null, (file, res) => {
            let stream;
            try {
                stream = file.read_finish(res);
            } catch {
                finish(null);
                return;
            }
            GdkPixbuf.Pixbuf.new_from_stream_at_scale_async(stream, job.bucket, job.bucket, true, null, (_s, r) => {
                try {
                    const pixbuf = GdkPixbuf.Pixbuf.new_from_stream_finish(r);
                    GLib.mkdir_with_parents(THUMBS, 0o700);
                    pixbuf.savev(job.out, 'png', [], []);
                    finish(job.out);
                } catch {
                    finish(null);
                }
                try {
                    stream.close(null);
                } catch {}
            });
        });
    }
}

/// Writes in the background (for images that can be several MB).
function writeBytesAsync(path, bytes, done) {
    Gio.File.new_for_path(path).replace_contents_bytes_async(bytes, null, false,
        Gio.FileCreateFlags.REPLACE_DESTINATION, null, (f, res) => {
            try {
                f.replace_contents_finish(res);
                done?.(true);
            } catch (e) {
                console.warn(`GNotch: couldn't write ${path}: ${e}`);
                done?.(false);
            }
        });
}

/// Texts longer than this aren't kept: a huge history.json would be re-read and re-written on every copy.
export const CLIP_MAX_TEXT = 200_000;

/// Keeps a broken file aside instead of overwriting it.
function backUp(path, text, why) {
    const backup = path.replace(/\.json$/, `.unreadable-${Math.floor(Date.now() / 1000)}.json`);
    if (text)
        writeText(backup, text);
    console.warn(`GNotch: ${path} unreadable (${why}), backed up to ${backup}`);
}

// MARK: Sessions + state

export class Storage {
    constructor() {
        this.dir = DATA_DIR;
        GLib.mkdir_with_parents(this.dir, 0o755);
        this.sessionsPath = join(this.dir, 'sessions.json');
        this.statePath = join(this.dir, 'state.json');
        this.sessions = [];
        this.loadSessions();
        this.state = readJSON(this.statePath) ?? {};
    }

    loadSessions() {
        const text = readText(this.sessionsPath);
        try {
            this.sessions = Core.parseSessions(text);
        } catch (e) {
            backUp(this.sessionsPath, text, e);
            this.sessions = [];
        }
    }

    /// Re-reads first so blocks another client appended in the meantime survive.
    addSession(session) {
        this.loadSessions();
        this.sessions.push(session);
        writeText(this.sessionsPath, Core.serializeSessions(this.sessions));
    }

    saveState() {
        writeText(this.statePath, `${JSON.stringify(this.state, null, 2)}\n`);
    }
}

// MARK: Vision board

export class VisionBoard {
    constructor() {
        this.dir = join(DATA_DIR, 'VisionBoard');
        GLib.mkdir_with_parents(this.dir, 0o755);
        this.path = join(this.dir, 'board.json');
        this.load();
    }

    load() {
        const text = readText(this.path);
        try {
            const list = text ? JSON.parse(text) : [];
            if (!Array.isArray(list))
                throw new Error('not a list');
            this.items = Core.visionOrdered(list).map((it, i) => {
                if (it.cols && it.rows && it.order !== undefined)
                    return it;
                const [cols, rows] = Core.visionDefaultSize(it);
                return {...it, order: it.order ?? i, cols: it.cols ?? cols, rows: it.rows ?? rows};
            });
        } catch (e) {
            backUp(this.path, text, e);
            this.items = [];
        }
    }

    save() {
        writeText(this.path, `${JSON.stringify(this.items)}\n`);
    }

    get ordered() { return Core.visionOrdered(this.items); }

    imagePath(item) { return item.imageFile ? join(this.dir, item.imageFile) : null; }

    _insert(item) {
        const [cols, rows] = Core.visionDefaultSize(item);
        this.items = Core.visionInsertFirst(this.items, [{...item, cols, rows}]);
        this.save();
    }

    _imageItem(id, name) {
        const size = imageSize(join(this.dir, name));
        const aspect = size ? Math.max(0.3, Math.min(3.5, size[0] / size[1])) : 1;
        return {id, kind: 'image', date: Core.isoDate(Date.now()), imageFile: name, aspect: Math.round(aspect * 100) / 100};
    }

    addText(text) {
        const t = (text ?? '').trim();
        if (!t)
            return false;
        this._insert({id: newId(), kind: 'text', date: Core.isoDate(Date.now()), text: t.slice(0, 400)});
        return true;
    }

    /// `bytes` is a GLib.Bytes (from the clipboard). Saved in the background, then added.
    addImageBytes(bytes, done) {
        const id = newId();
        const name = `${id}.png`;
        writeBytesAsync(join(this.dir, name), bytes, ok => {
            if (ok)
                this._insert(this._imageItem(id, name));
            done?.(ok);
        });
    }

    addImageFile(path) {
        const ext = (path.split('.').pop() ?? 'png').toLowerCase();
        if (!imageSize(path))
            return false;
        const id = newId();
        const name = `${id}.${ext}`;
        Gio.File.new_for_path(path).copy(Gio.File.new_for_path(join(this.dir, name)), Gio.FileCopyFlags.NONE, null, null);
        this._insert(this._imageItem(id, name));
        return true;
    }

    resize(id) {
        this.items = this.items.map(it => {
            if (it.id !== id)
                return it;
            const [cols, rows] = Core.nextVisionSize(it);
            return {...it, cols, rows};
        });
        this.save();
    }

    move(id, delta) {
        this.items = Core.visionMove(this.items, id, delta);
        this.save();
    }

    tidy() {
        this.items = Core.visionTidy(this.items);
        this.save();
    }

    remove(id) {
        const item = this.items.find(it => it.id === id);
        if (item?.imageFile)
            removeFile(this.imagePath(item));
        this.items = this.items.filter(it => it.id !== id);
        this.save();
    }
}

// MARK: Clipboard history

export class ClipHistory {
    constructor() {
        this.dir = join(DATA_DIR, 'Clipboard');
        this.imagesDir = join(this.dir, 'images');
        GLib.mkdir_with_parents(this.imagesDir, 0o700);
        this.path = join(this.dir, 'history.json');
        const text = readText(this.path);
        try {
            this.items = text ? JSON.parse(text) : [];
            if (!Array.isArray(this.items))
                throw new Error('not a list');
        } catch (e) {
            backUp(this.path, text, e);
            this.items = [];
        }
    }

    save() {
        writeText(this.path, `${JSON.stringify(this.items)}\n`);
    }

    imagePath(item) { return item.imageFile ? join(this.imagesDir, item.imageFile) : null; }

    _add(item) {
        const {items, dropped} = Core.clipAdd(this.items, {pinned: false, date: Core.isoDate(Date.now()), ...item});
        this.items = items;
        for (const d of dropped) {
            if (d.imageFile)
                removeFile(this.imagePath(d));
        }
        this.save();
    }

    addText(text, sourceApp) {
        if (!text || !text.trim() || text.length > CLIP_MAX_TEXT)
            return;
        const signature = `t:${GLib.compute_checksum_for_string(GLib.ChecksumType.SHA1, text, -1)}`;
        this._add({id: newId(), kind: 'text', text, sourceApp, signature});
    }

    addFiles(paths, sourceApp) {
        const signature = `f:${paths.join('\n')}`;
        this._add({id: newId(), kind: 'file', paths, sourceApp, signature});
    }

    /// `bytes` is a GLib.Bytes. Written in the background; `done()` runs once it's in the history.
    addImage(bytes, sourceApp, done) {
        const signature = `i:${GLib.compute_checksum_for_bytes(GLib.ChecksumType.SHA1, bytes)}`;
        const existing = this.items.find(i => i.signature === signature);
        if (existing) {
            this._add({...existing}); // just moves it to the top
            done?.();
            return;
        }
        const id = newId();
        const name = `${id}.png`;
        const path = join(this.imagesDir, name);
        writeBytesAsync(path, bytes, ok => {
            if (!ok)
                return;
            const size = imageSize(path);
            this._add({id, kind: 'image', imageFile: name, imageWidth: size?.[0], imageHeight: size?.[1], sourceApp, signature});
            done?.();
        });
    }

    togglePin(id) {
        this.items = this.items.map(i => (i.id === id ? {...i, pinned: !i.pinned} : i));
        this.save();
    }

    remove(id) {
        const item = this.items.find(i => i.id === id);
        if (item?.imageFile)
            removeFile(this.imagePath(item));
        this.items = this.items.filter(i => i.id !== id);
        this.save();
    }

    /// Clears everything except pins.
    clear() {
        for (const i of this.items) {
            if (!i.pinned && i.imageFile)
                removeFile(this.imagePath(i));
        }
        this.items = this.items.filter(i => i.pinned);
        this.save();
    }
}

/// Newest screenshots in ~/Pictures/Screenshots (where Ubuntu's Print Screen saves them).
export function listScreenshots(limit = 40) {
    const pictures = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_PICTURES) ?? join(GLib.get_home_dir(), 'Pictures');
    const dir = Gio.File.new_for_path(join(pictures, 'Screenshots'));
    const out = [];
    try {
        const en = dir.enumerate_children('standard::name,standard::content-type,time::modified', Gio.FileQueryInfoFlags.NONE, null);
        let info;
        while ((info = en.next_file(null)) !== null) {
            if ((info.get_content_type() ?? '').startsWith('image/'))
                out.push({path: join(dir.get_path(), info.get_name()), name: info.get_name(), mtime: info.get_attribute_uint64('time::modified')});
        }
        en.close(null);
    } catch {
        return [];
    }
    return out.sort((a, b) => b.mtime - a.mtime).slice(0, limit);
}
