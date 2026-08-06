#include "sfx_player.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "resource.h"

namespace {

// Every shipped clip is 44.1 kHz / mono / 16-bit PCM, so ONE voice format
// serves the whole pool and any voice can play any clip. LoadClipFromResource
// rejects anything else rather than playing it at the wrong speed.
constexpr int kSampleRate = 44100;
constexpr int kChannels = 1;
constexpr int kBitsPerSample = 16;

// Four is already headroom: the real overlap is the pill's rise arriving while
// a completion chime still rings — two. The spare voices cost a few hundred
// bytes each and mean a burst can never eat its own tail.
constexpr size_t kVoiceCount = 4;

constexpr float kPi = 3.14159265358979323846f;

struct WaveData {
  const int16_t* pcm;
  size_t frames;
  int sample_rate;
  int channels;
  int bits;
};

uint32_t ReadU32(const uint8_t* p) {
  uint32_t v;
  std::memcpy(&v, p, sizeof(v));
  return v;
}

uint16_t ReadU16(const uint8_t* p) {
  uint16_t v;
  std::memcpy(&v, p, sizeof(v));
  return v;
}

// Walk the RIFF chunk list properly instead of assuming the canonical 44-byte
// header — plenty of WAV writers slip a LIST/INFO chunk in front of `data`,
// and a fixed offset would then play metadata as audio (loud noise).
bool ParseWave(const uint8_t* bytes, size_t size, WaveData* out) {
  if (!bytes || size < 12) return false;
  if (std::memcmp(bytes, "RIFF", 4) != 0) return false;
  if (std::memcmp(bytes + 8, "WAVE", 4) != 0) return false;

  bool have_fmt = false;
  size_t pos = 12;
  while (pos + 8 <= size) {
    const uint8_t* id = bytes + pos;
    const uint32_t chunk_size = ReadU32(bytes + pos + 4);
    const size_t body = pos + 8;
    if (body + chunk_size > size) break;  // truncated file — use what parsed

    if (std::memcmp(id, "fmt ", 4) == 0 && chunk_size >= 16) {
      const uint16_t format = ReadU16(bytes + body);
      // 1 = PCM, 0xFFFE = WAVE_FORMAT_EXTENSIBLE (PCM underneath for our files)
      if (format != 1 && format != 0xFFFE) return false;
      out->channels = ReadU16(bytes + body + 2);
      out->sample_rate = static_cast<int>(ReadU32(bytes + body + 4));
      out->bits = ReadU16(bytes + body + 14);
      have_fmt = true;
    } else if (std::memcmp(id, "data", 4) == 0) {
      if (!have_fmt) return false;
      out->pcm = reinterpret_cast<const int16_t*>(bytes + body);
      out->frames = chunk_size / sizeof(int16_t);
      return out->frames > 0;
    }
    pos = body + chunk_size + (chunk_size & 1);  // chunks are word-aligned
  }
  return false;
}

}  // namespace

SfxPlayer& SfxPlayer::Instance() {
  static SfxPlayer instance;
  return instance;
}

SfxPlayer::~SfxPlayer() { Shutdown(); }

