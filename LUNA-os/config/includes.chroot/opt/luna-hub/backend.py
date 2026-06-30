#!/usr/bin/env python3
import subprocess, psutil
from flask import Flask, jsonify, send_from_directory

app = Flask(__name__, static_folder="static")

def read_temps():
    try:
        temps = psutil.sensors_temperatures()
        if not temps:
            return None
        for name, entries in temps.items():
            if entries:
                return entries[0].current
    except Exception:
        return None
    return None

def read_fan_rpm():
    try:
        fans = psutil.sensors_fans()
        for name, entries in fans.items():
            if entries:
                return entries[0].current
    except Exception:
        return None
    return None


def read_gpu():
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"], text=True, timeout=2
        ).strip().split(", ")
        return {"vendor": "NVIDIA", "util": int(out[0]), "mem_used_mb": int(out[1]),
                "mem_total_mb": int(out[2]), "temp": int(out[3])}
    except Exception:
        pass
    try:
        import glob
        cards = glob.glob("/sys/class/drm/card*/device/gpu_busy_percent")
        if cards:
            util = int(open(cards[0]).read().strip())
            return {"vendor": "AMD", "util": util, "mem_used_mb": None, "mem_total_mb": None, "temp": None}
    except Exception:
        pass
    return {"vendor": None, "util": None, "mem_used_mb": None, "mem_total_mb": None, "temp": None}

@app.route("/api/stats")
def stats():
    battery = psutil.sensors_battery()
    return jsonify({
        "cpu_percent": psutil.cpu_percent(interval=0.3),
        "ram_percent": psutil.virtual_memory().percent,
        "ram_used_gb": round(psutil.virtual_memory().used / (1024**3), 1),
        "ram_total_gb": round(psutil.virtual_memory().total / (1024**3), 1),
        "cpu_temp": read_temps(),
        "fan_rpm": read_fan_rpm(),
        "battery_percent": battery.percent if battery else None,
        "battery_plugged": battery.power_plugged if battery else None,
        "gpu": read_gpu(),
    })

@app.route("/api/perf-mode/<mode>", methods=["POST"])
def set_perf_mode(mode):
    valid = {"performance": "performance", "balanced": "balanced", "power-saver": "power-saver"}
    if mode not in valid:
        return jsonify({"ok": False, "error": "invalid mode"}), 400
    try:
        subprocess.run(["powerprofilesctl", "set", valid[mode]], check=True)
        return jsonify({"ok": True, "mode": mode})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

@app.route("/api/perf-mode")
def get_perf_mode():
    try:
        out = subprocess.check_output(["powerprofilesctl", "get"], text=True).strip()
        return jsonify({"mode": out})
    except Exception:
        return jsonify({"mode": None})

@app.route("/")
def index():
    return send_from_directory(app.static_folder, "index.html")

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5151)
