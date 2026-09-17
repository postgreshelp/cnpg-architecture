#!/usr/bin/env python3
"""
conn_monitor.py — replacement for TARS's custom Go connection-monitor utility (§8 of the source
doc). Runs on a schedule (see manifests/monitoring/conn-monitor-cronjob.yaml, every 10 minutes
to match TARS), and:
  1. Samples/logs active connection counts per database.
  2. Alerts (log line + optional email) once sustained connections exceed ALERT_THRESHOLD_PCT
     of max_connections (TARS itself uses 68%, i.e. 170/250; this POC's defaults below reflect
     its reduced max_connections=50 instead — see manifests/cluster/cluster-primary.yaml).
  3. Terminates sessions idle for more than IDLE_MINUTES (TARS: 5 minutes).

Auth is via a K8s Secret mounted as env vars (mirrors TARS's tars-monitor-db secret pattern —
see manifests/monitoring/conn-monitor-secret.yaml.template). The env vars set in
manifests/monitoring/conn-monitor-cronjob.yaml always override these fallback defaults; the
defaults below only matter if this script is run standalone without that CronJob's env.
"""
import os
import sys
import smtplib
from email.mime.text import MIMEText

import psycopg2

PGHOST = os.environ.get("PGHOST", "tarsdb-primary-rw.tars-db.svc.cluster.local.")
PGPORT = os.environ.get("PGPORT", "5432")
PGUSER = os.environ.get("PGUSER", "postgres")
PGPASSWORD = os.environ.get("PGPASSWORD", "")
PGDATABASE = os.environ.get("PGDATABASE", "postgres")

MAX_CONNECTIONS = int(os.environ.get("MAX_CONNECTIONS", "50"))       # matches cluster-primary.yaml's max_connections
ALERT_THRESHOLD_PCT = float(os.environ.get("ALERT_THRESHOLD_PCT", "0.68"))  # matches TARS's 68% ratio
IDLE_MINUTES = int(os.environ.get("IDLE_MINUTES", "5"))
WATCH_DATABASES = os.environ.get("WATCH_DATABASES", "tars").split(",")     # matches cluster-primary.yaml's bootstrap database

ALERT_EMAIL_TO = os.environ.get("ALERT_EMAIL_TO", "")
SMTP_HOST = os.environ.get("SMTP_HOST", "")


def connect():
    return psycopg2.connect(
        host=PGHOST, port=PGPORT, user=PGUSER, password=PGPASSWORD, dbname=PGDATABASE,
        connect_timeout=10,
    )


def sample_and_log(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            select datname, count(*)
            from pg_stat_activity
            where datname = any(%s)
            group by datname
            """,
            (WATCH_DATABASES,),
        )
        for datname, count in cur.fetchall():
            print(f"[conn_monitor] db={datname} active_connections={count}")

        cur.execute("select count(*) from pg_stat_activity")
        total = cur.fetchone()[0]
        print(f"[conn_monitor] total_connections={total} max_connections={MAX_CONNECTIONS}")
        return total


def check_threshold(total):
    threshold = int(MAX_CONNECTIONS * ALERT_THRESHOLD_PCT)
    if total >= threshold:
        msg = (
            f"ALERT: sustained connection count {total} >= threshold {threshold} "
            f"({ALERT_THRESHOLD_PCT*100:.0f}% of max_connections={MAX_CONNECTIONS})"
        )
        print(f"[conn_monitor] {msg}")
        send_alert(msg)


def send_alert(body):
    if not (ALERT_EMAIL_TO and SMTP_HOST):
        print("[conn_monitor] ALERT_EMAIL_TO / SMTP_HOST not configured — logging only.")
        return
    try:
        msg = MIMEText(body)
        msg["Subject"] = "[TARS PostgreSQL] Connection threshold alert"
        msg["From"] = "conn-monitor@tars"
        msg["To"] = ALERT_EMAIL_TO
        with smtplib.SMTP(SMTP_HOST) as s:
            s.send_message(msg)
    except Exception as e:  # pragma: no cover — best-effort alerting, never crash the reaper
        print(f"[conn_monitor] failed to send alert email: {e}", file=sys.stderr)


def reap_idle_sessions(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            select pid, usename, datname, state,
                   now() - state_change as idle_for
            from pg_stat_activity
            where state = 'idle'
              and now() - state_change > interval %s
              and pid <> pg_backend_pid()
            """,
            (f"{IDLE_MINUTES} minutes",),
        )
        rows = cur.fetchall()
        for pid, usename, datname, state, idle_for in rows:
            print(f"[conn_monitor] terminating idle pid={pid} user={usename} db={datname} idle_for={idle_for}")
            cur.execute("select pg_terminate_backend(%s)", (pid,))
        conn.commit()
        print(f"[conn_monitor] idle-reaper terminated {len(rows)} session(s) (> {IDLE_MINUTES}m idle)")


def main():
    conn = connect()
    try:
        total = sample_and_log(conn)
        check_threshold(total)
        reap_idle_sessions(conn)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
