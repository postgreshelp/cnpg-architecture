#!/usr/bin/env python3
"""
fake_inserts.py — loads 1,000 authors + 100,000 books via Faker, same as the original assignment
script, retargeted at the CNPG primary service (via kubectl port-forward, see
scripts/09-load-test-data.sh) instead of the old Helm-chart primary.
"""
import os
import psycopg2
from faker import Faker

fake = Faker()
conn = psycopg2.connect(
    host="localhost",   # port-forwarded to tarsdb-primary-rw
    port=os.environ.get("TARS_PGPORT", "5432"),
    database="tars",
    user="tars_admin",
    password=os.environ["TARS_PGPASSWORD"],   # set by scripts/09-load-test-data.sh from the
                                               # live tarsdb-app-user Secret — never hardcoded
)
cursor = conn.cursor()

num_authors = 1000
num_books = 100000
batch_size = 5000

print("Inserting authors...")
author_ids = []
for i in range(num_authors):
    cursor.execute("INSERT INTO authors (name) VALUES (%s) RETURNING author_id", (fake.name(),))
    author_ids.append(cursor.fetchone()[0])
    if (i + 1) % batch_size == 0:
        conn.commit()
        print(f"{i + 1} authors inserted...")
conn.commit()
print(f"Total authors inserted: {num_authors}")

print("Inserting books...")
for i in range(num_books):
    random_author_id = fake.random.choice(author_ids)
    cursor.execute(
        "INSERT INTO books (title, author_id) VALUES (%s, %s)",
        (fake.sentence(), random_author_id),
    )
    if (i + 1) % batch_size == 0:
        conn.commit()
        print(f"{i + 1} books inserted...")
conn.commit()
print(f"Total books inserted: {num_books}")

cursor.close()
conn.close()
print("Data insertion completed.")
