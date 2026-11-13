#!/usr/bin/env python3
"""Sample an explicitly selected AYUsage process. Run with python3 -I."""
import argparse
import datetime
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("pid", type=int)
parser.add_argument("output", type=pathlib.Path)
parser.add_argument("--seconds", type=int, default=30)
args = parser.parse_args()
command = subprocess.check_output(["ps", "-p", str(args.pid), "-o", "comm="], text=True).strip()
if not command.endswith("/AYUsage"):
    raise SystemExit("The selected process is not AYUsage")
seconds = max(5, min(300, args.seconds))
samples = []
started = time.monotonic()
for index in range(seconds // 5 + 1):
    line = subprocess.check_output(["ps", "-p", str(args.pid), "-o", "rss=,pcpu=,time="], text=True).strip()
    rss, cpu, total = line.split()
    fields = list(map(float, total.split(":")))
    cpu_seconds = sum(value * 60 ** power for power, value in enumerate(reversed(fields)))
    samples.append({"elapsedSeconds": round(time.monotonic() - started, 2), "rssMiB": round(int(rss) / 1024, 2), "psCpuPercent": float(cpu), "totalCpuSeconds": cpu_seconds})
    if index < seconds // 5:
        time.sleep(5)
duration = samples[-1]["elapsedSeconds"] - samples[0]["elapsedSeconds"]
average = (samples[-1]["totalCpuSeconds"] - samples[0]["totalCpuSeconds"]) / duration * 100
result = {"mode": "normal; panel explicitly hidden before sampling", "build": "release arm64", "pid": args.pid, "measuredAt": datetime.datetime.now().astimezone().isoformat(), "durationSeconds": duration, "averageCpuPercentOneCore": round(average, 3), "samples": samples, "limitation": "Short sample including any scheduled refresh; not a long-term leak benchmark. RSS includes shared resident mappings."}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({"rssMiB": [min(s["rssMiB"] for s in samples), max(s["rssMiB"] for s in samples)], "averageCpuPercentOneCore": result["averageCpuPercentOneCore"], "durationSeconds": duration}))
