#ifndef RUNNER_SFX_PLAYER_H_
#define RUNNER_SFX_PLAYER_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <xaudio2.h>

#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// ═══════════════════════════════════════════════════════════════════════════
// SFX PLAYER — the mixer behind Slate's one sound.
//
// Native rather than a pub.dev package for a concrete reason: this process
// hosts TWO Flutter engines (the main window and the capture pill — see
// main.cpp). A Dart audio plugin would have to be registered on both, giving
// two independent device sessions that cannot mix with each other. One C++
// mixer below both engines has no such seam, and costs less: no plugin
// registration, no asset loading, no channel hop per sound.
//
// The clip is embedded in the exe as RCDATA (Runner.rc), so there is no file
// I/O, no path resolution, and no way to ship a build with the audio missing.
// A resource is already mapped into the image, so `pcm` points straight at it:
// zero copies, zero allocation on the hot path.
// ═══════════════════════════════════════════════════════════════════════════

class SfxPlayer {
 public:
  static SfxPlayer& Instance();

  // Idempotent. Returns false when the machine has no usable audio device —
  // every later Play() is then a silent no-op, never an error.
  bool Init();
  void Shutdown();

  // Fire and forget; `gain` is linear 0..1. Must never block the platform
  // thread — a stall here would be a stutter in the UI that triggered it.
  void Play(const std::string& id, float gain);

 private:
  SfxPlayer() = default;
  ~SfxPlayer();
  SfxPlayer(const SfxPlayer&) = delete;
  SfxPlayer& operator=(const SfxPlayer&) = delete;

  struct Clip {
    const int16_t* pcm = nullptr;  // into the RCDATA image — always valid
    size_t samples = 0;
  };

  // Grab a free voice, or steal the oldest one. Caller holds `lock_`.
  IXAudio2SourceVoice* AcquireVoice();

  bool LoadClipFromResource(const std::string& id, int resource_id);

  IXAudio2* xaudio_ = nullptr;
  IXAudio2MasteringVoice* master_ = nullptr;
  std::map<std::string, Clip> clips_;
  std::vector<IXAudio2SourceVoice*> voices_;
  size_t next_voice_ = 0;
  bool ready_ = false;
  bool init_attempted_ = false;
  std::mutex lock_;
};

// Wire the `slate/sfx` channel onto the main engine. The returned channel must
// outlive that engine, so the caller stores it.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterSfxChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SFX_PLAYER_H_
