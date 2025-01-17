WHISPER_LIB_DIR := $(LOCAL_PATH)/../../../../../cpp
LOCAL_LDLIBS    := -landroid -llog

# NOTE: If you want to debug the native code, you can uncomment ifneq and endif
# ifneq ($(APP_OPTIM),debug)

# Make the final output library smaller by only keeping the symbols referenced from the app.
LOCAL_CFLAGS += -O3 -DNDEBUG
LOCAL_CFLAGS += -fvisibility=hidden -fvisibility-inlines-hidden
LOCAL_CFLAGS += -ffunction-sections -fdata-sections
LOCAL_LDFLAGS += -Wl,--gc-sections
LOCAL_LDFLAGS += -Wl,--exclude-libs,ALL
LOCAL_LDFLAGS += -flto

# endif

LOCAL_CFLAGS    += -DSTDC_HEADERS -std=c11 -I $(WHISPER_LIB_DIR)
LOCAL_CPPFLAGS  += -std=c++11 -I $(WHISPER_LIB_DIR)
LOCAL_SRC_FILES := $(WHISPER_LIB_DIR)/ggml.c \
                   $(WHISPER_LIB_DIR)/whisper.cpp \
                   $(WHISPER_LIB_DIR)/rn-whisper.cpp \
                   $(LOCAL_PATH)/jni.cpp
