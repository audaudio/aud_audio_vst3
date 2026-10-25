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
// - The state is the preset, the parameter values, the control values and
//   the settings of the editor as JSON - no path, no document.

#ifndef AUD_VST3_PLUGIN_HPP
#define AUD_VST3_PLUGIN_HPP

#include <array>
#include <atomic>
#include <bitset>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "public.sdk/source/vst/vstsinglecomponenteffect.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"

#include "aud_spsc_queue.hpp"

#include "aud_vst3_config.hpp"
#include "aud_vst3_shared.hpp"
#include "aud_vst3_param.hpp"

namespace aud_vst3 {

// #############################################################################
// The id of the stepped parameter "Preset", also the id of the program list.
uint32_t presetParamId();

// #############################################################################
// What a view learns from the plugin, on the DAW's UI thread.
class PluginObserver {
 public:
  // ...........................................................................
  // Destroys the observer; it must have been removed from the plugin.
  virtual ~PluginObserver() = default;

  // ...........................................................................
  // A parameter the DAW sees changed through the DAW, a preset or another
  // view.
  virtual void paramChanged(uint32_t id, double normalized) = 0;

  // ...........................................................................
  // The preset at `index` plays now.
  virtual void presetChanged(uint32_t index) = 0;
};

// #############################################################################
// What the editor keeps per plugin instance across its views.
class EditorState {
 public:
  // ...........................................................................
  // Destroys the state, at the latest when the plugin terminates.
  virtual ~EditorState() = default;
};

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

  Steinberg::tresult PLUGIN_API setParamNormalized(
      Steinberg::Vst::ParamID tag, Steinberg::Vst::ParamValue value) SMTG_OVERRIDE;

  // ###########################################################################
  // The settings, the engine and the editor (aud_vst3_editor.mm)

  // ...........................................................................
  // The settings of the bundle; empty before initialize.
  const Settings& settings() const { return settings_; }

  // ...........................................................................
  // The engine; null after terminate, while a view may still exist.
  Engine* engine() { return engine_.get(); }

  // ...........................................................................
  // The number of this plugin instance in the DAW process, from 1.
  uint32_t instance() const { return instance_; }

  // ...........................................................................
  // The mapping of the graph parameter `id` the DAW sees, or null.
  const ParamMapping* mapping(uint32_t id) const;

  // ...........................................................................
  // The normalized value of parameter `id` as the controller holds it.
  double normalized(uint32_t id) { return getParamNormalized(id); }

  // ...........................................................................
  // The index of the preset that plays.
  uint32_t preset() const { return static_cast<uint32_t>(preset_.load()); }

  // ...........................................................................
  // The state of the editor; reset at terminate.
  std::shared_ptr<EditorState>& editorState() { return editorState_; }

  // ...........................................................................
  // [UI thread] The settings the editor of this instance sent last
  // (AudShellSettings, ticket 38), which the state keeps with the DAW's
  // project and every welcome hands to the editor; empty for none.
  const std::string& editorSettings() const { return editorSettings_; }

  // ...........................................................................
  // [UI thread] Keeps the editor's `settings` and tells the DAW that its
  // project changed; false, keeping the old ones, for settings longer than
  // kMaxEditorSettings.
  bool setEditorSettings(std::string settings);

  // ...........................................................................
  // [UI thread] Adds `observer`, which learns every change from now on.
  void addObserver(PluginObserver* observer);

  // ...........................................................................
  // [UI thread] Removes `observer`.
  void removeObserver(PluginObserver* observer);

  // ...........................................................................
  // [UI thread] Begins a gesture of `owner` on parameter `id`. The plugin
  // keeps the open gestures per owner, so that endEdits() closes what a
  // closed view or a crashed editor left open: the DAW must see an endEdit
  // for every beginEdit.
  void editBegin(uint32_t id, const PluginObserver* owner);

  // ...........................................................................
  // [UI thread] Changes parameter `id` in the controller, in the DAW and in
  // every observer but `origin`.
  void edit(uint32_t id, double normalized, PluginObserver* origin);

  // ...........................................................................
  // [UI thread] Ends the gesture of `owner` on parameter `id`.
  void editEnd(uint32_t id, const PluginObserver* owner);

  // ...........................................................................
  // [UI thread] Ends every gesture `owner` left open.
  void endEdits(const PluginObserver* owner);

  // ...........................................................................
  // [UI thread] The editor chose the preset at `index`: it plays, the DAW
  // records the change like a program change, the other observers hear it.
  void selectPreset(uint32_t index, PluginObserver* origin);

  // ...........................................................................
  // [UI thread] MIDI 1.0 bytes the editor played: their channel voice
  // messages play from the next block on and leave through the event
  // output, so that a MIDI track records them; false when they did not all
  // fit the queue.
  bool editorMidi(const std::vector<uint8_t>& bytes);

  // ...........................................................................
  // [UI thread] Ends every note the editor holds, with note offs to the
  // graph and the DAW: the editor ended or crashed, and its note offs never
  // come. Returns how many it ended.
  size_t releaseEditorNotes();

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

  // A message the editor played, on its way to the next block.
  struct EditorMidi {
    uint8_t status;
    uint8_t data1;
    uint8_t data2;
  };

  void notifyPreset(uint32_t index);
  void followEditorNote(uint8_t status, uint8_t data1, uint8_t data2);

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
  void takeEditorMidi(Steinberg::Vst::ProcessData& data) AUD_VST3_NONBLOCKING;
  void addEvent(const AudEvent& event) AUD_VST3_NONBLOCKING;
  int32_t controlIndex(uint32_t id) const;

  const uint32_t instance_;
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
  AudSpscQueue<EditorMidi> editorMidi_{1024};
  // The notes the editor holds, by channel * 128 + key (UI thread).
  std::bitset<16 * 128> editorNotes_;
  // The views and their open gestures (UI thread).
  std::vector<PluginObserver*> observers_;
  std::map<const PluginObserver*, std::set<uint32_t>> openEdits_;
  std::shared_ptr<EditorState> editorState_;
  std::string editorSettings_;  // UI thread
  // Whether the views and the UI thread's blocks may still touch the
  // plugin; terminate clears it on the UI thread.
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
  // Whether initialize retained the UI thread (aud_vst3_ui_thread.hpp).
  bool uiThread_ = false;

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

// #############################################################################
// Creates the editor's view of `plugin` (aud_vst3_editor.mm on macOS,
// aud_vst3_editor_win.cpp on Windows); null when there is none.
Steinberg::IPlugView* createEditorView(Plugin* plugin);

}  // namespace aud_vst3

#endif  // AUD_VST3_PLUGIN_HPP
