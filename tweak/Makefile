# VCamUSB — virtuelle Kamera (Dopamine2-roothide / Relaxin)
#   VCamHub   -> SpringBoard (WS-Server + Floating-Button via UIWindow)
#   VCamInject-> mediaserverd (WS-Client + Decode + FigCapture-Frame-Swap)
#   VCamProbe -> minimaler Lade-/Diagnose-Canary (beide Prozesse)
#
# Build:  make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# WICHTIG: 14.0-Deployment nötig, damit die Toolchain arm64e bauen kann!
# (iOS 13.0 + arm64e geht nicht — Warning im CI-Log. Das Gerät ist arm64e,
#  roothide lädt nur Universal-Binaries sauber.)
TARGET := iphone:clang:latest:14.0
# Explizit BEIDE Archs bauen — das Gerät ist arm64e (A11), roothide lädt
# nur Universal-Binaries sauber. Ohne ARCHS baut Theos nur arm64.
ARCHS := arm64 arm64e
TWEAK_NAME := VCamHub VCamInject VCamInject_v2 VCamProbe VCamAVF DeviceDump

# ---- Hub: kein Substrate (constructor + Notification-Observer), UIKit für UIWindow
VCamHub_FILES := Hub.x
VCamHub_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamHub_FRAMEWORKS := UIKit

# ---- Inject: Substrate (%hook) + Video-Decoder
VCamInject_FILES := Inject.x
VCamInject_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamInject_FRAMEWORKS := CydiaSubstrate CoreVideo CoreMedia VideoToolbox Accelerate

# ---- Inject_v2: Sauberer Neubau mit BWPhotoEncoderNode-Hook
VCamInject_v2_FILES := Inject_v2.x
VCamInject_v2_CFLAGS := -fobjc-arc -Wno-unused-variable -Wno-unused-function
VCamInject_v2_FRAMEWORKS := CydiaSubstrate CoreVideo CoreMedia VideoToolbox Accelerate IOSurface

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
