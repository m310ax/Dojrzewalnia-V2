import numpy as np


class AIController:
    def predict_temp_rise(self, temp_history):
        if len(temp_history) < 3:
            return 0.0

        history = [float(value) for value in temp_history]
        return float((history[-1] - history[0]) / max(len(history) - 1, 1))

    def recommend_target(self, temp_history, target):
        trend = self.predict_temp_rise(temp_history)
        current_temp = float(temp_history[-1]) if temp_history else float(target)
        future_temp = current_temp + trend * 10

        if future_temp > target:
            target -= min(2.0, (future_temp - target) * 0.5)
        elif future_temp < target - 0.5:
            target += min(1.0, (target - future_temp) * 0.25)

        return round(float(target), 2)