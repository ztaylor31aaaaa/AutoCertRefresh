# AutoCertRefresh

A Sileo tweak that automatically refreshes apps installed from your developer/enterprise certificate. Detects the Apple ID used by Dopamine/host jailbreak, stores a verification token in Keychain, and schedules background refreshes.

## Features

- **Auto-detects** your Dopamine/host jailbreak Apple ID and Team ID
- **Keychain-secured** verification token (encrypted, device-only)
- **Background refresh** every 1-24 hours (configurable via Settings)
- **Certificate-aware** — only refreshes apps matching your certificate
- **Test button** in Settings for manual refresh
- **Rootless compatible** — works with Dopamine, palera1n, roothide, and other rootless jailbreaks
- **Modern native Sileo depiction** support

## Requirements

- iOS 14.0+
- Jailbroken device (Dopamine, palera1n, roothide, etc.)
- Sileo 2.0+
- PreferenceLoader
- Developer or Enterprise certificate installed on device
- Apps signed with that certificate

## Installation

### Via Sileo (Recommended)

1. Add the repository containing AutoCertRefresh to Sileo
2. Search for "AutoCertRefresh"
3. Install
4. Respring (or run `uicache`)

### Manual Installation

```bash
# Build from source
make package

# Install the .deb
dpkg -i .theos/_/debs/com.autocertrefresh_1.0.0_iphoneos-arm64.deb
```

## Configuration

Open **Settings → AutoCertRefresh**:

| Setting | Description |
|---------|-------------|
| **Enable Auto Refresh** | Master on/off toggle |
| **Refresh Interval** | How often to check (1-24 hours) |
| **Account Override** | Manually specify Apple ID (optional, auto-detects from Dopamine) |
| **Use Keychain Token** | Enable secure token verification |
| **Setup Verification Token** | Create/verify your secure token |
| **Test Refresh Now** | Manual trigger for immediate refresh |
| **Clear Stored Token** | Remove token from Keychain |

### First-Time Setup

1. Open Settings → AutoCertRefresh
2. Verify "Detected Account" shows your Apple ID and Team ID
3. Tap **"Setup Verification Token"** and enter a secure token
4. Enable **"Use Keychain Token"**
5. Set your preferred **Refresh Interval**
6. Tap **"Test Refresh Now"** to verify it works

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                        AutoCertRefresh                       │
├─────────────────────────────────────────────────────────────┤
│  1. Reads Dopamine account from /var/mobile/.dopamine_account │
│  2. Extracts Team ID and Developer Certificate               │
│  3. Scans /var/containers/Bundle/Application for .app bundles│
│  4. Parses embedded.mobileprovision for matching certificate │
│  5. Re-signs matching apps with ldid OR requests installd    │
│  6. Runs uicache to refresh SpringBoard                      │
│  7. Schedules next run via BGTaskScheduler + launchd fallback│
└─────────────────────────────────────────────────────────────┘
```

### Certificate Detection

The tweak looks for your Dopamine account in:
- `/var/mobile/.dopamine_account` (primary)
- `/var/mobile/Library/Preferences/com.opa334.dopamine.plist`
- `/var/mobile/Documents/dopamine_account.plist`
- `/var/root/.dopamine_account`

### Refresh Methods

1. **ldid re-signing** (preferred) — Re-signs app binary with `ldid -S`
2. **installd revalidation** — Asks `installd` to re-validate the app signature
3. **uicache** — Always runs to refresh SpringBoard icons

## Building from Source

### Option 1: GitHub Actions (Recommended — no local toolchain needed)

**Zero setup, builds on every push, creates Releases automatically.**

1. **Create GitHub repo & push:**
   ```bash
   chmod +x create_repo.sh
   # Edit create_repo.sh: set GITHUB_USER="your-username"
   ./create_repo.sh
   ```

2. **Watch it build:** Go to `https://github.com/YOUR_USER/AutoCertRefresh/actions`

3. **Get the .deb:**
   - **Any commit:** Download from Actions → Artifacts (kept 30 days)
   - **Release:** Tag a version → `git tag v1.0.0 && git push origin v1.0.0`
     - Creates a GitHub Release with both `arm64` and `arm64e` .deb files

### Option 2: Local Build (macOS/Linux only)

**Requires:** Theos, iOS SDK, ldid, dpkg-deb — **won't work on Windows**

```bash
# Prerequisites (macOS)
brew install theos ldid dpkg
# Theos installer also fetches SDK automatically on first build

# Build
make package          # Creates .deb in .theos/_/debs/

# Install to device via SSH
export THEOS_DEVICE_IP=192.168.x.x
make install
```

### Option 3: macOS VM / Cloud Mac

| Platform | Notes |
|----------|-------|
| **UTM / VMware** (Windows) | Install macOS, then Option 2 |
| **GitHub Codespaces** (macOS) | `gh codespace create -r YOUR_USER/AutoCertRefresh` |
| **MacStadium / Corellium** | Rent-a-Mac, SSH in, Option 2 |

---

### Build Commands (local)

```bash
# Standard build
make

# Build package (.deb) — VERSION auto-detected from git tag or commit
make package

# Override version manually
make package VERSION=1.2.3

# Install to device (requires SSH + THEOS_DEVICE_IP)
make install

# Clean build artifacts
make clean

# Show computed version
make version
```

### Project Structure

```
AutoCertRefresh/
├── Tweak.xm                    # Main tweak logic (Objective-C++)
├── Preferences/
│   ├── AutoCertRefreshListController.h/m  # Settings UI
│   ├── entry.plist             # PreferenceLoader specifiers
│   ├── Info.plist              # Bundle metadata
│   └── Makefile                # Preference bundle build
├── Resources/
│   └── com.autocertrefresh.daemon.plist  # launchd fallback
├── control                     # Debian package metadata
├── entitlements.plist          # Code signing entitlements
├── native-depiction.json       # Sileo native depiction
├── Makefile                    # Main Theos Makefile
└── README.md                   # This file
```

## Troubleshooting

### "No Dopamine account found"
- Ensure Dopamine is installed and has run at least once
- Check `/var/mobile/.dopamine_account` exists and is readable
- Use "Account Override" in Settings to manually enter Apple ID

### "No certificate found for account"
- Ensure your developer/enterprise certificate is installed on device
- Check Settings → General → VPN & Device Management
- The certificate must match the Team ID from Dopamine

### Apps not refreshing
- Check logs: `/var/mobile/Library/Logs/AutoCertRefresh.log`
- Verify `ldid` is available: `which ldid` (should be `/usr/bin/ldid` or `/bootstrap/bin/ldid`)
- Try "Test Refresh Now" in Settings for immediate feedback

### Keychain token issues
- Ensure "Use Keychain Token" is enabled
- Try "Clear Stored Token" then "Setup Verification Token" again
- Verify Access Group `group.com.sileo.autocertrefresh` is in entitlements

## Logs

- Tweak logs: Check via `syslog` or Console.app
- Daemon logs: `/var/mobile/Library/Logs/AutoCertRefresh.log`
- Error logs: `/var/mobile/Library/Logs/AutoCertRefresh.error.log`

## License

MIT License — see LICENSE file for details.

## Credits

- **Dopamine** by opa334 — jailbreak framework
- **Sileo** by Sileo Team — package manager
- **Theos** by DHowett — build system
- **PreferenceLoader** by saurik — settings framework

## Support

- GitHub Issues: https://github.com/yourusername/AutoCertRefresh/issues
- Discord: [Your Discord Link]

---

**Disclaimer**: This tweak is for educational purposes and personal use on your own devices. Ensure you have the right to sign and distribute the apps being refreshed.