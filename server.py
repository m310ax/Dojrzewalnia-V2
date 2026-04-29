import json
import os
import sqlite3
import threading
import time
import uuid
from collections import defaultdict, deque

import paho.mqtt.client as mqtt
import requests
from flask import Flask, jsonify, render_template, request
from flask_bcrypt import Bcrypt
from flask_cors import CORS
from flask_jwt_extended import (
    JWTManager,
    create_access_token,
    get_jwt_identity,
    jwt_required,
)

from ai import ai_control, check_alerts


app = Flask(__name__)
app.config["JWT_SECRET_KEY"] = os.environ.get("JWT_SECRET_KEY", "SUPER_SECRET_KEY")
app.config["PORT"] = int(os.environ.get("PORT", "20345"))
USERS_FILE = "/root/curing-system/data/users.json"

bcrypt = Bcrypt(app)
jwt = JWTManager(app)
CORS(app)

conn = sqlite3.connect("app.db", check_same_thread=False)
c = conn.cursor()

c.execute(
    """
CREATE TABLE IF NOT EXISTS users (
 id TEXT PRIMARY KEY,
 email TEXT UNIQUE,
 password TEXT
)
"""
)

c.execute(
    """
CREATE TABLE IF NOT EXISTS devices (
 id TEXT PRIMARY KEY,
 name TEXT NOT NULL,
 owner_id TEXT NOT NULL
)
"""
)

c.execute(
    """
CREATE TABLE IF NOT EXISTS notification_tokens (
 token TEXT PRIMARY KEY,
 owner_id TEXT NOT NULL
)
"""
)

c.execute(
    """
CREATE TABLE IF NOT EXISTS telemetry_history (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 device_id TEXT NOT NULL,
 owner_id TEXT NOT NULL,
 temp REAL NOT NULL,
 hum REAL NOT NULL,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
)
"""
)

c.execute(
    """
CREATE TABLE IF NOT EXISTS pid_modes (
 device_id TEXT PRIMARY KEY,
 owner_id TEXT NOT NULL,
 mode TEXT NOT NULL,
 target_temp REAL,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
)
"""
)

c.execute(
    """
CREATE TABLE IF NOT EXISTS pid_state (
 device_id TEXT PRIMARY KEY,
 integral REAL NOT NULL DEFAULT 0,
 last_error REAL NOT NULL DEFAULT 0,
 last_output REAL NOT NULL DEFAULT 0,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
)
"""
)

c.execute(
    """
CREATE TABLE IF NOT EXISTS pid_config (
 device_id TEXT PRIMARY KEY,
 owner_id TEXT NOT NULL,
 kp REAL NOT NULL DEFAULT 2.0,
 ki REAL NOT NULL DEFAULT 0.1,
 kd REAL NOT NULL DEFAULT 1.0,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
)
"""
)

conn.commit()

scenes = {
    "night": {"temp": 1.5, "hum": 75},
    "dry": {"temp": 3.0, "hum": 60},
    "boost": {"temp": 5.0, "hum": 50},
}

ai_scenes = {"ai_on", "ai_off"}

MQTT_SERVER = os.environ.get("MQTT_SERVER", "yasmin345.mikrus.xyz")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "30345"))
MQTT_USERNAME = os.environ.get("MQTT_USERNAME", "curing_user")
MQTT_PASSWORD = os.environ.get("MQTT_PASSWORD", "mocne")
MQTT_TOPIC = "devices/+/#"

device_data = {}
device_data_lock = threading.Lock()
available_devices = {}
available_devices_lock = threading.Lock()

PID_CYCLE_TIME_SECONDS = 30.0
PID_AUTOTUNE_SAMPLES = 30
PID_AUTOTUNE_INTERVAL_SECONDS = 2.0
mqtt_client = None
mqtt_started = False
mqtt_start_lock = threading.Lock()
AI_DEVICE_BEARER_TOKEN = os.environ.get("AI_DEVICE_BEARER_TOKEN", "SECRET123")
ai_device_state = {}
ai_history = defaultdict(lambda: deque(maxlen=120))


def require_device_token():
    auth_header = (request.headers.get("Authorization") or "").strip()
    expected = f"Bearer {AI_DEVICE_BEARER_TOKEN}"
    if auth_header != expected:
        return jsonify({"error": "unauthorized"}), 401
    return None


def _normalize_device_value(logical_topic, payload):
    text = payload.strip()
    if logical_topic in {
        "curing/temp",
        "curing/humidity",
        "curing/set/temp_min",
        "curing/set/temp_max",
        "curing/set/hum_min",
        "curing/set/hum_max",
        "curing/set/temp",
        "curing/set/hum",
        "curing/set/hysteresis",
        "curing/set/air_time",
        "curing/set/air_interval",
    }:
        try:
            return float(text)
        except ValueError:
            return text

    return text


def _device_field_name(logical_topic):
    field_map = {
        "data": "data",
        "status": "status",
        "autotune": "autotune_status",
        "curing/device/id": "device_runtime_id",
        "curing/temp": "temp",
        "curing/humidity": "humidity",
        "curing/status": "status",
        "curing/device/ip": "device_ip",
        "curing/device/sensor": "sensor",
        "curing/device/wifi": "wifi",
        "curing/set/temp_min": "temp_min",
        "curing/set/temp_max": "temp_max",
        "curing/set/hum_min": "hum_min",
        "curing/set/hum_max": "hum_max",
        "curing/set/profile": "profile",
        "curing/mode": "mode",
        "control/mode": "mode",
        "control/ai": "ai_enabled",
    }
    return field_map.get(logical_topic, logical_topic.replace("/", "_"))


