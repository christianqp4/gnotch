// Builds both variants of the extension from the one ES-module source:
//   build/45/<uuid>  GNOME 45–49 (ES modules): a copy of the source
//   build/42/<uuid>  GNOME 42–44 (Ubuntu 22.04): converted to the old imports.* module system
// Usage: node linux/gnome-extension/build.mjs
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const UUID = 'gnotch@christianqp4.github.io';
const SRC = path.join(HERE, UUID);
const OUT = path.join(HERE, 'build');

const LEGACY_SHELL = ['42', '43', '44'];

/// Old-style modules export their top-level `var`s and functions, but not `const`/`class`.
export function legacyCore(src) {
    const out = src
        .replace(/^export const /gm, 'var ')
        .replace(/^export class (\w+)/gm, 'var $1 = class $1')
        .replace(/^export function /gm, 'function ');
    if (/^\s*(import|export)\b/m.test(out))
        throw new Error('core.js: unconverted import/export left');
    return out;
}

export function legacyExtension(src) {
    const shims = {
        "import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';":
            'const Me = imports.misc.extensionUtils.getCurrentExtension();\n' +
            'class Extension {\n    constructor() {\n        this.path = Me.path;\n        this.uuid = Me.metadata.uuid;\n    }\n}',
        "import * as Main from 'resource:///org/gnome/shell/ui/main.js';": 'const Main = imports.ui.main;',
        "import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';": 'const PanelMenu = imports.ui.panelMenu;',
        "import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';": 'const PopupMenu = imports.ui.popupMenu;',
        "import * as Core from './core.js';": 'const Core = Me.imports.core;',
    };
    let out = src.replace(/^import (\w+) from 'gi:\/\/(\w+)';$/gm, 'const $1 = imports.gi.$2;');
    for (const [from, to] of Object.entries(shims)) {
        if (!out.includes(from))
            throw new Error(`extension.js: expected import not found: ${from}`);
        out = out.replace(from, to);
    }
    out = out.replace(/^export default class (\w+)/m, 'class $1');
    out += '\n// GNOME 42–44 entry point.\nfunction init() {\n    return new GNotchExtension();\n}\n';
    if (/^\s*(import|export)\b/m.test(out))
        throw new Error('extension.js: unconverted import/export left');
    return out;
}

export function build() {
    fs.rmSync(OUT, {recursive: true, force: true});
    const modern = path.join(OUT, '45', UUID);
    const legacy = path.join(OUT, '42', UUID);
    fs.cpSync(SRC, modern, {recursive: true, filter: f => !f.endsWith('.DS_Store')});
    fs.cpSync(SRC, legacy, {recursive: true, filter: f => !f.endsWith('.DS_Store')});

    fs.writeFileSync(path.join(legacy, 'core.js'), legacyCore(fs.readFileSync(path.join(SRC, 'core.js'), 'utf8')));
    fs.writeFileSync(path.join(legacy, 'extension.js'), legacyExtension(fs.readFileSync(path.join(SRC, 'extension.js'), 'utf8')));
    const meta = JSON.parse(fs.readFileSync(path.join(SRC, 'metadata.json'), 'utf8'));
    meta['shell-version'] = LEGACY_SHELL;
    fs.writeFileSync(path.join(legacy, 'metadata.json'), `${JSON.stringify(meta, null, 2)}\n`);
    return {modern, legacy, version: meta['version-name']};
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const {modern, legacy} = build();
    console.log(`${path.relative(process.cwd(), modern)}\n${path.relative(process.cwd(), legacy)}`);
}
