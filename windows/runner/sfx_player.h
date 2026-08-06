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
// SFX PLAYER — one XAudio2 mixer for the whole PROCESS.
//
// Why native and not a pub.dev package: this process runs TWO Flutter engines
// (the main window and the capture pill — see main.cpp). A Dart audio package
// would have to be registered on both, giving two independent device sessions
// that cannot mix with each other — the pill's entrance sound could never
// overlap a chime from the main window, they would fight for the device. One
// C++ mixer below both engines is the only way they share a voice pool.
//
// The clips are embedded in the exe as RCDATA (Runner.rc), so there is no file
// I/O, no path resolution, and no way to ship a build with missing sounds.
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

  // Fire and forget. Must never block the platform thread: a stalled call here
  // would be a stutter in the UI that triggered the sound.
  //   gain    linear 0..1 (already multiplied by the caller's master)
  //   trim_ms 0 = play whole clip; >0 = play only the head, this long
  //   fade_ms fade-out length applied at the end of the (trimmed) clip
  void Play(const std::string& id, float gain, int trim_ms, int fade_ms);

 private:
  SfxPlayer() = default;
  ~SfxPlayer();
  SfxPlayer(const SfxPlayer&) = delete;
  SfxPlayer& operator=(const SfxPlayer&) = delete;

  struct Clip {
    const int16_t* pcm = nullptr;  // into the RCDATA image — always valid
    size_t frames = 0;

    // Trim+fade is a different waveform, so it cannot be done by XAudio2 flags.
    // We render it ONCE into `derived` and keep the parameters that produced
    // it; a HUD tweak rebuilds it, playback reuses it. Never rebuilt on a
    // keystroke-rate path (only progress_loop is ever trimmed).
    std::vector<int16_t> derived;
    int derived_trim_ms = -1;
    int derived_fade_ms = -1;
  };

  // Resolves `id` to the buffer/length to submit, building the trimmed variant
  // on demand. Caller holds `lock_`.
  bool ResolveBuffer(const std::string& id, int trim_ms, int fade_ms,
                     const int16_t** out_pcm, size_t* out_frames);

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

// Wire the `slate/sfx` channel onto an engine. Called for BOTH engines; they
// share the single SfxPlayer above. The returned channel must outlive the
// engine, so the caller stores it.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterSfxChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SFX_PLAYER_H_
