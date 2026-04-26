import json
import os
import sqlite3
import threading
import time
import uuid

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

conn.commit()

scenes = {
    "night": {"temp": 1.5, "hum": 75},
    "dry": {"temp": 3.0, "hum": 60},
    "boost": {"temp": 5.0, "hum": 50},
}

MQTT_SERVER = os.environ.get("MQTT_SERVER", "srv22.mikr.us")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "20552"))
MQTT_USERNAME = os.environ.get("MQTT_USERNAME", "curing_user")
MQTT_PASSWORD = os.environ.get("MQTT_PASSWORD", "mocne")
MQTT_TOPIC = "devices/+/#"

device_data = {}
device_data_lock = threading.Lock()
available_devices = {}
available_devices_lock = threading.Lock()
mqtt_client = None
mqtt_started = False
mqtt_start_lock = threading.Lock()


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
    }
    return field_map.get(logical_topic, logical_topic.replace("/", "_"))


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

        with available_devices_lock:
            available_devices[device_id] = {
                "id": device_id,
                "ip": data_payload.get("ip"),
                "rssi": data_payload.get("rssi"),
                "last_seen": time.time(),
            }

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
        else:
            if not logical_topic.startswith("curing/"):
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
    cool_ok, cool_result = publish_device_command(device_id, "control/cool", "auto")
    if not cool_ok:
        return False, cool_result

    fan_ok, fan_result = publish_device_command(device_id, "control/fan", "auto")
    if not fan_ok:
        return False, fan_result

    return True, "released"


def run_pid_control(device_id, target_temp):
    c.execute(
        "SELECT temp FROM telemetry_history WHERE device_id=? ORDER BY id DESC LIMIT 8",
        (device_id,),
    )
    rows = list(reversed(c.fetchall()))
    if len(rows) < 5:
        return {"status": "skipped", "reason": "not_enough_history"}

    current_temp = float(rows[-1][0])
    c.execute(
        "SELECT integral, last_error FROM pid_state WHERE device_id=?",
        (device_id,),
    )
    previous_state = c.fetchone()

    kp = 2.0
    ki = 0.1
    kd = 1.0
    threshold = 0.35

    error = current_temp - float(target_temp)
    integral = _clamp((previous_state[0] if previous_state else 0.0) + error, -100.0, 100.0)
    last_error = previous_state[1] if previous_state else 0.0
    derivative = error - last_error
    output = kp * error + ki * integral + kd * derivative

    cool_on = output > threshold
    fan_on = output > (threshold * 0.5)

    cool_ok, cool_result = publish_device_command(
        device_id,
        "control/cool",
        1 if cool_on else 0,
    )
    if not cool_ok:
        return {"status": "error", "reason": cool_result}

    fan_ok, fan_result = publish_device_command(
        device_id,
        "control/fan",
        1 if fan_on else 0,
    )
    if not fan_ok:
        return {"status": "error", "reason": fan_result}

    c.execute(
        """
        INSERT OR REPLACE INTO pid_state (device_id, integral, last_error, last_output, updated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
        """,
        (device_id, integral, error, output),
    )
    conn.commit()

    return {
        "status": "ok",
        "device_id": device_id,
        "current_temp": round(current_temp, 2),
        "target_temp": round(float(target_temp), 2),
        "output": round(output, 3),
        "cool": cool_on,
        "fan": fan_on,
    }


def publish_device_command(device_id, logical_topic, value):
    start_mqtt_listener()
    client = mqtt_client
    if client is None:
        return False, "MQTT client unavailable"

    if not logical_topic.startswith(("curing/", "control/")):
        return False, "Invalid control topic"

    scoped_topic = f"devices/{device_id}/{logical_topic}"
    result = client.publish(scoped_topic, str(value))
    if result.rc != mqtt.MQTT_ERR_SUCCESS:
        return False, "Nie udało się wysłać komendy MQTT"

    return True, scoped_topic


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
@jwt_required()
def get_available_devices():
    now = time.time()
    with available_devices_lock:
        entries = [dict(device) for device in available_devices.values()]

    entries.sort(key=lambda item: item["id"].lower())
    return jsonify(
        [
            {
                "id": entry["id"],
                "ip": entry.get("ip"),
                "rssi": entry.get("rssi"),
                "quality": _connection_quality(entry.get("rssi")),
                "online": (now - float(entry.get("last_seen") or 0)) < 15,
            }
            for entry in entries
        ]
    )


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
    if not device_id or mode not in {"auto", "manual"}:
        return jsonify({"error": "device_id and mode are required"}), 400

    if not user_owns_device(uid, device_id):
        return jsonify({"error": "Nie znaleziono urządzenia"}), 404

    target_temp = data.get("target_temp")
    if mode == "auto":
        if not isinstance(target_temp, (int, float)):
            return jsonify({"error": "target_temp must be numeric in auto mode"}), 400
        target_temp = _clamp(float(target_temp), 0.0, 25.0)
    else:
        target_temp = None

    c.execute(
        """
        INSERT OR REPLACE INTO pid_modes (device_id, owner_id, mode, target_temp, updated_at)
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
        """,
        (device_id, uid, mode, target_temp),
    )
    conn.commit()

    if mode == "manual":
        clear_pid_state(device_id)
        released, details = release_pid_overrides(device_id)
        if not released:
            return jsonify({"error": details}), 503
        return jsonify({"status": "OK", "device_id": device_id, "mode": mode})

    pid_result = run_pid_control(device_id, target_temp)
    return jsonify(
        {
            "status": "OK",
            "device_id": device_id,
            "mode": mode,
            "target_temp": target_temp,
            "pid": pid_result,
        }
    )


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


@app.route("/scenes", methods=["GET"])
@jwt_required()
def list_scenes():
    return jsonify(scenes)


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