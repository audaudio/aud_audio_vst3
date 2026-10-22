// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds the VST3 bundle of an app from its plugin.json (ticket 37,
// doc/plugin-bundle.md) with clang, without CMake: the vendored SDK subset
// (src/third_party/vst3sdk/SOURCES.txt), the graph engine, the node
// packages plugin.json names, and the shell. The packages come from a
// package config - the app's, so that the plugin plays the versions the app
// plays -, compiled from their sources and the manifests of their vendored
// code (build-001) by the recipes below, which mirror their build hooks.
//
// The bundle exports only the three VST3 entry points and hides all other
// symbols (plugin-004): -fvisibility=hidden and an exported-symbols list, so
// that two plugins over the engine never share code in one DAW process. It
// is built for Apple silicon (release-005) and signed with the hardened
// runtime: by `--sign <identity>`, ad hoc without.
//
// Objects are cached under .dart_tool/vst3-build by the hash of their
// source, the flags and all headers the build may include.
//
//   node scripts/build-plugin.js                  the example plugin
//   node scripts/build-plugin.js --config <plugin.json>
//       [--package-config <.dart_tool/package_config.json>]
//       [--out <directory>] [--sign <identity>] [--install]
//       [--editor <app>] [--rtsan] [--watchdog]
//
// --editor puts the built editor app - signed by its own build with the App
// Sandbox and the app group - into Contents/Helpers under the name
// plugin.json gives it as `editor`; the bundle is signed around it.

'use strict';

const { createHash } = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { fileURLToPath, pathToFileURL } = require('node:url');

const root = path.resolve(__dirname, '..');
const sdkDir = path.join(root, 'src', 'third_party', 'vst3sdk');
const buildDir = path.join(root, '.dart_tool', 'vst3-build');
const installDir = path.join(os.homedir(), 'Library', 'Audio', 'Plug-Ins', 'VST3');
const exampleConfig = path.join(root, 'example', 'plugin', 'plugin.json');

// The shell's own sources.
const shellSources = [
  'src/aud_vst3_bundle.mm',
  'src/aud_vst3_editor.mm',
  'src/aud_vst3_engine.cpp',
  'src/aud_vst3_factory.cpp',
  'src/aud_vst3_midi.cpp',
  'src/aud_vst3_objc.mm',
  'src/aud_vst3_param.cpp',
  'src/aud_vst3_plugin.cpp',
  'src/aud_vst3_settings.cpp',
  'src/aud_vst3_socket.cpp',
  'src/aud_vst3_surfaces.mm',
  'src/aud_vst3_transport.cpp',
];

const frameworks = [
  'AppKit',
  'CoreAudio',
  'CoreFoundation',
  'CoreGraphics',
  'Foundation',
  'IOSurface',
  'QuartzCore',
];

// The machine every object and binary is built for.
const targetFlags = ['-arch', 'arm64', '-mmacosx-version-min=12.0'];

// ............................................................................
// The node packages: what their build hooks compile, the function that
// registers their nodes, and the one that sets the samplers' voice budget.

// Every C++ file directly in `dir`, as the hooks list them.
function cppIn(dir) {
  return fs
    .readdirSync(dir)
    .filter((file) => file.endsWith('.cpp'))
    .sort()
    .map((file) => path.join(dir, file));
}

function readList(file) {
  return fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
}

function listIn(dir, manifest) {
  return readList(path.join(dir, manifest)).map((entry) => path.join(dir, entry));
}

