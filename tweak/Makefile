TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := mediaserverd springboard
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := VCamUSB

VCamUSB_FILES := Tweak.x
VCamUSB_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamUSB_LIBRARIES := substrate
VCamUSB_FRAMEWORKS := UIKit CoreVideo CoreMedia VideoToolbox

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@echo "=== VCamUSB .deb gebaut ==="
	@ls -la packages/
