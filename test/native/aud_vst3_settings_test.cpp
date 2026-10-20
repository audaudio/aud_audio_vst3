// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The settings an app hands the shell and the state of an instance
// (aud_vst3_settings.hpp).

#include "aud_vst3_settings.hpp"

#include "aud_audio_graph.h"
#include "aud_vst3_harness.hpp"

using namespace aud_vst3;
using aud_vst3_test::expectEqual;
using aud_vst3_test::expectNear;
using aud_vst3_test::group;
using aud_vst3_test::test;

namespace {

const char* const kConfig = R"({
  "schema": 1, "name": "Test",
  "content": ["containing-app:Contents/Resources/x", "app:com.a:Contents"],
  "voiceBudget": 96, "freeRunningTransport": false,
  "parameters": [{ "node": "delay", "param": "mix", "name": "Delay Mix" },
                 { "node": "out", "param": "master" }],
  "controls": [{ "id": "slider", "name": "Slider", "channel": 0, "cc": 74,
                 "default": 0.25 }]
})";

const char* const kDocument = R"({"schema": 1, "nodes": []})";

const char* const kPresets = R"({
  "schema": 1, "default": "b",
  "presets": [
    { "id": "a", "name": "A", "nodes": { "x": { "schema": 1, "type": "t.a" } } },
    { "id": "b", "nodes": { "x": { "schema": 1, "type": "t.a",
                                   "params": { "p": 0.5 } } } }
  ]
})";

}  // namespace

int main() {
  group("settings", [] {
    test("read configuration, document and presets", [] {
      Settings settings;
      std::string error;
      expectEqual(parseSettings(kConfig, kDocument, kPresets, &settings, &error), true);
      expectEqual(error, std::string());
      expectEqual(settings.name, std::string("Test"));
      expectEqual(settings.content.size(), size_t{2});
      expectEqual(settings.voiceBudget, 96);
      expectEqual(settings.freeRunningTransport, false);
      expectEqual(settings.params.size(), size_t{2});
      expectEqual(settings.params[0].id, aud_host_param_id("delay", "mix"));
      expectEqual(settings.params[1].name, std::string("out master"));
      expectEqual(settings.controls.size(), size_t{1});
      expectEqual(settings.controls[0].cc, 74u);
      expectNear(settings.controls[0].defaultValue, 0.25, 0);
      expectEqual(settings.controls[0].paramId, aud_host_param_id("control", "slider"));
      expectEqual(settings.presets.size(), size_t{2});
      expectEqual(settings.presets[1].name, std::string("b"));
      expectEqual(settings.defaultPreset, 1u);
      expectEqual(settings.presets[0].nodes.size(), size_t{1});
      expectEqual(settings.presets[0].nodes[0].first, std::string("x"));
      expectEqual(settings.presetIndex("a"), 0);
      expectEqual(settings.presetIndex("c"), -1);
    });
    test("refuse what is wrong, with a reason", [] {
      const auto refuses = [](const char* config, const char* presets) {
        Settings settings;
        std::string error;
        const bool ok = parseSettings(config, kDocument, presets, &settings, &error);
        return !ok && !error.empty();
      };
      expectEqual(refuses(R"({"name": "x"})", kPresets), true);
      expectEqual(refuses(R"({"schema": 1})", kPresets), true);
      expectEqual(refuses(R"({"schema": 1, "name": "x", "controls": [{"id": "c", "channel": 16, "cc": 1}]})", kPresets), true);
      expectEqual(refuses(kConfig, R"({"schema": 1, "presets": []})"), true);
      expectEqual(refuses(kConfig, R"({"schema": 1, "default": "z", "presets": [{"id": "a", "nodes": {}}]})"), true);
      expectEqual(refuses(kConfig, R"({"schema": 1, "presets": [{"id": "a", "nodes": {}}, {"id": "a", "nodes": {}}]})"), true);
    });
  });

  group("state", [] {
    test("reads back what it wrote", [] {
      ShellState state;
      state.preset = "b";
      state.params = {{7, 0.25f}, {aud_host_param_id("delay", "mix"), 1.0f}};
      state.controls = {{"slider", 0.5}};
      ShellState back;
      std::string error;
      expectEqual(decodeState(encodeState(state), &back, &error), true);
      expectEqual(back.preset, std::string("b"));
      expectEqual(back.params.size(), size_t{2});
      expectEqual(back.params[1].first, aud_host_param_id("delay", "mix"));
      expectNear(back.params[0].second, 0.25, 0);
      expectEqual(back.controls.size(), size_t{1});
      expectNear(back.controls[0].second, 0.5, 0);
    });
    test("refuses a state of another schema or with bad values", [] {
      ShellState back;
      std::string error;
      expectEqual(decodeState(R"({"schema": 2})", &back, &error), false);
      expectEqual(decodeState(R"({"schema": 1, "params": {"x": 1}})", &back, &error), false);
      expectEqual(decodeState("no json", &back, &error), false);
    });
  });
  return aud_vst3_test::finish();
}
