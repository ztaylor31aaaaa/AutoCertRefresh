#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <BackgroundTasks/BackgroundTasks.h>
#import <substrate.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const kKeychainService = @"com.autocertrefresh.token";
static NSString *const kKeychainAccount = @"autocertrefresh_token";
static NSString *const kAccessGroup = @"group.com.sileo.autocertrefresh";
static NSString *const kDopamineAccountPath = @"/var/mobile/.dopamine_account";
static NSString *const kBGTaskIdentifier = @"com.autocertrefresh.refresh";
static NSString *const kLaunchdLabel = @"com.autocertrefresh.daemon";
static NSString *const kSelectedAppsKey = @"com.autocertrefresh.selectedApps";

@interface AutoCertRefresh : NSObject
+ (instancetype)sharedInstance;
- (void)start;
- (void)stop;
- (BOOL)hasValidToken;
- (void)storeToken:(NSString *)token;
- (NSString *)loadToken;
- (void)clearToken;
- (NSDictionary *)detectDopamineAccount;
- (NSArray<NSDictionary *> *)findAppsForCertificate:(NSData *)certData;
- (NSDictionary *)getAppInfoWithExpiration:(NSString *)appPath;
- (NSString *)formatTimeRemaining:(NSTimeInterval)seconds;
- (void)scheduleBackgroundRefresh;
- (void)performRefreshWithCompletion:(void (^)(BOOL success, NSError *error))completion;
- (void)refreshAppsForCertificates:(NSArray<NSData *> *)certificates completion:(void (^)(BOOL, NSError *))completion;
- (void)refreshSpecificApps:(NSArray<NSString *> *)bundleIds completion:(void (^)(BOOL, NSError *))completion;
- (NSArray<NSString *> *)getSelectedAppBundleIds;
- (void)setSelectedAppBundleIds:(NSArray<NSString *> *)bundleIds;
@end

@implementation AutoCertRefresh

+ (instancetype)sharedInstance {
    static AutoCertRefresh *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[AutoCertRefresh alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _refreshTimer = nil;
    }
    return self;
}

- (void)start {
    [self scheduleBackgroundRefresh];

    // Also set up a local timer as fallback for rootless environment
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    _refreshTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (_refreshTimer) {
        uint64_t interval = 6 * 60 * 60 * NSEC_PER_SEC; // 6 hours default
        NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
        if ([prefs objectForKey:@"refreshIntervalHours"]) {
            interval = [prefs integerForKey:@"refreshIntervalHours"] * 60 * 60 * NSEC_PER_SEC;
        }
        dispatch_source_set_timer(_refreshTimer, dispatch_walltime(NULL, 0), interval, 60 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(_refreshTimer, ^{
            [self performRefreshWithCompletion:^(BOOL success, NSError *error) {
                if (!success) {
                    NSLog(@"AutoCertRefresh: Scheduled refresh failed: %@", error);
                }
            }];
        });
        dispatch_resume(_refreshTimer);
    }
}

- (void)stop {
    if (_refreshTimer) {
        dispatch_source_cancel(_refreshTimer);
        _refreshTimer = nil;
    }
    [[BGTaskScheduler sharedScheduler] cancelAllTaskRequests];
}

- (BOOL)hasValidToken {
    NSString *token = [self loadToken];
    return token != nil && token.length > 0;
}

- (void)storeToken:(NSString *)token {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(id)kSecClass] = (id)kSecClassGenericPassword;
    query[(id)kSecAttrService] = kKeychainService;
    query[(id)kSecAttrAccount] = kKeychainAccount;
    query[(id)kSecAttrAccessGroup] = kAccessGroup;
    query[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    query[(id)kSecValueData] = [token dataUsingEncoding:NSUTF8StringEncoding];

    SecItemDelete((__bridge CFDictionaryRef)query);
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    if (status != errSecSuccess) {
        NSLog(@"AutoCertRefresh: Failed to store token: %d", (int)status);
    }
}

- (NSString *)loadToken {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(id)kSecClass] = (id)kSecClassGenericPassword;
    query[(id)kSecAttrService] = kKeychainService;
    query[(id)kSecAttrAccount] = kKeychainAccount;
    query[(id)kSecAttrAccessGroup] = kAccessGroup;
    query[(id)kSecReturnData] = @YES;
    query[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        NSData *data = (__bridge_transfer NSData *)result;
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return nil;
}

- (void)clearToken {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(id)kSecClass] = (id)kSecClassGenericPassword;
    query[(id)kSecAttrService] = kKeychainService;
    query[(id)kSecAttrAccount] = kKeychainAccount;
    query[(id)kSecAttrAccessGroup] = kAccessGroup;
    SecItemDelete((__bridge CFDictionaryRef)query);
}

