#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift не ловит NSException: AVFoundation бросает их (installTap при чужом формате входа),
/// и без этой обёртки исключение молча обрывает обработчик нажатия.
@interface ObjCCatch : NSObject
/// Выполнить блок; брошенное в нём NSException вернуть как NSError (домен — имя исключения, текст — reason).
+ (BOOL)run:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
