#import <React/RCTBridgeModule.h>

// Exposes ReplayIQRN (ReplayIQRN.swift) to JavaScript as NativeModules.ReplayIQRN.
@interface RCT_EXTERN_MODULE(ReplayIQRN, NSObject)
RCT_EXTERN_METHOD(start:(NSString *)key endpoint:(NSString *)endpoint options:(NSDictionary *)options)
RCT_EXTERN_METHOD(identify:(NSString *)userId traits:(NSDictionary *)traits)
RCT_EXTERN_METHOD(track:(NSString *)name properties:(NSDictionary *)properties)
RCT_EXTERN_METHOD(screen:(NSString *)name)
RCT_EXTERN_METHOD(log:(NSString *)message level:(NSString *)level)
RCT_EXTERN_METHOD(recordError:(NSString *)message stack:(NSString *)stack filename:(NSString *)filename line:(nonnull NSNumber *)line column:(nonnull NSNumber *)column)
RCT_EXTERN_METHOD(optOut)
RCT_EXTERN_METHOD(optIn)
RCT_EXTERN_METHOD(stop)
RCT_EXTERN_METHOD(reset)
RCT_EXTERN_METHOD(flush)
RCT_EXTERN_METHOD(getSessionId:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
@end
