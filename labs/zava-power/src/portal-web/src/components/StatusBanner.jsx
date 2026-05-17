import { useState, useEffect, useRef } from "react";

const OUTAGE_API = import.meta.env.VITE_OUTAGE_API_URL || "";
const GRID_API = import.meta.env.VITE_GRID_API_URL || "";

export default function StatusBanner() {
  const [healthy, setHealthy] = useState(true);
  const [detail, setDetail] = useState("");
  const intervalRef = useRef(null);

  useEffect(() => {
    async function checkHealth() {
      if (!OUTAGE_API && !GRID_API) {
        setHealthy(true);
        setDetail("Demo mode — no backends configured");
        return;
      }

      const checks = [];

      if (OUTAGE_API) {
        checks.push(
          fetch(`${OUTAGE_API}/health`, { signal: AbortSignal.timeout(3000) })
            .then((r) => (r.ok ? null : "Outage API unhealthy"))
            .catch(() => "Outage API unreachable")
        );
      }

      if (GRID_API) {
        checks.push(
          fetch(`${GRID_API}/health`, { signal: AbortSignal.timeout(3000) })
            .then((r) => (r.ok ? null : "Grid Status API unhealthy"))
            .catch(() => "Grid Status API unreachable")
        );
      }

      const results = await Promise.all(checks);
      const failures = results.filter(Boolean);

      if (failures.length > 0) {
        setHealthy(false);
        setDetail(failures.join(", "));
      } else {
        setHealthy(true);
        setDetail("");
      }
    }

    checkHealth();
    intervalRef.current = setInterval(checkHealth, 5000);
    return () => clearInterval(intervalRef.current);
  }, []);

  return (
    <div className={`status-banner ${healthy ? "status-ok" : "status-error"}`}>
      {healthy ? (
        <span>✅ All Systems Operational</span>
      ) : (
        <span>🔴 Service Degradation Detected — {detail}</span>
      )}
    </div>
  );
}
