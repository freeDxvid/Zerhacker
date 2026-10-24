#import <Cocoa/Cocoa.h>
// Offline test: runs every preset and random patterns with a running transport, checks for
// NaN, clipping and missing effect, and saves a screenshot of the editor.
#include "../src/plugin.cpp"
#include "public.sdk/source/common/memorystream.h"

static void run(Zerhacker* z, const FxPattern& pat, double& rmsIn, double& rmsOut, double& peak, double& diff, bool& bad) {
    for (int i = 0; i < kNumParams; i++) z->setParamNormalized(i, pat.v[i]);
    // push params through process() like a host would: simplest is direct state load
    MemoryStream ms; z->setActive(false);
    {
        IBStreamer s(&ms, kLittleEndian);
        s.writeInt32(0x5A524831); s.writeInt32(kNumParams);
        for (int i = 0; i < kNumParams; i++) s.writeDouble(pat.v[i]);
        s.writeStr8(pat.name.c_str());
    }
    ms.seek(0, IBStream::kIBSeekSet, nullptr);
    z->setState(&ms);
    z->setActive(true);
    const int bs = 512; const double sr = 48000, bpm = 140;
    std::vector<float> iL(bs), iR(bs), oL(bs), oR(bs);
    float* ib[2] = {iL.data(), iR.data()}; float* ob[2] = {oL.data(), oR.data()};
    AudioBusBuffers in{}, out{}; in.numChannels = out.numChannels = 2; in.channelBuffers32 = ib; out.channelBuffers32 = ob;
    ProcessContext ctx{}; ctx.state = ProcessContext::kPlaying | ProcessContext::kTempoValid | ProcessContext::kProjectTimeMusicValid; ctx.tempo = bpm;
    double si = 0, so = 0, d = 0; peak = 0; bad = false; long n = 0, t = 0;
    for (int b = 0; b < int(sr * 8 / bs); b++) {
        for (int i = 0; i < bs; i++, t++) {
            double ph = t / sr;
            float x = float(0.4 * std::sin(6.283 * 220 * ph) * (0.6 + 0.4 * std::sin(6.283 * 0.5 * ph)));
            iL[i] = x; iR[i] = x * 0.9f;
        }
        ctx.projectTimeMusic = (double(b) * bs / sr) * bpm / 60;
        ProcessData pd{}; pd.numSamples = bs; pd.numInputs = pd.numOutputs = 1; pd.inputs = &in; pd.outputs = &out;
        pd.processContext = &ctx; pd.symbolicSampleSize = kSample32;
        z->process(pd);
        for (int i = 0; i < bs; i++) {
            if (!std::isfinite(oL[i]) || !std::isfinite(oR[i])) bad = true;
            si += iL[i] * iL[i]; so += oL[i] * oL[i]; d += (oL[i] - iL[i]) * (oL[i] - iL[i]);
            peak = std::max(peak, double(std::fabs(oL[i]))); n++;
        }
    }
    rmsIn = std::sqrt(si / n); rmsOut = std::sqrt(so / n); diff = std::sqrt(d / n);
}

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        auto* z = new Zerhacker;
        z->initialize(nullptr);
        ProcessSetup ps{kRealtime, kSample32, 512, 48000};
        z->setupProcessing(ps);
        int problems = 0;
        auto check = [&](const FxPattern& pat) {
            double ri, ro, pk, df; bool bad;
            run(z, pat, ri, ro, pk, df, bad);
            bool noEffect = pat.name != "Leer" && df < 0.005;
            bool off = pat.name == "Leer" && df > 0.001;
            if (bad || pk > 1.0 || noEffect || off) problems++;
            printf("%-20s out/in %.2f  peak %.2f  change %.3f %s%s%s\n", pat.name.c_str(), ro / ri, pk, df,
                   bad ? "NaN! " : "", noEffect ? "KEIN EFFEKT " : "", off ? "LEER VERÄNDERT" : "");
        };
        for (int i = 0; i < kNumPresets; i++) check(fromPreset(kPresets[i]));
        std::mt19937 rng(7);
        for (int i = 0; i < 20; i++) check(randomPattern(rng));
        printf("Problems: %d\n", problems);
        if (problems) return 1;

        IPlugView* view = createZerhackerEditor(z, z);
        NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 420) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        view->attached((__bridge void*)w.contentView, kPlatformTypeNSView);
        NSView* v = w.contentView.subviews.firstObject;
        NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"zerhacker_ui.png" atomically:YES];
        view->removed();
    }
}