def _update_device_snapshot(device_id, **values):
    with device_data_lock:
        snapshot = dict(device_data.get(device_id, {}))
        snapshot.update(values)
        snapshot["_updated_at"] = int(time.time())
        device_data[device_id] = snapshot


def _touch_discovered_device(device_id, ip=None, rssi=None):
    normalized_device_id = str(device_id or "").strip()
    if not normalized_device_id:
        return

    with available_devices_lock:
        existing = dict(available_devices.get(normalized_device_id, {}))
        available_devices[normalized_device_id] = {
            "id": normalized_device_id,
            "ip": ip if ip is not None else existing.get("ip"),
            "rssi": rssi if rssi is not None else existing.get("rssi"),
            "first_seen": existing.get("first_seen", time.time()),
            "last_seen": time.time(),
        }


def _publish_raw_topic(topic, payload):
    start_mqtt_listener()
    client = mqtt_client
    if client is None:
        return False

    result = client.publish(topic, payload)
    return result.rc == mqtt.MQTT_ERR_SUCCESS


def _publish_autotune_status(device_id, status, **extra):
    payload = json.dumps({"device_id": device_id, "status": status, **extra})
    _publish_raw_topic(f"devices/{device_id}/autotune", payload)
    _update_device_snapshot(device_id, autotune_status=status, **extra)


def get_pid_coefficients(device_id):
    c.execute(
        "SELECT kp, ki, kd FROM pid_config WHERE device_id=?",
        (device_id,),
    )
    row = c.fetchone()
    if row is None:
        return {"kp": 2.0, "ki": 0.1, "kd": 1.0}

    return {"kp": float(row[0]), "ki": float(row[1]), "kd": float(row[2])}


def save_pid_coefficients(device_id, owner_id, kp, ki, kd):
    c.execute(
        """
        INSERT OR REPLACE INTO pid_config (device_id, owner_id, kp, ki, kd, updated_at)
        VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        """,
        (device_id, owner_id, float(kp), float(ki), float(kd)),
    )
    conn.commit()
    return get_pid_coefficients(device_id)


def get_live_snapshot(device_id):
    with device_data_lock:
        return dict(device_data.get(device_id, {}))


def autotune_pid(device_id, owner_id):
    history = []
    _publish_autotune_status(device_id, "running")

    command_ok, command_result = publish_device_command(device_id, "cooling", True)
    if not command_ok:
        _publish_autotune_status(device_id, "error", reason=command_result)
        return {"status": "error", "reason": command_result}

    try:
        for _ in range(PID_AUTOTUNE_SAMPLES):
            snapshot = get_live_snapshot(device_id)
            temp_value = snapshot.get("temp", snapshot.get("data", {}).get("temp"))
            try:
                history.append(float(temp_value))
            except (TypeError, ValueError, AttributeError):
                pass
            time.sleep(PID_AUTOTUNE_INTERVAL_SECONDS)
    finally:
        publish_device_command(device_id, "cooling", False)

    if len(history) < 5:
        _publish_autotune_status(device_id, "error", reason="not_enough_samples")
        return {"status": "error", "reason": "not_enough_samples", "samples": len(history)}

    t_max = max(history)
    t_min = min(history)
    ku = max((t_max - t_min) * 10.0, 0.1)
    tu = max(len(history) * PID_AUTOTUNE_INTERVAL_SECONDS, 1.0)

    kp = 0.6 * ku
    ki = 2.0 * kp / tu
    kd = kp * tu / 8.0
    coeffs = save_pid_coefficients(device_id, owner_id, kp, ki, kd)
    _publish_autotune_status(device_id, "done", **coeffs)

    return {
        "status": "ok",
        "device_id": device_id,
        "samples": len(history),
        "range": round(t_max - t_min, 3),
        **coeffs,
    }


def control_humidity(device_id, current_humidity):
    targets = get_current_device_targets(device_id)
    target_hum = float(targets["hum"])
    humidifier_on = float(current_humidity) < target_hum
    command_ok, command_result = publish_device_command(
        device_id,
        "humidifier",
        humidifier_on,
    )
    if not command_ok:
        return {"status": "error", "reason": command_result}

    return {
        "status": "ok",
        "target_hum": round(target_hum, 1),
        "humidifier": humidifier_on,
    }