- (NSDictionary *)detectDopamineAccount {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kDopamineAccountPath]) {
        // Check alternative locations
        NSArray *altPaths = @[
            @"/var/mobile/Library/Preferences/com.opa334.dopamine.plist",
            @"/var/mobile/Documents/dopamine_account.plist",
            @"/var/root/.dopamine_account"
        ];
        for (NSString *path in altPaths) {
            if ([fm fileExistsAtPath:path]) {
                return [NSDictionary dictionaryWithContentsOfFile:path];
            }
        }
        return nil;
    }
    return [NSDictionary dictionaryWithContentsOfFile:kDopamineAccountPath];
}

- (NSArray<NSDictionary *> *)findAppsForCertificate:(NSData *)certData {
    NSMutableArray *results = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    // Scan common app installation directories
    NSArray *searchPaths = @[
        @"/var/containers/Bundle/Application",
        @"/Applications",
        @"/var/mobile/Containers/Bundle/Application"
    ];

    for (NSString *basePath in searchPaths) {
        if (![fm fileExistsAtPath:basePath]) continue;

        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
        for (NSString *relativePath in enumerator) {
            if (![relativePath hasSuffix:@".app"]) continue;

            NSString *fullPath = [basePath stringByAppendingPathComponent:relativePath];
            NSString *embeddedPath = [fullPath stringByAppendingPathComponent:@"embedded.mobileprovision"];

            if ([fm fileExistsAtPath:embeddedPath]) {
                NSData *provisionData = [NSData dataWithContentsOfFile:embeddedPath];
                if (provisionData) {
                    // Parse mobileprovision (CMS signed plist)
                    NSDictionary *provision = [self parseMobileProvision:provisionData];
                    if (provision && [self certificateMatches:provision certData:certData]) {
                        NSString *bundleId = provision[@"application-identifier"];
                        if (bundleId) {
                            bundleId = [bundleId substringFromIndex:[bundleId rangeOfString:@"."].location + 1];
                        }
                        NSDictionary *appInfo = [self getAppInfoWithExpiration:fullPath];
                        if (appInfo) {
                            NSMutableDictionary *mutableInfo = [appInfo mutableCopy];
                            mutableInfo[@"path"] = fullPath;
                            mutableInfo[@"bundleId"] = bundleId ?: @"unknown";
                            mutableInfo[@"provision"] = provision;
                            [results addObject:mutableInfo];
                        }
                    }
                }
            }
        }
    }
    return results;
}

