# Theos Makefile for AutoCertRefresh Preferences Bundle

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AutoCertRefreshPreferences
AutoCertRefreshPreferences_FILES = AutoCertRefreshListController.m
AutoCertRefreshPreferences_INSTALL_PATH = /Library/PreferenceBundles
AutoCertRefreshPreferences_FRAMEWORKS = Foundation Security BackgroundTasks
AutoCertRefreshPreferences_PRIVATE_FRAMEWORKS = Preferences
AutoCertRefreshPreferences_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AutoCertRefreshPreferences_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/bundle.mk