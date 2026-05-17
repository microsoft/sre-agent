"""
Zava Power ZeroOps Lab — Outage API Microservice

Simulates Zava Power Electric' outage reporting system for the ZeroOps
observability lab. Provides endpoints for querying active outages, submitting
new outage reports, viewing outage map data, and retrieving operational metrics.

This service is designed to be deployed as a container in Azure Container Apps
and monitored via Application Insights, Grafana, and Azure Monitor as part of
the Zava Power ZeroOps self-healing infrastructure demo.
"""

import datetime
import logging
import os
import uuid

from flask import Flask, jsonify, request

# ---------------------------------------------------------------------------
# Application setup
# ---------------------------------------------------------------------------

app = Flask(__name__)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logger = logging.getLogger(__name__)

# Application Insights via OpenTelemetry
_ai_connection = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")
if _ai_connection:
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor
        configure_azure_monitor(connection_string=_ai_connection)
        logger.info("Application Insights telemetry enabled (OpenTelemetry)")
    except ImportError:
        logger.warning("azure-monitor-opentelemetry not installed — telemetry disabled")

# ---------------------------------------------------------------------------
# Sample outage data
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
        "estimated_restoration": "2025-01-15T16:00:00Z",
        "cause": "Vehicle struck utility pole",
        "crew_status": "dispatched",
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
        "estimated_restoration": "2025-01-15T15:00:00Z",
        "cause": "Underground cable fault",
        "crew_status": "dispatched",
    },
]

# ---------------------------------------------------------------------------
# GeoJSON-style map data (simplified centroids for each region)
# ---------------------------------------------------------------------------

MAP_DATA = {
    "type": "FeatureCollection",
    "features": [
        {
            "type": "Feature",
            "properties": {"region": "Lehigh Valley, PA", "active_outages": 2},
            "geometry": {"type": "Point", "coordinates": [-75.4714, 40.6023]},
        },
        {
            "type": "Feature",
            "properties": {"region": "Lancaster, PA", "active_outages": 1},
            "geometry": {"type": "Point", "coordinates": [-76.3055, 40.0379]},
        },
        {
            "type": "Feature",
            "properties": {"region": "Harrisburg, PA", "active_outages": 1},
            "geometry": {"type": "Point", "coordinates": [-76.8844, 40.2732]},
        },
        {
            "type": "Feature",
            "properties": {"region": "Louisville, KY", "active_outages": 1},
            "geometry": {"type": "Point", "coordinates": [-85.7585, 38.2527]},
        },
        {
            "type": "Feature",
            "properties": {"region": "Providence, RI", "active_outages": 0},
            "geometry": {"type": "Point", "coordinates": [-71.4128, 41.8240]},
        },
    ],
}

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.before_request
def log_request():
    logger.info("%s %s from %s", request.method, request.path, request.remote_addr)


@app.route("/health", methods=["GET"])
def health():
    if os.getenv("FORCE_ERROR", "").lower() == "true":
        return (
            jsonify({"status": "unhealthy", "error": "Service forcefully degraded"}),
            503,
        )
    return jsonify({"status": "healthy", "service": "outage-api", "version": "1.0.0"})


@app.route("/outages", methods=["GET"])
def get_outages():
    return jsonify(OUTAGES)


@app.route("/report", methods=["POST"])
def report_outage():
    body = request.get_json(silent=True)
    if not body or not body.get("address") or not body.get("description"):
        return (
            jsonify({"error": "Both 'address' and 'description' fields are required"}),
            400,
        )

    ticket_id = f"TKT-{uuid.uuid4().hex[:8].upper()}"
    logger.info("New outage report: %s — %s", ticket_id, body["address"])

    return (
        jsonify(
            {
                "ticket_id": ticket_id,
                "status": "received",
                "address": body["address"],
                "description": body["description"],
                "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            }
        ),
        201,
    )


@app.route("/map", methods=["GET"])
def outage_map():
    return jsonify(MAP_DATA)


@app.route("/metrics", methods=["GET"])
def metrics():
    total = len(OUTAGES)
    active = sum(1 for o in OUTAGES if o["status"] in ("active", "investigating"))
    customers = sum(o["affected_customers"] for o in OUTAGES)
    avg_restoration_minutes = 285  # simulated average

    return jsonify(
        {
            "total_outages": total,
            "active_outages": active,
            "avg_restoration_minutes": avg_restoration_minutes,
            "customers_affected": customers,
        }
    )


# ---------------------------------------------------------------------------
# Entrypoint (development server)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    logger.info("Starting outage-api on port %d", port)
    app.run(host="0.0.0.0", port=port)
