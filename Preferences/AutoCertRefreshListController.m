#import "AutoCertRefreshListController.h"
#import <Preferences/Preferences.h>
#import <Security/Security.h>
#import "Tweak.xm"

@interface AutoCertRefreshListController ()
@property (nonatomic, strong) NSUserDefaults *prefs;
@property (nonatomic, strong) PSSpecifier *detectedAccountSpecifier;
@property (nonatomic, strong) PSSpecifier *detectedTeamIdSpecifier;
@property (nonatomic, strong) PSSpecifier *detectedCertCountSpecifier;
@property (nonatomic, strong) NSMutableArray *appSpecifiers;
@end

@implementation AutoCertRefreshListController

- (void)viewDidLoad {
    [super viewDidLoad];
    _prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.autocertrefresh"];
    if (!_prefs) {
        _prefs = [NSUserDefaults standardUserDefaults];
    }
    _appSpecifiers = [NSMutableArray array];

    self.title = @"AutoCertRefresh";

    // Add "Test Refresh Now" button
    UIBarButtonItem *testButton = [[UIBarButtonItem alloc] initWithTitle:@"Test All"
                                                                    style:UIBarButtonItemStylePlain
                                                                   target:self
                                                                   action:@selector(testRefreshNow)];
    UIBarButtonItem *refreshSelectedButton = [[UIBarButtonItem alloc] initWithTitle:@"Refresh Selected"
                                                                            style:UIBarButtonItemStylePlain
                                                                           target:self
                                                                           action:@selector(refreshSelectedApps)];
    self.navigationItem.rightBarButtonItems = @[testButton, refreshSelectedButton];

    // Cache specifiers for dynamic updates
    for (PSSpecifier *spec in _specifiers) {
        if ([spec.key isEqualToString:@"detectedAccount"]) _detectedAccountSpecifier = spec;
        if ([spec.key isEqualToString:@"detectedTeamId"]) _detectedTeamIdSpecifier = spec;
        if ([spec.key isEqualToString:@"detectedCertCount"]) _detectedCertCountSpecifier = spec;
    }

    [self updateDetectedInfo];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateDetectedInfo];
    [self updateAppList];
}

- (void)testRefreshNow {
    [[AutoCertRefresh sharedInstance] performRefreshWithCompletion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:success ? @"Success" : @"Failed"
                                                                            message:error ? error.localizedDescription : @"Refresh completed"
                                                                     preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }];
}

- (void)refreshSelectedApps {
    NSArray<NSString *> *selectedApps = [[AutoCertRefresh sharedInstance] getSelectedAppBundleIds];
    if (selectedApps.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Selection"
                                                                        message:@"No apps selected for individual refresh. Use the switches below to select apps."
                                                                     preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [[AutoCertRefresh sharedInstance] refreshSpecificApps:selectedApps completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:success ? @"Success" : @"Failed"
                                                                            message:error ? error.localizedDescription : [NSString stringWithFormat:@"Refreshed %lu selected app(s)", (unsigned long)selectedApps.count]
                                                                     preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }];
}

- (void)updateDetectedInfo {
    NSDictionary *account = [[AutoCertRefresh sharedInstance] detectDopamineAccount];
    if (account) {
        _detectedAccountSpecifier.defaultValue = account[@"AppleID"] ?: account[@"apple_id"] ?: @"Unknown";
        _detectedTeamIdSpecifier.defaultValue = account[@"TeamIdentifier"] ?: account[@"team_id"] ?: @"Unknown";

        NSData *certData = nil;
        if (account[@"DeveloperCertificate"]) {
            certData = [NSData dataWithBase64EncodedString:account[@"DeveloperCertificate"] options:0];
        }

        if (certData) {
            NSArray *apps = [[AutoCertRefresh sharedInstance] findAppsForCertificate:certData];
            _detectedCertCountSpecifier.defaultValue = [NSString stringWithFormat:@"%lu apps", (unsigned long)apps.count];
        } else {
            _detectedCertCountSpecifier.defaultValue = @"No certificate data";
        }
    } else {
        _detectedAccountSpecifier.defaultValue = @"Not found (check Dopamine)";
        _detectedTeamIdSpecifier.defaultValue = @"—";
        _detectedCertCountSpecifier.defaultValue = @"—";
    }

    [_detectedAccountSpecifier setNeedsDisplay];
    [_detectedTeamIdSpecifier setNeedsDisplay];
    [_detectedCertCountSpecifier setNeedsDisplay];
}

