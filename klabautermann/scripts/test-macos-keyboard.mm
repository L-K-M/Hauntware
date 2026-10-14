#import <Cocoa/Cocoa.h>
#import <FlutterMacOS/FlutterMacOS.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <objc/runtime.h>
#define FLUTTER_API_SYMBOL_PREFIX Fixture
#include "flutter/shell/platform/embedder/embedder.h"
#include "flutter/shell/platform/embedder/test_utils/key_codes.g.h"
#if KLABAUTERMANN_USE_CONTROLLER
#import "KlabautermannFlutterViewController.h"
#define FixtureController KlabautermannFlutterViewController
#else
#define FixtureController FlutterViewController
#endif

// The checks are shared with the sibling products.
#include "../../scripts/macos-keyboard-fixture.mm"
