// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds the VST3 bundle of an app from its plugin.json (ticket 37,
// doc/plugin-bundle.md) with clang, without CMake: the vendored SDK subset
// (src/third_party/vst3sdk/SOURCES.txt), the graph engine, the node
// packages plugin.json names, the shared core of the shells and the shell.
// The packages and aud_audio_plugin, whose scripts/plugin-build.js compiles
// the core, the graph and the packages by its recipes (build-001), come
// from a package config - the app's, so that the plugin plays the versions
// the app plays (plugin-010).
//
// The bundle exports only the three VST3 entry points and hides all other
// symbols (plugin-004), so that two plugins over the engine never share code
// in one DAW process. On macOS it is built for Apple silicon (release-005)
// with -fvisibility=hidden and an exported-symbols list, and signed with the
// hardened runtime: by `--sign <identity>`, ad hoc without. On Windows
// (ticket 38) it is a DLL for x86-64, built by the clang++ and lld-link of
// Visual Studio against the static C++ runtime, so that the DAW's machine
// needs no runtime of Visual Studio; it exports what the SDK marks for
// export, which the build checks, and the engine's AUD_EXPORT is empty.
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
// plugin.json gives it as `editor`; the bundle is signed around it (macOS).
// --install copies the bundle into the user's VST3 folder:
// ~/Library/Audio/Plug-Ins/VST3 on macOS,
// %LOCALAPPDATA%\Programs\Common\VST3 on Windows.

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { fileURLToPath, pathToFileURL } = require('node:url');

const root = path.resolve(__dirname, '..');

// The package config the build resolves its packages through: the app's,
// named by --package-config, or this package's own.
function packageConfigOf(argv) {
  const at = argv.indexOf('--package-config');
  return at >= 0 && at + 1 < argv.length
    ? path.resolve(argv[at + 1])
    : path.join(root, '.dart_tool', 'package_config.json');
}

// The shared build of aud_audio_plugin (scripts/plugin-build.js), from the
// package config of this run.
function pluginBuildOf(configPath) {
  if (!fs.existsSync(configPath)) {
    throw new Error(`Run dart pub get first: ${configPath} is missing`);
  }
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const entry = config.packages.find((p) => p.name === 'aud_audio_plugin');
  if (!entry) throw new Error(`Package aud_audio_plugin is not in ${configPath}`);
  const pluginRoot = fileURLToPath(new URL(entry.rootUri, pathToFileURL(configPath)));
  return require(path.join(pluginRoot, 'scripts', 'plugin-build.js'));
}

const core = pluginBuildOf(
  packageConfigOf(require.main === module ? process.argv.slice(2) : []),
);
const {
  windows,
  useVisualStudioLlvm,
  coreSources,
  cppIn,
  readList,
  recipesOf,
  packagesSource,
  packageSrcOf,
  hashOf,
  compilerOf,
  coreFlags,
  headersHash,
  compileAll,
  removePath,
} = core;

if (windows) useVisualStudioLlvm();

const sdkDir = path.join(root, 'src', 'third_party', 'vst3sdk');
const buildDir = path.join(root, '.dart_tool', 'vst3-build');
const installDir = windows
  ? path.join(
      process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'),
      'Programs',
      'Common',
      'VST3',
    )
  : path.join(os.homedir(), 'Library', 'Audio', 'Plug-Ins', 'VST3');
const exampleConfig = path.join(root, 'example', 'plugin', 'plugin.json');

// The shell's own sources: those of every platform, then those of macOS or
// Windows.
const shellSources = [
  'src/aud_vst3_bundle.cpp',
  'src/aud_vst3_factory.cpp',
  'src/aud_vst3_midi.cpp',
  'src/aud_vst3_param.cpp',
  'src/aud_vst3_plugin.cpp',
  'src/aud_vst3_socket.cpp',
  'src/aud_vst3_ui_thread.cpp',
  ...(windows
    ? ['src/aud_vst3_editor_win.cpp']
    : ['src/aud_vst3_editor.mm', 'src/aud_vst3_objc.mm', 'src/aud_vst3_surfaces.mm']),
];

// The platform of the shared core's sources.
const platform = windows ? 'windows' : 'macos';