- (void)updateAppList {
    // Remove old dynamic app specifiers
    for (PSSpecifier *spec in _appSpecifiers) {
        [_specifiers removeObject:spec];
    }
    [_appSpecifiers removeAllObjects];

    // Get apps with expiration info
    NSDictionary *account = [[AutoCertRefresh sharedInstance] detectDopamineAccount];
    if (!account) return;

    NSString *teamId = account[@"TeamIdentifier"] ?: account[@"team_id"];
    NSData *certData = nil;
    if (account[@"DeveloperCertificate"]) {
        certData = [NSData dataWithBase64EncodedString:account[@"DeveloperCertificate"] options:0];
    }
    if (!certData) {
        certData = [[AutoCertRefresh sharedInstance] findCertificateForTeamId:teamId];
    }
    if (!certData) return;

    NSArray<NSDictionary *> *apps = [[AutoCertRefresh sharedInstance] findAppsForCertificate:certData];
    NSArray<NSString *> *selectedApps = [[AutoCertRefresh sharedInstance] getSelectedAppBundleIds];

    // Add section header for apps
    PSSpecifier *appsHeader = [PSSpecifier specifierWithType:PSGroupCell
                                                       key:@"appsHeader"
                                                       title:@"Installed Apps (Expiration)"
                                                      target:self];
    [_specifiers insertObject:appsHeader atIndex:[_specifiers indexOfObject:[self specForKey:@"aboutHeader"]]];
    [_appSpecifiers addObject:appsHeader];

    // Add each app as a switch cell with expiration info
    for (NSDictionary *app in apps) {
        NSString *bundleId = app[@"bundleId"];
        NSString *displayName = app[@"displayName"];
        NSString *timeRemaining = app[@"timeRemainingStr"];
        BOOL isExpired = [app[@"isExpired"] boolValue];

        BOOL isSelected = [selectedApps containsObject:bundleId];

        NSString *title = [NSString stringWithFormat:@"%@ (%@) - %@", displayName, bundleId, timeRemaining];
        if (isExpired) {
            title = [NSString stringWithFormat:@"⚠️ %@ (EXPIRED)", title];
        }

        PSSpecifier *appSpec = [PSSpecifier specifierWithType:PSSwitchCell
                                                         key:bundleId
                                                        title:title
                                                       target:self];
        appSpec.defaultValue = @(isSelected);
        appSpec.action = @selector(appSelectionChanged:);
        [_appSpecifiers addObject:appSpec];

        // Insert before the "About" section
        NSUInteger insertIndex = [_specifiers indexOfObject:[self specForKey:@"aboutHeader"]];
        if (insertIndex != NSNotFound) {
            [_specifiers insertObject:appSpec atIndex:insertIndex];
        } else {
            [_specifiers addObject:appSpec];
        }
    }

    [self.tableView reloadData];
}

- (PSSpecifier *)specForKey:(NSString *)key {
    for (PSSpecifier *spec in _specifiers) {
        if ([spec.key isEqualToString:key]) return spec;
    }
    return nil;
}

- (void)appSelectionChanged:(PSSpecifier *)specifier {
    NSArray<NSString *> *selectedApps = [[AutoCertRefresh sharedInstance] getSelectedAppBundleIds];
    NSMutableArray *mutableSelection = [selectedApps mutableCopy];

    NSString *bundleId = specifier.key;
    BOOL isSelected = [specifier.boolValue];

    if (isSelected) {
        if (![mutableSelection containsObject:bundleId]) {
            [mutableSelection addObject:bundleId];
        }
    } else {
        [mutableSelection removeObject:bundleId];
    }

    [[AutoCertRefresh sharedInstance] setSelectedAppBundleIds:mutableSelection];
}

- (void)setupTokenAction:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Setup Verification Token"
                                                                    message:@"Enter a secure token for verifying auto-refresh operations. This will be stored in Keychain."
                                                                 preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Enter token";
        textField.secureTextEntry = YES;
    }];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Confirm token";
        textField.secureTextEntry = YES;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *tokenField = alert.textFields[0];
        UITextField *confirmField = alert.textFields[1];

        if (!tokenField.text || tokenField.text.length == 0) {
            [self showError:@"Token cannot be empty"];
            return;
        }

        if (![tokenField.text isEqualToString:confirmField.text]) {
            [self showError:@"Tokens do not match"];
            return;
        }

        [[AutoCertRefresh sharedInstance] storeToken:tokenField.text];
        [self showSuccess:@"Token saved to Keychain"];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)testRefreshAction:(PSSpecifier *)specifier {
    [[AutoCertRefresh sharedInstance] performRefreshWithCompletion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:success ? @"Refresh Successful" : @"Refresh Failed"
                                                                            message:error ? error.localizedDescription : @"All apps refreshed successfully"
                                                                         preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            [self updateDetectedInfo];
            [self updateAppList];
        });
    }];
}

- (void)clearTokenAction:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Token"
                                                                    message:@"This will remove the stored verification token from Keychain."
                                                                 preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[AutoCertRefresh sharedInstance] clearToken];
        [self showSuccess:@"Token cleared"];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                    message:message
                                                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSuccess:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Success"
                                                                    message:message
                                                                 preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end