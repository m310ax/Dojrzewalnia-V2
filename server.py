import os
import sqlite3
import uuid

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
app.config["PORT"] = int(os.environ.get("PORT", "20551"))

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

conn.commit()

scenes = {
    "night": {"temp": 1.5, "hum": 75},
    "dry": {"temp": 3.0, "hum": 60},
    "boost": {"temp": 5.0, "hum": 50},
}


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


@app.route("/")
def index():
    return render_template("admin.html")


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


@app.route("/register", methods=["POST"])
def register():
    try:
        data = request.get_json(force=True)

        print("DATA:", data)

        if not data:
            return jsonify({"success": False, "error": "No JSON"}), 400

        email = data.get("email")
        password = data.get("password")

        if not email or not password:
            return jsonify({"success": False, "error": "Missing data"}), 400

        return jsonify({"success": True}), 200

    except Exception as e:
        print("ERROR:", e)
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/login", methods=["POST"])
def login():
    data = request.get_json(force=True)
    error = validate_fields(data, ["email", "password"])
    if error:
        return jsonify({"error": error}), 400

    c.execute(
        "SELECT id, password FROM users WHERE email=?",
        (data["email"].strip().lower(),),
    )
    user = c.fetchone()

    if user and bcrypt.check_password_hash(user[1], data["password"]):
        token = create_access_token(identity=user[0])
        return jsonify(access_token=token)

    return jsonify({"error": "Unauthorized"}), 401


@app.route("/devices", methods=["POST"])
@jwt_required()
def add_device():
    uid = get_jwt_identity()
    data = request.get_json(force=True)
    error = validate_fields(data, ["id", "name"])
    if error:
        return jsonify({"error": error}), 400

    c.execute(
        "INSERT OR REPLACE INTO devices (id, name, owner_id) VALUES (?, ?, ?)",
        (data["id"].strip(), data["name"].strip(), uid),
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


@app.route("/devices/<device_id>", methods=["DELETE"])
@jwt_required()
def delete_device(device_id):
    uid = get_jwt_identity()
    c.execute("DELETE FROM devices WHERE id=? AND owner_id=?", (device_id, uid))
    conn.commit()
    return jsonify({"status": "OK"})


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
    data = request.get_json(force=True)
    error = validate_fields(data, ["device_id", "scene"])
    if error:
        return jsonify({"error": error}), 400

    scene_name = data["scene"].strip().lower()
    if scene_name not in scenes:
        return jsonify({"error": "Unknown scene"}), 404

    cfg = scenes[scene_name]
    optimized_temp = cfg["temp"]
    temp_history = validate_numeric_list(data.get("temp_history"))
    if temp_history is not None:
        optimized_temp = ai_control(temp_history, [], cfg["temp"])
        optimized_temp = max(0.0, min(25.0, optimized_temp))

    return jsonify(
        {
            "status": "OK",
            "device_id": data["device_id"].strip(),
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
    app.run(host="0.0.0.0", port=10551)