def apply_device_mode(owner_id, device_id, mode, target_temp=None):
    normalized_mode = str(mode or "").strip().lower()
    if normalized_mode not in {"auto", "manual", "ai"}:
        return False, {"error": "device_id and mode are required"}, 400

    if normalized_mode == "auto":
        if not isinstance(target_temp, (int, float)):
            return False, {"error": "target_temp must be numeric in auto mode"}, 400
        normalized_target = _clamp(float(target_temp), 0.0, 25.0)
    elif isinstance(target_temp, (int, float)):
        normalized_target = _clamp(float(target_temp), 0.0, 25.0)
    else:
        normalized_target = None

    c.execute(
        """
        INSERT OR REPLACE INTO pid_modes (device_id, owner_id, mode, target_temp, updated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
        """,
        (device_id, owner_id, normalized_mode, normalized_target),
    )
    conn.commit()

    if normalized_mode == "manual":
        clear_pid_state(device_id)
        released, details = release_pid_overrides(device_id)
        if not released:
            return False, {"error": details}, 503
        _update_device_snapshot(device_id, ai_enabled=False)
        return True, {"status": "OK", "device_id": device_id, "mode": normalized_mode}, 200

    if normalized_mode == "ai":
        command_ok, command_result = publish_device_command(device_id, "mode", normalized_mode)
        if not command_ok:
            return False, {"error": command_result}, 503
        _update_device_snapshot(device_id, mode="ai", ai_enabled=True)
        return True, {"status": "OK", "device_id": device_id, "mode": normalized_mode}, 200

    command_ok, command_result = publish_device_command(device_id, "mode", normalized_mode)
    if not command_ok:
        return False, {"error": command_result}, 503

    pid_result = run_pid_control(device_id, normalized_target)
    return True, {
        "status": "OK",
        "device_id": device_id,
        "mode": normalized_mode,
        "target_temp": normalized_target,
        "pid": pid_result,
    }, 200


def _coerce_control_bool(value):
    if isinstance(value, bool):
        return value

    if isinstance(value, (int, float)):
        return value != 0

    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "on", "high", "yes"}:
            return True
        if normalized in {"0", "false", "off", "low", "no"}:
            return False

    return None


def _build_control_payload(device_id, logical_topic, value):
    normalized_topic = str(logical_topic or "").strip().lower()
    alias_map = {
        "cooling": "control/cool",
        "humidifier": "control/humidifier",
        "fan": "control/fan",
    }
    normalized_topic = alias_map.get(normalized_topic, normalized_topic)
    payload = {"device_id": device_id}

    if normalized_topic in {"mode", "control/mode"}:
        mode = str(value).strip().lower()
        if mode not in {"auto", "manual", "ai"}:
            return None
        payload["mode"] = mode
        return payload

    if normalized_topic == "control/ai":
        ai_enabled = _coerce_control_bool(value)
        if ai_enabled is None:
            return None
        payload["ai"] = ai_enabled
        payload["mode"] = "ai" if ai_enabled else "manual"
        return payload

    control_field_map = {
        "control/cool": "cooling",
        "control/heater": "cooling",
        "control/hum": "humidifier",
        "control/humifier": "humidifier",
        "control/humidifier": "humidifier",
        "control/fan": "fan",
        "control/dehumidifier": "fan",
    }

    control_field = control_field_map.get(normalized_topic)
    if control_field is None:
        return None

    bool_value = _coerce_control_bool(value)
    if bool_value is None:
        return None

    payload[control_field] = bool_value
    return payload


def store_device_message(topic, payload):
    if topic == "devices/available":
        try:
            data_payload = json.loads(payload)
        except json.JSONDecodeError:
            return False

        if not isinstance(data_payload, dict):
            return False

        device_id = str(data_payload.get("id") or "").strip()
        if not device_id:
            return False

        _touch_discovered_device(
            device_id,
            ip=data_payload.get("ip"),
            rssi=data_payload.get("rssi"),
        )

        return True

    parts = topic.split("/", 2)
    if len(parts) != 3 or parts[0] != "devices" or not parts[1].strip():
        return False

    logical_topic = parts[2]
    device_id = parts[1].strip()
    with device_data_lock:
        snapshot = dict(device_data.get(device_id, {}))

        if logical_topic == "data":
            try:
                data_payload = json.loads(payload)
            except json.JSONDecodeError:
                return False

            if not isinstance(data_payload, dict):
                return False

            data_payload["device_id"] = str(
                data_payload.get("device_id") or device_id
            ).strip() or device_id

            if "temp" in data_payload:
                try:
                    snapshot["temp"] = float(data_payload["temp"])
                except (TypeError, ValueError):
                    snapshot["temp"] = data_payload["temp"]

            hum_value = data_payload.get("hum", data_payload.get("humidity"))
            if hum_value is not None:
                try:
                    normalized_hum = float(hum_value)
                except (TypeError, ValueError):
                    normalized_hum = hum_value

                snapshot["hum"] = normalized_hum
                snapshot["humidity"] = normalized_hum

            snapshot["data"] = data_payload
            _touch_discovered_device(device_id)
        else:
            if not logical_topic.startswith(("curing/", "control/")):
                return False

            snapshot[_device_field_name(logical_topic)] = _normalize_device_value(
                logical_topic, payload
            )

            if logical_topic == "curing/humidity" and "hum" not in snapshot:
                snapshot["hum"] = snapshot.get("humidity")

        snapshot["_last_topic"] = topic
        snapshot["_updated_at"] = int(time.time())
        device_data[device_id] = snapshot

    return True


def user_owns_device(owner_id, device_id):
    c.execute("SELECT 1 FROM devices WHERE id=? AND owner_id=?", (device_id, owner_id))
    return c.fetchone() is not None


def _connection_quality(rssi):
    if not isinstance(rssi, (int, float)):
        return "unknown"
    if rssi > -60:
        return "excellent"
    if rssi > -70:
        return "good"
    if rssi > -80:
        return "weak"
    return "bad"


def _serialize_discovered_devices():
    now = time.time()
    with available_devices_lock:
        entries = [dict(device) for device in available_devices.values()]

    entries.sort(key=lambda item: item["id"].lower())
    return [
        {
            "id": entry["id"],
            "ip": entry.get("ip"),
            "rssi": entry.get("rssi"),
            "quality": _connection_quality(entry.get("rssi")),
            "online": (now - float(entry.get("last_seen") or 0)) < 15,
            "first_seen": int(entry.get("first_seen") or entry.get("last_seen") or now),
        }
        for entry in entries
    ]


