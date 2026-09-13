TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

# Zwei Tweaks in einem Paket:
#   VCamHub   -> SpringBoard (WS-Server + Fan-out)
#   VCamInject -> mediaserverd (WS-Client + Decode + FigCapture-Frame-Swap)
TWEAK_NAME := VCamHub VCamInject VCamProbe

# WICHTIG: Substrate als FRAMEWORK linken (nicht als -lsubstrate Library)!
# Das produziert @rpath/CydiaSubstrate.framework/CydiaSubstrate wie bei den
# funktionierenden Tweaks (VoiceChangerX, LordVCAM). Die Library-Variante
# erzeugt @loader_path/.jbroot/usr/lib/libsubstrate.dylib, das mediaserverd
# nicht auflösen kann -> dlopen schlägt fehl -> Tweak wird nicht geladen.
VCamHub_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamHub_FILES := Hub.x
VCamHub_FRAMEWORKS := CydiaSubstrate
VCamHub_LDFLAGS := -Wl,-rpath,@loader_path/.jbroot/usr/lib -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks

VCamInject_FILES := Inject.x
VCamInject_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamInject_FRAMEWORKS := CydiaSubstrate CoreVideo CoreMedia VideoToolbox
VCamInject_LDFLAGS := -Wl,-rpath,@loader_path/.jbroot/usr/lib -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks

VCamProbe_FILES := Probe.x
VCamProbe_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamProbe_FRAMEWORKS := CydiaSubstrate
VCamProbe_LDFLAGS := -Wl,-rpath,@loader_path/.jbroot/usr/lib -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks

include $(THEOS_MAKE_PATH)/tweak.mk

after-package::
	@echo "=== VCamUSB .deb gebaut ==="
	@ls -la packages/
