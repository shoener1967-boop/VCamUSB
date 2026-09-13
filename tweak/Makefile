# VCamUSB — virtuelle Kamera (Dopamine2-roothide / Relaxin)
#   VCamHub   -> SpringBoard (WS-Server + präsentierter Status-Banner)
#   VCamInject-> mediaserverd (WS-Client + Decode + FigCapture-Frame-Swap)
#   VCamProbe -> minimaler Lade-/Diagnose-Canary (beide Prozesse)
#
# Build:  make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
TWEAK_NAME := VCamHub VCamInject VCamProbe

# ---- Hub: Substrate (%hook SpringBoard) + UIKit für Status-Panel
VCamHub_FILES := Hub.x
VCamHub_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamHub_FRAMEWORKS := CydiaSubstrate UIKit

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
