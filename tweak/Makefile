TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := mediaserverd
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := VCamInject

VCamInject_FILES := Inject.x
VCamInject_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamInject_LIBRARIES := substrate
VCamInject_FRAMEWORKS := CoreVideo CoreMedia VideoToolbox Accelerate

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@echo "=== VCamInject .deb gebaut ==="
	@ls -la packages/
