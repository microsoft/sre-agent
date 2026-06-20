import { useState, useEffect } from "react";
import StatusBanner from "../components/StatusBanner";

const OUTAGE_API = import.meta.env.VITE_OUTAGE_API_URL || "";
const GRID_API = import.meta.env.VITE_GRID_API_URL || "";

const MOCK_METRICS = {
  active_outages: 3,
  customers_affected: 1247,
  avg_restoration_minutes: 48,
};

const MOCK_REGIONS = [
  { name: "Lehigh Valley", load_pct: 72 },
  { name: "Harrisburg", load_pct: 65 },
  { name: "Lancaster", load_pct: 81 },
  { name: "Scranton", load_pct: 58 },
];

export default function Dashboard() {
  const [metrics, setMetrics] = useState(MOCK_METRICS);
  const [regions, setRegions] = useState(MOCK_REGIONS);

  useEffect(() => {
    if (OUTAGE_API) {
      fetch(`${OUTAGE_API}/metrics`)
        .then((r) => r.json())
        .then(setMetrics)
        .catch(() => {});
    }
    if (GRID_API) {
      fetch(`${GRID_API}/regions`)
        .then((r) => r.json())
        .then((data) => setRegions(data.regions || data))
        .catch(() => {});
    }
  }, []);

  const avgLoad =
    regions.length > 0
      ? Math.round(regions.reduce((s, r) => s + r.load_pct, 0) / regions.length)
      : 0;

  return (
    <div className="dashboard">
      <StatusBanner />

      <h1>System Dashboard</h1>

      <div className="cards">
        <div className="card card-warning">
          <div className="card-value">{metrics.active_outages}</div>
          <div className="card-label">Active Outages</div>
        </div>
        <div className="card card-danger">
          <div className="card-value">
            {metrics.customers_affected.toLocaleString()}
          </div>
          <div className="card-label">Customers Affected</div>
        </div>
        <div className="card card-info">
          <div className="card-value">{metrics.avg_restoration_minutes} min</div>
          <div className="card-label">Avg Restoration Time</div>
        </div>
        <div className="card card-success">
          <div className="card-value">{avgLoad}%</div>
          <div className="card-label">Grid Load</div>
        </div>
      </div>

      <h2>Regional Grid Load</h2>
      <div className="region-grid">
        {regions.map((r) => (
          <div key={r.name} className="region-card">
            <div className="region-name">{r.name}</div>
            <div className="region-bar-track">
              <div
                className={`region-bar-fill ${
                  r.load_pct > 80 ? "bar-high" : r.load_pct > 60 ? "bar-med" : "bar-low"
                }`}
                style={{ width: `${r.load_pct}%` }}
              />
            </div>
            <div className="region-pct">{r.load_pct}%</div>
          </div>
        ))}
      </div>
    </div>
  );
}
