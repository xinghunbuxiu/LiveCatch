#include "include/lixh_player/lixh_player_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "lixh_player_plugin.h"

void LixhPlayerPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  lixh_player::LixhPlayerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
