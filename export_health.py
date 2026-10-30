"""Saves recovery, training-load and progress data from Garmin as JSON in data/health/.

Called by export_data.py during the daily sync. Every call is optional: if Garmin does not
have a metric for your watch, that file is simply skipped.
"""
import json
from datetime import date, timedelta
from pathlib import Path

OUT = Path("data/health")
START = date(2024, 9, 1)  # covers late 2024, your benchmark period


def _save(name, data):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.json").write_text(json.dumps(data, default=str))


def _chunks(start, end, days):
    cur = start
    while cur <= end:
        nxt = min(cur + timedelta(days=days - 1), end)
        yield cur.isoformat(), nxt.isoformat()
        cur = nxt + timedelta(days=1)


def _try(label, fn):
    try:
        out = fn()
        print(f"{label}: ok")
        return out
    except Exception as e:  # noqa: BLE001
        print(f"{label}: skipped ({type(e).__name__}: {e})")
        return None


def run(client, acts=None):
    today = date.today()

    def ranged(method, days=28, start=START):
        rows = []
        for a, b in _chunks(start, today, days):
            r = method(a, b)
            if isinstance(r, list):
                rows += r
            elif r is not None:
                rows.append(r)
        return rows

    for name, method, days in [
        ("resting_hr", client.get_rhr_daily, 90),
        ("sleep", client.get_sleep_daily, 28),
        ("body_battery", client.get_daily_body_battery_stats, 28),
        ("stress", client.get_daily_stress_stats, 28),
        ("hrv", client.get_hrv_data_range, 28),
        ("steps", client.get_daily_steps, 28),
    ]:
        data = _try(name, lambda m=method, d=days: ranged(m, d))
        if data is not None:
            _save(name, data)

    rp = _try("race_predictions", lambda: [client.get_race_predictions(a, b, "monthly") for a, b in _chunks(START, today, 360)])
    if rp is not None:
        _save("race_predictions", rp)
    es = _try("endurance_score", lambda: [client.get_endurance_score(a, b, "weekly") for a, b in _chunks(START, today, 360)])
    if es is not None:
        _save("endurance_score", es)

    # training status: a few benchmark days in late 2024 plus the last 8 weeks
    days = [date(2024, 11, 15), date(2024, 12, 15)] + [today - timedelta(days=7 * k) for k in range(8, -1, -1)]
    ts = _try("training_status", lambda: {d.isoformat(): client.get_daily_training_status(d.isoformat()) for d in days})
    if ts is not None:
        _save("training_status", ts)

    rd = _try("readiness", lambda: {(today - timedelta(days=k)).isoformat(): client.get_morning_training_readiness((today - timedelta(days=k)).isoformat()) for k in range(28)})
    if rd is not None:
        _save("readiness", rd)

    # strength sets logged on the watch, last 60 days
    if acts is not None and "activity_id" in acts.columns:
        recent = acts[(acts.type == "strength_training") & (acts.date >= str(today - timedelta(days=60)))]
        sets = _try("strength_sets", lambda: {str(int(i)): client.get_activity_exercise_sets(int(i)) for i in recent.activity_id.dropna()})
        if sets is not None:
            _save("strength_sets", sets)
