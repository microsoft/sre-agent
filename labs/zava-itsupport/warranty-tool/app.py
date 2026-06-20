"""Zava Warranty Lookup Service — FastAPI application.

Serves warranty status data for the Zava Café SRE Agent demo.
"""

from datetime import date

from fastapi import FastAPI, HTTPException

app = FastAPI(title="Zava Warranty Lookup Service", version="1.0.0")

# Mock warranty database
WARRANTY_DB: dict[str, dict] = {
    "SN-2023-XPS-4471": {
        "device_model": "Dell XPS 15 9530",
        "purchase_date": "2023-03-15",
        "warranty_expiry": "2026-03-15",
        "warranty_years": 3,
        "recommended_replacement": "Dell XPS 15 9540 or equivalent",
    },
    "SN-2024-MBP-8832": {
        "device_model": 'MacBook Pro 16" M3',
        "purchase_date": "2024-06-20",
        "warranty_expiry": "2027-06-20",
        "warranty_years": 3,
        "recommended_replacement": 'MacBook Pro 16" M4 or equivalent',
    },
    "SN-2022-TPX-1199": {
        "device_model": "Lenovo ThinkPad X1 Carbon Gen 10",
        "purchase_date": "2022-01-10",
        "warranty_expiry": "2025-01-10",
        "warranty_years": 3,
        "recommended_replacement": "Lenovo ThinkPad X1 Carbon Gen 12 or equivalent",
    },
    "SN-2024-HPE-5567": {
        "device_model": "HP EliteBook 860 G10",
        "purchase_date": "2024-09-01",
        "warranty_expiry": "2027-09-01",
        "warranty_years": 3,
        "recommended_replacement": "HP EliteBook 860 G11 or equivalent",
    },
    "SN-2021-DEL-3344": {
        "device_model": "Dell Latitude 5520",
        "purchase_date": "2021-11-30",
        "warranty_expiry": "2024-11-30",
        "warranty_years": 3,
        "recommended_replacement": "Dell Latitude 5550 or equivalent",
    },
}


def _lookup(serial_number: str) -> dict:
    """Build a warranty result dict for a given serial number."""
    device = WARRANTY_DB.get(serial_number)
    if device is None:
        return None

    today = date.today()
    expiry = date.fromisoformat(device["warranty_expiry"])

    is_expired = today > expiry
    delta = (today - expiry).days if is_expired else 0
    warranty_years = device["warranty_years"]

    return {
        "found": True,
        "serial_number": serial_number,
        "device_model": device["device_model"],
        "purchase_date": device["purchase_date"],
        "warranty_expiry": device["warranty_expiry"],
        "warranty_status": "Expired" if is_expired else "Active",
        "days_since_expiry": delta if is_expired else None,
        "days_until_expiry": (expiry - today).days if not is_expired else None,
        "eligible_for_replacement": is_expired,
        "replacement_reason": (
            f"Standard warranty period ({warranty_years} years) has expired"
            if is_expired
            else f"Device is still under warranty until {device['warranty_expiry']}"
        ),
        "recommended_replacement": (
            device["recommended_replacement"] if is_expired else None
        ),
    }


@app.get("/")
def root():
    return {"service": "Zava Warranty Lookup Service", "version": "1.0.0"}


@app.get("/health")
def health():
    return {"status": "healthy"}


@app.get("/warranty/{serial_number}")
def warranty_lookup(serial_number: str):
    result = _lookup(serial_number)
    if result is None:
        raise HTTPException(
            status_code=404,
            detail={"found": False, "error": "Device not found in warranty database"},
        )
    return result


@app.get("/devices")
def list_devices():
    devices = []
    for serial, info in WARRANTY_DB.items():
        devices.append(
            {
                "serial_number": serial,
                "device_model": info["device_model"],
                "purchase_date": info["purchase_date"],
                "warranty_expiry": info["warranty_expiry"],
            }
        )
    return {"devices": devices, "count": len(devices)}
