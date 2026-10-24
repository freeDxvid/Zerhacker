// Zerhacker – tempo-synced gate + time effect (stutter, reverse, half speed, tape stop), VST3 effect.

#include "shared.h"
#include "public.sdk/source/main/pluginfactory.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "base/source/fstreamer.h"

#include <algorithm>
#include <atomic>
#include <climits>
#include <cmath>
#include <vector>

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {
constexpr int32 kStateMagic = 0x5A524831;  // "ZRH1"
constexpr int kFade = 256;                  // crossfade length at effect changes

struct Path {
    int mode = kNormal;
    double anchor = 0, k = 0, run = 0;  // run start (absolute sample), samples since start, run length
};
} // namespace

class Zerhacker : public SingleComponentEffect, public ZerhackerAPI {
public:
    static FUnknown* createInstance(void*) { return (IAudioProcessor*)new Zerhacker; }

    Zerhacker() {
        FxPattern def = fromPreset(kPresets[0]);
        for (int i = 0; i < kNumParams; i++) p[i] = def.v[i];
    }

    tresult PLUGIN_API initialize(FUnknown* context) override {
        tresult r = SingleComponentEffect::initialize(context);
        if (r != kResultOk) return r;
        alloc();
        addAudioInput(STR16("Stereo In"), SpeakerArr::kStereo);
        addAudioOutput(STR16("Stereo Out"), SpeakerArr::kStereo);
        for (int i = 0; i < kSteps; i++) {
            std::string num = std::to_string(i + 1);
            std::u16string vn = u"Lautstaerke " + std::u16string(num.begin(), num.end());
            std::u16string tn = u"Zeit " + std::u16string(num.begin(), num.end());
            parameters.addParameter((const char16*)vn.c_str(), nullptr, 0, p[kVol0 + i], ParameterInfo::kCanAutomate, kVol0 + i);
            parameters.addParameter((const char16*)tn.c_str(), nullptr, kNumModes - 1, p[kTime0 + i], ParameterInfo::kCanAutomate, kTime0 + i);
        }
        parameters.addParameter(STR16("Glaette"), STR16("%"), 0, p[kSmooth], ParameterInfo::kCanAutomate, kSmooth);
        parameters.addParameter(STR16("Mix"), STR16("%"), 0, p[kMix], ParameterInfo::kCanAutomate, kMix);
        parameters.addParameter(STR16("Rate"), nullptr, 2, p[kRate], ParameterInfo::kCanAutomate, kRate);
        return kResultOk;
    }

    tresult PLUGIN_API setBusArrangements(SpeakerArrangement* ins, int32 numIns, SpeakerArrangement* outs, int32 numOuts) override {
        return (numIns == 1 && numOuts == 1 && ins[0] == SpeakerArr::kStereo && outs[0] == SpeakerArr::kStereo) ? kResultTrue : kResultFalse;
    }

    tresult PLUGIN_API canProcessSampleSize(int32 s) override { return s == kSample32 ? kResultTrue : kResultFalse; }

    tresult PLUGIN_API setupProcessing(ProcessSetup& setup) override {
        sr = setup.sampleRate;
        alloc();
        return SingleComponentEffect::setupProcessing(setup);
    }

    tresult PLUGIN_API setActive(TBool state) override {
        reset();
        return SingleComponentEffect::setActive(state);
    }

    tresult PLUGIN_API process(ProcessData& data) override {
        if (auto* changes = data.inputParameterChanges) {
            for (int32 i = 0; i < changes->getParameterCount(); i++) {
                auto* q = changes->getParameterData(i);
                int32 off; ParamValue v;
                if (!q || q->getPointCount() == 0 || q->getPoint(q->getPointCount() - 1, off, v) != kResultTrue) continue;
                if (q->getParameterId() < kNumParams) p[q->getParameterId()] = v;
            }
        }
        if (data.numInputs == 0 || data.numOutputs == 0 || data.numSamples == 0) return kResultOk;
        AudioBusBuffers& in = data.inputs[0];
        AudioBusBuffers& out = data.outputs[0];
        const int32 n = data.numSamples;
        if (in.numChannels < 2 || out.numChannels < 2 || !in.channelBuffers32 || !out.channelBuffers32) {
            for (int32 c = 0; c < out.numChannels; c++)
                if (out.channelBuffers32 && out.channelBuffers32[c])
                    for (int32 s = 0; s < n; s++)
                        out.channelBuffers32[c][s] = (in.channelBuffers32 && c < in.numChannels) ? in.channelBuffers32[c][s] : 0.f;
            return kResultOk;
        }

        double tempo = 120, ppq0 = freePpq;
        if (auto* ctx = data.processContext) {
            if ((ctx->state & ProcessContext::kTempoValid) && ctx->tempo > 0) tempo = ctx->tempo;
            if ((ctx->state & ProcessContext::kPlaying) && (ctx->state & ProcessContext::kProjectTimeMusicValid)) ppq0 = ctx->projectTimeMusic;
        }
        const double spb = kStepsPerBeat[rateIdx(p[kRate])];
        stepLen = std::min(sr * 60.0 / tempo / spb, (double(N) - 4096) / kSteps);
        const double dppq = tempo / 60.0 / sr;
        const float mix = float(p[kMix]);
        const float smooth = float(1 - std::exp(-1.0 / ((0.0005 + p[kSmooth] * p[kSmooth] * 0.04) * sr)));

        for (int32 s = 0; s < n; s++) {
            long long stepAbs = (long long)std::floor((ppq0 + s * dppq) * spb);
            if (stepAbs != lastStepAbs) onStep(stepAbs);

            float inL = in.channelBuffers32[0][s], inR = in.channelBuffers32[1][s];
            buf[0][size_t(wc % N)] = inL;
            buf[1][size_t(wc % N)] = inR;

            float g1, wetL, wetR;
            double pos = pathPos(cur, g1);
            wetL = readAt(0, pos) * g1;
            wetR = readAt(1, pos) * g1;
            if (fade > 0) {
                float g0, a = float(fade) / kFade;
                double opos = pathPos(old, g0);
                wetL = wetL * (1 - a) + readAt(0, opos) * g0 * a;
                wetR = wetR * (1 - a) + readAt(1, opos) * g0 * a;
                old.k += 1;
                fade--;
            }
            gain += (float(p[kVol0 + step]) - gain) * smooth;
            out.channelBuffers32[0][s] = inL * (1 - mix) + wetL * gain * mix;
            out.channelBuffers32[1][s] = inR * (1 - mix) + wetR * gain * mix;
            wc++;
            cur.k += 1;
        }
        freePpq = ppq0 + n * dppq;
        shownStep = step;
        out.silenceFlags = 0;
        return kResultOk;
    }

