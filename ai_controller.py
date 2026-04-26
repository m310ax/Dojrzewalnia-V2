import numpy as np


class AIController:
    def predict_temp_rise(self, temp_history):
        if len(temp_history) < 3:
            return 0

        diffs = np.diff(temp_history)
        return float(np.mean(diffs))

    def recommend_target(self, temp_history, target):
        trend = self.predict_temp_rise(temp_history)

        if trend > 0.2:
            target -= 0.5

        if trend < -0.2:
            target += 0.5

        return round(target, 2)