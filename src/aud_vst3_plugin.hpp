// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The spike plugin of ticket 24: a VST3 over the headless host, processor
// and controller in one object (SingleComponentEffect). It loads the graph
// document of its bundle, exposes the document's parameters under their
// stable ids and renders through aud_host_render. The editor depends on
// the variant (aud_vst3_config.hpp).

#ifndef AUD_VST3_PLUGIN_HPP
#define AUD_VST3_PLUGIN_HPP

#include <atomic>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "aud_vst3_config.hpp"
#include "aud_vst3_engine.hpp"
#include "aud_vst3_param.hpp"
#include "aud_vst3_probe.hpp"
#include "public.sdk/source/vst/vstsinglecomponenteffect.h"

namespace aud_vst3 {

// The id of the parameter that starts the synthetic knob drag of the
// latency measurement in an open editor: the stable id of "spike/test",
// a node id no document of the spike uses. VST3 leaves the top bit of a
// parameter id to the host, as the stable ids do.
uint32_t testParamId();

// What a view learns from the plugin, on the host's UI thread.
class ParamObserver {
 public:
  virtual ~ParamObserver() = default;
  // A parameter changed through the host or another view.
  virtual void paramChanged(uint32_t id, double normalized) = 0;
  // The test parameter asks for the synthetic drag.
  virtual void testRequested() {}
};

// What an editor variant keeps across its views: the editor process of
// variant A stays warm after its view closes (open question 2).
class EditorState {
 public:
  virtual ~EditorState() = default;
};

class Plugin : public Steinberg::Vst::SingleComponentEffect {
 public:
  Plugin();
  ~Plugin() override;

  static Steinberg::FUnknown* createInstance(void* context);

  // IPluginBase
  Steinberg::tresult PLUGIN_API initialize(FUnknown* context) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API terminate() SMTG_OVERRIDE;

  // IComponent and IEditController (one object, one state)
  Steinberg::tresult PLUGIN_API setActive(Steinberg::TBool state) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setState(Steinberg::IBStream* state) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API getState(Steinberg::IBStream* state) SMTG_OVERRIDE;

  // IAudioProcessor
  Steinberg::tresult PLUGIN_API setBusArrangements(
      Steinberg::Vst::SpeakerArrangement* inputs, Steinberg::int32 numIns,
      Steinberg::Vst::SpeakerArrangement* outputs,
      Steinberg::int32 numOuts) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API canProcessSampleSize(
      Steinberg::int32 symbolicSampleSize) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setupProcessing(
      Steinberg::Vst::ProcessSetup& setup) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setProcessing(Steinberg::TBool state) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API process(Steinberg::Vst::ProcessData& data) SMTG_OVERRIDE;
  Steinberg::uint32 PLUGIN_API getLatencySamples() SMTG_OVERRIDE;
  Steinberg::uint32 PLUGIN_API getTailSamples() SMTG_OVERRIDE;

  // IEditController
  Steinberg::IPlugView* PLUGIN_API createView(Steinberg::FIDString name) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setParamNormalized(
      Steinberg::Vst::ParamID tag, Steinberg::Vst::ParamValue value) SMTG_OVERRIDE;

  // [UI thread] The edits of a view: begin, change and end a gesture.
  // `inputStamp` is the time of the input event that caused the change.
  // The plugin keeps the open gestures per `owner` (a view), so that
  // endEdits() closes what a closed view or a crashed editor left open:
  // the host must see an endEdit for every beginEdit.
  void editBegin(uint32_t id, const void* owner);
  void edit(uint32_t id, double normalized, int64_t inputStamp,
            ParamObserver* origin);
  void editEnd(uint32_t id, const void* owner);
  void endEdits(const void* owner);

  void addObserver(ParamObserver* observer);
  void removeObserver(ParamObserver* observer);

  // The parameters of the document, ordered by id; none after terminate.
  const std::vector<EngineParam>& params() const;
  const ParamMapping* mapping(uint32_t id) const;
  double normalized(uint32_t id);

  // The state of the editor variant; reset at terminate.
  std::shared_ptr<EditorState>& editorState() { return editorState_; }

  // The engine; null after terminate, while a view may still exist.
  Engine* engine() { return engine_.get(); }
  Probe& probe() { return *probe_; }
  uint32_t instance() const { return instance_; }
  // Whether the inline-symbol skew test found this image's own registry.
  bool skewOk() const { return skewOk_; }

  OBJ_METHODS(Plugin, SingleComponentEffect)
  REFCOUNT_METHODS(SingleComponentEffect)

 private:
  static std::string bundledDocument();
  // [realtime] The body of process(): parameters to the engine, then one
  // block.
  void pushChanges(Steinberg::Vst::ProcessData& data,
                   Engine& engine) AUD_VST3_NONBLOCKING;
  void renderBlock(Steinberg::Vst::ProcessData& data,
                   Engine& engine) AUD_VST3_NONBLOCKING;

  const uint32_t instance_;
  std::unique_ptr<Probe> probe_;
  std::unique_ptr<Engine> engine_;
  // The engine as process() sees it and the process calls in flight:
  // terminate() takes the engine away and waits for them, so that a
  // process() racing it never touches a freed engine.
  std::atomic<Engine*> rtEngine_{nullptr};
  std::atomic<int32_t> processing_{0};
  // Sorted by id; read by the realtime thread, written before processing.
  std::vector<ParamMapping> mappings_;
  std::vector<ParamObserver*> observers_;
  // The open gestures by owner (UI thread).
  std::map<const void*, std::set<uint32_t>> openEdits_;
  std::shared_ptr<EditorState> editorState_;
  bool skewOk_ = true;
  bool rtsanProbe_ = false;
  bool testRunning_ = false;
};

// Creates the editor of this build's variant, or NULL for the generic view.
Steinberg::IPlugView* createEditorView(Plugin* plugin);

}  // namespace aud_vst3

#endif  // AUD_VST3_PLUGIN_HPP