const recipes = {
  aud_dsp_sampler: (src) => {
    const sfizz = path.join(src, 'third_party', 'sfizz');
    return {
      sources: [...cppIn(src), ...listIn(sfizz, 'SOURCES.txt')],
      includes: [src, ...listIn(sfizz, 'INCLUDES.txt')],
      defines: [
        'GHC_FILESYSTEM_FWD',
        'ENABLE_DSD',
        'ENABLE_THREADS',
        'HAVE_FSEEKO',
        'HAVE___BUILTIN_CLZ',
        'NOMINMAX',
      ],
      flags: [],
      register: 'aud_dsp_sampler_register',
      voiceBudget: 'aud_dsp_sampler_set_voice_budget',
      notices: [path.join(src, 'third_party', 'NOTICES.md')],
    };
  },
  aud_dsp_effects: (src) => {
    const third = path.join(src, 'third_party');
    return {
      sources: [
        ...cppIn(src),
        path.join(third, 'dunne_audio_kit', 'AdjustableDelayLine.cpp'),
        path.join(third, 'dunne_audio_kit', 'StereoDelay.cpp'),
        path.join(third, 'freeverb', 'allpass.cpp'),
        path.join(third, 'freeverb', 'comb.cpp'),
        path.join(third, 'freeverb', 'revmodel.cpp'),
      ],
      includes: [src, path.join(third, 'freeverb'), path.join(third, 'dunne_audio_kit')],
      defines: [],
      flags: ['-ffp-contract=off'],
      register: 'aud_dsp_effects_register',
      notices: [path.join(third, 'NOTICES.md')],
    };
  },
  aud_audio_script: (src, packageSrc) => {
    const quickjs = path.join(packageSrc('gg_quickjs'), 'quickjs-ng');
    return {
      sources: [
        ...cppIn(src),
        ...['dtoa.c', 'libregexp.c', 'libunicode.c', 'quickjs.c'].map((file) =>
          path.join(quickjs, file),
        ),
      ],
      includes: [src, quickjs],
      defines: ['_GNU_SOURCE'],
      flags: [],
      // QuickJS-ng as gg_quickjs builds it: unsigned char, no warnings of
      // third-party code.
      cFlags: ['-funsigned-char', '-w'],
      register: 'aud_audio_script_register',
      notices: [
        path.join(src, 'third_party', 'NOTICES.md'),
        path.join(quickjs, 'LICENSE'),
      ],
    };
  },
};

// ............................................................................
// Arguments, tools

function parseArgs(argv) {
  const options = {
    config: exampleConfig,
    packageConfig: path.join(root, '.dart_tool', 'package_config.json'),
    out: path.join(root, 'build', 'vst3'),
    sign: '-',
    editor: null,
    install: false,
    rtsan: false,
    watchdog: false,
  };
  for (let i = 0; i < argv.length; ++i) {
    const arg = argv[i];
    if (arg === '--config') options.config = path.resolve(argv[++i]);
    else if (arg === '--package-config') options.packageConfig = path.resolve(argv[++i]);
    else if (arg === '--out') options.out = path.resolve(argv[++i]);
    else if (arg === '--sign') options.sign = argv[++i];
    else if (arg === '--editor') options.editor = path.resolve(argv[++i]);
    else if (arg === '--install') options.install = true;
    else if (arg === '--rtsan') options.rtsan = true;
    else if (arg === '--watchdog') options.watchdog = true;
    else throw new Error(`Unknown option ${arg}`);
  }
  return options;
}

