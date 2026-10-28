"""Run this ONCE on your laptop. It logs in to Garmin (including the MFA code if you use one)
and prints a token. Paste that token into the dashboard's secrets as GARMIN_TOKEN.
Your password is never stored anywhere. Rerun only if the dashboard says the login expired.
"""
from getpass import getpass

from garminconnect import Garmin

email = input("Garmin email: ").strip()
password = getpass("Garmin password: ")
client = Garmin(email=email, password=password, prompt_mfa=lambda: input("MFA code: ").strip())
client.login()
token = client.garth.dumps()
with open("garmin_token.txt", "w") as f:
    f.write(token)
print("\nDone. Your token is saved in garmin_token.txt (keep it private, don't upload it to GitHub).")
