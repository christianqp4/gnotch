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

const ME = 'const Me = imports.misc.extensionUtils.getCurrentExtension();';

/// Converts one ES module to GNOME 42's old module system, where a file's top-level `var`s and
/// functions are its exports (`const` and `class` are not), and imports go through `imports.*`.
export function legacyModule(src, {entry = false} = {}) {
    let out = src
        .replace(/^import (\w+) from 'gi:\/\/(\w+)';$/gm, 'const $1 = imports.gi.$2;')
        .replace(/^import Cairo from 'cairo';$/m, 'const Cairo = imports.cairo;')
        .replace(/^import \* as (\w+) from 'resource:\/\/\/org\/gnome\/shell\/(ui|misc)\/(\w+)\.js';$/gm, 'const $1 = imports.$2.$3;')
        .replace(/^import \{Extension\} from 'resource:\/\/\/org\/gnome\/shell\/extensions\/extension\.js';$/m,
            'class Extension {\n    constructor() {\n        this.path = Me.path;\n        this.uuid = Me.metadata.uuid;\n    }\n}')
        .replace(/^import \* as (\w+) from '\.\/(\w+)\.js';$/gm, 'const $1 = Me.imports.$2;')
        .replace(/^export default class (\w+)/m, 'class $1')
        .replace(/^export const /gm, 'var ')
        .replace(/^export class (\w+)/gm, 'var $1 = class $1')
        .replace(/^export function /gm, 'function ');
    if (/\bMe\./.test(out)) {
        const firstImport = out.search(/^const \w+ = imports\./m);
        out = firstImport >= 0 ? `${out.slice(0, firstImport)}${ME}\n${out.slice(firstImport)}` : `${ME}\n${out}`;
    }
    if (entry)
        out += '\n// GNOME 42–44 entry point.\nfunction init() {\n    return new GNotchExtension();\n}\n';
    const left = out.match(/^\s*(import|export)\b.*$/m);
    if (left)
        throw new Error(`unconverted line: ${left[0]}`);
    return out;
}

export function build() {
    fs.rmSync(OUT, {recursive: true, force: true});
    const modern = path.join(OUT, '45', UUID);
    const legacy = path.join(OUT, '42', UUID);
    fs.cpSync(SRC, modern, {recursive: true, filter: f => !f.endsWith('.DS_Store')});
    fs.cpSync(SRC, legacy, {recursive: true, filter: f => !f.endsWith('.DS_Store')});

    for (const file of fs.readdirSync(SRC).filter(f => f.endsWith('.js'))) {
        const src = fs.readFileSync(path.join(SRC, file), 'utf8');
        fs.writeFileSync(path.join(legacy, file), legacyModule(src, {entry: file === 'extension.js'}));
    }
    const meta = JSON.parse(fs.readFileSync(path.join(SRC, 'metadata.json'), 'utf8'));
    meta['shell-version'] = LEGACY_SHELL;
    fs.writeFileSync(path.join(legacy, 'metadata.json'), `${JSON.stringify(meta, null, 2)}\n`);
    return {modern, legacy, version: meta['version-name']};
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const {modern, legacy} = build();
    console.log(`${path.relative(process.cwd(), modern)}\n${path.relative(process.cwd(), legacy)}`);
}
