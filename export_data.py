"""Pulls your Garmin data and saves it as CSV files in the data/ folder.

Runs automatically every day via GitHub Actions (.github/workflows/sync.yml),
which commits the updated files back to the repo.
Without GARMIN_TOKEN set it writes sample data, so you can test it.
"""
import os
from datetime import date
from pathlib import Path

import garmin_data as gd

START = date(2024, 1, 1)
OUT = Path("data")


def main():
    today = date.today()
    token = os.environ.get("GARMIN_TOKEN")
    if token:
        client = gd.get_client(token)
        acts = gd.fetch_activities(client, START, today)
        weights = gd.fetch_weights(client, START, today)
        try:
            daily = gd.fetch_daily_calories(client, START, today)
        except Exception as err:  # noqa: BLE001
            print("Daily calories unavailable:", err)
            daily = None
    else:
        print("No GARMIN_TOKEN set, writing sample data.")
        acts, weights = gd.demo_data(START, today)
        daily = None

    OUT.mkdir(exist_ok=True)
    acts = acts.sort_values("date")
    acts.assign(date=acts.date.dt.strftime("%Y-%m-%d"), minutes=acts.minutes.round(1), kcal=acts.kcal.round(),
                km=acts.km.round(2)).to_csv(OUT / "activities.csv", index=False)
    weights.sort_values("date").assign(date=lambda d: d.date.dt.strftime("%Y-%m-%d"),
                                       kg=lambda d: d.kg.round(2)).to_csv(OUT / "weights.csv", index=False)
    if daily is not None and len(daily):
        daily.sort_values("date").assign(date=lambda d: d.date.dt.strftime("%Y-%m-%d")).to_csv(OUT / "daily_calories.csv", index=False)
    if token:
        try:
            import export_health
            export_health.run(client, acts)
        except Exception as err:  # noqa: BLE001
            print("Health data skipped:", err)
    (OUT / "last_updated.txt").write_text(f"{today.isoformat()}\n")
    print(f"Saved {len(acts)} activities and {len(weights)} weigh-ins to data/.")


if __name__ == "__main__":
    main()
