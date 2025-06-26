//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <audioplayers_linux/audioplayers_linux_plugin.h>
#include <flutter_audio_capture/flutter_audio_capture_plugin.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>
#include <record_linux/record_linux_plugin.h>
#include <sim_card_info/sim_card_info_plugin.h>
#include <sim_number_picker/sim_number_picker_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) audioplayers_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AudioplayersLinuxPlugin");
  audioplayers_linux_plugin_register_with_registrar(audioplayers_linux_registrar);
  g_autoptr(FlPluginRegistrar) flutter_audio_capture_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "FlutterAudioCapturePlugin");
  flutter_audio_capture_plugin_register_with_registrar(flutter_audio_capture_registrar);
  g_autoptr(FlPluginRegistrar) flutter_webrtc_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "FlutterWebRTCPlugin");
  flutter_web_r_t_c_plugin_register_with_registrar(flutter_webrtc_registrar);
  g_autoptr(FlPluginRegistrar) record_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "RecordLinuxPlugin");
  record_linux_plugin_register_with_registrar(record_linux_registrar);
  g_autoptr(FlPluginRegistrar) sim_card_info_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "SimCardInfoPlugin");
  sim_card_info_plugin_register_with_registrar(sim_card_info_registrar);
  g_autoptr(FlPluginRegistrar) sim_number_picker_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "SimNumberPickerPlugin");
  sim_number_picker_plugin_register_with_registrar(sim_number_picker_registrar);
}
