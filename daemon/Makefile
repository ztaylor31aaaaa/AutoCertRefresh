# Theos Makefile for AutoCertRefresh Daemon Helper

include $(THEOS)/makefiles/common.mk

TOOL_NAME = autocertrefresh-daemon
autocertrefresh-daemon_FILES = main.m
autocertrefresh-daemon_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
autocertrefresh-daemon_FRAMEWORKS = Foundation Security
autocertrefresh-daemon_INSTALL_PATH = /bootstrap/usr/bin
autocertrefresh-daemon_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk