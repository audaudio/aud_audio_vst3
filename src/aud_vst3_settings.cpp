// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#include "aud_vst3_settings.hpp"

#include <cmath>
#include <cstdlib>
#include <fstream>
#include <set>
#include <sstream>

#include "aud_audio_graph.h"
#include "aud_json.hpp"

namespace aud_vst3 {

using aud::Json;

namespace {

constexpr int64_t kSchema = 1;

bool fail(std::string* error, const std::string& message) {
  if (error != nullptr) *error = message;
  return false;
}

bool readFile(const std::string& path, std::string* out) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return false;
  std::ostringstream text;
  text << file.rdbuf();
  *out = text.str();
  return true;
}

bool parse(const std::string& text, const std::string& what, Json* out,
           std::string* error) {
  std::string parseError;
  if (!aud::parseJson(text.data(), text.size(), out, &parseError)) {
    return fail(error, what + ": " + parseError);
  }
  if (!out->isObject()) return fail(error, what + " is no object");
  return true;
}

// The string member `key` of `object`; `fallback` when it is missing.
bool stringOf(const Json& object, const char* key, const std::string& what,
              bool required, std::string* out, std::string* error) {
  const Json* value = object.find(key);
  if (value == nullptr || value->isNull()) {
    if (required) return fail(error, what + " needs " + key);
    return true;
  }
  if (!value->isString()) return fail(error, what + "." + key + " is no text");
  *out = value->string;
  return true;
}

bool schemaOf(const Json& object, const std::string& what, std::string* error) {
  const Json* schema = object.find("schema");
  if (schema == nullptr || !schema->isInteger() ||
      schema->integer() != kSchema) {
    return fail(error, what + " needs schema 1");
  }
  return true;
}

bool readParams(const Json& config, Settings* out, std::string* error) {
  const Json* params = config.find("parameters");
  if (params == nullptr || params->isNull()) return true;
  if (!params->isArray()) return fail(error, "parameters is no list");
  for (const Json& entry : params->array) {
    if (!entry.isObject()) return fail(error, "a parameter is no object");
    ShellParam param;
    if (!stringOf(entry, "node", "a parameter", true, &param.node, error) ||
        !stringOf(entry, "param", "a parameter", true, &param.param, error) ||
        !stringOf(entry, "name", "a parameter", false, &param.name, error)) {
      return false;
    }
    if (param.name.empty()) param.name = param.node + " " + param.param;
    param.id = aud_host_param_id(param.node.c_str(), param.param.c_str());
    out->params.push_back(param);
  }
  return true;
}

bool readControls(const Json& config, Settings* out, std::string* error) {
  const Json* controls = config.find("controls");
  if (controls == nullptr || controls->isNull()) return true;
  if (!controls->isArray()) return fail(error, "controls is no list");
  for (const Json& entry : controls->array) {
    if (!entry.isObject()) return fail(error, "a control is no object");
    ShellControl control;
    if (!stringOf(entry, "id", "a control", true, &control.id, error) ||
        !stringOf(entry, "name", "a control", false, &control.name, error)) {
      return false;
    }
    if (control.name.empty()) control.name = control.id;
    const Json* channel = entry.find("channel");
    const Json* cc = entry.find("cc");
    if (channel == nullptr || !channel->isInteger() || channel->integer() < 0 ||
        channel->integer() > 15) {
      return fail(error, "control " + control.id + " needs a channel 0 to 15");
    }
    if (cc == nullptr || !cc->isInteger() || cc->integer() < 0 ||
        cc->integer() > 127) {
      return fail(error, "control " + control.id + " needs a cc 0 to 127");
    }
    control.channel = static_cast<uint32_t>(channel->integer());
    control.cc = static_cast<uint32_t>(cc->integer());
    if (const Json* value = entry.find("default")) {
      if (!value->isNumber() || value->number < 0 || value->number > 1) {
        return fail(error, "control " + control.id + " needs a default 0 to 1");
      }
      control.defaultValue = value->number;
    }
    control.paramId = aud_host_param_id("control", control.id.c_str());
    out->controls.push_back(control);
  }
  return true;
}

bool readPresets(const std::string& text, Settings* out, std::string* error) {
  Json root;
  if (!parse(text, "presets", &root, error) ||
      !schemaOf(root, "presets", error)) {
    return false;
  }
  const Json* presets = root.find("presets");
  if (presets == nullptr || !presets->isArray() || presets->array.empty()) {
    return fail(error, "presets needs a list of presets");
  }
  std::set<std::string> ids;
  for (const Json& entry : presets->array) {
    if (!entry.isObject()) return fail(error, "a preset is no object");
    ShellPreset preset;
    if (!stringOf(entry, "id", "a preset", true, &preset.id, error) ||
        !stringOf(entry, "name", "a preset", false, &preset.name, error)) {
      return false;
    }
    if (!ids.insert(preset.id).second) {
      return fail(error, "preset " + preset.id + " is there twice");
    }
    if (preset.name.empty()) preset.name = preset.id;
    const Json* nodes = entry.find("nodes");
    if (nodes == nullptr || !nodes->isObject()) {
      return fail(error, "preset " + preset.id + " needs nodes");
    }
    for (const auto& [node, nodePreset] : nodes->object) {
      if (!nodePreset.isObject()) {
        return fail(error, "preset " + preset.id + ": " + node + " is no object");
      }
      std::string json;
      aud::writeJson(nodePreset, 0, &json);
      preset.nodes.emplace_back(node, std::move(json));
    }
    out->presets.push_back(std::move(preset));
  }
  std::string fallback;
  if (!stringOf(root, "default", "presets", false, &fallback, error)) {
    return false;
  }
  out->defaultPreset = 0;
  if (!fallback.empty()) {
    const int32_t index = out->presetIndex(fallback);
    if (index < 0) return fail(error, "the default preset " + fallback + " is missing");
    out->defaultPreset = static_cast<uint32_t>(index);
  }
  return true;
}

}  // namespace

