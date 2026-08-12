#include "sfx_player.h"

#include <algorithm>
#include <cstring>

#include "resource.h"

namespace {

// The shipped clip is 44.1 kHz / mono / 16-bit PCM, so one voice format serves
// the whole pool. LoadClipFromResource rejects anything else rather than
// playing it at the wrong speed.
constexpr int kSampleRate = 44100;
constexpr int kChannels = 1;
constexpr int kBitsPerSample = 16;

// Four is already headroom for a 0.3 s sound: ticking tasks faster than three
// deep is not a thing a person does. The spare voices cost a few hundred bytes
// each and mean a burst can never eat its own tail.
constexpr size_t kVoiceCount = 4;

struct WaveData {
  const int16_t* pcm;
  size_t samples;
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
      // 1 = PCM, 0xFFFE = WAVE_FORMAT_EXTENSIBLE (PCM underneath for our file)
      if (format != 1 && format != 0xFFFE) return false;
      out->channels = ReadU16(bytes + body + 2);
      out->sample_rate = static_cast<int>(ReadU32(bytes + body + 4));
      out->bits = ReadU16(bytes + body + 14);
      have_fmt = true;
    } else if (std::memcmp(id, "data", 4) == 0) {
      if (!have_fmt) return false;
      out->pcm = reinterpret_cast<const int16_t*>(bytes + body);
      out->samples = chunk_size / sizeof(int16_t);
      return out->samples > 0;
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

  // The id is the contract with Dart (lib/core/sfx/sfx.dart) — keep in sync.
  LoadClipFromResource("done", IDR_SFX_DONE);
  // Reminder chime. Until its own clip ships (44.1 kHz / mono / 16-bit PCM,
  // see the format gate in LoadClipFromResource), fall back to the completion
  // one at a different gain: a reminder that makes NO sound is a reminder that
  // does not exist, and that is the one failure this feature cannot afford.
  if (!LoadClipFromResource("due", IDR_SFX_DUE)) {
    LoadClipFromResource("due", IDR_SFX_DONE);
  }

  ready_ = !clips_.empty();
  return ready_;
}

bool SfxPlayer::LoadClipFromResource(const std::string& id, int resource_id) {
  HRSRC found =
      ::FindResourceW(nullptr, MAKEINTRESOURCEW(resource_id), RT_RCDATA);
  if (!found) return false;
  HGLOBAL loaded = ::LoadResource(nullptr, found);
  if (!loaded) return false;
  const auto* bytes = static_cast<const uint8_t*>(::LockResource(loaded));
  const DWORD size = ::SizeofResource(nullptr, found);

  WaveData wave{};
  if (!ParseWave(bytes, size, &wave)) return false;
  // A wrong format would play at the wrong speed and pitch on this pool.
  // Silence is a better failure than a chipmunk.
  if (wave.sample_rate != kSampleRate || wave.channels != kChannels ||
      wave.bits != kBitsPerSample) {
    return false;
  }

  clips_[id] = Clip{wave.pcm, wave.samples};
  return true;
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
  // All busy — steal the round-robin next one. Cutting the oldest tail is
  // inaudible; refusing to play the newest chime is not.
  IXAudio2SourceVoice* voice = voices_[next_voice_];
  next_voice_ = (next_voice_ + 1) % voices_.size();
  voice->Stop(0);
  voice->FlushSourceBuffers();
  return voice;
}

void SfxPlayer::Play(const std::string& id, float gain) {
  std::lock_guard<std::mutex> guard(lock_);
  if (!ready_ || gain <= 0.0f) return;

  auto it = clips_.find(id);
  if (it == clips_.end()) return;

  IXAudio2SourceVoice* voice = AcquireVoice();
  if (!voice) return;
  voice->Stop(0);
  voice->FlushSourceBuffers();

  XAUDIO2_BUFFER buffer{};
  buffer.AudioBytes = static_cast<UINT32>(it->second.samples * sizeof(int16_t));
  buffer.pAudioData = reinterpret_cast<const BYTE*>(it->second.pcm);
  buffer.Flags = XAUDIO2_END_OF_STREAM;
  // pAudioData must outlive the voice reading it. RCDATA lives in the mapped
  // image for the whole process, so it always does.
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
      const auto* id = id_it == args->end()
                           ? nullptr
                           : std::get_if<std::string>(&id_it->second);
      if (!id) {
        result->Error("bad_args", "play expects a string id");
        return;
      }
      double gain = 1.0;
      auto gain_it = args->find(flutter::EncodableValue("gain"));
      if (gain_it != args->end()) {
        if (const auto* d = std::get_if<double>(&gain_it->second)) gain = *d;
      }
      SfxPlayer::Instance().Play(*id, static_cast<float>(gain));
      // Reply immediately — Dart never awaits this, and holding the reply
      // would put channel latency in front of the frame that caused it.
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