// What the bundle links of the system: frameworks on macOS, libraries on
// Windows.
const frameworks = windows
  ? []
  : ['AppKit', 'CoreAudio', 'CoreFoundation', 'CoreGraphics', 'Foundation', 'IOSurface', 'QuartzCore'];
const systemLibraries = windows
  ? ['user32', 'gdi32', 'shell32', 'ole32', 'advapi32', 'ws2_32']
  : [];

// The machine every object and binary is built for: Apple silicon, or
// x86-64 Windows with the static C++ runtime.
const targetFlags = windows
  ? ['--target=x86_64-pc-windows-msvc', '-fms-runtime-lib=static']
  : ['-arch', 'arm64', '-mmacosx-version-min=12.0'];

// The folder of the binary inside Contents, as the VST3 bundle format names
// it for the platform.
const binaryFolder = windows ? 'x86_64-win' : 'MacOS';

// The entry points a bundle exports on Windows (plugin-004).
const windowsExports = ['ExitDll', 'GetPluginFactory', 'InitDll'];

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
  return core.run(command, args, cwd);
}

// Whether a source of the vendored SDK builds on this platform: the
// manifests list those of macOS and Windows (scripts/vendor-vst3sdk.js).
function forPlatform(file) {
  const macOnly = file.endsWith('.mm') || /\/(macmain|module_mac)\.\w+$/.test(file);
  const windowsOnly = /_win32\.cpp$/.test(file) || file.endsWith('/dllmain.cpp');
  return windows ? !macOnly : !windowsOnly;
}

// The sources of the vendored SDK subset. vstsinglecomponenteffect.cpp
// compiles vsteditcontroller.cpp itself, with the controller's setState and
// getState renamed.
function sdkSources() {
  return readList(path.join(sdkDir, 'SOURCES.txt'))
    .filter((file) => file !== 'public.sdk/source/vst/vsteditcontroller.cpp')
    .filter(forPlatform)
    .map((file) => path.join(sdkDir, file));
}

// The flags every object shares: those of aud_audio_plugin for the target
// (coreFlags), the SDK's, and the includes of the SDK and the shell. The
// log of the shared core is the plugin's: AUD_VST3_LOG names its file in a
// test.
function baseFlags(options, dirs) {
  return [
    ...coreFlags(options, dirs, targetFlags),
    '-DRELEASE=1',
    '-DSMTG_USE_STDATOMIC_H=1',
    '-DAUD_PLUGIN_LOG_ENV="AUD_VST3_LOG"',
    '-I',
    sdkDir,
    '-I',
    path.join(root, 'src'),
  ];
}

