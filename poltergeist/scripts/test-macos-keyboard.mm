#import <Cocoa/Cocoa.h>
#import <FlutterMacOS/FlutterMacOS.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <objc/runtime.h>
#define FLUTTER_API_SYMBOL_PREFIX Fixture
#include "flutter/shell/platform/embedder/embedder.h"
#include "flutter/shell/platform/embedder/test_utils/key_codes.g.h"
#if POLTERGEIST_USE_CONTROLLER
#import "PoltergeistFlutterViewController.h"
#define FixtureController PoltergeistFlutterViewController
#else
#define FixtureController FlutterViewController
#endif

// The checks are shared with the sibling products.
#include "../../scripts/macos-keyboard-fixture.mm"
