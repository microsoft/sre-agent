# Bug: Build Failure — "Upgraded Flask to v3 for async support"
#
# A developer upgraded Flask from 2.x to 3.x for async route support
# but didn't update the import paths. Flask 3 removed flask.json.jsonify
# as a top-level import (must use flask.jsonify directly now).
#
# The build succeeds (pip install works) but the app fails to START
# because the import fails at module load time.
#
# This bug causes the pipeline BUILD stage to fail (container won't start
# during docker build health check) or the DEPLOY stage to fail
# (container crashes immediately on startup).

"""
Zava Power ZeroOps Lab — Outage API Microservice
(v2.0.0 — upgraded to Flask 3.x for async support)
"""

import datetime
import logging
import os
import uuid

# BUG: This import worked in Flask 2.x but fails in Flask 3.x
# Flask 3 removed the flask.json module's jsonify re-export
from flask import Flask, request
from flask.json import jsonify  # BUG: ImportError in Flask 3.x — should be: from flask import jsonify

app = Flask(__name__)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

OUTAGES = [
    {"id": "OUT-1001", "region": "Lehigh Valley, PA", "affected_customers": 3420, "status": "active"},
]

@app.route("/health")
def health():
    return jsonify({"status": "healthy", "service": "outage-api", "version": "2.0.0"})

@app.route("/outages")
def get_outages():
    return jsonify(OUTAGES)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