function run(command, args, cwd = root) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
  if (result.error) throw new Error(`${command} failed: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`${path.basename(command)} failed:\n${result.stdout}${result.stderr}`);
  }
  return result.stdout;
}

// The `src` directory of a package, resolved through `configPath`.
function packageSrcOf(configPath) {
  if (!fs.existsSync(configPath)) {
    throw new Error(`Run dart pub get first: ${configPath} is missing`);
  }
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  return (name) => {
    const entry = config.packages.find((p) => p.name === name);
    if (!entry) throw new Error(`Package ${name} is not in ${configPath}`);
    const rootUri = new URL(entry.rootUri, pathToFileURL(configPath));
    return path.join(fileURLToPath(rootUri), 'src');
  };
}

// The sources of the vendored SDK subset. vstsinglecomponenteffect.cpp
// compiles vsteditcontroller.cpp itself, with the controller's setState and
// getState renamed.
function sdkSources() {
  return readList(path.join(sdkDir, 'SOURCES.txt'))
    .filter((file) => file !== 'public.sdk/source/vst/vsteditcontroller.cpp')
    .map((file) => path.join(sdkDir, file));
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

// The flags every object shares: the target, optimization, hidden symbols
// and the includes of the SDK, the graph, the core and the shell.
function baseFlags(options, dirs) {
  const flags = [
    ...targetFlags,
    '-O3',
    '-g',
    '-DRELEASE=1',
    '-DNDEBUG=1',
    '-DSMTG_USE_STDATOMIC_H=1',
    '-fvisibility=hidden',
    '-fvisibility-inlines-hidden',
    '-I',
    sdkDir,
    '-I',
    dirs.graph,
    '-I',
    dirs.core,
    '-I',
    path.join(root, 'src'),
  ];
  if (options.rtsan) {
    // The graph and the plugin mark their realtime path nonblocking, so the
    // sanitizer checks everything a block calls (ticket 20, decision 8).
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
      else if (/\.(h|hpp|hh|inc)$/.test(entry.name)) files.push(full);
    }
  };
  for (const dir of dirs) if (fs.existsSync(dir)) walk(dir);
  return hashOf(files.sort().map((file) => file + fs.statSync(file).mtimeMs + fs.statSync(file).size));
}

// Compiles `files` with `flags` (plus `cFlags` for C files) into `objDir`.
async function compileAll(compiler, flags, files, objDir, headers, cFlags = []) {
  fs.mkdirSync(objDir, { recursive: true });
  const jobs = files.map((file) => {
    const key = hashOf([
      compiler,
      ...flags,
      ...cFlags,
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
        ...(job.file.endsWith('.c') ? cFlags : []),
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

// ............................................................................
// The bundle

function readConfig(file) {
  const config = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const key of ['name', 'vendor', 'version', 'bundleId', 'classId']) {
    if (typeof config[key] !== 'string' || config[key] === '') {
      throw new Error(`${file} needs ${key}`);
    }
  }
  if (!/^[0-9A-Fa-f]{32}$/.test(config.classId)) {
    throw new Error(`${file}: classId must be 32 hex digits`);
  }
  config.packages = config.packages ?? [];
  for (const name of config.packages) {
    if (!recipes[name]) throw new Error(`${file}: no recipe for package ${name}`);
  }
  return config;
}

// The C string literal of `text`.
function cString(text) {
  return JSON.stringify(String(text));
}

function identityDefines(config) {
  const cid = config.classId.toUpperCase();
  return [
    `-DAUD_VST3_NAME=${cString(config.name)}`,
    `-DAUD_VST3_VENDOR=${cString(config.vendor)}`,
    `-DAUD_VST3_URL=${cString(config.url ?? '')}`,
    `-DAUD_VST3_EMAIL=${cString(config.email ?? '')}`,
    `-DAUD_VST3_VERSION=${cString(config.version)}`,
    `-DAUD_VST3_BUNDLE_ID=${cString(config.bundleId)}`,
    `-DAUD_VST3_SUBCATEGORIES=${cString(config.subCategories ?? 'Instrument|Synth')}`,
    ...[0, 1, 2, 3].map((i) => `-DAUD_VST3_CID${i}=0x${cid.slice(i * 8, i * 8 + 8)}u`),
  ];
}

// The registration of the packages, generated per build.
function packagesSource(config, packageRecipes) {
  const lines = [
    '// Generated by scripts/build-plugin.js; do not edit.',
    '#include "aud_vst3_packages.hpp"',
    '',
  ];
  for (const recipe of packageRecipes) {
    lines.push(`extern "C" int32_t ${recipe.register}(const AudHostApi* host);`);
    if (recipe.voiceBudget) {
      lines.push(`extern "C" void ${recipe.voiceBudget}(int32_t voices);`);
    }
  }
  lines.push(
    '',
    'namespace aud_vst3 {',
    '',
    'bool registerPackages(AudGraph* graph, std::string* error) {',
    '  const AudHostApi* api = aud_graph_host_api(graph);',
  );
  config.packages.forEach((name, i) => {
    lines.push(
      `  if (const int32_t result = ${packageRecipes[i].register}(api); result != AUD_OK) {`,
      `    if (error != nullptr) *error = "${name} refused: " + std::to_string(result);`,
      '    return false;',
      '  }',
    );
  });
  lines.push('  return true;', '}', '', 'void setVoiceBudget(int32_t voices) {');
  const budget = packageRecipes.find((recipe) => recipe.voiceBudget);
  lines.push(budget ? `  ${budget.voiceBudget}(voices);` : '  (void)voices;');
  lines.push('}', '', '}  // namespace aud_vst3', '');
  return lines.join('\n');
}

function infoPlist(config, executable) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>English</string>
  <key>CFBundleExecutable</key>
  <string>${executable}</string>
  <key>CFBundleIdentifier</key>
  <string>${config.bundleId}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${config.name}</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>${config.version}</string>
  <key>CFBundleSignature</key>
  <string>????</string>
  <key>CFBundleVersion</key>
  <string>${config.version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
</dict>
</plist>
`;
}

// The module info of the VST3 SDK, which a DAW may read instead of loading
// the binary; it says what the factory says.
function moduleInfo(config, bundleName) {
  return JSON.stringify(
    {
      Name: bundleName,
      Version: config.version,
      'Factory Info': {
        Vendor: config.vendor,
        URL: config.url ?? '',
        'E-Mail': config.email ?? '',
        Flags: {
          Unicode: true,
          'Classes Discardable': false,
          'Component Non Discardable': false,
        },
      },
      Compatibility: [],
      Classes: [
        {
          CID: config.classId.toUpperCase(),
          Category: 'Audio Module Class',
          Name: config.name,
          Vendor: config.vendor,
          Version: config.version,
          'SDKVersion': 'VST 3.8.1',
          'Sub Categories': (config.subCategories ?? 'Instrument|Synth').split('|'),
          'Class Flags': 0,
          Cardinality: 2147483647,
          Snapshots: [],
        },
      ],
    },
    null,
    2,
  );
}

async function build(options) {
  const config = readConfig(options.config);
  const configDir = path.dirname(options.config);
  const packageSrc = packageSrcOf(options.packageConfig);
  const dirs = { graph: packageSrc('aud_audio_graph'), core: packageSrc('aud_audio_core') };
  const packageRecipes = config.packages.map((name) => ({
    name,
    ...recipes[name](packageSrc(name), packageSrc),
  }));
  const compiler = compilerOf(options);
  const flags = baseFlags(options, dirs);
  const headers = headersHash([
    sdkDir,
    dirs.graph,
    dirs.core,
    path.join(root, 'src'),
    ...packageRecipes.flatMap((recipe) => recipe.includes),
  ]);
  const variant = `${options.rtsan ? 'rtsan' : 'release'}${options.watchdog ? '-watchdog' : ''}`;
  const objDir = path.join(buildDir, variant);

  // The SDK, the graph and each package, then the shell with the identity
  // of this plugin and its generated registration.
  const objects = [
    ...(await compileAll(compiler, flags, sdkSources(), path.join(objDir, 'sdk'), headers)),
    ...(await compileAll(compiler, flags, cppIn(dirs.graph), path.join(objDir, 'graph'), headers)),
  ];
  for (const recipe of packageRecipes) {
    const packageFlags = [
      ...flags,
      ...recipe.includes.flatMap((dir) => ['-I', dir]),
      ...recipe.defines.map((define) => `-D${define}`),
      ...recipe.flags,
    ];
    objects.push(
      ...(await compileAll(
        compiler,
        packageFlags,
        recipe.sources,
        path.join(objDir, recipe.name),
        headers,
        recipe.cFlags ?? [],
      )),
    );
  }
  const generated = path.join(objDir, `packages-${hashOf([config.packages.join(',')])}.cpp`);
  fs.mkdirSync(objDir, { recursive: true });
  fs.writeFileSync(generated, packagesSource(config, packageRecipes));
  objects.push(
    ...(await compileAll(
      compiler,
      [...flags, ...identityDefines(config)],
      [...shellSources.map((file) => path.join(root, file)), generated],
      path.join(objDir, 'shell'),
      headers,
    )),
  );

  // The bundle.
  const executable = config.name.replace(/[^A-Za-z0-9_-]/g, '');
  const bundleName = `${executable}.vst3`;
  const bundle = path.join(options.out, bundleName);
  fs.rmSync(bundle, { recursive: true, force: true });
  const contents = path.join(bundle, 'Contents');
  const macos = path.join(contents, 'MacOS');
  const resources = path.join(contents, 'Resources');
  const settings = path.join(resources, 'aud_plugin');
  fs.mkdirSync(macos, { recursive: true });
  fs.mkdirSync(settings, { recursive: true });
  const linkArgs = [
    ...targetFlags,
    '-bundle',
    '-o',
    path.join(macos, executable),
    ...objects,
    ...frameworks.flatMap((framework) => ['-framework', framework]),
    '-Wl,-dead_strip',
    '-exported_symbols_list',
    path.join(root, 'src', 'aud_vst3_exports.exp'),
  ];
  if (options.rtsan) linkArgs.push('-fsanitize=realtime');
  run(compiler, linkArgs);
  fs.writeFileSync(path.join(contents, 'Info.plist'), infoPlist(config, executable));
  fs.writeFileSync(path.join(contents, 'PkgInfo'), 'BNDL????');
  fs.writeFileSync(path.join(resources, 'moduleinfo.json'), moduleInfo(config, bundleName));
  for (const file of [
    path.basename(options.config),
    config.document ?? 'document.json',
    config.presets ?? 'presets.json',
  ]) {
    fs.copyFileSync(path.join(configDir, file), path.join(settings, file));
  }
  // The notices of every vendored source travel with the bundle
  // (license-001).
  const notices = path.join(resources, 'notices');
  fs.mkdirSync(notices, { recursive: true });
  fs.copyFileSync(path.join(root, 'src', 'third_party', 'NOTICES.md'), path.join(notices, 'aud_audio_vst3.md'));
  fs.copyFileSync(path.join(sdkDir, 'LICENSE.txt'), path.join(notices, 'vst3sdk-LICENSE.txt'));
  for (const recipe of packageRecipes) {
    recipe.notices.forEach((file, i) => {
      if (fs.existsSync(file)) {
        fs.copyFileSync(file, path.join(notices, `${recipe.name}${i === 0 ? '' : `-${i}`}-${path.basename(file)}`));
      }
    });
  }
  if (options.editor) {
    if (!config.editor) throw new Error(`${options.config} names no editor`);
    const helpers = path.join(contents, 'Helpers');
    fs.mkdirSync(helpers, { recursive: true });
    // The editor keeps its own signature with its entitlements; the
    // bundle's seals it.
    run('ditto', [options.editor, path.join(helpers, config.editor)]);
  }
  run('codesign', [
    '--force',
    '--options',
    'runtime',
    '--timestamp=none',
    '--sign',
    options.sign,
    bundle,
  ]);
  if (options.install) {
    fs.mkdirSync(installDir, { recursive: true });
    const target = path.join(installDir, bundleName);
    fs.rmSync(target, { recursive: true, force: true });
    run('ditto', [bundle, target]);
  }
  console.log(`Built ${bundle}${options.install ? ' (installed)' : ''}`);
  return bundle;
}

// The compile settings, for scripts/test-native.js and scripts/host.js.
module.exports = {
  root,
  sdkDir,
  buildDir,
  frameworks,
  targetFlags,
  run,
  packageSrcOf,
  sdkSources,
  hashOf,
  compilerOf,
  baseFlags,
  headersHash,
  compileAll,
  cppIn,
  build,
  parseArgs,
};

if (require.main === module) {
  build(parseArgs(process.argv.slice(2))).catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