- (NSDictionary *)getAppInfoWithExpiration:(NSString *)appPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *embeddedPath = [appPath stringByAppendingPathComponent:@"embedded.mobileprovision"];

    if (![fm fileExistsAtPath:embeddedPath]) return nil;

    NSData *provisionData = [NSData dataWithContentsOfFile:embeddedPath];
    if (!provisionData) return nil;

    NSDictionary *provision = [self parseMobileProvision:provisionData];
    if (!provision) return nil;

    // Get expiration date
    NSDate *expirationDate = provision[@"ExpirationDate"];
    if (!expirationDate) return nil;

    // Get app display name from Info.plist
    NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    NSString *displayName = infoPlist[@"CFBundleDisplayName"] ?: infoPlist[@"CFBundleName"] ?: @"Unknown";
    NSString *bundleId = infoPlist[@"CFBundleIdentifier"] ?: @"unknown";
    NSString *version = infoPlist[@"CFBundleShortVersionString"] ?: @"1.0";

    // Calculate time remaining
    NSTimeInterval timeRemaining = [expirationDate timeIntervalSinceNow];
    BOOL isExpired = timeRemaining <= 0;
    NSString *timeRemainingStr = [self formatTimeRemaining:timeRemaining];

    // Get certificate info
    NSArray *certs = provision[@"DeveloperCertificates"];
    NSData *firstCert = certs.firstObject;
    NSString *certSubject = @"Unknown";
    if (firstCert) {
        SecCertificateRef certRef = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)firstCert);
        if (certRef) {
            CFStringRef summary = SecCertificateCopySubjectSummary(certRef);
            if (summary) {
                certSubject = (__bridge_transfer NSString *)summary;
            }
            CFRelease(certRef);
        }
    }

    // Get team identifier
    NSString *teamId = provision[@"TeamIdentifier"];
    if (teamId && [teamId isKindOfClass:[NSArray class]]) {
        teamId = teamId.firstObject;
    }

    return @{
        @"path": appPath,
        @"bundleId": bundleId,
        @"displayName": displayName,
        @"version": version,
        @"expirationDate": expirationDate,
        @"timeRemaining": @(timeRemaining),
        @"timeRemainingStr": timeRemainingStr,
        @"isExpired": @(isExpired),
        @"teamId": teamId ?: @"Unknown",
        @"certSubject": certSubject,
        @"provision": provision
    };
}

- (NSString *)formatTimeRemaining:(NSTimeInterval)seconds {
    if (seconds <= 0) {
        return @"EXPIRED";
    }

    NSInteger days = seconds / (24 * 3600);
    NSInteger hours = (seconds - days * 24 * 3600) / 3600;
    NSInteger minutes = (seconds - days * 24 * 3600 - hours * 3600) / 60;

    if (days > 0) {
        return [NSString stringWithFormat:@"%ldd %ldh %ldm", (long)days, (long)hours, (long)minutes];
    } else if (hours > 0) {
        return [NSString stringWithFormat:@"%ldh %ldm", (long)hours, (long)minutes];
    } else {
        return [NSString stringWithFormat:@"%ldm", (long)minutes];
    }
}

- (NSDictionary *)parseMobileProvision:(NSData *)data {
    // Mobileprovision is a CMS signed plist - strip signature to get inner plist
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!string) return nil;

    NSRange plistStart = [string rangeOfString:@"<?xml"];
    NSRange plistEnd = [string rangeOfString:@"</plist>"];
    if (plistStart.location == NSNotFound || plistEnd.location == NSNotFound) return nil;

    NSRange plistRange = NSMakeRange(plistStart.location, plistEnd.location + 8 - plistStart.location);
    NSString *plistString = [string substringWithRange:plistRange];
    NSData *plistData = [plistString dataUsingEncoding:NSUTF8StringEncoding];

    NSError *error = nil;
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:plistData
                                                                    options:0
                                                                 format:NULL
                                                                   error:&error];
    return plist;
}

- (BOOL)certificateMatches:(NSDictionary *)provision certData:(NSData *)certData {
    NSArray *certs = provision[@"DeveloperCertificates"];
    if (!certs) return NO;

    for (NSData *cert in certs) {
        if ([cert isEqualToData:certData]) return YES;
    }
    return NO;
}

