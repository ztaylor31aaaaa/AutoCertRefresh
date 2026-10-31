# Theos Makefile for AutoCertRefresh
# Build with: make package
# CI sets VERSION via env; locally falls back to git tag or dev version

export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.4:14.0
export DEBUG = 0
export FINALPACKAGE = 1
export FOR_RELEASE = 1

THEOS_DEVICE_IP = localhost
THEOS_DEVICE_PORT = 2222

# VERSION: CI passes it; locally derive from git tag or commit
ifeq ($(VERSION),)
  GIT_TAG := $(shell git describe --tags --exact-match 2>/dev/null | sed 's/^v//')
  ifneq ($(GIT_TAG),)
    VERSION := $(GIT_TAG)
  else
    COMMIT_COUNT := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
    COMMIT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null || echo "dev")
    VERSION := 0.0.0-dev.$(COMMIT_COUNT).$(COMMIT_HASH)
  endif
endif
export VERSION

PACKAGE_VERSION = $(VERSION)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoCertRefresh
AutoCertRefresh_FILES = Tweak.xm
AutoCertRefresh_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
# Remove Swift libs - SDK may not have them; tweak is ObjC++ only
AutoCertRefresh_LDFLAGS =
AutoCertRefresh_FRAMEWORKS = Foundation Security BackgroundTasks
AutoCertRefresh_PRIVATE_FRAMEWORKS = Preferences
AutoCertRefresh_LIBRARIES = substrate
AutoCertRefresh_CODESIGN_FLAGS = -Sentitlements.plist

SUBPROJECTS = Preferences daemon

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

# Preference bundle subproject
Preferences_INSTALL_PATH = /Library/PreferenceBundles
Preferences_BUNDLE_NAME = AutoCertRefreshPreferences
Preferences_BUNDLE_EXTENSION = bundle
Preferences_FILES = Preferences/AutoCertRefreshListController.m
Preferences_FRAMEWORKS = Foundation Security BackgroundTasks
Preferences_PRIVATE_FRAMEWORKS = Preferences
Preferences_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
Preferences_CODESIGN_FLAGS = -Sentitlements.plist

# Daemon tool subproject
daemon_INSTALL_PATH = /bootstrap/usr/bin
daemon_FILES = daemon/main.m
daemon_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
daemon_FRAMEWORKS = Foundation Security
daemon_CODESIGN_FLAGS = -Sentitlements.plist

# Copy Resources to staging for DEBIAN scripts
before-package::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/Application Support/AutoCertRefresh
	@cp Resources/com.autocertrefresh.daemon.plist $(THEOS_STAGING_DIR)/Library/Application Support/AutoCertRefresh/
	@mkdir -p $(THEOS_STAGING_DIR)/DEBIAN
	@cp DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/
	@cp DEBIAN/prerm $(THEOS_STAGING_DIR)/DEBIAN/
	@chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/postinst
	@chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/prerm

# Custom targets
after-package::
	@echo "Package built: .theos/_/debs/$(TWEAK_NAME)_$(VERSION)_$(ARCH).deb"

clean::
	rm -rf .theos
	rm -rf Preferences/.theos
	rm -rf daemon/.theos

# Install to device
install:: package
	dpkg -i .theos/_/debs/$(TWEAK_NAME)_$(VERSION)_$(ARCH).deb

# Install preference bundle only
install-prefs::
	$(MAKE) -C Preferences install

# Build without packaging
build::
	$(MAKE) all

# Print version
version:
	@echo $(VERSION)

.PHONY: after-package clean install install-prefs build version