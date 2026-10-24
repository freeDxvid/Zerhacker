// Zerhacker editor – preset bar, volume lane (draw), time lane (click), two knobs, rate switch

#import <Cocoa/Cocoa.h>
#include "shared.h"
#include "public.sdk/source/common/pluginview.h"
#include <cmath>
#include <cstring>

using namespace Steinberg;

static const int kW = 720, kH = 420;
static const NSRect kVolRect = {{24, 150}, {672, 140}};
static const NSRect kTimeRect = {{24, 84}, {672, 38}};
static const NSPoint kKnobPos[2] = {{48, 40}, {170, 40}};
static const int kKnobParam[2] = {kSmooth, kMix};
static NSString* const kKnobName[2] = {@"GLÄTTE", @"MIX"};
static NSString* const kModeSymbol[kNumModes] = {@"·", @"⟳", @"◀", @"½", @"⤓"};
static const int kModeColor[kNumModes] = {0x3A3632, 0xE8A33D, 0x6FA8DC, 0x8FCB7A, 0xD9705A};

static NSColor* rgb(int hex, CGFloat a = 1) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:a];
}

static void fill(NSRect r, NSColor* c, CGFloat radius = 0) {
    [c setFill];
    if (radius > 0) [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] fill];
    else NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
}

@interface ZerhackerView : NSView {
    Vst::EditController* ctl;
    ZerhackerAPI* api;
    double shown[kNumParams];
    int lastStep, dragKnob;
    BOOL paintingVol;
    double dragStart;
    NSPoint dragPoint;
    std::mt19937 rng;
}
@property (strong) NSTimer* timer;
@property (strong) NSTextField* nameLabel;
@property (strong) NSPopUpButton* presetMenu;
@property (strong) NSSegmentedControl* rateSeg;
- (instancetype)initWithController:(Vst::EditController*)c api:(ZerhackerAPI*)a;
- (void)stop;
@end

@implementation ZerhackerView

- (NSButton*)button:(NSString*)title frame:(NSRect)f action:(SEL)action {
    NSButton* b = [NSButton buttonWithTitle:title target:self action:action];
    b.frame = f;
    b.bezelStyle = NSBezelStyleRounded;
    [self addSubview:b];
    return b;
}

- (instancetype)initWithController:(Vst::EditController*)c api:(ZerhackerAPI*)a {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, kW, kH)])) return nil;
    ctl = c;
    api = a;
    lastStep = -1;
    dragKnob = -1;
    rng.seed(std::random_device{}());
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (int i = 0; i < kNumParams; i++) shown[i] = ctl->getParamNormalized(i);

    [self button:@"◀" frame:NSMakeRect(30, 330, 38, 30) action:@selector(prevPreset:)];
    [self button:@"▶" frame:NSMakeRect(68, 330, 38, 30) action:@selector(nextPreset:)];
    self.nameLabel = [NSTextField labelWithString:@""];
    self.nameLabel.frame = NSMakeRect(118, 335, 300, 22);
    self.nameLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    self.nameLabel.textColor = rgb(0xF2EDE6);
    [self addSubview:self.nameLabel];

    self.presetMenu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(430, 332, 140, 26) pullsDown:YES];
    [self.presetMenu addItemWithTitle:@"Presets"];
    for (int i = 0; i < kNumPresets; i++) [self.presetMenu addItemWithTitle:@(kPresets[i].name)];
    self.presetMenu.target = self;
    self.presetMenu.action = @selector(pickPreset:);
    [self addSubview:self.presetMenu];
    [self button:@"🎲 Zufall" frame:NSMakeRect(580, 330, 112, 30) action:@selector(randomize:)];

    self.rateSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"1/8", @"1/16", @"1/32"]
                                                     trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(rateChanged:)];
    self.rateSeg.frame = NSMakeRect(318, 27, 150, 26);
    self.rateSeg.selectedSegment = rateIdx(shown[kRate]);
    [self addSubview:self.rateSeg];

    [self syncLabel];
    __weak ZerhackerView* weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer*) { [weakSelf poll]; }];
    return self;
}

