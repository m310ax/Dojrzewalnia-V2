import numpy as np


def predict_next(values):
    cleaned = [float(value) for value in values if value is not None]
    if not cleaned:
        return 0.0

    if len(cleaned) < 5:
        return cleaned[-1]

    trend = np.polyfit(range(len(cleaned)), cleaned, 1)
    return float(trend[0] * len(cleaned) + trend[1])


def ai_control(temp_history, hum_history, target_temp):
    cleaned = [float(value) for value in temp_history if value is not None]
    target = float(target_temp)

    if len(cleaned) < 5:
        return round(target, 2)

    trend = cleaned[-1] - cleaned[-5]
    predicted = cleaned[-1] + trend
    error = target - predicted
    adjustment = error * 0.3
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