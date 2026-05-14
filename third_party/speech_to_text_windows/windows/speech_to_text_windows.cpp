#include "include/speech_to_text_windows/speech_to_text_windows.h"
#include <flutter/plugin_registrar_windows.h>

#include "speech_to_text_windows_plugin.h"

void SpeechToTextWindowsRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  SpeechToTextWindowsPluginRegisterWithRegistrar(registrar);
}
