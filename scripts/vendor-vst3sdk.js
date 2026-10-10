// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Vendors the subset of the VST3 SDK that the plugin and the validator
// compile (decision build-001, ticket 24).
//
// The SDK's own CMake modules name the translation units of each library:
// `base`, `pluginterfaces`, `sdk_common`, `sdk` and `sdk_hosting` in
// cmake/modules/SMTG_VST3_SDK.cmake, the validator in its CMakeLists.txt.
// The script reads those lists, keeps the macOS sources, collects their
// header closure with `clang -MM`, copies sources, headers and license files
// into the destination and writes the manifests the build script reads:
//
// - SOURCES.txt: the translation units of a plugin,
// - VALIDATOR_SOURCES.txt: those of the validator,
// - INCLUDES.txt: every header the two include.
//
// Without --sdk the script clones the SDK at the pinned tag into
// .dart_tool/vst3sdk-<tag>, with the submodules it needs.
//
// Usage:
//   node scripts/vendor-vst3sdk.js [--sdk <checkout>] [--tag <tag>]
//     [--dest src/third_party/vst3sdk]

'use strict';

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const defaultTag = 'v3.8.1_build_84';
const submodules = ['base', 'pluginterfaces', 'public.sdk', 'cmake'];

// The SDK file that holds the plugin's macOS entry points.
const macMain = 'public.sdk/source/main/macmain.cpp';
// The base class of a plugin whose processor and controller are one object.
const singleComponent = 'public.sdk/source/vst/vstsinglecomponenteffect.cpp';
// The SDK file that loads a bundle in the validator on macOS.
const moduleMac = 'public.sdk/source/vst/hosting/module_mac.mm';

function option(args, name, fallback) {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback;
}

function run(command, args, cwd) {
  return execFileSync(command, args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: 64 * 1024 * 1024,
  });
}

// Clones the SDK at `tag` with the submodules it needs, unless it exists.
function checkout(tag) {
  const dir = path.join(root, '.dart_tool', `vst3sdk-${tag}`);
  if (fs.existsSync(path.join(dir, 'public.sdk', 'source'))) return dir;
  fs.mkdirSync(path.dirname(dir), { recursive: true });
  run('git', [
    'clone',
    '--quiet',
    '--depth',
    '1',
    '--branch',
    tag,
    'https://github.com/steinbergmedia/vst3sdk.git',
    dir,
  ]);
  run('git', ['submodule', 'update', '--init', '--depth', '1', ...submodules], dir);
  return dir;
}