- (void)stop { [self.timer invalidate]; self.timer = nil; }

- (void)poll {
    BOOL dirty = NO;
    for (int i = 0; i < kNumParams; i++) {
        double v = ctl->getParamNormalized(i);
        if (v != shown[i]) { shown[i] = v; dirty = YES; }
    }
    int st = api->currentStep();
    if (st != lastStep) { lastStep = st; dirty = YES; }
    if (self.rateSeg.selectedSegment != rateIdx(shown[kRate])) self.rateSeg.selectedSegment = rateIdx(shown[kRate]);
    if (dirty) self.needsDisplay = YES;
    [self syncLabel];
}

- (void)syncLabel {
    NSString* name = [NSString stringWithUTF8String:api->presetName.c_str()] ?: @"";
    if (![self.nameLabel.stringValue isEqualToString:name]) self.nameLabel.stringValue = name;
}

- (void)setParam:(int)i value:(double)v {
    v = fmin(fmax(v, 0), 1);
    shown[i] = v;
    ctl->beginEdit(i);
    ctl->setParamNormalized(i, v);
    ctl->performEdit(i, v);
    ctl->endEdit(i);
    self.needsDisplay = YES;
}

- (void)loadPattern:(const FxPattern&)pat {
    for (int i = 0; i < kNumParams; i++) [self setParam:i value:pat.v[i]];
    api->presetName = pat.name;
    [self syncLabel];
}

- (void)loadPresetIndex:(int)i {
    api->presetIndex = (i + kNumPresets) % kNumPresets;
    [self loadPattern:fromPreset(kPresets[api->presetIndex])];
}

- (void)prevPreset:(id)s { [self loadPresetIndex:api->presetIndex - 1]; }
- (void)nextPreset:(id)s { [self loadPresetIndex:api->presetIndex + 1]; }
- (void)pickPreset:(id)s { [self loadPresetIndex:int(self.presetMenu.indexOfSelectedItem) - 1]; }
- (void)randomize:(id)s { [self loadPattern:randomPattern(rng)]; }
- (void)rateChanged:(id)s { [self setParam:kRate value:self.rateSeg.selectedSegment / 2.0]; }

// MARK: drawing

- (void)text:(NSString*)s at:(NSPoint)p size:(CGFloat)size weight:(NSFontWeight)w color:(NSColor*)c center:(BOOL)center {
    NSDictionary* a = @{NSFontAttributeName: [NSFont systemFontOfSize:size weight:w], NSForegroundColorAttributeName: c, NSKernAttributeName: @(size < 12 ? 1 : 0)};
    NSSize sz = [s sizeWithAttributes:a];
    [s drawAtPoint:NSMakePoint(center ? p.x - sz.width / 2 : p.x, p.y - sz.height / 2) withAttributes:a];
}

- (void)textRight:(NSString*)s at:(NSPoint)p {
    NSDictionary* a = @{NSFontAttributeName: [NSFont systemFontOfSize:10], NSForegroundColorAttributeName: rgb(0x5E5952)};
    NSSize sz = [s sizeWithAttributes:a];
    [s drawAtPoint:NSMakePoint(p.x - sz.width, p.y - sz.height / 2) withAttributes:a];
}