- (void)scheduleBackgroundRefresh {
    if (@available(iOS 13.0, *)) {
        BGTaskScheduler *scheduler = [BGTaskScheduler sharedScheduler];
        [scheduler registerForTaskWithIdentifier:kBGTaskIdentifier usingQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0) launchHandler:^(BGTask *task) {
            [self performRefreshWithCompletion:^(BOOL success, NSError *error) {
                [task setTaskCompletedWithError:error];
            }];
        }];

        BGAppRefreshTaskRequest *request = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:kBGTaskIdentifier];
        request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:6 * 60 * 60]; // 6 hours
        NSError *error = nil;
        [scheduler submitTaskRequest:request error:&error];
        if (error) {
            NSLog(@"AutoCertRefresh: Failed to schedule BGTask: %@", error);
        }
    }
}

- (void)performRefreshWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    NSDictionary *account = [self detectDopamineAccount];
    if (!account) {
        completion(NO, [NSError errorWithDomain:@"AutoCertRefresh" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No Dopamine account found"}]);
        return;
    }

    NSString *teamId = account[@"TeamIdentifier"] ?: account[@"team_id"];
    NSString *appleId = account[@"AppleID"] ?: account[@"apple_id"];

    // Extract certificate from keychain or account info
    NSData *certData = nil;
    if (account[@"DeveloperCertificate"]) {
        certData = [NSData dataWithBase64EncodedString:account[@"DeveloperCertificate"] options:0];
    }

    if (!certData) {
        // Try to find certificate in keychain matching team ID
        certData = [self findCertificateForTeamId:teamId];
    }

    if (!certData) {
        completion(NO, [NSError errorWithDomain:@"AutoCertRefresh" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No certificate found for account"}]);
        return;
    }

    NSArray<NSDictionary *> *apps = [self findAppsForCertificate:certData];
    if (apps.count == 0) {
        completion(YES, nil); // Nothing to refresh
        return;
    }

    // Check if we should refresh only selected apps
    NSArray<NSString *> *selectedApps = [self getSelectedAppBundleIds];
    if (selectedApps.count > 0) {
        [self refreshSpecificApps:selectedApps completion:completion];
    } else {
        [self refreshAppsForCertificates:@[certData] completion:completion];
    }
}

- (NSArray<NSString *> *)getSelectedAppBundleIds {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    return [prefs objectForKey:kSelectedAppsKey] ?: @[];
}

- (void)setSelectedAppBundleIds:(NSArray<NSString *> *)bundleIds {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setObject:bundleIds forKey:kSelectedAppsKey];
    [prefs synchronize];
}

- (NSData *)findCertificateForTeamId:(NSString *)teamId {
    // Search keychain for certificate matching team ID
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(id)kSecClass] = (id)kSecClassCertificate;
    query[(id)kSecReturnRef] = @YES;
    query[(id)kSecMatchLimit] = (id)kSecMatchLimitAll;

    CFArrayRef results = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&results);
    if (status != errSecSuccess || !results) return nil;

    for (SecCertificateRef certRef in (__bridge NSArray *)results) {
        CFDataRef certDataRef = SecCertificateCopyData(certRef);
        if (certDataRef) {
            NSData *certData = (__bridge_transfer NSData *)certDataRef;
            // Check if certificate contains team ID in subject
            SecCertificateCopySubjectSummary(certRef);
            CFStringRef summary = SecCertificateCopySubjectSummary(certRef);
            if (summary && [(NSString *)summary containsString:teamId]) {
                return certData;
            }
        }
    }
    return nil;
}

- (void)refreshAppsForCertificates:(NSArray<NSData *> *)certificates completion:(void (^)(BOOL, NSError *))completion {
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    dispatch_async(queue, ^{
        NSError *lastError = nil;
        BOOL anySuccess = NO;

        for (NSData *certData in certificates) {
            NSArray<NSDictionary *> *apps = [self findAppsForCertificate:certData];

            for (NSDictionary *app in apps) {
                NSString *appPath = app[@"path"];
                NSString *bundleId = app[@"bundleId"];

                // Method 1: Re-sign with ldid if we have signing identity
                BOOL success = [self reSignAppAtPath:appPath withCertificate:certData];

                if (!success) {
                    // Method 2: Ask installd to re-validate
                    success = [self requestInstalldRevalidation:bundleId];
                }

                if (success) {
                    anySuccess = YES;
                    NSLog(@"AutoCertRefresh: Refreshed %@", bundleId);
                } else {
                    lastError = [NSError errorWithDomain:@"AutoCertRefresh" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to refresh %@", bundleId]}];
                }
            }
        }

        // Run uicache
        [self runUICache];

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(anySuccess, lastError);
        });
    });
}

