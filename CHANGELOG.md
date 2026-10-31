# Changelog

All notable changes to AutoCertRefresh will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2024-XX-XX

### Added
- Initial release
- Auto-detection of Dopamine/host jailbreak Apple ID and Team ID
- Keychain-secured verification token storage (device-only, encrypted)
- Background refresh scheduling via BGTaskScheduler (iOS 13+)
- launchd fallback daemon for rootless environments
- Certificate-aware app detection (scans embedded.mobileprovision)
- Multiple refresh methods: ldid re-signing, installd revalidation
- Automatic uicache after refresh
- Preference bundle with Settings integration:
  - Enable/disable toggle
  - Configurable refresh interval (1-24 hours)
  - Account override field
  - Keychain token setup/clear
  - Test refresh now button
  - Detected account info display
- Modern native Sileo depiction (native-depiction.json)
- Rootless jailbreak compatibility (Dopamine, palera1n, roothide)
- Comprehensive logging to /var/mobile/Library/Logs/

### Technical Details
- Written in Objective-C++ with Logos substrate hooks
- Swift-compatible frameworks (Foundation, Security, BackgroundTasks)
- Theos build system with aggregate subprojects
- Proper Debian packaging with postinst/prerm scripts
- Code signing entitlements for keychain access groups
- Application group sharing with Sileo

## [Unreleased]

### Planned
- Support for multiple certificates/accounts
- Push notification trigger for immediate refresh
- Webhook integration for remote triggering
- Per-app refresh exclusion list
- Improved certificate parsing with OpenSSL
- Unit tests for core logic