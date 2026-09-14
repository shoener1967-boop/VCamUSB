# VCamUSB — virtuelle Kamera (Dopamine2-roothide / Relaxin)
#   VCamHub   -> SpringBoard (WS-Server + Floating-Button via UIWindow)
#   VCamInject-> mediaserverd (WS-Client + Decode + FigCapture-Frame-Swap)
#   VCamProbe -> minimaler Lade-/Diagnose-Canary (beide Prozesse)
#
# Build:  make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
TARGET := iphone:clang:latest:13.0
TWEAK_NAME := VCamHub VCamInject VCamProbe VCamAVF DeviceDump

# ---- Hub: kein Substrate (constructor + Notification-Observer), UIKit für UIWindow
VCamHub_FILES := Hub.x
VCamHub_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamHub_FRAMEWORKS := UIKit

# ---- Inject: Substrate (%hook) + Video-Decoder
VCamInject_FILES := Inject.x
VCamInject_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamInject_FRAMEWORKS := CydiaSubstrate CoreVideo CoreMedia VideoToolbox Accelerate

# ---- AVF: App-seitiger AVFoundation-Diagnose-Hook (Dritt-Apps)
VCamAVF_FILES := AVF.x
VCamAVF_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamAVF_FRAMEWORKS := CydiaSubstrate CoreMedia AVFoundation

# ---- Probe: Substrate (%ctor) Canary
VCamProbe_FILES := Probe.x
VCamProbe_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamProbe_FRAMEWORKS := CydiaSubstrate

# ---- DeviceDump: AVCaptureDevice-Liste ausgeben (Diagnose virtuelle Kamera)
DeviceDump_FILES := DeviceDump.x
DeviceDump_CFLAGS := -fobjc-arc -Wno-unused-variable
DeviceDump_FRAMEWORKS := AVFoundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