def _clamp(value, minimum, maximum):
    return max(minimum, min(maximum, value))


def get_device_mode(device_id):
    c.execute(
        "SELECT mode, target_temp FROM pid_modes WHERE device_id=?",
        (device_id,),
    )
    row = c.fetchone()
    if row is None:
        return {"mode": "manual", "target_temp": None}
    return {"mode": row[0], "target_temp": row[1]}


def clear_pid_state(device_id):
    c.execute("DELETE FROM pid_state WHERE device_id=?", (device_id,))
    conn.commit()


def release_pid_overrides(device_id):
    released, release_result = publish_device_command(device_id, "mode", "manual")
    if not released:
        return False, release_result

    return True, "released"


def run_pid_control(device_id, target_temp):
    c.execute(
        "SELECT temp, hum FROM telemetry_history WHERE device_id=? ORDER BY id DESC LIMIT 8",
        (device_id,),
    )
    rows = list(reversed(c.fetchall()))
    if len(rows) < 5:
        return {"status": "skipped", "reason": "not_enough_history"}

    current_temp = float(rows[-1][0])
    current_hum = float(rows[-1][1])
    c.execute(
        "SELECT integral, last_error FROM pid_state WHERE device_id=?",
        (device_id,),
    )
    previous_state = c.fetchone()

    coeffs = get_pid_coefficients(device_id)
    kp = coeffs["kp"]
    ki = coeffs["ki"]
    kd = coeffs["kd"]

    error = current_temp - float(target_temp)
    integral = _clamp((previous_state[0] if previous_state else 0.0) + error, -100.0, 100.0)
    last_error = previous_state[1] if previous_state else 0.0
    derivative = error - last_error
    output = kp * error + ki * integral + kd * derivative

    power = _clamp(max(output, 0.0) * 25.0, 0.0, 100.0)
    on_time = PID_CYCLE_TIME_SECONDS * (power / 100.0)
    off_time = PID_CYCLE_TIME_SECONDS - on_time
    cycle_position = time.time() % PID_CYCLE_TIME_SECONDS

    cool_on = power > 0 and cycle_position < on_time
    fan_on = power > 5.0

    cool_ok, cool_result = publish_device_command(
        device_id,
        "control/cool",
        cool_on,
    )
    if not cool_ok:
        return {"status": "error", "reason": cool_result}

    fan_ok, fan_result = publish_device_command(
        device_id,
        "control/fan",
        fan_on,
    )
    if not fan_ok:
        return {"status": "error", "reason": fan_result}

    c.execute(
        """
        INSERT OR REPLACE INTO pid_state (device_id, integral, last_error, last_output, updated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
        """,
        (device_id, integral, error, power),
    )
    conn.commit()

    humidity_result = control_humidity(device_id, current_hum)

    return {
        "status": "ok",
        "device_id": device_id,
        "current_temp": round(current_temp, 2),
        "current_hum": round(current_hum, 2),
        "target_temp": round(float(target_temp), 2),
        "output": round(output, 3),
        "power": round(power, 1),
        "cycle_time": PID_CYCLE_TIME_SECONDS,
        "on_time": round(on_time, 2),
        "off_time": round(off_time, 2),
        "coefficients": coeffs,
        "cool": cool_on,
        "fan": fan_on,
        "humidity": humidity_result,
    }


def publish_device_command(device_id, logical_topic, value):
    start_mqtt_listener()
    client = mqtt_client
    if client is None:
        return False, "MQTT client unavailable"

    normalized_topic = str(logical_topic or "").strip().lower()
    if normalized_topic.startswith("curing/"):
        scoped_topic = f"devices/{device_id}/{normalized_topic}"
        result = client.publish(scoped_topic, str(value))
        if result.rc != mqtt.MQTT_ERR_SUCCESS:
            return False, "Nie udało się wysłać komendy MQTT"
        return True, scoped_topic

    control_payload = _build_control_payload(device_id, normalized_topic, value)
    if control_payload is None:
        return False, "Invalid control topic or value"

    published_topics = []
    mode_topics = {
        "mode": "control/mode",
        "ai": "control/ai",
    }
    control_fields = {
        "cooling": "control/cool",
        "humidifier": "control/humidifier",
        "fan": "control/fan",
    }

    for field, scoped_suffix in mode_topics.items():
        if field not in control_payload:
            continue

        scoped_topic = f"devices/{device_id}/{scoped_suffix}"
        field_value = control_payload[field]
        payload = str(field_value).lower() if isinstance(field_value, bool) else str(field_value)
        result = client.publish(scoped_topic, payload)
        if result.rc != mqtt.MQTT_ERR_SUCCESS:
            return False, "Nie udało się wysłać komendy MQTT"
        published_topics.append(scoped_topic)

    for field, scoped_suffix in control_fields.items():
        if field not in control_payload:
            continue

        scoped_topic = f"devices/{device_id}/{scoped_suffix}"
        field_value = control_payload[field]
        payload = str(field_value).lower() if isinstance(field_value, bool) else str(field_value)
        result = client.publish(scoped_topic, payload)
        if result.rc != mqtt.MQTT_ERR_SUCCESS:
            return False, "Nie udało się wysłać komendy MQTT"
        published_topics.append(scoped_topic)

    if not published_topics:
        return False, "Invalid control topic or value"

    if len(published_topics) == 1:
        return True, published_topics[0]

    return True, published_topics


