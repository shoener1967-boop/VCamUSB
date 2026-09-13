# Test-Tweak: exakt VoiceChangerX-Formel (rootless-Scheme)
# install_name @rpath/Name.dylib, RPATHs /.jbroot/..., kein Substrate nötig
TWEAK_NAME := TstLoad
TstLoad_FILES := TstLoad.x
TstLoad_CFLAGS := -fobjc-arc
TstLoad_LDFLAGS := -Wl,-install_name,@rpath/TstLoad.dylib -Wl,-rpath,/.jbroot/usr/lib -Wl,-rpath,/.jbroot/Library/Frameworks

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