// The .cpp and .mm files a CMake list names, relative to the SDK root.
function sourcesOf(text) {
  const result = [];
  const pattern = /\$\{SDK_ROOT\}\/([^\s)"]+\.(?:cpp|mm))/g;
  for (const match of text.matchAll(pattern)) result.push(match[1]);
  return result;
}

// The body of the CMake function `name` in `text`.
function functionBody(text, name) {
  const start = text.indexOf(`function(${name})`);
  if (start < 0) throw new Error(`CMake function ${name} not found`);
  const end = text.indexOf('endfunction()', start);
  return text.slice(start, end);
}

function isMacSource(file) {
  return !/_(win32|linux)\.(cpp|mm)$/.test(file);
}

function unique(list) {
  return [...new Set(list)];
}

// The translation units of the plugin and the validator.
function translationUnits(sdk) {
  const modules = fs.readFileSync(
    path.join(sdk, 'cmake', 'modules', 'SMTG_VST3_SDK.cmake'),
    'utf8',
  );
  const lib = (name) => sourcesOf(functionBody(modules, name));
  const base = lib('smtg_create_lib_base_target');
  const interfaces = lib('smtg_create_pluginterfaces_target');
  const common = lib('smtg_create_public_sdk_common_target');
  const sdkLib = lib('smtg_create_public_sdk_target');
  const hosting = lib('smtg_create_public_sdk_hosting_target');
  const validatorList = fs.readFileSync(
    path.join(
      sdk,
      'public.sdk',
      'samples',
      'vst-hosting',
      'validator',
      'CMakeLists.txt',
    ),
    'utf8',
  );
  const validatorDir = 'public.sdk/samples/vst-hosting/validator';
  const validatorOwn = [...validatorList.matchAll(/^\s*(source\/[^\s]+\.cpp)/gm)]
    .map((match) => `${validatorDir}/${match[1]}`);
  const plugin = unique(
    [
      ...base,
      ...interfaces,
      ...common,
      ...sdkLib,
      singleComponent,
      macMain,
    ].filter(isMacSource),
  );
  const validator = unique(
    [
      ...base,
      ...interfaces,
      ...common,
      ...hosting,
      ...sourcesOf(validatorList),
      ...validatorOwn,
      moduleMac,
    ].filter(isMacSource),
  );
  return { plugin, validator };
}

// The headers inside the SDK that `files` include, relative to the SDK.
function headerClosure(sdk, files) {
  const headers = new Set();
  for (const file of files) {
    const objc = file.endsWith('.mm');
    const output = run(
      'clang++',
      [
        '-MM',
        '-x',
        objc ? 'objective-c++' : 'c++',
        ...(objc ? ['-fobjc-arc'] : []),
        '-std=c++17',
        '-DRELEASE=1',
        '-DSMTG_USE_STDATOMIC_H=1',
        '-I',
        sdk,
        path.join(sdk, file),
      ],
      sdk,
    );
    const dependencies = output
      .replace(/\\\n/g, ' ')
      .split(/\s+/)
      .slice(1)
      .filter(Boolean);
    for (const dependency of dependencies) {
      const absolute = path.resolve(sdk, dependency);
      const relative = path.relative(sdk, absolute);
      if (relative.startsWith('..') || path.isAbsolute(relative)) continue;
      if (/\.(cpp|mm)$/.test(relative)) continue;
      headers.add(relative);
    }
  }
  return [...headers].sort();
}

function copy(sdk, dest, relative) {
  const target = path.join(dest, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(path.join(sdk, relative), target);
}

function commitOf(dir) {
  return run('git', ['rev-parse', '--short', 'HEAD'], dir).trim();
}

function notices(sdk, tag) {
  const commits = submodules
    .filter((name) => name !== 'cmake')
    .map((name) => `\`${name}\` ${commitOf(path.join(sdk, name))}`)
    .join(', ');
  const today = new Date().toISOString().slice(0, 10);
  return `# Third-party notices of aud_audio_vst3

\`vst3sdk\` holds the subset of the VST3 SDK that the plugin and the
validator compile: the translation units the SDK's CMake modules list for
the libraries \`base\`, \`pluginterfaces\`, \`sdk_common\`, \`sdk\` and
\`sdk_hosting\` and for the validator (macOS only), the entry points of
\`macmain.cpp\`, the single-component base class
\`vstsinglecomponenteffect.cpp\`, and the headers they include. The
manifests are \`vst3sdk/SOURCES.txt\` (a plugin),
\`vst3sdk/VALIDATOR_SOURCES.txt\` (the validator) and
\`vst3sdk/INCLUDES.txt\` (the headers). Source:
https://github.com/steinbergmedia/vst3sdk at tag \`${tag}\` (${commits}),
vendored on ${today} for ticket 24 by \`scripts/vendor-vst3sdk.js\`.

| Component | Path | Version | License |
| --- | --- | --- | --- |
| VST 3 SDK | \`vst3sdk/base\`, \`vst3sdk/pluginterfaces\`, \`vst3sdk/public.sdk\` | ${tag} | MIT, \`vst3sdk/LICENSE.txt\` and the \`LICENSE.txt\` of each folder |
| json.h | \`vst3sdk/public.sdk/source/vst/moduleinfo/json.h\` | ${tag} | Unlicense (public domain), header of the file |

The editor app (\`editor/\`) carries the Flutter engine and framework
(BSD-3-Clause) into the bundles: in \`Contents/Helpers\` for the variants
A, S and F, in \`Contents/Frameworks\` for B. \`flutter build\` writes
their notices and those of every Dart package into the app's
\`flutter_assets/NOTICES.Z\`, which travels with it. \`build-plugin.js\`
copies these notices and \`vst3sdk/LICENSE.txt\` into each bundle's
\`Contents/Resources\`.

VST is a registered trademark of Steinberg Media Technologies GmbH.
`;
}

function main() {
  const args = process.argv.slice(2);
  const tag = option(args, '--tag', defaultTag);
  const sdk = path.resolve(option(args, '--sdk', '') || checkout(tag));
  const dest = path.resolve(
    root,
    option(args, '--dest', path.join('src', 'third_party', 'vst3sdk')),
  );
  const { plugin, validator } = translationUnits(sdk);
  const headers = headerClosure(sdk, unique([...plugin, ...validator]));
  fs.rmSync(dest, { recursive: true, force: true });
  for (const file of unique([...plugin, ...validator, ...headers])) {
    copy(sdk, dest, file);
  }
  for (const license of [
    'LICENSE.txt',
    'base/LICENSE.txt',
    'pluginterfaces/LICENSE.txt',
    'public.sdk/LICENSE.txt',
  ]) {
    copy(sdk, dest, license);
  }
  fs.writeFileSync(path.join(dest, 'SOURCES.txt'), `${plugin.join('\n')}\n`);
  fs.writeFileSync(
    path.join(dest, 'VALIDATOR_SOURCES.txt'),
    `${validator.join('\n')}\n`,
  );
  fs.writeFileSync(path.join(dest, 'INCLUDES.txt'), `${headers.join('\n')}\n`);
  fs.writeFileSync(path.join(path.dirname(dest), 'NOTICES.md'), notices(sdk, tag));
  console.log(
    `Vendored ${plugin.length} plugin and ${validator.length} validator ` +
      `sources with ${headers.length} headers into ${path.relative(root, dest)}`,
  );
}

main();
