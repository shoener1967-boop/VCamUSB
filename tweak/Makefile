# VCamUSB — virtuelle Kamera (Dopamine2-roothide / Relaxin)
#   VCamHub   -> SpringBoard (WS-Server + schwebender Status-Banner)
#   VCamInject-> mediaserverd (WS-Client + Decode + FigCapture-Frame-Swap)
#   VCamProbe -> minimaler Lade-/Diagnose-Canary (beide Prozesse)
#
# Build:  make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
TWEAK_NAME := VCamHub VCamInject VCamProbe

# ---- Hub: kein Substrate nötig (constructor-Attribut), aber UIKit für Banner
VCamHub_FILES := Hub.x
VCamHub_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamHub_FRAMEWORKS := UIKit

# ---- Inject: Substrate (%hook) + Video-Decoder
VCamInject_FILES := Inject.x
VCamInject_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamInject_FRAMEWORKS := CydiaSubstrate CoreVideo CoreMedia VideoToolbox

# ---- Probe: Substrate (%ctor) Canary
VCamProbe_FILES := Probe.x
VCamProbe_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamProbe_FRAMEWORKS := CydiaSubstrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