// #############################################################################
int32_t Settings::presetIndex(const std::string& id) const {
  for (size_t i = 0; i < presets.size(); ++i) {
    if (presets[i].id == id) return static_cast<int32_t>(i);
  }
  return -1;
}

// #############################################################################
bool parseSettings(const std::string& configText, const std::string& document,
                   const std::string& presets, Settings* out,
                   std::string* error) {
  Json config;
  if (!parse(configText, "plugin.json", &config, error) ||
      !schemaOf(config, "plugin.json", error) ||
      !stringOf(config, "name", "plugin.json", true, &out->name, error) ||
      !stringOf(config, "editor", "plugin.json", false, &out->editor, error)) {
    return false;
  }
  if (const Json* content = config.find("content")) {
    if (!content->isArray()) return fail(error, "content is no list");
    for (const Json& location : content->array) {
      if (!location.isString()) return fail(error, "a content location is no text");
      out->content.push_back(location.string);
    }
  }
  if (const Json* budget = config.find("voiceBudget")) {
    if (!budget->isInteger() || budget->integer() < 0) {
      return fail(error, "voiceBudget is no count");
    }
    out->voiceBudget = static_cast<int32_t>(budget->integer());
  }
  if (const Json* free = config.find("freeRunningTransport")) {
    if (!free->isBool()) return fail(error, "freeRunningTransport is no boolean");
    out->freeRunningTransport = free->boolean;
  }
  if (!readParams(config, out, error) || !readControls(config, out, error)) {
    return false;
  }
  Json documentJson;
  if (!parse(document, "document", &documentJson, error)) return false;
  out->document = document;
  return readPresets(presets, out, error);
}

// #############################################################################
bool readSettings(const std::string& directory, Settings* out,
                  std::string* error) {
  std::string config;
  if (!readFile(directory + "/plugin.json", &config)) {
    return fail(error, "no plugin.json in " + directory);
  }
  Json root;
  if (!parse(config, "plugin.json", &root, error)) return false;
  std::string documentFile = "document.json";
  std::string presetsFile = "presets.json";
  if (!stringOf(root, "document", "plugin.json", false, &documentFile, error) ||
      !stringOf(root, "presets", "plugin.json", false, &presetsFile, error)) {
    return false;
  }
  std::string document;
  std::string presets;
  if (!readFile(directory + "/" + documentFile, &document)) {
    return fail(error, "no " + documentFile + " in " + directory);
  }
  if (!readFile(directory + "/" + presetsFile, &presets)) {
    return fail(error, "no " + presetsFile + " in " + directory);
  }
  return parseSettings(config, document, presets, out, error);
}

// #############################################################################
std::string encodeState(const ShellState& state) {
  Json root = Json::ofObject();
  root.set("schema", Json::ofNumber(kSchema));
  root.set("preset", Json::ofString(state.preset));
  Json params = Json::ofObject();
  for (const auto& [id, value] : state.params) {
    params.set(std::to_string(id), Json::ofNumber(value));
  }
  root.set("params", std::move(params));
  Json controls = Json::ofObject();
  for (const auto& [id, value] : state.controls) {
    controls.set(id, Json::ofNumber(value));
  }
  root.set("controls", std::move(controls));
  std::string text;
  aud::writeJson(root, 0, &text);
  return text;
}

// #############################################################################
bool decodeState(const std::string& text, ShellState* out, std::string* error) {
  Json root;
  if (!parse(text, "state", &root, error) || !schemaOf(root, "state", error) ||
      !stringOf(root, "preset", "state", false, &out->preset, error)) {
    return false;
  }
  if (const Json* params = root.find("params")) {
    if (!params->isObject()) return fail(error, "state params is no object");
    for (const auto& [key, value] : params->object) {
      char* end = nullptr;
      const unsigned long id = std::strtoul(key.c_str(), &end, 10);
      if (key.empty() || *end != '\0' || !value.isNumber() ||
          !std::isfinite(value.number)) {
        return fail(error, "state param " + key + " is invalid");
      }
      out->params.emplace_back(static_cast<uint32_t>(id),
                               static_cast<float>(value.number));
    }
  }
  if (const Json* controls = root.find("controls")) {
    if (!controls->isObject()) return fail(error, "state controls is no object");
    for (const auto& [key, value] : controls->object) {
      if (!value.isNumber() || !std::isfinite(value.number)) {
        return fail(error, "state control " + key + " is invalid");
      }
      out->controls.emplace_back(key, value.number);
    }
  }
  return true;
}

}  // namespace aud_vst3
