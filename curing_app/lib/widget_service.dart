import 'package:home_widget/home_widget.dart';

class WidgetService {
  static Future<void> updateDashboard({
    required String device,
    required double temp,
    required double hum,
    required bool online,
  }) async {
    try {
      await HomeWidget.saveWidgetData<String>('device', device);
      await HomeWidget.saveWidgetData<String>('temp', temp.toStringAsFixed(1));
      await HomeWidget.saveWidgetData<String>('hum', hum.toStringAsFixed(0));
      await HomeWidget.saveWidgetData<String>(
        'online',
        online ? 'online' : 'offline',
      );
      await HomeWidget.updateWidget();
    } catch (_) {
      // Native Android widget setup may still be missing in the host app.
    }
  }
}