bool SfxPlayer::Init() {
  std::lock_guard<std::mutex> guard(lock_);
  if (init_attempted_) return ready_;
  init_attempted_ = true;

  if (FAILED(::XAudio2Create(&xaudio_, 0, XAUDIO2_DEFAULT_PROCESSOR))) {
    xaudio_ = nullptr;
    return false;
  }
  if (FAILED(xaudio_->CreateMasteringVoice(&master_))) {
    xaudio_->Release();
    xaudio_ = nullptr;
    master_ = nullptr;
    return false;
  }

  WAVEFORMATEX fmt{};
  fmt.wFormatTag = WAVE_FORMAT_PCM;
  fmt.nChannels = kChannels;
  fmt.nSamplesPerSec = kSampleRate;
  fmt.wBitsPerSample = kBitsPerSample;
  fmt.nBlockAlign = fmt.nChannels * fmt.wBitsPerSample / 8;
  fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;
  fmt.cbSize = 0;

  voices_.reserve(kVoiceCount);
  for (size_t i = 0; i < kVoiceCount; ++i) {
    IXAudio2SourceVoice* voice = nullptr;
    if (FAILED(xaudio_->CreateSourceVoice(&voice, &fmt))) break;
    voices_.push_back(voice);
  }
  if (voices_.empty()) {
    master_->DestroyVoice();
    master_ = nullptr;
    xaudio_->Release();
    xaudio_ = nullptr;
    return false;
  }

  // Ids are the contract with Dart (lib/core/sfx/sfx.dart) — keep in sync.
  LoadClipFromResource("done", IDR_SFX_DONE);
  LoadClipFromResource("pill", IDR_SFX_PILL);

  ready_ = !clips_.empty();
  return ready_;
}

bool SfxPlayer::LoadClipFromResource(const std::string& id, int resource_id) {
  HRSRC found = ::FindResourceW(nullptr, MAKEINTRESOURCEW(resource_id),
                                RT_RCDATA);
  if (!found) return false;
  HGLOBAL loaded = ::LoadResource(nullptr, found);
  if (!loaded) return false;
  const auto* bytes = static_cast<const uint8_t*>(::LockResource(loaded));
  const DWORD size = ::SizeofResource(nullptr, found);

  WaveData wave{};
  if (!ParseWave(bytes, size, &wave)) return false;
  // Wrong format would play at the wrong speed/pitch on this pool. Silence is
  // a better failure than a chipmunk.
  if (wave.sample_rate != kSampleRate || wave.channels != kChannels ||
      wave.bits != kBitsPerSample) {
    return false;
  }

  Clip clip;
  clip.pcm = wave.pcm;
  clip.frames = wave.frames;
  clips_[id] = std::move(clip);
  return true;
}

bool SfxPlayer::ResolveBuffer(const std::string& id, int trim_ms, int fade_ms,
                              const int16_t** out_pcm, size_t* out_frames) {
  auto it = clips_.find(id);
  if (it == clips_.end()) return false;
  Clip& clip = it->second;

  const size_t full = clip.frames;
  size_t want = full;
  if (trim_ms > 0) {
    const size_t trimmed =
        static_cast<size_t>(trim_ms) * kSampleRate / 1000u;
    want = std::min(full, trimmed);
  }
  const bool needs_fade = fade_ms > 0 && want > 0;
  const bool needs_trim = want < full;

  if (!needs_trim && !needs_fade) {
    *out_pcm = clip.pcm;
    *out_frames = full;
    return true;
  }

  // Rebuild only when the shape actually changed (HUD move), not per play.
  if (clip.derived_trim_ms != trim_ms || clip.derived_fade_ms != fade_ms ||
      clip.derived.size() != want) {
    clip.derived.assign(clip.pcm, clip.pcm + want);
    if (needs_fade) {
      size_t fade = static_cast<size_t>(fade_ms) * kSampleRate / 1000u;
      fade = std::min(fade, want);
      const size_t start = want - fade;
      for (size_t i = 0; i < fade; ++i) {
        // Raised cosine, not a straight line: a linear tail on a sustained
        // tone is audible as a corner, this one just stops existing.
        const float t = static_cast<float>(i) / static_cast<float>(fade);
        const float g = 0.5f * (1.0f + std::cos(kPi * t));
        clip.derived[start + i] =
            static_cast<int16_t>(clip.derived[start + i] * g);
      }
    }
    clip.derived_trim_ms = trim_ms;
    clip.derived_fade_ms = fade_ms;
  }

  *out_pcm = clip.derived.data();
  *out_frames = clip.derived.size();
  return *out_frames > 0;
}

