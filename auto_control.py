import json
import os

import paho.mqtt.client as mqtt

from ai_controller import AIController


BROKER = os.environ.get("AUTO_CONTROL_BROKER", "localhost")
PORT = int(os.environ.get("AUTO_CONTROL_PORT", "30345"))
DEVICE_ID = os.environ.get("AUTO_CONTROL_DEVICE_ID", "ESP123")
TARGET_TEMP = float(os.environ.get("AUTO_CONTROL_TARGET_TEMP", "14"))

ai = AIController()
temp_history = []
ai_enabled = False

client = mqtt.Client(client_id=f"auto-control-{DEVICE_ID}")


def _normalize_bool(value):
    return str(value).strip().lower() in {"1", "true", "on", "yes"}


def _publish_heater(enabled):
    client.publish(f"devices/{DEVICE_ID}/control/heater", "1" if enabled else "0")


def on_connect(client, userdata, flags, rc):
    if rc != 0:
        raise RuntimeError(f"MQTT connection failed with code {rc}")

    client.subscribe(f"devices/{DEVICE_ID}/data")
    client.subscribe(f"devices/{DEVICE_ID}/control/ai")
    print(f"Auto control connected for {DEVICE_ID}")


def on_message(client, userdata, msg):
    global temp_history, TARGET_TEMP, ai_enabled

    payload_text = msg.payload.decode(errors="ignore")

    if msg.topic == f"devices/{DEVICE_ID}/control/ai":
        ai_enabled = _normalize_bool(payload_text)
        if not ai_enabled:
            _publish_heater(False)
        print(f"AI CONTROL: {'ON' if ai_enabled else 'OFF'}")
        return

    try:
        payload = json.loads(payload_text)
    except json.JSONDecodeError:
        return

    temp_value = payload.get("temp")
    if temp_value is None:
        return

    try:
        temp = float(temp_value)
    except (TypeError, ValueError):
        return

    temp_history.append(temp)

    if len(temp_history) > 20:
        temp_history.pop(0)

    if not ai_enabled:
        print(f"TEMP: {temp} | AI disabled")
        return

    new_target = ai.recommend_target(temp_history, TARGET_TEMP)

    if temp < new_target:
        _publish_heater(True)
    else:
        _publish_heater(False)

    print(f"TEMP: {temp} | TARGET: {new_target}")


client.on_connect = on_connect
client.on_message = on_message
client.connect(BROKER, PORT, 60)
client.loop_forever()