- (void)drawRect:(NSRect)dirty {
    fill(self.bounds, rgb(0x1C1A18));
    [self text:@"Zerhacker" at:NSMakePoint(24, kH - 30) size:20 weight:NSFontWeightSemibold color:rgb(0xF2EDE6) center:NO];
    [self text:@"GATE · STUTTER · TAPE STOP" at:NSMakePoint(140, kH - 29) size:11 weight:NSFontWeightMedium color:rgb(0x8C857C) center:NO];
    fill(NSMakeRect(24, 324, kW - 48, 42), rgb(0x24211E), 8);

    CGFloat colW = kVolRect.size.width / kSteps;
    // volume lane
    [self text:@"LAUTSTÄRKE" at:NSMakePoint(24, 302) size:10.5 weight:NSFontWeightSemibold color:rgb(0x8C857C) center:NO];
    [self textRight:@"ziehen zum Malen" at:NSMakePoint(696, 302)];
    fill(kVolRect, rgb(0x141311), 8);
    for (int i = 0; i < kSteps; i++) {
        NSRect col = NSMakeRect(kVolRect.origin.x + i * colW, kVolRect.origin.y, colW, kVolRect.size.height);
        if ((i / 4) % 2 == 1) fill(NSInsetRect(col, 0, 4), rgb(0xFFFFFF, 0.025));
        if (i == lastStep) fill(NSInsetRect(col, 1, 4), rgb(0xFFFFFF, 0.07), 4);
        double v = shown[kVol0 + i];
        CGFloat h = (kVolRect.size.height - 12) * v;
        if (h > 0.5) fill(NSMakeRect(col.origin.x + 4, kVolRect.origin.y + 6, colW - 8, h), rgb(0xE8A33D, i == lastStep ? 1 : 0.8), 3);
    }

    // time lane
    [self text:@"ZEIT-EFFEKT" at:NSMakePoint(24, 133) size:10.5 weight:NSFontWeightSemibold color:rgb(0x8C857C) center:NO];
    [self textRight:@"Klick = wechseln · Rechtsklick = aus" at:NSMakePoint(696, 133)];
    for (int i = 0; i < kSteps; i++) {
        int m = timeMode(shown[kTime0 + i]);
        NSRect cell = NSInsetRect(NSMakeRect(kTimeRect.origin.x + i * colW, kTimeRect.origin.y, colW, kTimeRect.size.height), 2, 0);
        fill(cell, rgb(kModeColor[m], m == kNormal ? 1 : (i == lastStep ? 1 : 0.75)), 5);
        if (i == lastStep && m == kNormal) fill(cell, rgb(0xFFFFFF, 0.08), 5);
        [self text:kModeSymbol[m] at:NSMakePoint(NSMidX(cell), NSMidY(cell)) size:15 weight:NSFontWeightSemibold
             color:m == kNormal ? rgb(0x6F6962) : rgb(0x1C1A18) center:YES];
    }

    // knobs
    for (int k = 0; k < 2; k++) {
        NSPoint c = kKnobPos[k];
        double v = shown[kKnobParam[k]];
        fill(NSMakeRect(c.x - 15, c.y - 15, 30, 30), rgb(0x2A2724), 15);
        NSBezierPath* track = [NSBezierPath bezierPath];
        [track appendBezierPathWithArcWithCenter:c radius:20 startAngle:225 endAngle:-45 clockwise:YES];
        track.lineWidth = 3.5; track.lineCapStyle = NSLineCapStyleRound;
        [rgb(0xFFFFFF, 0.08) setStroke]; [track stroke];
        if (v > 0.001) {
            NSBezierPath* arc = [NSBezierPath bezierPath];
            [arc appendBezierPathWithArcWithCenter:c radius:20 startAngle:225 endAngle:225 - 270 * v clockwise:YES];
            arc.lineWidth = 3.5; arc.lineCapStyle = NSLineCapStyleRound;
            [rgb(0xE8A33D) setStroke]; [arc stroke];
        }
        [self text:kKnobName[k] at:NSMakePoint(c.x + 30, c.y + 7) size:10 weight:NSFontWeightSemibold color:rgb(0xB5ADA3) center:NO];
        [self text:[NSString stringWithFormat:@"%d %%", int(std::lround(v * 100))] at:NSMakePoint(c.x + 30, c.y - 8)
              size:11 weight:NSFontWeightRegular color:rgb(0x6F6962) center:NO];
    }
    [self text:@"RATE" at:NSMakePoint(282, 40) size:10 weight:NSFontWeightSemibold color:rgb(0xB5ADA3) center:NO];

    // legend
    NSArray* lines = @[@"⟳ Stutter     ◀ Rückwärts", @"½ Halbes Tempo     ⤓ Tape Stop"];
    for (int i = 0; i < 2; i++)
        [self text:lines[i] at:NSMakePoint(500, 48 - i * 18) size:11 weight:NSFontWeightRegular color:rgb(0x8C857C) center:NO];
}