IXAudio2SourceVoice* SfxPlayer::AcquireVoice() {
  // Prefer a voice that has finished on its own.
  for (size_t i = 0; i < voices_.size(); ++i) {
    const size_t idx = (next_voice_ + i) % voices_.size();
    XAUDIO2_VOICE_STATE state{};
    voices_[idx]->GetState(&state, XAUDIO2_VOICE_NOSAMPLESPLAYED);
    if (state.BuffersQueued == 0) {
      next_voice_ = (idx + 1) % voices_.size();
      return voices_[idx];
    }
  }
  // All eight busy — steal the round-robin next one. Cutting the oldest tick
  // is inaudible; refusing to play the newest one is not.
  IXAudio2SourceVoice* voice = voices_[next_voice_];
  next_voice_ = (next_voice_ + 1) % voices_.size();
  voice->Stop(0);
  voice->FlushSourceBuffers();
  return voice;
}

void SfxPlayer::Play(const std::string& id, float gain, int trim_ms,
                     int fade_ms) {
  std::lock_guard<std::mutex> guard(lock_);
  if (!ready_ || gain <= 0.0f) return;

  const int16_t* pcm = nullptr;
  size_t frames = 0;
  if (!ResolveBuffer(id, trim_ms, fade_ms, &pcm, &frames)) return;

  IXAudio2SourceVoice* voice = AcquireVoice();
  if (!voice) return;
  voice->Stop(0);
  voice->FlushSourceBuffers();

  XAUDIO2_BUFFER buffer{};
  buffer.AudioBytes = static_cast<UINT32>(frames * sizeof(int16_t));
  buffer.pAudioData = reinterpret_cast<const BYTE*>(pcm);
  buffer.Flags = XAUDIO2_END_OF_STREAM;
  // pAudioData must stay alive until the voice drains it. Both sources are
  // stable for the process lifetime: RCDATA lives in the mapped image, and
  // `derived` is only ever reassigned from the platform thread that also
  // submits — a rebuild cannot race a voice that is reading it.
  if (FAILED(voice->SubmitSourceBuffer(&buffer))) return;

  voice->SetVolume(std::clamp(gain, 0.0f, 1.0f));
  voice->Start(0);
}

void SfxPlayer::Shutdown() {
  std::lock_guard<std::mutex> guard(lock_);
  ready_ = false;
  for (auto* voice : voices_) {
    voice->Stop(0);
    voice->FlushSourceBuffers();
    voice->DestroyVoice();
  }
  voices_.clear();
  clips_.clear();
  if (master_) {
    master_->DestroyVoice();
    master_ = nullptr;
  }
  if (xaudio_) {
    xaudio_->Release();
    xaudio_ = nullptr;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CHANNEL
// ═══════════════════════════════════════════════════════════════════════════

namespace {

double GetDouble(const flutter::EncodableMap& map, const char* key,
                 double fallback) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
  if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*i64);
  }
  return fallback;
}

int GetInt(const flutter::EncodableMap& map, const char* key, int fallback) {
  return static_cast<int>(GetDouble(map, key, fallback));
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterSfxChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "slate/sfx",
          &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler([](const auto& call, auto result) {
    const std::string& method = call.method_name();

    if (method == "play") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (!args) {
        result->Error("bad_args", "play expects a map");
        return;
      }
      auto id_it = args->find(flutter::EncodableValue("id"));
      const auto* id =
          id_it == args->end() ? nullptr : std::get_if<std::string>(&id_it->second);
      if (!id) {
        result->Error("bad_args", "play expects a string id");
        return;
      }
      SfxPlayer::Instance().Play(
          *id, static_cast<float>(GetDouble(*args, "gain", 1.0)),
          GetInt(*args, "trimMs", 0), GetInt(*args, "fadeMs", 0));
      // Reply immediately — Dart never awaits this, and holding the reply
      // would put channel latency in front of the next keystroke.
      result->Success();
      return;
    }

    if (method == "init") {
      result->Success(flutter::EncodableValue(SfxPlayer::Instance().Init()));
      return;
    }

    result->NotImplemented();
  });

  return channel;
}