def get_current_device_targets(device_id):
    defaults = {"temp": 14.0, "hum": 80.0}

    with device_data_lock:
        snapshot = dict(device_data.get(device_id, {}))

    if not snapshot:
        return defaults

    temp_value = snapshot.get("temp_max", snapshot.get("temp", defaults["temp"]))
    hum_value = snapshot.get(
        "hum_max",
        snapshot.get("hum", snapshot.get("humidity", defaults["hum"])),
    )

    try:
        temp_target = _clamp(float(temp_value), 0.0, 25.0)
    except (TypeError, ValueError):
        temp_target = defaults["temp"]

    try:
        hum_target = _clamp(float(hum_value), 0.0, 100.0)
    except (TypeError, ValueError):
        hum_target = defaults["hum"]

    return {"temp": round(temp_target, 1), "hum": round(hum_target, 0)}


def _handle_mqtt_connect(client, userdata, flags, rc):
    if rc == 0:
        client.subscribe(MQTT_TOPIC)


def _handle_mqtt_message(client, userdata, message):
    payload = message.payload.decode("utf-8", errors="ignore")
    store_device_message(message.topic, payload)


def start_mqtt_listener():
    global mqtt_client, mqtt_started

    with mqtt_start_lock:
        if mqtt_started:
            return

        client = mqtt.Client(client_id="dojrzewalnia-backend")
        client.username_pw_set(MQTT_USERNAME, MQTT_PASSWORD)
        client.on_connect = _handle_mqtt_connect
        client.on_message = _handle_mqtt_message
        client.reconnect_delay_set(min_delay=2, max_delay=15)
        client.connect_async(MQTT_SERVER, MQTT_PORT, keepalive=30)
        client.loop_start()
        mqtt_client = client
        mqtt_started = True


def validate_fields(data, required_fields):
    if not isinstance(data, dict):
        return "Invalid JSON payload"

    for field in required_fields:
        value = data.get(field)
        if not isinstance(value, str) or not value.strip():
            return f"Field '{field}' is required"

    return None


def validate_numeric_list(values):
    if not isinstance(values, list) or not values:
        return None

    cleaned = []
    for value in values:
        if isinstance(value, (int, float)):
            cleaned.append(float(value))

    return cleaned or None


def send_push(token, title, body):
    server_key = os.environ.get("FCM_SERVER_KEY", "").strip()
    if not server_key:
        return False

    response = requests.post(
        "https://fcm.googleapis.com/fcm/send",
        headers={
            "Authorization": f"key={server_key}",
            "Content-Type": "application/json",
        },
        json={
            "to": token,
            "notification": {"title": title, "body": body},
        },
        timeout=10,
    )
    return response.ok


def send_alert(title, message, owner_id=None):
    if owner_id:
        c.execute(
            "SELECT token FROM notification_tokens WHERE owner_id=?",
            (owner_id,),
        )
    else:
        c.execute("SELECT token FROM notification_tokens")

    tokens = [row[0] for row in c.fetchall()]
    sent = 0
    for token in tokens:
        if send_push(token, title, message):
            sent += 1

    print(f"ALERT: {title} {message} -> tokens={len(tokens)} sent={sent}")
    return sent


def record_telemetry(device_id, owner_id, temp, hum):
    c.execute(
        "INSERT INTO telemetry_history (device_id, owner_id, temp, hum) VALUES (?, ?, ?, ?)",
        (device_id, owner_id, float(temp), float(hum)),
    )
    conn.commit()


def learn_ai_settings(device_id, hum, hum_rate, proposed_kp, proposed_target_hum):
    state = ai_device_state.setdefault(
        device_id,
        {
            "kp": 2.0,
            "targetHum": 80.0,
            "updatedAt": int(time.time()),
        },
    )

    kp = float(state.get("kp", 2.0))
    target_hum = float(state.get("targetHum", 80.0))

    if isinstance(proposed_kp, (int, float)):
        kp = float(proposed_kp)
    if isinstance(proposed_target_hum, (int, float)):
        target_hum = float(proposed_target_hum)

    if hum_rate > 1.5:
        kp *= 0.9
    elif hum_rate < 0.3:
        kp *= 1.1

    if hum > target_hum + 3.0:
        kp *= 0.8
        target_hum -= 0.5
    elif hum < target_hum - 5.0:
        kp *= 1.2
        target_hum += 0.5

    if hum > 85.0:
        target_hum -= 0.2
    elif hum < 75.0:
        target_hum += 0.2

    kp = max(0.5, min(5.0, kp))
    target_hum = max(50.0, min(95.0, target_hum))

    state.update(
        {
            "kp": round(kp, 3),
            "targetHum": round(target_hum, 2),
            "updatedAt": int(time.time()),
        }
    )
    return state


@app.before_request
def ensure_mqtt_listener_started():
    start_mqtt_listener()


@app.route("/")
def index():
    return render_template("admin.html")


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


