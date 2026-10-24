// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// What an app hands the shell (ticket 37, doc/plugin-bundle.md): the
// configuration plugin.json, the graph document and the presets, read from
// the plugin's Resources/aud_plugin, and the state a DAW project keeps.

#ifndef AUD_VST3_SETTINGS_HPP
#define AUD_VST3_SETTINGS_HPP

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace aud_vst3 {

// #############################################################################
// A graph parameter the DAW sees.
struct ShellParam {
  std::string node;
  std::string param;
  std::string name;
  // The stable id: aud_host_param_id(node, param).
  uint32_t id = 0;
};

// #############################################################################
// A parameter that sends a MIDI control change to the graph's event input.
struct ShellControl {
  std::string id;
  std::string name;
  uint32_t channel = 0;
  uint32_t cc = 0;
  // The value from 0 to 1 a new instance starts with.
  double defaultValue = 0;
  // The parameter id: aud_host_param_id("control", id).
  uint32_t paramId = 0;
};

// #############################################################################
// A preset: the node presets it applies, as JSON text by node id.
struct ShellPreset {
  std::string id;
  std::string name;
  std::vector<std::pair<std::string, std::string>> nodes;
};

// #############################################################################
// The configuration, the document and the presets.
struct Settings {
  std::string name;
  // Where the content may be, in the order the shell tries them.
  std::vector<std::string> content;
  // The voice budget of the samplers; 0 lifts it.
  int32_t voiceBudget = 0;
  // Whether the transport runs on while the DAW is stopped.
  bool freeRunningTransport = true;
  std::vector<ShellParam> params;
  std::vector<ShellControl> controls;
  // The editor app in Contents/Helpers; empty for the generic view.
  std::string editor;
  // The app group the sandboxed editor belongs to: the prefix of the Mach
  // names the plugin shares with it; empty for an editor without sandbox.
  std::string appGroup;
  // The size of the editor's view in points, and the smallest it may get.
  double editorWidth = 1024;
  double editorHeight = 640;
  double editorMinWidth = 768;
  double editorMinHeight = 480;
  // The graph document as JSON text.
  std::string document;
  std::vector<ShellPreset> presets;
  // The index of the preset a new instance plays.
  uint32_t defaultPreset = 0;

  // ...........................................................................
  // The index of the preset `id`, or -1.
  int32_t presetIndex(const std::string& id) const;
};

// #############################################################################
// Reads plugin.json and the files it names from `directory`; false with
// `error` for a missing or invalid file.
bool readSettings(const std::string& directory, Settings* out,
                  std::string* error);

// #############################################################################
// Parses the configuration text and the texts of document and presets;
// false with `error`. readSettings reads the files and calls it.
bool parseSettings(const std::string& config, const std::string& document,
                   const std::string& presets, Settings* out,
                   std::string* error);

// #############################################################################
// The state of an instance as a DAW project keeps it: the preset by id, the
// plain values of the graph parameters by stable id, the values of the
// controls by id and the settings of the editor as the editor wrote them
// (ticket 38) - never a path of the machine.
struct ShellState {
  std::string preset;
  std::vector<std::pair<uint32_t, float>> params;
  std::vector<std::pair<std::string, double>> controls;
  std::string editor;
};

// #############################################################################
// The longest settings of an editor a state keeps, in bytes
// (AudShellSettings.maxLength).
constexpr size_t kMaxEditorSettings = 256 * 1024;

// #############################################################################
// The state as JSON text.
std::string encodeState(const ShellState& state);

// #############################################################################
// Reads a state from JSON text; false with `error`.
bool decodeState(const std::string& text, ShellState* out, std::string* error);

}  // namespace aud_vst3

#endif  // AUD_VST3_SETTINGS_HPP
