#import <FlutterMacOS/FlutterMacOS.h>

NS_ASSUME_NONNULL_BEGIN

/// Preserves injected Command shortcuts and invalidates native text fields
/// before Flutter tears down their accessibility tree (copied from
/// Séance's SeanceFlutterViewController, docs/SHARED.md).
@interface KlabautermannFlutterViewController : FlutterViewController
@end

NS_ASSUME_NONNULL_END