@app.route("/register", methods=["POST"])
def register():
    data = request.get_json(force=True)
    error = validate_fields(data, ["email", "password"])
    if error:
        return jsonify({"error": error}), 400

    email = data["email"].strip().lower()
    password = data["password"]

    c.execute("SELECT 1 FROM users WHERE email=?", (email,))
    if c.fetchone() is not None:
        return jsonify({"error": "Użytkownik już istnieje"}), 409

    password_hash = bcrypt.generate_password_hash(password).decode("utf-8")
    c.execute(
        "INSERT INTO users (id, email, password) VALUES (?, ?, ?)",
        (str(uuid.uuid4()), email, password_hash),
    )
    conn.commit()
    return jsonify({"success": True}), 200


@app.route("/login", methods=["POST"])
def login():
    data = request.get_json(force=True)
    error = validate_fields(data, ["email", "password"])
    if error:
        return jsonify({"error": error}), 400

    c.execute(
        "SELECT id, email, password FROM users WHERE email=?",
        (data["email"].strip().lower(),),
    )
    user = c.fetchone()

    if user and bcrypt.check_password_hash(user[2], data["password"]):
        token = create_access_token(identity=user[0])
        return jsonify({"success": True, "token": token, "access_token": token})

    return jsonify({"success": False, "error": "Invalid credentials"}), 401


@app.route("/me", methods=["GET"])
@jwt_required()
def me():
    uid = get_jwt_identity()
    c.execute("SELECT email FROM users WHERE id=?", (uid,))
    user = c.fetchone()

    if user is None:
        return jsonify({"error": "Invalid token"}), 401

    return jsonify({"email": user[0]})


@app.route("/devices", methods=["POST"])
@jwt_required()
def add_device():
    uid = get_jwt_identity()
    data = request.get_json(force=True)
    error = validate_fields(data, ["id"])
    if error:
        return jsonify({"error": error}), 400

    raw_name = data.get("name", "")
    if raw_name is None:
        raw_name = ""
    if not isinstance(raw_name, str):
        return jsonify({"error": "Field 'name' must be a string"}), 400

    device_id = data["id"].strip()
    device_name = raw_name.strip() or device_id

    c.execute(
        "INSERT OR REPLACE INTO devices (id, name, owner_id) VALUES (?, ?, ?)",
        (device_id, device_name, uid),
    )
    conn.commit()
    return jsonify({"status": "OK"})


@app.route("/devices", methods=["GET"])
@jwt_required()
def get_devices():
    uid = get_jwt_identity()
    c.execute(
        "SELECT id, name FROM devices WHERE owner_id=? ORDER BY name COLLATE NOCASE",
        (uid,),
    )
    rows = c.fetchall()
    return jsonify([{"id": row[0], "name": row[1]} for row in rows])


@app.route("/devices/available", methods=["GET"])
def get_available_devices():
    return jsonify(_serialize_discovered_devices())


@app.route("/devices/discovered", methods=["GET"])
def get_discovered_devices():
    return jsonify(_serialize_discovered_devices())


@app.route("/discovered", methods=["GET"])
def get_discovered_devices_alias():
    return jsonify(_serialize_discovered_devices())


@app.route("/devices/<device_id>", methods=["DELETE"])
@jwt_required()
def delete_device(device_id):
    uid = get_jwt_identity()
    c.execute("DELETE FROM devices WHERE id=? AND owner_id=?", (device_id, uid))
    conn.commit()
    return jsonify({"status": "OK"})


@app.route("/mode", methods=["GET"])
@jwt_required()
def get_mode():
    uid = get_jwt_identity()
    device_id = (request.args.get("device_id") or "").strip()
    if not device_id:
        return jsonify({"error": "device_id query parameter is required"}), 400

    if not user_owns_device(uid, device_id):
        return jsonify({"error": "Nie znaleziono urządzenia"}), 404

    mode = get_device_mode(device_id)
    return jsonify({"device_id": device_id, **mode})


@app.route("/mode", methods=["POST"])
@jwt_required()
def set_mode():
    uid = get_jwt_identity()
    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON payload"}), 400

    device_id = str(data.get("device_id") or "").strip()
    mode = str(data.get("mode") or "").strip().lower()
    if not device_id or mode not in {"auto", "manual", "ai"}:
        return jsonify({"error": "device_id and mode are required"}), 400

    if not user_owns_device(uid, device_id):
        return jsonify({"error": "Nie znaleziono urządzenia"}), 404

    success, payload, status_code = apply_device_mode(
        uid,
        device_id,
        mode,
        data.get("target_temp"),
    )
    return jsonify(payload), status_code


@app.route("/device_data", methods=["POST"])
@jwt_required()
def get_device_data_snapshot():
    uid = get_jwt_identity()
    data = request.get_json(force=True)
    error = validate_fields(data, ["device_id"])
    if error:
        return jsonify({"error": error}), 400

    device_id = data["device_id"].strip()
    if not user_owns_device(uid, device_id):
        return jsonify({"error": "Nie znaleziono urządzenia"}), 404

    with device_data_lock:
        snapshot = dict(device_data.get(device_id, {}))

    if not snapshot:
        return jsonify({"error": "Brak danych live dla urządzenia"}), 404

    return jsonify({"success": True, "data": snapshot})


@app.route("/latest", methods=["GET"])
@jwt_required()
def latest_device_data():
    uid = get_jwt_identity()
    device_id = (request.args.get("device_id") or "").strip()
    if not device_id:
        return jsonify({"error": "device_id query parameter is required"}), 400

    if not user_owns_device(uid, device_id):
        return jsonify({"error": "Nie znaleziono urządzenia"}), 404

    with device_data_lock:
        snapshot = dict(device_data.get(device_id, {}))

    if not snapshot:
        return jsonify({"error": "Brak danych live dla urządzenia"}), 404

    topic = snapshot.pop("_last_topic", f"devices/{device_id}/curing")
    updated_at = snapshot.pop("_updated_at", int(time.time()))
    return jsonify(
        {
            "device_id": device_id,
            "topic": topic,
            "data": snapshot,
            "time": updated_at,
        }
    )


