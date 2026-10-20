// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The VST3 shell (ticket 37, S18 on macOS): an instrument over the headless
// host, processor and controller in one object (SingleComponentEffect). It
// plays the graph document of the app that built it, with the app's node
// packages linked in (doc/plugin-bundle.md):
//
// - Its presets are the program list and the stepped parameter "Preset";
//   a preset applies its node presets on the control thread.
// - The DAW sees the graph parameters plugin.json lists, under their stable
//   ids, and the controls, which send MIDI control changes.
// - The DAW's notes and, through IMidiMapping, its control changes, channel
//   pressure and pitch bend reach the graph's event input at their sample
//   offsets (aud_vst3_midi.hpp); the DAW's transport drives the graph's
//   (aud_vst3_transport.hpp).
// - The state is the preset, the parameter values and the control values as
//   JSON - no path, no document.

#ifndef AUD_VST3_PLUGIN_HPP
#define AUD_VST3_PLUGIN_HPP

#include <array>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include "public.sdk/source/vst/vstsinglecomponenteffect.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"

#include "aud_spsc_queue.hpp"

#include "aud_vst3_config.hpp"
#include "aud_vst3_engine.hpp"
#include "aud_vst3_param.hpp"
#include "aud_vst3_settings.hpp"
#include "aud_vst3_transport.hpp"

namespace aud_vst3 {

// #############################################################################
// The id of the stepped parameter "Preset", also the id of the program list.
uint32_t presetParamId();

// #############################################################################
// The plugin; see above. The DAW calls it on its UI thread, and process() on
// its realtime thread.
class Plugin : public Steinberg::Vst::SingleComponentEffect,
               public Steinberg::Vst::IMidiMapping {
 public:
  // ...........................................................................
  // Creates the plugin; initialize() reads the settings and opens the engine.
  Plugin();

  // ...........................................................................
  // Destroys the plugin, which terminate() has emptied.
  ~Plugin() override;

  // ...........................................................................
  // Creates a plugin for the factory.
  static Steinberg::FUnknown* createInstance(void* context);

  // ###########################################################################
  // IPluginBase

  Steinberg::tresult PLUGIN_API initialize(FUnknown* context) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API terminate() SMTG_OVERRIDE;

  // ###########################################################################
  // IComponent and IEditController (one object, one state)

  Steinberg::tresult PLUGIN_API setActive(Steinberg::TBool state) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setState(Steinberg::IBStream* state) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API getState(Steinberg::IBStream* state) SMTG_OVERRIDE;

  // ###########################################################################
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

  // ###########################################################################
  // IEditController

  Steinberg::IPlugView* PLUGIN_API createView(Steinberg::FIDString name) SMTG_OVERRIDE;

  // ###########################################################################
  // IMidiMapping

  Steinberg::tresult PLUGIN_API getMidiControllerAssignment(
      Steinberg::int32 busIndex, Steinberg::int16 channel,
      Steinberg::Vst::CtrlNumber midiControllerNumber,
      Steinberg::Vst::ParamID& id) SMTG_OVERRIDE;

  // ###########################################################################
  // The settings and the engine, for the views

  // ...........................................................................
  // The settings of the bundle; empty before initialize.
  const Settings& settings() const { return settings_; }

  // ...........................................................................
  // The engine; null after terminate, while a view may still exist.
  Engine* engine() { return engine_.get(); }

  // ###########################################################################
  // FUnknown

  OBJ_METHODS(Plugin, SingleComponentEffect)
  DEFINE_INTERFACES
  DEF_INTERFACE(IMidiMapping)
  END_DEFINE_INTERFACES(SingleComponentEffect)
  REFCOUNT_METHODS(SingleComponentEffect)

 private:
  // The most events one block hands the graph; more are dropped.
  static constexpr uint32_t kMaxEvents = 2048;

  // A control's value on its way from the UI thread to the next block.
  struct ControlChange {
    uint32_t index;
    float value;
  };

  void addParameters();
  void addMidiParameters();
  void presetApplied(Engine& engine, uint32_t index);
  int32_t presetOf(double normalized) const;
  // [realtime] The parts of process().
  void takeParams(Steinberg::Vst::ProcessData& data, Engine& engine,
                  uint32_t frames) AUD_VST3_NONBLOCKING;
  void takeEvents(Steinberg::Vst::ProcessData& data,
                  uint32_t frames) AUD_VST3_NONBLOCKING;
  void takeTransport(Steinberg::Vst::ProcessData& data,
                     uint32_t frames) AUD_VST3_NONBLOCKING;
  void addEvent(const AudEvent& event) AUD_VST3_NONBLOCKING;
  const ParamMapping* mapping(uint32_t id) const;
  int32_t controlIndex(uint32_t id) const;

  Settings settings_;
  std::unique_ptr<Engine> engine_;
  // The engine as process() sees it and the process calls in flight:
  // terminate() takes the engine away and waits for them, so that a
  // process() racing it never touches a freed engine.
  std::atomic<Engine*> rtEngine_{nullptr};
  std::atomic<int32_t> processing_{0};
  // The mappings of the graph parameters the DAW sees, sorted by id; read
  // by the realtime thread, written before processing.
  std::vector<ParamMapping> mappings_;
  // The ids of the controls' parameters, in the order of the settings.
  std::vector<uint32_t> controlIds_;
  // Whether the hidden MIDI parameters are there (no id collided).
  std::vector<bool> midiParams_;
  // The preset that plays, and the controls' last values, NaN for one that
  // never moved (realtime thread writes, getState reads).
  std::atomic<int32_t> preset_{0};
  std::unique_ptr<std::atomic<float>[]> controlValues_;
  AudSpscQueue<ControlChange> controlChanges_{64};
  // Whether the views and the UI thread's blocks may still touch the
  // plugin; terminate clears it on the UI thread.
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);

  // The realtime thread's block: events, transport.
  std::array<AudEvent, kMaxEvents> events_{};
  uint32_t numEvents_ = 0;
  uint64_t droppedEvents_ = 0;
  TransportClock clock_;
  AudTransportSegment segment_{};
  AudTransportSnapshot snapshot_{};
  double sampleRate_ = 48000;
  uint32_t latency_ = 0;
  uint32_t tail_ = 0;
};

}  // namespace aud_vst3

#endif  // AUD_VST3_PLUGIN_HPP
