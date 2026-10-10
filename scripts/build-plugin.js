// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds the VST3 bundles of the spike S0-plugin-ui (ticket 24) with clang,
// without CMake (decision 4 of the plan review): the vendored SDK subset
// (src/third_party/vst3sdk/SOURCES.txt), the graph engine and the plugin.
// The graph and the core come from the package config, as the graph's build
// hook resolves them (build-001); flavor 2 builds against the graph and the
// core at tag 0.3.0, cloned into .dart_tool.
//
// Every bundle exports only the three VST3 entry points and hides all other
// symbols (-fvisibility=hidden, an exported-symbols list), so two
// aud_audio-based plugins in one process never share code; --no-hygiene
// builds the control bundle of that test without both.
//
// Objects are cached under .dart_tool/vst3-build by the hash of their
// source, the flags and all headers the build may include.
//
//   node scripts/build-plugin.js                    variants A, S, F, B, C, D
//   node scripts/build-plugin.js --variant C        one variant
//   node scripts/build-plugin.js --flavor 2         against graph 0.3.0
//   node scripts/build-plugin.js --no-hygiene       the collision control
//   node scripts/build-plugin.js --rtsan            RealtimeSanitizer
//   node scripts/build-plugin.js --watchdog         the graph's watchdog
//   node scripts/build-plugin.js --install          copy to the user's
//                                                   VST3 folder
//   node scripts/build-plugin.js --editor           build the Flutter editor
//                                                   and put it into bundles A,
//                                                   S, F, and in process into B
//   node scripts/build-plugin.js --flutter <flutter>  the Flutter SDK of the
//                                                   editor, its folder or its
//                                                   bin/flutter (the B test
//                                                   with two Flutter versions)
//
// Variant B carries the editor in process: a copy of FlutterMacOS.framework
// whose name, Objective-C classes and Swift module start with a random
// prefix of the same length as `Flutter`, so that two plugins with two
// Flutter versions do not share classes, and the editor's AOT framework.

'use strict';

const { createHash } = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const sdkDir = path.join(root, 'src', 'third_party', 'vst3sdk');
const buildDir = path.join(root, '.dart_tool', 'vst3-build');
const outDir = path.join(root, 'build', 'vst3');
const installDir = path.join(
  os.homedir(),
  'Library',
  'Audio',
  'Plug-Ins',
  'VST3',
);

// The plugin's own sources; the view of the variant is added per build.
const pluginSources = [
  'src/aud_vst3_engine.cpp',
  'src/aud_vst3_factory.cpp',
  'src/aud_vst3_param.cpp',
  'src/aud_vst3_plugin.cpp',
  'src/aud_vst3_probe.cpp',
  'src/aud_vst3_skew.cpp',
];

const variantSources = {
  A: [
    'src/aud_vst3_driver.mm',
    'src/aud_vst3_objc.mm',
    'src/aud_vst3_remote_view.mm',
    'src/aud_vst3_socket.cpp',
    'src/aud_vst3_surfaces.mm',
  ],
  B: [
    'src/aud_vst3_driver.mm',
    'src/aud_vst3_objc.mm',
    'src/aud_vst3_flutter_view.mm',
  ],
  S: [
    'src/aud_vst3_driver.mm',
    'src/aud_vst3_objc.mm',
    'src/aud_vst3_remote_view.mm',
    'src/aud_vst3_socket.cpp',
    'src/aud_vst3_surfaces.mm',
  ],
  F: [
    'src/aud_vst3_driver.mm',
    'src/aud_vst3_objc.mm',
    'src/aud_vst3_remote_view.mm',
    'src/aud_vst3_socket.cpp',
    'src/aud_vst3_surfaces.mm',
  ],
  C: [
    'src/aud_vst3_driver.mm',
    'src/aud_vst3_objc.mm',
    'src/aud_vst3_native_view.mm',
  ],
  D: [],
};

const frameworks = ['Cocoa', 'CoreAudio', 'CoreGraphics', 'IOSurface', 'QuartzCore'];

