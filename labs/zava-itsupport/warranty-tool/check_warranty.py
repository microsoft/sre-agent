"""Warranty Lookup Tool for Zava Café SRE Agent Demo.

A Python tool that checks laptop warranty status and replacement eligibility.
SRE Agent invokes this as a Python tool by calling check_warranty(serial_number).

Standalone usage:
    python check_warranty.py SN-2023-XPS-4471
"""

import json
import sys

import requests

WARRANTY_API_URL = "https://app-zava-warranty.azurewebsites.net"


def check_warranty(serial_number: str) -> dict:
    """Check warranty status by calling the Zava Warranty API."""
    try:
        response = requests.get(
            f"{WARRANTY_API_URL}/warranty/{serial_number}", timeout=10
        )
        return response.json()
    except Exception as e:
        return {"found": False, "error": f"Failed to reach warranty API: {str(e)}"}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python check_warranty.py <serial_number>")
        print("Example: python check_warranty.py SN-2023-XPS-4471")
        sys.exit(1)

    result = check_warranty(sys.argv[1])
    print(json.dumps(result, indent=2))