@app.route("/control", methods=["POST"])
@jwt_required()
def control_device():
    uid = get_jwt_identity()
    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON payload"}), 400

    error = validate_fields(data, ["device_id", "topic"])
    if error:
        return jsonify({"error": error}), 400

    device_id = data["device_id"].strip()
    if not user_owns_device(uid, device_id):
        return jsonify({"error": "Nie znaleziono urządzenia"}), 404

    value = data.get("value")
    if value is None:
        return jsonify({"error": "Field 'value' is required"}), 400

    normalized_topic = data["topic"].strip().lower()
    if normalized_topic == "mode":
        success, payload, status_code = apply_device_mode(uid, device_id, value)
        return jsonify(payload), status_code

    if normalized_topic == "autotune":
        enabled = _coerce_control_bool(value)
        if enabled is not True:
            return jsonify({"error": "autotune requires true value"}), 400

        result = autotune_pid(device_id, uid)
        status_code = 200 if result.get("status") == "ok" else 503
        return jsonify(result), status_code

    success, details = publish_device_command(
        device_id,
        data["topic"].strip(),
        value,
    )
    if not success:
        return jsonify({"error": details}), 503

    return jsonify({"success": True, "topic": details})


@app.route("/auto/run", methods=["POST"])
def run_auto_pid():
    c.execute(
        "SELECT device_id, target_temp FROM pid_modes WHERE mode='auto' ORDER BY device_id"
    )
    rows = c.fetchall()
    results = []

    for device_id, target_temp in rows:
        if target_temp is None:
            results.append(
                {"device_id": device_id, "status": "skipped", "reason": "missing_target"}
            )
            continue

        results.append(run_pid_control(device_id, float(target_temp)))

    return jsonify(
        {
            "success": True,
            "processed": len(rows),
            "results": results,
        }
    )


@app.route("/admin/users", methods=["GET"])
@jwt_required()
def list_users():
    c.execute("SELECT id, email FROM users ORDER BY email COLLATE NOCASE")
    rows = c.fetchall()
    return jsonify([{"id": row[0], "email": row[1]} for row in rows])


@app.route("/admin/devices", methods=["GET"])
@jwt_required()
def list_all_devices():
    c.execute(
        """
        SELECT devices.id, devices.name, devices.owner_id, users.email
        FROM devices
        LEFT JOIN users ON users.id = devices.owner_id
        ORDER BY devices.name COLLATE NOCASE
        """
    )
    rows = c.fetchall()
    return jsonify(
        [
            {
                "id": row[0],
                "name": row[1],
                "owner_id": row[2],
                "owner_email": row[3],
                "mqtt_status": "unknown",
            }
            for row in rows
        ]
    )


@app.route("/admin/devices/<device_id>", methods=["DELETE"])
@jwt_required()
def admin_delete_device(device_id):
    c.execute("DELETE FROM devices WHERE id=?", (device_id,))
    conn.commit()
    return jsonify({"status": "OK"})


@app.route("/fcm/token", methods=["POST"])
@jwt_required()
def register_fcm_token():
    uid = get_jwt_identity()
    data = request.get_json(force=True)
    error = validate_fields(data, ["token"])
    if error:
        return jsonify({"error": error}), 400

    c.execute(
        "INSERT OR REPLACE INTO notification_tokens (token, owner_id) VALUES (?, ?)",
        (data["token"].strip(), uid),
    )
    conn.commit()
    return jsonify({"status": "OK"})


@app.route("/telemetry", methods=["POST"])
@jwt_required()
def save_telemetry():
    uid = get_jwt_identity()
    data = request.get_json(force=True)
    error = validate_fields(data, ["device_id"])
    if error:
        return jsonify({"error": error}), 400

    temp = data.get("temp")
    hum = data.get("hum")
    if not isinstance(temp, (int, float)) or not isinstance(hum, (int, float)):
        return jsonify({"error": "temp and hum must be numeric"}), 400

    record_telemetry(data["device_id"].strip(), uid, temp, hum)
    return jsonify({"status": "OK"})


@app.route("/history", methods=["GET"])
@jwt_required()
def get_history():
    uid = get_jwt_identity()
    device_id = (request.args.get("device") or "").strip()
    if not device_id:
        return jsonify({"error": "device query parameter is required"}), 400

    limit_raw = request.args.get("limit", "60")
    try:
        limit = max(1, min(int(limit_raw), 300))
    except ValueError:
        limit = 60

    c.execute(
        """
        SELECT temp, hum, created_at
        FROM telemetry_history
        WHERE owner_id=? AND device_id=?
        ORDER BY id DESC
        LIMIT ?
        """,
        (uid, device_id, limit),
    )
    rows = list(reversed(c.fetchall()))
    return jsonify(
        [
            {"temp": row[0], "hum": row[1], "created_at": row[2]}
            for row in rows
        ]
    )