    tresult PLUGIN_API setState(IBStream* state) override {
        IBStreamer s(state, kLittleEndian);
        int32 magic = 0, count = 0;
        if (!s.readInt32(magic) || magic != kStateMagic || !s.readInt32(count)) return kResultFalse;
        for (int i = 0; i < count; i++) {
            double v;
            if (!s.readDouble(v)) return kResultFalse;
            if (i < kNumParams) { p[i] = v; setParamNormalized(i, v); }
        }
        if (char8* name = s.readStr8()) { presetName = name; delete[] name; }
        return kResultOk;
    }

    tresult PLUGIN_API getState(IBStream* state) override {
        IBStreamer s(state, kLittleEndian);
        s.writeInt32(kStateMagic);
        s.writeInt32(kNumParams);
        for (int i = 0; i < kNumParams; i++) s.writeDouble(p[i]);
        s.writeStr8(presetName.c_str());
        return kResultOk;
    }

    IPlugView* PLUGIN_API createView(FIDString name) override {
        return FIDStringsEqual(name, ViewType::kEditor) ? createZerhackerEditor(this, this) : nullptr;
    }

    int currentStep() const override { return shownStep; }

private:
    double p[kNumParams];
    double sr = 44100, freePpq = 0, stepLen = 5000;
    std::vector<float> buf[2];
    long long N = 1, wc = 0, lastStepAbs = LLONG_MIN;
    int step = 0, fade = 0;
    float gain = 1;
    Path cur, old;
    std::atomic<int> shownStep{0};

    void alloc() {
        N = (long long)(sr * 16) + 8192;
        buf[0].assign(size_t(N), 0.f);
        buf[1].assign(size_t(N), 0.f);
        reset();
    }

    void reset() {
        std::fill(buf[0].begin(), buf[0].end(), 0.f);
        std::fill(buf[1].begin(), buf[1].end(), 0.f);
        wc = N;  // keep indices positive
        lastStepAbs = LLONG_MIN;
        cur = old = Path{kNormal, double(wc), 0, 0};
        fade = 0;
        gain = float(p[kVol0]);
    }

    void onStep(long long stepAbs) {
        int st = int(((stepAbs % kSteps) + kSteps) % kSteps);
        int m = timeMode(p[kTime0 + st]);
        bool contiguous = stepAbs == lastStepAbs + 1;
        lastStepAbs = stepAbs;
        step = st;
        if (contiguous && m == cur.mode) return;  // the run (or plain playback) continues

        int run = 0;
        while (run < kSteps && timeMode(p[kTime0 + (st + run) % kSteps]) == m) run++;
        old = cur;
        fade = kFade;
        cur = Path{m, double(wc), 0, run * stepLen};
    }

    double pathPos(const Path& t, float& g) const {
        g = 1;
        switch (t.mode) {
        case kRepeat: {
            double L = stepLen * 0.5, f = std::fmod(t.k, L);
            g = float(std::clamp(std::min(f, L - f) / 48.0, 0.0, 1.0));
            return t.anchor + f;
        }
        case kReverse: return t.anchor - 1 - std::min(t.k, t.run);
        case kHalf: return t.anchor + t.k * 0.5;
        case kTape: {
            double T = std::max(t.run, 1.0), kk = std::min(t.k, T);
            g = float(std::clamp((T - kk) / (0.08 * T), 0.0, 1.0));
            return t.anchor + kk - kk * kk / (2 * T);
        }
        default: return t.anchor + t.k;
        }
    }

    float readAt(int c, double pos) const {
        pos = std::clamp(pos, double(wc - N + 2), double(wc));
        long long i0 = (long long)std::floor(pos);
        float f = float(pos - i0);
        return buf[c][size_t(i0 % N)] * (1 - f) + buf[c][size_t((i0 + 1) % N)] * f;
    }
};

BEGIN_FACTORY_DEF("dk", "", "")
    DEF_CLASS2(INLINE_UID(0x2B7C9E14, 0x5F3A4C81, 0xA6D20B7E, 0x91C4F35A),
               PClassInfo::kManyInstances, kVstAudioEffectClass, "Zerhacker", 0,
               PlugType::kFx, "0.9.0", kVstVersionString, Zerhacker::createInstance)
END_FACTORY
