//
//  AutoCertRefresh Daemon Helper
//  Standalone binary for launchd fallback in rootless environments
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const kKeychainService = @"com.autocertrefresh.token";
static NSString *const kKeychainAccount = @"autocertrefresh_token";
static NSString *const kAccessGroup = @"group.com.sileo.autocertrefresh";
static NSString *const kDopamineAccountPath = @"/var/mobile/.dopamine_account";

@interface DaemonHelper : NSObject
- (BOOL)performRefresh;
- (NSDictionary *)detectDopamineAccount;
- (NSArray<NSDictionary *> *)findAppsForCertificate:(NSData *)certData;
- (NSDictionary *)parseMobileProvision:(NSData *)data;
- (BOOL)certificateMatches:(NSDictionary *)provision certData:(NSData *)certData;
- (NSData *)findCertificateForTeamId:(NSString *)teamId;
- (BOOL)reSignAppAtPath:(NSString *)appPath;
- (BOOL)requestInstalldRevalidation:(NSString *)bundleId;
- (void)runUICache;
@end

@implementation DaemonHelper

- (BOOL)performRefresh {
    NSLog(@"AutoCertRefresh Daemon: Starting refresh cycle");

    NSDictionary *account = [self detectDopamineAccount];
    if (!account) {
        NSLog(@"AutoCertRefresh Daemon: No Dopamine account found");
        return NO;
    }

    NSString *teamId = account[@"TeamIdentifier"] ?: account[@"team_id"];
    NSData *certData = nil;

    if (account[@"DeveloperCertificate"]) {
        certData = [NSData dataWithBase64EncodedString:account[@"DeveloperCertificate"] options:0];
    }

    if (!certData) {
        certData = [self findCertificateForTeamId:teamId];
    }

    if (!certData) {
        NSLog(@"AutoCertRefresh Daemon: No certificate found");
        return NO;
    }

    NSArray<NSDictionary *> *apps = [self findAppsForCertificate:certData];
    if (apps.count == 0) {
        NSLog(@"AutoCertRefresh Daemon: No apps found for certificate");
        return YES;
    }

    BOOL anySuccess = NO;
    for (NSDictionary *app in apps) {
        NSString *appPath = app[@"path"];
        NSString *bundleId = app[@"bundleId"];

        BOOL success = [self reSignAppAtPath:appPath];
        if (!success) {
            success = [self requestInstalldRevalidation:bundleId];
        }

        if (success) {
            anySuccess = YES;
            NSLog(@"AutoCertRefresh Daemon: Refreshed %@", bundleId);
        } else {
            NSLog(@"AutoCertRefresh Daemon: Failed to refresh %@", bundleId);
        }
    }

    [self runUICache];
    return anySuccess;
}

- (NSDictionary *)detectDopamineAccount {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[
        kDopamineAccountPath,
        @"/var/mobile/Library/Preferences/com.opa334.dopamine.plist",
        @"/var/mobile/Documents/dopamine_account.plist",
        @"/var/root/.dopamine_account"
    ];

    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) {
            return [NSDictionary dictionaryWithContentsOfFile:path];
        }
    }
    return nil;
}

- (NSArray<NSDictionary *> *)findAppsForCertificate:(NSData *)certData {
    NSMutableArray *results = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

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
                    NSDictionary *provision = [self parseMobileProvision:provisionData];
                    if (provision && [self certificateMatches:provision certData:certData]) {
                        NSString *bundleId = provision[@"application-identifier"];
                        if (bundleId) {
                            bundleId = [bundleId substringFromIndex:[bundleId rangeOfString:@"."].location + 1];
                        }
                        [results addObject:@{
                            @"path": fullPath,
                            @"bundleId": bundleId ?: @"unknown"
                        }];
                    }
                }
            }
        }
    }
    return results;
}

- (NSDictionary *)parseMobileProvision:(NSData *)data {
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!string) return nil;

    NSRange plistStart = [string rangeOfString:@"<?xml"];
    NSRange plistEnd = [string rangeOfString:@"</plist>"];
    if (plistStart.location == NSNotFound || plistEnd.location == NSNotFound) return nil;

    NSRange plistRange = NSMakeRange(plistStart.location, plistEnd.location + 8 - plistStart.location);
    NSString *plistString = [string substringWithRange:plistRange];
    NSData *plistData = [plistString dataUsingEncoding:NSUTF8StringEncoding];

    NSError *error = nil;
    return [NSPropertyListSerialization propertyListWithData:plistData options:0 format:NULL error:&error];
}

- (BOOL)certificateMatches:(NSDictionary *)provision certData:(NSData *)certData {
    NSArray *certs = provision[@"DeveloperCertificates"];
    if (!certs) return NO;

    for (NSData *cert in certs) {
        if ([cert isEqualToData:certData]) return YES;
    }
    return NO;
}

- (NSData *)findCertificateForTeamId:(NSString *)teamId {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(id)kSecClass] = (id)kSecClassCertificate;
    query[(id)kSecReturnRef] = @YES;
    query[(id)kSecMatchLimit] = (id)kSecMatchLimitAll;

    CFArrayRef results = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&results);
    if (status != errSecSuccess || !results) return nil;

    for (SecCertificateRef certRef in (__bridge NSArray *)results) {
        CFStringRef summary = SecCertificateCopySubjectSummary(certRef);
        if (summary && [(NSString *)summary containsString:teamId]) {
            CFDataRef certDataRef = SecCertificateCopyData(certRef);
            if (certDataRef) {
                return (__bridge_transfer NSData *)certDataRef;
            }
        }
    }
    return nil;
}

- (BOOL)reSignAppAtPath:(NSString *)appPath {
    NSString *ldidPath = @"/usr/bin/ldid";
    if (![[NSFileManager defaultManager] fileExistsAtPath:ldidPath]) {
        ldidPath = @"/bootstrap/bin/ldid";
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

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        DaemonHelper *helper = [[DaemonHelper alloc] init];
        BOOL success = [helper performRefresh];
        return success ? 0 : 1;
    }
}