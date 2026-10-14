"""Prints the TAPO_HASH for lights.json: sha256(sha1(email) + sha1(password)).

The bulbs authenticate against this hash, so the app never holds the Tapo
account password itself.
"""
import getpass
import hashlib

email = input("Tapo account email: ").strip()
password = getpass.getpass("Tapo account password: ")
print(hashlib.sha256(
    hashlib.sha1(email.encode()).digest()
    + hashlib.sha1(password.encode()).digest()
).hexdigest())
