#pragma once
// Must come first: this header renames EditController::get/setState for the single-component class.
#include "public.sdk/source/vst/vstsinglecomponenteffect.h"
#include "pluginterfaces/gui/iplugview.h"

#include <random>
#include <string>

static const int kSteps = 16;
enum Param { kVol0 = 0, kTime0 = kSteps, kSmooth = 2 * kSteps, kMix, kRate, kNumParams };
enum TimeMode { kNormal, kRepeat, kReverse, kHalf, kTape, kNumModes };

inline int timeMode(double v) { return std::min(kNumModes - 1, int(v * (kNumModes - 1) + 0.5)); }
inline double timeValue(int m) { return double(m) / (kNumModes - 1); }
inline int rateIdx(double v) { return std::min(2, int(v * 2 + 0.5)); }   // 1/8, 1/16, 1/32
static const double kStepsPerBeat[3] = {2, 4, 8};

struct FxPreset {
    const char* name;
    const char* vol;   // 16 digits, 0..9
    const char* time;  // 16 chars: - normal, r repeat, v reverse, h half, t tape stop
    double smooth;
    int rate;
};

static const FxPreset kPresets[] = {
    {"Leer", "9999999999999999", "----------------", 0.2, 1},
    {"Gate 1/16", "9090909090909090", "----------------", 0.15, 1},
    {"Gate 1/8", "9900990099009900", "----------------", 0.15, 1},
    {"Off-Beat", "0099009900990099", "----------------", 0.2, 1},
    {"Sidechain Pump", "2579257925792579", "----------------", 0.5, 1},
    {"Hard Pump", "0369036903690369", "----------------", 0.35, 1},
    {"Dotted Gate", "9909909909909909", "----------------", 0.15, 1},
    {"Trap Chop", "9909009909090900", "----------------", 0.15, 1},
    {"Drill Bounce", "9900909009009090", "----------------", 0.15, 1},
    {"Triplet Feel", "9009009009009009", "----------------", 0.2, 1},
    {"Ghost Notes", "9393939393939393", "----------------", 0.25, 1},
    {"Echo Chop", "9050905090509050", "----------------", 0.2, 1},
    {"Swing Gate", "9909099099090990", "----------------", 0.15, 1},
    {"Breakdown", "9999999955553333", "----------------", 0.4, 1},
    {"Stop & Go", "9999999900009999", "----------------", 0.2, 1},
    {"Mute letzter Beat", "9999999999990000", "----------------", 0.2, 1},
    {"Stutter Ende", "9999999999999999", "------------rrrr", 0.2, 1},
    {"Stutter Beat 3", "9999999999999999", "--------rrrr----", 0.2, 1},
    {"Roll Fill", "9999999999997777", "--------rrrrrrrr", 0.2, 1},
    {"Stutter Roll Gate", "9999999990909090", "--------rrrrrrrr", 0.15, 1},
    {"Build Up", "9000900090909999", "------------rrrr", 0.15, 1},
    {"Half Time", "9999999999999999", "hhhhhhhhhhhhhhhh", 0.2, 1},
    {"Half Time Drop", "9999999999999999", "--------hhhhhhhh", 0.2, 1},
    {"Half & Reverse", "9999999999999999", "hhhhhhhhvvvvvvvv", 0.2, 1},
    {"Lo-Fi Wobble", "9797979797979797", "hh--hh--hh--hh--", 0.3, 1},
    {"Tape Stop", "9999999999999999", "------------tttt", 0.2, 1},
    {"Langer Tape Stop", "9999999999999999", "--------tttttttt", 0.2, 1},
    {"Tape Stop Takt", "9999999999999999", "tttttttttttttttt", 0.2, 1},
    {"Pump + Stop", "2579257925792579", "------------tttt", 0.5, 1},
    {"Reverse Ende", "9999999999999999", "------------vvvv", 0.2, 1},
    {"Reverse Snare", "9999999999999999", "----vv------vv--", 0.2, 1},
    {"Reverse Beat", "9999999999999999", "vvvv----vvvv----", 0.2, 1},
    {"Glitch 1", "9909990999909999", "--r---v---rr--t-", 0.15, 1},
    {"Glitch 2", "9999999999999999", "-rr--v--r--vv-tt", 0.15, 1},
    {"Glitch 1/32", "9909990999909999", "----rr------vvrr", 0.1, 2},
    {"Slow Gate 1/8", "9909909099099090", "--------------tt", 0.25, 0},
};
static const int kNumPresets = int(sizeof(kPresets) / sizeof(kPresets[0]));

struct FxPattern {
    std::string name;
    double v[kNumParams];
};

inline int modeFromChar(char c) {
    switch (c) { case 'r': return kRepeat; case 'v': return kReverse; case 'h': return kHalf; case 't': return kTape; default: return kNormal; }
}

inline FxPattern fromPreset(const FxPreset& p) {
    FxPattern out;
    out.name = p.name;
    for (int i = 0; i < kSteps; i++) {
        out.v[kVol0 + i] = (p.vol[i] - '0') / 9.0;
        out.v[kTime0 + i] = timeValue(modeFromChar(p.time[i]));
    }
    out.v[kSmooth] = p.smooth;
    out.v[kMix] = 1;
    out.v[kRate] = p.rate / 2.0;
    return out;
}

// Musical randomizer: beat-sized motifs in A-A-A-B style plus sparse time effects, mostly at the end of the bar.
inline FxPattern randomPattern(std::mt19937& rng) {
    auto U = [&](double a, double b) { return std::uniform_real_distribution<double>(a, b)(rng); };
    auto I = [&](int a, int b) { return std::uniform_int_distribution<int>(a, b)(rng); };
    static const char* motifs[] = {"9999", "9090", "9900", "0099", "9009", "2579", "0369", "9909", "9099", "9390", "9000", "9990", "9939"};
    static const char* forms[] = {"AAAB", "ABAB", "AAAA", "ABAC", "AABB"};
    const int nm = int(sizeof(motifs) / sizeof(motifs[0]));
    const char* m[3] = {motifs[I(0, nm - 1)], motifs[I(0, nm - 1)], motifs[I(0, nm - 1)]};
    const char* form = forms[I(0, 4)];

    std::string vol, time(kSteps, '-');
    for (int b = 0; b < 4; b++) vol += m[form[b] - 'A'];
    if (U(0, 1) < 0.65) {
        static const char fx[] = {'r', 'r', 't', 'v', 'h'};
        char c = fx[I(0, 4)];
        int len = (c == 'h' || c == 't') && U(0, 1) < 0.5 ? 8 : (U(0, 1) < 0.5 ? 4 : 2);
        for (int i = kSteps - len; i < kSteps; i++) time[i] = c;
    }
    if (U(0, 1) < 0.3) { int s = I(2, 3) * 2; time[s] = time[s + 1] = U(0, 1) < 0.5 ? 'r' : 'v'; }

    FxPreset p{"", vol.c_str(), time.c_str(), U(0.1, 0.45), U(0, 1) < 0.15 ? 0 : 1};
    FxPattern out = fromPreset(p);
    out.name = "Zufall #" + std::to_string(I(100, 999));
    return out;
}

struct ZerhackerAPI {
    virtual ~ZerhackerAPI() = default;
    virtual int currentStep() const = 0;
    std::string presetName = "Leer";
    int presetIndex = 0;
};

Steinberg::IPlugView* createZerhackerEditor(Steinberg::Vst::EditController* controller, ZerhackerAPI* api);