// The flags of the SDK and of the shell, which includes its headers: on
// Windows the SDK calls the wide functions, as its CMake defines UNICODE,
// and its headers push and pop the packing across includes on purpose. The
// graph and the packages build without, as their hooks do.
const sdkFlags = windows ? ['-DUNICODE', '-D_UNICODE', '-Wno-pragma-pack'] : [];

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
    `-DAUD_PLUGIN_LOG_SUBSYSTEM=${cString(config.bundleId)}`,
    `-DAUD_VST3_SUBCATEGORIES=${cString(config.subCategories ?? 'Instrument|Synth')}`,
    ...[0, 1, 2, 3].map((i) => `-DAUD_VST3_CID${i}=0x${cid.slice(i * 8, i * 8 + 8)}u`),
  ];
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
  const packageRecipes = recipesOf(config.packages, packageSrc);
  const compiler = compilerOf(options);
  const flags = baseFlags(options, dirs);
  const headers = headersHash([
    sdkDir,
    dirs.graph,
    dirs.core,
    core.pluginSrc,
    path.join(root, 'src'),
    ...packageRecipes.flatMap((recipe) => recipe.includes),
  ]);
  const variant = `${options.rtsan ? 'rtsan' : 'release'}${options.watchdog ? '-watchdog' : ''}`;
  const objDir = path.join(buildDir, variant);

  // The SDK, the graph and each package, then the shell with the identity
  // of this plugin and its generated registration.
  const objects = [
    ...(await compileAll(compiler, [...flags, ...sdkFlags], sdkSources(), path.join(objDir, 'sdk'), headers)),
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
  fs.writeFileSync(generated, packagesSource(packageRecipes));
  objects.push(
    ...(await compileAll(
      compiler,
      [...flags, ...sdkFlags, ...identityDefines(config)],
      [...coreSources(platform), ...shellSources.map((file) => path.join(root, file)), generated],
      path.join(objDir, 'shell'),
      headers,
    )),
  );

  // The bundle.
  const executable = config.name.replace(/[^A-Za-z0-9_-]/g, '');
  const bundleName = `${executable}.vst3`;
  const bundle = path.join(options.out, bundleName);
  removePath(bundle);
  const contents = path.join(bundle, 'Contents');
  const binaryDir = path.join(contents, binaryFolder);
  const resources = path.join(contents, 'Resources');
  const settings = path.join(resources, 'aud_plugin');
  fs.mkdirSync(binaryDir, { recursive: true });
  fs.mkdirSync(settings, { recursive: true });
  if (windows) {
    linkWindows(compiler, objects, packageRecipes, path.join(binaryDir, bundleName), objDir);
  } else {
    const linkArgs = [
      ...targetFlags,
      '-bundle',
      '-o',
      path.join(binaryDir, executable),
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
  }
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
    if (windows) throw new Error('--editor builds the Helpers of macOS only');
    if (!config.editor) throw new Error(`${options.config} names no editor`);
    const helpers = path.join(contents, 'Helpers');
    fs.mkdirSync(helpers, { recursive: true });
    // The editor keeps its own signature with its entitlements; the
    // bundle's seals it.
    run('ditto', [options.editor, path.join(helpers, config.editor)]);
  }
  if (!windows) {
    run('codesign', [
      '--force',
      '--options',
      'runtime',
      '--timestamp=none',
      '--sign',
      options.sign,
      bundle,
    ]);
  }
  if (options.install) {
    fs.mkdirSync(installDir, { recursive: true });
    const target = path.join(installDir, bundleName);
    removePath(target);
    if (windows) fs.cpSync(bundle, target, { recursive: true });
    else run('ditto', [bundle, target]);
  }
  console.log(`Built ${bundle}${options.install ? ' (installed)' : ''}`);
  return bundle;
}

// Links the DLL of a bundle on Windows (ticket 38) with lld-link: through a
// response file, as sfizz's objects pass the limit of a command line, with
// unused code dropped and the import library kept out of the bundle. Fails
// when the DLL exports other symbols than the entry points.
function linkWindows(compiler, objects, packageRecipes, binary, objDir) {
  const libraries = [
    ...systemLibraries,
    ...packageRecipes.flatMap((recipe) => recipe.libraries ?? []),
  ];
  const args = [
    ...targetFlags,
    '-fuse-ld=lld',
    '-shared',
    '-o',
    binary,
    ...objects,
    ...[...new Set(libraries)].map((library) => `-l${library}`),
    `-Wl,/IMPLIB:${path.join(objDir, `${path.basename(binary, '.vst3')}.lib`)}`,
    '-Wl,/OPT:REF',
    '-Wl,/OPT:ICF',
  ];
  // The response file of clang's GNU driver: quoted, with '/'.
  const response = path.join(objDir, 'link.rsp');
  fs.writeFileSync(
    response,
    args.map((arg) => `"${arg.replace(/\\/g, '/')}"`).join('\n'),
  );
  run(compiler, [`@${response}`]);
  const exportsOf = run('llvm-readobj', ['--coff-exports', binary]);
  const names = [...exportsOf.matchAll(/^\s*Name: (\S+)/gm)].map((match) => match[1]).sort();
  if (names.join(',') !== windowsExports.join(',')) {
    throw new Error(`${binary} exports ${names.join(', ')}; only ${windowsExports.join(', ')} may leave it`);
  }
}

// The compile settings, for scripts/test-native.js and scripts/host.js.
module.exports = {
  root,
  sdkDir,
  buildDir,
  windows,
  frameworks,
  systemLibraries,
  targetFlags,
  sdkFlags,
  run,
  packageSrcOf,
  forPlatform,
  sdkSources,
  hashOf,
  compilerOf,
  baseFlags,
  headersHash,
  compileAll,
  cppIn,
  coreSources,
  pluginSrc: core.pluginSrc,
  build,
  parseArgs,
  useVisualStudioLlvm,
};

if (require.main === module) {
  build(parseArgs(process.argv.slice(2))).catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
