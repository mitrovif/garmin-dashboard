"""Pulls the data the dashboard needs from Garmin Connect.

Only two kinds of calls are made, so a refresh stays quick:
activities (time, distance, pace, VO2 max) and weigh-ins.
"""
from datetime import date, timedelta

import numpy as np
import pandas as pd

RUN_TYPES = {"running", "treadmill_running", "trail_running", "track_running", "street_running"}


def get_client(token: str):
    """Log in with the saved token string (made once with setup_token.py)."""
    from garminconnect import Garmin

    client = Garmin()
    client.login(token)
    return client


def _year_chunks(start: date, end: date):
    cur = start
    while cur <= end:
        nxt = min(cur + timedelta(days=180), end)
        yield cur, nxt
        cur = nxt + timedelta(days=1)


def fetch_activities(client, start: date, end: date) -> pd.DataFrame:
    rows = []
    for a, b in _year_chunks(start, end):
        for act in client.get_activities_by_date(a.isoformat(), b.isoformat()) or []:
            rows.append(
                {
                    "date": pd.to_datetime(act.get("startTimeLocal")).normalize(),
                    "type": (act.get("activityType") or {}).get("typeKey", "other"),
                    "minutes": (act.get("duration") or 0) / 60,
                    "km": (act.get("distance") or 0) / 1000,
                    "vo2max": act.get("vO2MaxValue"),
                }
            )
    df = pd.DataFrame(rows, columns=["date", "type", "minutes", "km", "vo2max"])
    df["is_run"] = df["type"].isin(RUN_TYPES)
    return df


def fetch_weights(client, start: date, end: date) -> pd.DataFrame:
    rows = []
    for a, b in _year_chunks(start, end):
        data = client.get_body_composition(a.isoformat(), b.isoformat()) or {}
        for w in data.get("dateWeightList", []):
            if not w.get("weight"):
                continue
            day = w.get("calendarDate") or pd.to_datetime(w.get("date"), unit="ms")
            rows.append({"date": pd.to_datetime(day).normalize(), "kg": w["weight"] / 1000})
    df = pd.DataFrame(rows, columns=["date", "kg"])
    return df.groupby("date", as_index=False)["kg"].mean() if len(df) else df


def demo_data(start: date, end: date):
    """Realistic fake data so the dashboard can be previewed without a Garmin login."""
    rng = np.random.default_rng(7)
    days = pd.date_range(start, end, freq="D")
    acts = []
    for d in days:
        fit = 1.0 if d.year == 2024 else 0.75
        if rng.random() < 0.65 * fit:
            run = rng.random() < 0.55
            mins = rng.normal(55 if run else 60, 12)
            pace = rng.normal(5.2 if d.year == 2024 else 5.6, 0.25)
            acts.append(
                {
                    "date": d,
                    "type": "running" if run else "strength_training",
                    "minutes": max(mins, 20),
                    "km": max(mins, 20) / pace if run else 0,
                    "vo2max": round(rng.normal(52 if d.year == 2024 else 49, 0.6)) if run else None,
                }
            )
    a = pd.DataFrame(acts)
    a["is_run"] = a["type"].isin(RUN_TYPES)
    trend = np.where(days.year == 2024, 84.5, 89.0) + rng.normal(0, 0.4, len(days))
    w = pd.DataFrame({"date": days, "kg": trend}).iloc[::2]
    return a, w
