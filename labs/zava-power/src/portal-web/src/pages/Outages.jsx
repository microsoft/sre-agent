import { useState, useEffect } from "react";

const OUTAGE_API = import.meta.env.VITE_OUTAGE_API_URL || "";

const MOCK_OUTAGES = [
  {
    id: "OUT-001",
    region: "Lehigh Valley",
    affected_customers: 482,
    status: "Crew Dispatched",
    reported_at: "2025-01-15T08:23:00Z",
    cause: "Downed power line — high winds",
  },
  {
    id: "OUT-002",
    region: "Harrisburg",
    affected_customers: 215,
    status: "Under Investigation",
    reported_at: "2025-01-15T09:47:00Z",
    cause: "Transformer failure",
  },
  {
    id: "OUT-003",
    region: "Lancaster",
    affected_customers: 550,
    status: "Crew En Route",
    reported_at: "2025-01-15T10:12:00Z",
    cause: "Vehicle struck utility pole",
  },
  {
    id: "OUT-004",
    region: "Scranton",
    affected_customers: 89,
    status: "Monitoring",
    reported_at: "2025-01-15T11:05:00Z",
    cause: "Scheduled maintenance",
  },
];

function statusBadge(status) {
  const map = {
    "Crew Dispatched": "badge-warning",
    "Under Investigation": "badge-danger",
    "Crew En Route": "badge-warning",
    Monitoring: "badge-info",
    Restored: "badge-success",
  };
  return map[status] || "badge-info";
}

export default function Outages() {
  const [outages, setOutages] = useState(MOCK_OUTAGES);

  useEffect(() => {
    if (OUTAGE_API) {
      fetch(`${OUTAGE_API}/outages`)
        .then((r) => r.json())
        .then((data) => setOutages(data.outages || data))
        .catch(() => {});
    }
  }, []);

  return (
    <div className="outages-page">
      <h1>Current Outages</h1>
      <p className="subtitle">
        Showing {outages.length} active outage{outages.length !== 1 && "s"} across
        the Zava Power service territory
      </p>

      <div className="table-wrap">
        <table className="outage-table">
          <thead>
            <tr>
              <th>ID</th>
              <th>Region</th>
              <th>Affected</th>
              <th>Status</th>
              <th>Reported</th>
              <th>Cause</th>
            </tr>
          </thead>
          <tbody>
            {outages.map((o) => (
              <tr key={o.id}>
                <td className="mono">{o.id}</td>
                <td>{o.region}</td>
                <td className="num">{o.affected_customers.toLocaleString()}</td>
                <td>
                  <span className={`badge ${statusBadge(o.status)}`}>
                    {o.status}
                  </span>
                </td>
                <td>{new Date(o.reported_at).toLocaleString()}</td>
                <td>{o.cause}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