function parseArgs(argv) {
  const options = {
    variants: [],
    flavor: 1,
    hygiene: true,
    rtsan: false,
    watchdog: false,
    flutter: 'flutter',
    install: false,
    editor: false,
  };
  for (let i = 0; i < argv.length; ++i) {
    const arg = argv[i];
    if (arg === '--variant') options.variants.push(argv[++i].toUpperCase());
    else if (arg === '--flavor') options.flavor = Number(argv[++i]);
    else if (arg === '--no-hygiene') options.hygiene = false;
    else if (arg === '--rtsan') options.rtsan = true;
    else if (arg === '--watchdog') options.watchdog = true;
    else if (arg === '--install') options.install = true;
    else if (arg === '--editor') options.editor = true;
    else if (arg === '--flutter') {
      const sdk = argv[++i];
      const isDir = fs.existsSync(sdk) && fs.statSync(sdk).isDirectory();
      options.flutter = isDir ? path.join(sdk, 'bin', 'flutter') : sdk;
    }
    else throw new Error(`Unknown option ${arg}`);
  }
  if (options.variants.length === 0) {
    options.variants = ['A', 'S', 'F', 'B', 'C', 'D'];
  }
  for (const variant of options.variants) {
    if (!variantSources[variant]) throw new Error(`Unknown variant ${variant}`);
  }
  if (options.flavor !== 1 && options.flavor !== 2) {
    throw new Error('The flavor is 1 or 2');
  }
  return options;
}

function run(command, args, cwd = root) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
  if (result.error) throw new Error(`${command} failed: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(
      `${path.basename(command)} failed:\n${result.stdout}${result.stderr}`,
    );
  }
  return result.stdout;
}

// The `src` directory of a package, resolved through the package config.
function packageSrc(name) {
  const configPath = path.join(root, '.dart_tool', 'package_config.json');
  if (!fs.existsSync(configPath)) {
    throw new Error(`Run dart pub get first: ${configPath} is missing`);
  }
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const entry = config.packages.find((p) => p.name === name);
  if (!entry) throw new Error(`Package ${name} is not in the package config`);
  const rootUri = new URL(entry.rootUri, `file://${configPath}`);
  return path.join(decodeURIComponent(rootUri.pathname), 'src');
}

// The `src` directory of a family package at `tag`, cloned into .dart_tool.
function taggedSrc(name, tag) {
  const dir = path.join(root, '.dart_tool', `${name}-${tag}`);
  if (!fs.existsSync(path.join(dir, 'src'))) {
    run('git', [
      'clone',
      '--quiet',
      '--depth',
      '1',
      '--branch',
      tag,
      `git@github.com:audaudio/${name}.git`,
      dir,
    ]);
  }
  return path.join(dir, 'src');
}

function engineDirs(flavor) {
  if (flavor === 2) {
    return {
      graph: taggedSrc('aud_audio_graph', '0.3.0'),
      core: taggedSrc('aud_audio_core', '0.3.0'),
    };
  }
  return { graph: packageSrc('aud_audio_graph'), core: packageSrc('aud_audio_core') };
}

function readList(file) {
  return fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
}

function hashOf(parts) {
  const hash = createHash('sha256');
  for (const part of parts) hash.update(part).update('\0');
  return hash.digest('hex').slice(0, 20);
}

