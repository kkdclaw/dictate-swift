#import "ObjCCatch.h"

@implementation ObjCCatch
+ (BOOL)run:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            *error = [NSError errorWithDomain:e.name code:1
                                     userInfo:@{NSLocalizedDescriptionKey: e.reason ?: e.name}];
        }
        return NO;
    }
}
@end