- (void)refreshSpecificApps:(NSArray<NSString *> *)bundleIds completion:(void (^)(BOOL, NSError *))completion {
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    dispatch_async(queue, ^{
        NSError *lastError = nil;
        BOOL anySuccess = NO;

        NSDictionary *account = [self detectDopamineAccount];
        NSString *teamId = account[@"TeamIdentifier"] ?: account[@"team_id"];
        NSData *certData = nil;
        if (account[@"DeveloperCertificate"]) {
            certData = [NSData dataWithBase64EncodedString:account[@"DeveloperCertificate"] options:0];
        }
        if (!certData) {
            certData = [self findCertificateForTeamId:teamId];
        }
        if (!certData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, [NSError errorWithDomain:@"AutoCertRefresh" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No certificate found"}]);
            });
            return;
        }

        NSArray<NSDictionary *> *allApps = [self findAppsForCertificate:certData];

        for (NSDictionary *app in allApps) {
            NSString *bundleId = app[@"bundleId"];
            if (![bundleIds containsObject:bundleId]) continue;

            NSString *appPath = app[@"path"];

            BOOL success = [self reSignAppAtPath:appPath withCertificate:certData];
            if (!success) {
                success = [self requestInstalldRevalidation:bundleId];
            }

            if (success) {
                anySuccess = YES;
                NSLog(@"AutoCertRefresh: Refreshed %@", bundleId);
            } else {
                lastError = [NSError errorWithDomain:@"AutoCertRefresh" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to refresh %@", bundleId]}];
            }
        }

        [self runUICache];

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(anySuccess, lastError);
        });
    });
}

- (BOOL)reSignAppAtPath:(NSString *)appPath withCertificate:(NSData *)certData {
    // Use ldid to re-sign the app
    // This requires the signing identity to be available
    NSString *ldidPath = @"/usr/bin/ldid";
    if (![[NSFileManager defaultManager] fileExistsAtPath:ldidPath]) {
        ldidPath = @"/bootstrap/bin/ldid"; // Rootless path
    }

    NSTask *task = [NSTask new];
    task.launchPath = ldidPath;
    task.arguments = @[@"-S", appPath];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];

    [task launch];
    [task waitUntilExit];

    return task.terminationStatus == 0;
}

- (BOOL)requestInstalldRevalidation:(NSString *)bundleId {
    // Use MISValidateSignatureAndCopyInfo via installd
    // This is a private API call - use posix_spawn to call installd
    pid_t pid;
    char *argv[] = {"/usr/libexec/installd", "revalidate", (char *)[bundleId UTF8String], NULL};
    posix_spawn(&pid, argv[0], NULL, NULL, argv, NULL);
    int status;
    waitpid(pid, &status, 0);
    return WEXITSTATUS(status) == 0;
}

- (void)runUICache {
    pid_t pid;
    char *argv[] = {"/usr/bin/uicache", NULL};
    posix_spawn(&pid, argv[0], NULL, NULL, argv, NULL);
    waitpid(pid, NULL, 0);
}

@end

// Constructor
%ctor {
    [[AutoCertRefresh sharedInstance] start];

    // Register BGTask on app launch
    if (@available(iOS 13.0, *)) {
        [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:kBGTaskIdentifier
                                                          usingQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)
                                                       launchHandler:^(BGTask *task) {
            [[AutoCertRefresh sharedInstance] performRefreshWithCompletion:^(BOOL success, NSError *error) {
                [task setTaskCompletedWithError:error];
            }];
        }];
    }
}

%dtor {
    [[AutoCertRefresh sharedInstance] stop];
}