// The compiler: Apple's clang, or LLVM from Homebrew for RealtimeSanitizer.
function compilerOf(options) {
  if (!options.rtsan) return 'clang++';
  for (const candidate of [
    process.env.AUD_RTSAN_CXX,
    '/opt/homebrew/opt/llvm/bin/clang++',
    '/usr/local/opt/llvm/bin/clang++',
  ].filter(Boolean)) {
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error('RealtimeSanitizer needs LLVM from Homebrew');
}

function flagsOf(options, variant, dirs, prefix) {
  const flags = [
    '-arch',
    'arm64',
    '-mmacosx-version-min=12.0',
    '-O2',
    '-g',
    '-DRELEASE=1',
    '-DSMTG_USE_STDATOMIC_H=1',
    `-DAUD_VST3_VARIANT='${variant}'`,
    `-DAUD_VST3_FLAVOR=${options.flavor}`,
    `-DAUD_VST3_FLUTTER_PREFIX="${prefix}"`,
    '-I',
    sdkDir,
    '-I',
    dirs.graph,
    '-I',
    dirs.core,
    '-I',
    path.join(root, 'src'),
  ];
  if (options.hygiene) {
    flags.push('-fvisibility=hidden', '-fvisibility-inlines-hidden');
  } else {
    flags.push('-DAUD_VST3_NO_HYGIENE=1');
  }
  if (options.rtsan) {
    // The graph and the plugin mark their realtime path nonblocking, so the
    // sanitizer checks everything a block calls (ticket 20, decision 8).
    // Without the watchdog: its thread-local makes dyld allocate on the
    // first block of every audio thread in a plugin bundle (finding).
    flags.push(
      '-fsanitize=realtime',
      '-DAUD_GRAPH_RTSAN=1',
      '-DAUD_VST3_RTSAN=1',
      '-Wno-function-effects',
    );
  }
  if (options.watchdog) flags.push('-DAUD_GRAPH_WATCHDOG=1');
  return flags;
}

function languageFlags(file) {
  if (file.endsWith('.mm')) return ['-x', 'objective-c++', '-std=c++17', '-fobjc-arc'];
  if (file.endsWith('.c')) return ['-x', 'c', '-std=c11'];
  return ['-x', 'c++', '-std=c++17'];
}

// One hash over every header the builds may include: a header change
// rebuilds everything, an unchanged tree compiles nothing.
function headersHash(dirs) {
  const files = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (/\.(h|hpp)$/.test(entry.name)) files.push(full);
    }
  };
  for (const dir of dirs) walk(dir);
  return hashOf(files.sort().map((file) => file + fs.readFileSync(file, "utf8")));
}

async function compileAll(compiler, flags, files, objDir, headers) {
  fs.mkdirSync(objDir, { recursive: true });
  const jobs = files.map((file) => {
    const key = hashOf([
      compiler,
      ...flags,
      headers,
      file,
      fs.readFileSync(file, 'utf8'),
    ]);
    const object = path.join(objDir, `${path.basename(file)}-${key}.o`);
    return { file, object };
  });
  const pending = jobs.filter((job) => !fs.existsSync(job.object));
  const limit = Math.max(1, os.cpus().length);
  let next = 0;
  const failures = [];
  async function worker() {
    while (next < pending.length) {
      const job = pending[next++];
      const args = [
        ...flags,
        ...languageFlags(job.file),
        '-c',
        job.file,
        '-o',
        `${job.object}.tmp`,
      ];
      const code = await new Promise((resolve) => {
        const child = spawn(compiler, args, { cwd: root, stdio: 'inherit' });
        child.on('close', resolve);
      });
      if (code === 0) fs.renameSync(`${job.object}.tmp`, job.object);
      else failures.push(job.file);
    }
  }
  await Promise.all(Array.from({ length: limit }, worker));
  if (failures.length > 0) {
    throw new Error(`Compilation failed: ${failures.join(', ')}`);
  }
  return jobs.map((job) => job.object);
}

function infoPlist(name, identifier, executable) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>English</string>
  <key>CFBundleExecutable</key>
  <string>${executable}</string>
  <key>CFBundleIdentifier</key>
  <string>${identifier}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${name}</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleSignature</key>
  <string>????</string>
  <key>CFBundleVersion</key>
  <string>0.1.0</string>