// MARK: mouse

- (BOOL)acceptsFirstMouse:(NSEvent*)e { return YES; }

- (int)columnAt:(NSPoint)p {
    return std::clamp(int((p.x - kVolRect.origin.x) / (kVolRect.size.width / kSteps)), 0, kSteps - 1);
}

- (void)paintVol:(NSPoint)p {
    double v = (p.y - kVolRect.origin.y - 6) / (kVolRect.size.height - 12);
    [self setParam:kVol0 + [self columnAt:p] value:v];
}

- (void)mouseDown:(NSEvent*)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    paintingVol = NSPointInRect(p, kVolRect);
    dragKnob = -1;
    if (paintingVol) { [self paintVol:p]; return; }
    if (NSPointInRect(p, kTimeRect)) {
        int i = [self columnAt:p];
        int m = (e.modifierFlags & NSEventModifierFlagControl) ? kNormal : (timeMode(shown[kTime0 + i]) + 1) % kNumModes;
        [self setParam:kTime0 + i value:timeValue(m)];
        return;
    }
    for (int k = 0; k < 2; k++)
        if (hypot(p.x - kKnobPos[k].x, p.y - kKnobPos[k].y) < 26) {
            dragKnob = k;
            dragStart = shown[kKnobParam[k]];
            dragPoint = p;
            ctl->beginEdit(kKnobParam[k]);
        }
}

- (void)rightMouseDown:(NSEvent*)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (NSPointInRect(p, kTimeRect)) [self setParam:kTime0 + [self columnAt:p] value:timeValue(kNormal)];
}

- (void)mouseDragged:(NSEvent*)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (paintingVol) { [self paintVol:p]; return; }
    if (dragKnob < 0) return;
    int id = kKnobParam[dragKnob];
    double v = fmin(fmax(dragStart + (p.y - dragPoint.y + (p.x - dragPoint.x) * 0.5) / 160, 0), 1);
    shown[id] = v;
    ctl->setParamNormalized(id, v);
    ctl->performEdit(id, v);
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent*)e {
    if (dragKnob >= 0) ctl->endEdit(kKnobParam[dragKnob]);
    dragKnob = -1;
    paintingVol = NO;
}

@end

class ZerhackerEditor : public CPluginView {
public:
    ZerhackerEditor(Vst::EditController* c, ZerhackerAPI* a) : CPluginView(nullptr), ctl(c), api(a) {
        ViewRect r(0, 0, kW, kH);
        setRect(r);
    }
    tresult PLUGIN_API isPlatformTypeSupported(FIDString type) override {
        return strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue : kResultFalse;
    }
    tresult PLUGIN_API attached(void* parent, FIDString type) override {
        view = [[ZerhackerView alloc] initWithController:ctl api:api];
        [(__bridge NSView*)parent addSubview:view];
        return CPluginView::attached(parent, type);
    }
    tresult PLUGIN_API removed() override {
        [view stop];
        [view removeFromSuperview];
        view = nil;
        return CPluginView::removed();
    }

private:
    Vst::EditController* ctl;
    ZerhackerAPI* api;
    ZerhackerView* view = nil;
};

IPlugView* createZerhackerEditor(Vst::EditController* c, ZerhackerAPI* a) { return new ZerhackerEditor(c, a); }