@app.route("/ai/control", methods=["POST"])
@jwt_required()
def get_ai_control():
    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON payload"}), 400

    temp_history = validate_numeric_list(data.get("temp_history"))
    hum_history = validate_numeric_list(data.get("hum_history"))
    target_temp = data.get("target_temp")

    if temp_history is None or hum_history is None:
        return jsonify({"error": "History data is required"}), 400

    if not isinstance(target_temp, (int, float)):
        return jsonify({"error": "target_temp must be numeric"}), 400

    recommended_target = ai_control(temp_history, hum_history, target_temp)
    recommended_target = max(0.0, min(25.0, recommended_target))
    return jsonify(
        {
            "recommended_target": recommended_target,
            "current_target": round(float(target_temp), 2),
            "samples": len(temp_history),
        }
    )


@app.route("/ai/device/state", methods=["POST"])
def ai_device_state_update():
    unauthorized = require_device_token()
    if unauthorized is not None:
        return unauthorized

    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON payload"}), 400

    device_id = str(data.get("deviceId") or "").strip()
    if not device_id:
        return jsonify({"error": "deviceId is required"}), 400

    temp = data.get("temp")
    hum = data.get("hum")
    hum_rate = data.get("humRate")
    if not all(isinstance(value, (int, float)) for value in [temp, hum, hum_rate]):
        return jsonify({"error": "temp, hum and humRate must be numeric"}), 400

    ai_history[device_id].append(
        {
            "temp": float(temp),
            "hum": float(hum),
            "rate": float(hum_rate),
            "time": int(time.time()),
        }
    )

    state = learn_ai_settings(
        device_id,
        float(hum),
        float(hum_rate),
        data.get("kp"),
        data.get("targetHum"),
    )
    return jsonify(state)


@app.route("/ai/device/settings", methods=["GET"])
def ai_device_settings():
    unauthorized = require_device_token()
    if unauthorized is not None:
        return unauthorized

    device_id = str(request.args.get("deviceId") or "").strip()
    if not device_id:
        return jsonify({"error": "deviceId query parameter is required"}), 400

    state = ai_device_state.setdefault(
        device_id,
        {
            "kp": 2.0,
            "targetHum": 80.0,
            "updatedAt": int(time.time()),
        },
    )
    return jsonify(state)


@app.route("/scenes", methods=["GET"])
@jwt_required()
def list_scenes():
    return jsonify({**scenes, **{scene: {} for scene in sorted(ai_scenes)}})


@app.route("/scenes/apply", methods=["POST"])
@jwt_required()
def apply_scene():
    uid = get_jwt_identity()
    data = request.get_json(force=True)
    error = validate_fields(data, ["device_id", "scene"])
    if error:
        return jsonify({"error": error}), 400

    device_id = data["device_id"].strip()
    if not user_owns_device(uid, device_id):
        return jsonify({"error": "Nie znaleziono urządzenia"}), 404

    scene_name = data["scene"].strip().lower()
    if scene_name in ai_scenes:
        ai_enabled = scene_name == "ai_on"
        command_ok, command_result = publish_device_command(
            device_id,
            "control/ai",
            1 if ai_enabled else 0,
        )
        if not command_ok:
            return jsonify({"error": command_result}), 503

        _update_device_snapshot(device_id, ai_enabled=ai_enabled)

        return jsonify(
            {
                "status": "OK",
                "device_id": device_id,
                "scene": scene_name,
                "ai_enabled": ai_enabled,
                "commands": get_current_device_targets(device_id),
            }
        )

    if scene_name not in scenes:
        return jsonify({"error": "Unknown scene"}), 404

    cfg = scenes[scene_name]
    optimized_temp = cfg["temp"]
    temp_history = validate_numeric_list(data.get("temp_history"))
    if temp_history is not None:
        optimized_temp = ai_control(temp_history, [], cfg["temp"])
        optimized_temp = max(0.0, min(25.0, optimized_temp))

    temp_ok, temp_result = publish_device_command(
        device_id,
        "curing/set/temp_max",
        round(float(optimized_temp), 1),
    )
    hum_ok, hum_result = publish_device_command(
        device_id,
        "curing/set/hum_max",
        round(float(cfg["hum"]), 0),
    )
    if not temp_ok:
        return jsonify({"error": temp_result}), 503
    if not hum_ok:
        return jsonify({"error": hum_result}), 503

    return jsonify(
        {
            "status": "OK",
            "device_id": device_id,
            "scene": scene_name,
            "commands": {
                "temp": optimized_temp,
                "hum": cfg["hum"],
            },
        }
    )


@app.route("/alerts/evaluate", methods=["POST"])
@jwt_required()
def evaluate_alerts():
    uid = get_jwt_identity()
    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON payload"}), 400

    temp = data.get("temp")
    humidity = data.get("humidity")
    device_id = str(data.get("device_id") or "urządzeniu")

    if not isinstance(temp, (int, float)) or not isinstance(humidity, (int, float)):
        return jsonify({"error": "temp and humidity must be numeric"}), 400

    alerts = check_alerts(float(temp), float(humidity))
    if not alerts:
        return jsonify({"status": "OK", "alert_sent": False, "alerts": []})

    sent = 0
    for alert in alerts:
        sent += send_alert(
            "Alert dojrzewalni",
            f"{alert} na {device_id}. Temp: {float(temp):.1f}°C, Hum: {float(humidity):.1f}%",
            owner_id=uid,
        )

    return jsonify(
        {
            "status": "OK",
            "alert_sent": sent > 0,
            "sent": sent,
            "alerts": alerts,
        }
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=20345)