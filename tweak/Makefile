TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

# Zwei Tweaks in einem Paket:
#   VCamHub   -> SpringBoard (WS-Server + Fan-out)
#   VCamInject -> mediaserverd (WS-Client + Decode + FigCapture-Frame-Swap)
TWEAK_NAME := VCamHub VCamInject VCamProbe

# roothide-RPATHs — kritisch: ohne die kann mediaserverd die Dylib nicht
# dlopen'en, weil @loader_path/.jbroot/... vom Daemon-Pfad aus falsch zeigt.
VCamHub_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamHub_FILES := Hub.x
VCamHub_LDFLAGS := -Wl,-rpath,@loader_path/.jbroot/usr/lib -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks

VCamInject_FILES := Inject.x
VCamInject_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamInject_LIBRARIES := substrate
VCamInject_FRAMEWORKS := CoreVideo CoreMedia VideoToolbox
VCamInject_LDFLAGS := -Wl,-rpath,@loader_path/.jbroot/usr/lib -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks

VCamProbe_FILES := Probe.x
VCamProbe_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamProbe_LDFLAGS := -Wl,-rpath,@loader_path/.jbroot/usr/lib -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@echo "=== VCamUSB .deb gebaut ==="
	@ls -la packages/