</dict>
</plist>
`;
}

// A prefix of the length of `Flutter`, a letter and six hex digits, kept in
// .dart_tool so that rebuilding a bundle keeps its prefix.
function flutterPrefix(bundleName) {
  const file = path.join(buildDir, `${bundleName}.prefix`);
  if (fs.existsSync(file)) return fs.readFileSync(file, 'utf8').trim();
  const prefix = `F${createHash('sha256').update(`${bundleName}${Math.random()}`).digest('hex').slice(0, 6)}`;
  fs.mkdirSync(buildDir, { recursive: true });
  fs.writeFileSync(file, prefix);
  return prefix;
}

// Puts the editor of `editorApp` into `bundle` for variant B: its AOT
// framework as is, and FlutterMacOS.framework as `<prefix>MacOS.framework`,
// thinned to arm64, with every `Flutter` in its binary - class, protocol
// and Swift module names, the install name - and in its Info.plist
// replaced by the prefix.
function embedInProcessFlutter(bundle, editorApp, prefix) {
  const frameworks = path.join(bundle, 'Contents', 'Frameworks');
  fs.mkdirSync(frameworks, { recursive: true });
  const source = path.join(editorApp, 'Contents', 'Frameworks');
  run('ditto', [path.join(source, 'App.framework'), path.join(frameworks, 'App.framework')]);
  const name = `${prefix}MacOS`;
  const target = path.join(frameworks, `${name}.framework`);
  const version = path.join(target, 'Versions', 'A');
  fs.mkdirSync(version, { recursive: true });
  const original = path.join(source, 'FlutterMacOS.framework', 'Versions', 'A');
  run('ditto', [path.join(original, 'Resources'), path.join(version, 'Resources')]);
  const thin = path.join(version, name);
  run('lipo', [path.join(original, 'FlutterMacOS'), '-thin', 'arm64', '-output', thin]);
  const from = Buffer.from('Flutter');
  const to = Buffer.from(prefix);
  for (const file of [thin, path.join(version, 'Resources', 'Info.plist')]) {
    const bytes = fs.readFileSync(file);
    let count = 0;
    for (let i = bytes.indexOf(from); i >= 0; i = bytes.indexOf(from, i + 7)) {
      to.copy(bytes, i);
      count += 1;
    }
    fs.writeFileSync(file, bytes);
    if (file === thin) console.log(`Renamed ${count} occurrences of Flutter to ${prefix}`);
  }
  fs.symlinkSync('A', path.join(target, 'Versions', 'Current'));
  fs.symlinkSync(`Versions/Current/${name}`, path.join(target, name));
  fs.symlinkSync('Versions/Current/Resources', path.join(target, 'Resources'));
  run('codesign', ['--force', '--sign', '-', target]);
  run('codesign', ['--force', '--sign', '-', path.join(frameworks, 'App.framework')]);
}

function bundleNameOf(options, variant) {
  return `AudSpike${variant}${options.flavor}${options.hygiene ? '' : 'NoHygiene'}${
    options.rtsan ? 'Rtsan' : ''
  }${options.watchdog ? 'Watchdog' : ''}`;
}

// Builds the Flutter editor in release mode with `flutter` and returns its
// .app. Another SDK than the one on the path builds a copy of the editor
// under .dart_tool, whose overrides point at the siblings by absolute path.
function buildEditor(flutter) {
  let editor = path.join(root, 'editor');
  if (flutter !== 'flutter') {
    // <copy>/editor next to a link to src/, so that the runner's relative
    // include of src/aud_vst3_mach.h still resolves.
    const base = path.join(root, '.dart_tool', `editor-${hashOf([flutter])}`);
    const copy = path.join(base, 'editor');
    fs.mkdirSync(copy, { recursive: true });
    if (!fs.existsSync(path.join(base, 'src'))) {
      fs.symlinkSync(path.join(root, 'src'), path.join(base, 'src'));
    }
    run('rsync', ['-a', '--delete', '--exclude', 'build', '--exclude', '.dart_tool',
      '--exclude', 'pubspec.lock', `${editor}/`, `${copy}/`]);
    const pubspec = path.join(copy, 'pubspec.yaml');
    fs.writeFileSync(pubspec, fs.readFileSync(pubspec, 'utf8').replace('path: ../', `path: ${root}`));
    // An older SDK pins meta below what native_toolchain_c of the family's
    // build hooks needs; the override lets it build the editor (the B test).
    fs.writeFileSync(path.join(copy, 'pubspec_overrides.yaml'),
      `dependency_overrides:\n  aud_audio_ui_controls:\n    path: ${path.resolve(root, '..', 'aud_audio_ui_controls')}\n  meta: ^1.19.0\n`);
    editor = copy;
  }
  run(flutter, ['build', 'macos', '--release'], editor);
  const products = path.join(editor, 'build', 'macos', 'Build', 'Products', 'Release');
  const app = fs.readdirSync(products).find((entry) => entry.endsWith('.app'));
  if (!app) throw new Error(`No editor app in ${products}`);
  return path.join(products, app);
}

async function buildVariant(options, variant, editorApp) {
  const dirs = engineDirs(options.flavor);
  const compiler = compilerOf(options);
  // The prefix of the renamed Flutter framework of variant B: stable per
  // bundle name, random per build directory.
  const prefix = flutterPrefix(bundleNameOf(options, variant));
  const flags = flagsOf(options, variant, dirs, prefix);
  const graphSources = fs
    .readdirSync(dirs.graph)
    .filter((file) => file.endsWith('.cpp'))
    .map((file) => path.join(dirs.graph, file));
  // vstsinglecomponenteffect.cpp compiles vsteditcontroller.cpp itself, with
  // the controller's setState and getState renamed.
  const sdkSources = readList(path.join(sdkDir, 'SOURCES.txt'))
    .filter((file) => file !== 'public.sdk/source/vst/vsteditcontroller.cpp')
    .map((file) => path.join(sdkDir, file));
  const own = [...pluginSources, ...variantSources[variant]].map((file) =>
    path.join(root, file),
  );
  const config = `${variant}${options.flavor}${options.hygiene ? '' : '-nohygiene'}${
    options.rtsan ? '-rtsan' : ''
  }${options.watchdog ? '-watchdog' : ''}`;
  const objects = await compileAll(
    compiler,
    flags,
    [...sdkSources, ...graphSources, ...own],
    path.join(buildDir, config),
    headersHash([sdkDir, dirs.graph, dirs.core, path.join(root, 'src')]),
  );

  const name = bundleNameOf(options, variant);
  const bundle = path.join(outDir, `${name}.vst3`);
  fs.rmSync(bundle, { recursive: true, force: true });
  const macos = path.join(bundle, 'Contents', 'MacOS');
  fs.mkdirSync(macos, { recursive: true });
  const resources = path.join(bundle, 'Contents', 'Resources');
  fs.mkdirSync(resources, { recursive: true });
  // The notices of the vendored SDK travel with every bundle (license-001).
  const thirdParty = path.join(root, 'src', 'third_party');
  fs.copyFileSync(path.join(thirdParty, 'NOTICES.md'), path.join(resources, 'NOTICES.md'));
  fs.copyFileSync(
    path.join(thirdParty, 'vst3sdk', 'LICENSE.txt'),
    path.join(resources, 'VST3SDK-LICENSE.txt'),
  );
  const linkArgs = [
    '-arch',
    'arm64',
    '-mmacosx-version-min=12.0',
    '-bundle',
    '-o',
    path.join(macos, name),
    ...objects,
    ...frameworks.flatMap((framework) => ['-framework', framework]),
    '-Wl,-dead_strip',
  ];
  if (options.hygiene) {
    linkArgs.push(
      '-exported_symbols_list',
      path.join(root, 'src', 'aud_vst3_exports.exp'),
    );
  }
  if (options.rtsan) linkArgs.push('-fsanitize=realtime');
  run(compiler, linkArgs);
  fs.writeFileSync(
    path.join(bundle, 'Contents', 'Info.plist'),
    infoPlist(name, `io.audaudio.vst3.spike.${name.toLowerCase()}`, name),
  );
  fs.writeFileSync(path.join(bundle, 'Contents', 'PkgInfo'), 'BNDL????');
  if (variant === 'B' && editorApp) embedInProcessFlutter(bundle, editorApp, prefix);
  if (['A', 'S', 'F'].includes(variant) && editorApp) {
    const helpers = path.join(bundle, 'Contents', 'Helpers');
    fs.mkdirSync(helpers, { recursive: true });
    run('ditto', [editorApp, path.join(helpers, path.basename(editorApp))]);
    run('codesign', [
      '--force',
      '--deep',
      '--sign',
      '-',
      path.join(helpers, path.basename(editorApp)),
    ]);
  }
  run('codesign', ['--force', '--sign', '-', bundle]);
  if (options.install) {
    fs.mkdirSync(installDir, { recursive: true });
    const target = path.join(installDir, `${name}.vst3`);
    fs.rmSync(target, { recursive: true, force: true });
    run('ditto', [bundle, target]);
  }
  console.log(`Built ${path.relative(root, bundle)}${options.install ? ' (installed)' : ''}`);
  return bundle;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const editorApp =
    options.editor &&
    options.variants.some((variant) => ['A', 'S', 'F', 'B'].includes(variant))
      ? buildEditor(options.flutter)
      : null;
  for (const variant of options.variants) {
    await buildVariant(options, variant, editorApp);
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
