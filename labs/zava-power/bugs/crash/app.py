# Bug: Crash — "Refactored outage enrichment with SCADA cross-reference"
#
# A developer added a new feature to enrich outage data with live SCADA
# readings. The code calls .upper() on the crew_status field and accesses
# nested dict keys without null checks. Works fine in dev where all test
# data is complete, but crashes in production when real SCADA returns
# partial records with None fields.
#
# Root cause: Lines marked with # BUG below
#   - outage.get("scada_ref", {})["reading"] → KeyError on missing key
#   - crew.upper() when crew is None → AttributeError
#
# SRE Agent should find: AttributeError in /outages traceback,
# trace to this file, see the .upper() call on a nullable field.

"""
Zava Power ZeroOps Lab — Outage API Microservice
(v1.4.0 — added SCADA cross-reference enrichment)
"""

import datetime
import logging
import os
import uuid

from flask import Flask, jsonify, request

app = Flask(__name__)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logger = logging.getLogger(__name__)

_ai_connection = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")
if _ai_connection:
    try:
        from opencensus.ext.azure.trace_exporter import AzureExporter
        from opencensus.trace.tracer import Tracer
        _exporter = AzureExporter(connection_string=_ai_connection)
        _tracer = Tracer(exporter=_exporter)
        logger.info("Application Insights telemetry enabled")
    except ImportError:
        logger.warning("opencensus-ext-azure not installed — telemetry disabled")


# ---------------------------------------------------------------------------
# Outage data — note some records have None fields (from SCADA integration)
# ---------------------------------------------------------------------------

OUTAGES = [
    {
        "id": "OUT-1001",
        "region": "Lehigh Valley, PA",
        "affected_customers": 3420,
        "status": "active",
        "reported_at": "2025-01-15T08:23:00Z",
        "estimated_restoration": "2025-01-15T14:00:00Z",
        "cause": "Severe thunderstorm — downed power lines",
        "crew_status": "en_route",
    },
    {
        "id": "OUT-1002",
        "region": "Lancaster, PA",
        "affected_customers": 1875,
        "status": "active",
        "reported_at": "2025-01-15T09:10:00Z",
        "estimated_restoration": "2025-01-15T13:30:00Z",
        "cause": "Transformer failure at substation LAN-04",
        "crew_status": "on_site",
    },
    {
        "id": "OUT-1003",
        "region": "Harrisburg, PA",
        "affected_customers": 920,
        "status": "investigating",
        "reported_at": "2025-01-15T10:45:00Z",
        "estimated_restoration": None,           # Unknown — SCADA data incomplete
        "cause": None,                            # Not yet determined
        "crew_status": None,                      # Not yet dispatched
    },
    {
        "id": "OUT-1004",
        "region": "Louisville, KY",
        "affected_customers": 5100,
        "status": "active",
        "reported_at": "2025-01-15T06:00:00Z",
        "estimated_restoration": "2025-01-15T12:00:00Z",
        "cause": "Ice storm — widespread line damage",
        "crew_status": "on_site",
    },
    {
        "id": "OUT-1005",
        "region": "Providence, RI",
        "affected_customers": 640,
        "status": "restored",
        "reported_at": "2025-01-14T22:30:00Z",
        "estimated_restoration": "2025-01-15T04:00:00Z",
        "cause": "Planned maintenance overrun",
        "crew_status": "completed",
    },
    {
        "id": "OUT-1006",
        "region": "Lehigh Valley, PA",
        "affected_customers": 210,
        "status": "investigating",
        "reported_at": "2025-01-15T11:05:00Z",
        "estimated_restoration": None,           # Unknown
        "cause": None,                            # Under investigation
        "crew_status": None,                      # Pending dispatch
    },
]


def _enrich_outage(outage):
    """Enrich outage with SCADA cross-reference and normalized fields.

    Added in v1.4.0 for the grid operations dashboard integration.
    """
    enriched = dict(outage)

    # Normalize crew status for the dashboard display
    crew = outage["crew_status"]
    enriched["crew_display"] = crew.upper().replace("_", " ")  # BUG: crashes when crew_status is None

    # Add SCADA severity classification based on affected customers
    customers = outage["affected_customers"]
    if customers > 5000:
        enriched["scada_severity"] = "CRITICAL"
    elif customers > 1000:
        enriched["scada_severity"] = "HIGH"
    else:
        enriched["scada_severity"] = "MEDIUM"

    # Format cause for display — capitalize first letter
    cause = outage["cause"]
    enriched["cause_display"] = cause[0].upper() + cause[1:]  # BUG: crashes when cause is None

    return enriched


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.before_request
def log_request():
    logger.info("%s %s from %s", request.method, request.path, request.remote_addr)


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy", "service": "outage-api", "version": "1.4.0"})


@app.route("/outages", methods=["GET"])
def get_outages():
    # v1.4.0: Return enriched outage data with SCADA cross-references
    return jsonify([_enrich_outage(o) for o in OUTAGES])


@app.route("/report", methods=["POST"])
def report_outage():
    body = request.get_json(silent=True)
    if not body or not body.get("address") or not body.get("description"):
        return jsonify({"error": "Both 'address' and 'description' fields are required"}), 400

    ticket_id = f"TKT-{uuid.uuid4().hex[:8].upper()}"
    logger.info("New outage report: %s — %s", ticket_id, body["address"])

    return jsonify({
        "ticket_id": ticket_id,
        "status": "received",
        "address": body["address"],
        "description": body["description"],
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }), 201


MAP_DATA = {
    "type": "FeatureCollection",
    "features": [
        {"type": "Feature", "properties": {"region": "Lehigh Valley, PA", "active_outages": 2}, "geometry": {"type": "Point", "coordinates": [-75.4714, 40.6023]}},
        {"type": "Feature", "properties": {"region": "Lancaster, PA", "active_outages": 1}, "geometry": {"type": "Point", "coordinates": [-76.3055, 40.0379]}},
        {"type": "Feature", "properties": {"region": "Harrisburg, PA", "active_outages": 1}, "geometry": {"type": "Point", "coordinates": [-76.8867, 40.2732]}},
        {"type": "Feature", "properties": {"region": "Louisville, KY", "active_outages": 1}, "geometry": {"type": "Point", "coordinates": [-85.7585, 38.2527]}},
        {"type": "Feature", "properties": {"region": "Providence, RI", "active_outages": 0}, "geometry": {"type": "Point", "coordinates": [-71.4128, 41.8240]}},
    ],
}


@app.route("/map", methods=["GET"])
def outage_map():
    return jsonify(MAP_DATA)


@app.route("/metrics", methods=["GET"])
def metrics():
    total = len(OUTAGES)
    active = sum(1 for o in OUTAGES if o["status"] in ("active", "investigating"))
    customers = sum(o["affected_customers"] for o in OUTAGES)
    return jsonify({
        "total_outages": total,
        "active_outages": active,
        "avg_restoration_minutes": 285,
        "customers_affected": customers,
    })


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    logger.info("Starting outage-api on port %d", port)
    app.run(host="0.0.0.0", port=port, debug=False)
