import numpy as np

try:
    from sklearn.linear_model import LinearRegression
except Exception:  # pragma: no cover - optional runtime dependency fallback
    LinearRegression = None


def predict_next(values):
    cleaned = [float(value) for value in values if value is not None]
    if not cleaned:
        return 0.0

    if len(cleaned) < 3:
        return cleaned[-1]

    if LinearRegression is not None:
        x_axis = np.arange(len(cleaned)).reshape(-1, 1)
        y_axis = np.array(cleaned)
        model = LinearRegression()
        model.fit(x_axis, y_axis)
        future = np.array([[len(cleaned) + 5]])
        return float(model.predict(future)[0])

    trend = np.polyfit(range(len(cleaned)), cleaned, 1)
    return float(trend[0] * len(cleaned) + trend[1])


def ai_control(temp_history, hum_history, target_temp):
    cleaned = [float(value) for value in temp_history if value is not None]
    target = float(target_temp)

    if len(cleaned) < 3:
        return round(target, 2)

    future_temp = predict_next(cleaned)
    overshoot = future_temp - target
    adjustment = 0.0

    if overshoot > 0:
        adjustment = -min(2.0, overshoot * 0.5)
    elif overshoot < -0.5:
        adjustment = min(1.0, abs(overshoot) * 0.25)

    humidity_values = [float(value) for value in hum_history if value is not None]
    if humidity_values and humidity_values[-1] > 85:
        adjustment -= 0.2

    new_target = target + adjustment
    return round(new_target, 2)


def check_alerts(temp, hum):
    alerts = []

    if float(temp) > 10:
        alerts.append("Za wysoka temperatura")

    if float(hum) > 85:
        alerts.append("Za wysoka wilgotność")

    if float(temp) < 0:
        alerts.append("Za niska temperatura")

    return alerts