import { useState, useEffect } from "react";

const METER_API = import.meta.env.VITE_METER_API_URL || "";

const MOCK_USAGE = [
  { month: "Jul", kwh: 920 },
  { month: "Aug", kwh: 1050 },
  { month: "Sep", kwh: 870 },
  { month: "Oct", kwh: 640 },
  { month: "Nov", kwh: 710 },
  { month: "Dec", kwh: 890 },
  { month: "Jan", kwh: 980 },
];

const MAX_KWH = 1200;

export default function Usage() {
  const [usage, setUsage] = useState(MOCK_USAGE);

  useEffect(() => {
    if (METER_API) {
      fetch(`${METER_API}/usage`)
        .then((r) => r.json())
        .then((data) => setUsage(data.usage || data))
        .catch(() => {});
    }
  }, []);

  return (
    <div className="usage-page">
      <h1>Energy Usage</h1>
      <p className="subtitle">Monthly electricity consumption (kWh)</p>

      <div className="chart">
        {usage.map((d) => (
          <div key={d.month} className="chart-col">
            <div className="chart-value">{d.kwh}</div>
            <div className="chart-bar-track">
              <div
                className="chart-bar-fill"
                style={{ height: `${(d.kwh / MAX_KWH) * 100}%` }}
              />
            </div>
            <div className="chart-label">{d.month}</div>
          </div>
        ))}
      </div>

      <div className="usage-summary">
        <div className="summary-item">
          <span className="summary-label">Average</span>
          <span className="summary-value">
            {Math.round(usage.reduce((s, d) => s + d.kwh, 0) / usage.length)} kWh
          </span>
        </div>
        <div className="summary-item">
          <span className="summary-label">Peak</span>
          <span className="summary-value">
            {Math.max(...usage.map((d) => d.kwh))} kWh
          </span>
        </div>
        <div className="summary-item">
          <span className="summary-label">Current Rate</span>
          <span className="summary-value">$0.128 / kWh</span>
        </div>
      </div>
    </div>
  );
}
