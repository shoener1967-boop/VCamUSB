TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

# Zwei Tweaks in einem Paket:
#   VCamHub   -> SpringBoard (WS-Server + Fan-out, bind() erlaubt)
#   VCamInject -> mediaserverd (WS-Client + Decode + FigCapture-Frame-Swap)
TWEAK_NAME := VCamHub VCamInject

VCamHub_FILES := Hub.x
VCamHub_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamHub_LIBRARIES := substrate

VCamInject_FILES := Inject.x
VCamInject_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamInject_LIBRARIES := substrate
VCamInject_FRAMEWORKS := CoreVideo CoreMedia VideoToolbox

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@echo "=== VCamUSB .deb gebaut ==="
	@ls -la packages/
