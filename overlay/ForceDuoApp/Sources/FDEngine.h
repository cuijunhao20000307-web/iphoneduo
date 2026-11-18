#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const FDErrorDomain;

@interface FDAppRecord : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *signer;
@property (nonatomic, copy) NSString *containerUUID;
@property (nonatomic, copy) NSString *bundleName;
@property (nonatomic) NSUInteger sdkOffset;
@property (nonatomic) NSInteger sdkMajor;
@property (nonatomic) NSInteger sdkMinor;
@property (nonatomic) NSInteger sdkPatch;
@property (nonatomic, readonly) BOOL storeSigned;
@end

@interface FDEngine : NSObject
@property (class, nonatomic, readonly) FDEngine *shared;
@property (nonatomic, readonly, nullable) NSString *storePath;
@property (nonatomic, readonly) NSString *lastLog;

/// Grants access to the lsd cache with worse_query, reads and parses every user app.
- (nullable NSArray<FDAppRecord *> *)loadApps:(NSError **)error;

/// Version dictionaries map bundle IDs to @[major, minor, patch]. Real writes require
/// the observed SDK and installation container for every requested app.
- (nullable NSString *)applyVersions:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)versions
                        expectedSDKs:(nullable NSDictionary<NSString *, NSArray<NSNumber *> *> *)expectedSDKs
                  expectedContainers:(nullable NSDictionary<NSString *, NSString *> *)expectedContainers
                              dryRun:(BOOL)dryRun
                               error:(NSError **)error
    NS_SWIFT_NAME(applyVersions(_:expectedSDKs:expectedContainers:dryRun:));

/// Read-only: copies the active store into Documents/Diagnostics with a layout report.
- (nullable NSString *)exportDiagnostics:(NSError **)error;

- (nullable NSArray<NSNumber *> *)recoverSDKForBundleID:(NSString *)bundleID
                                      expectedContainer:(NSString *)container
                                                 error:(NSError **)error NS_SWIFT_NAME(recoverSDK(forBundleID:expectedContainer:));
+ (NSString *)deviceModel;
@end

NS_ASSUME_NONNULL_END
