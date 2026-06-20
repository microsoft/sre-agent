// Bug: Config — "Migrated notification gateway to new internal endpoint"
//
// A developer updated the notification gateway URL as part of a network
// migration (INFRA-3291). The new endpoint URL has a typo — port 9443
// instead of 8443. The service starts fine, passes health checks, but
// fails on every actual notification send because the downstream
// connection times out after 10 seconds.
//
// Root cause: Lines marked with // BUG below
//   - gatewayURL uses port 9443 (should be 8443)
//   - /send endpoint tries HTTP POST to gateway → 10s timeout → 500
//   - /health still returns 200 (doesn't check gateway connectivity)
//
// SRE Agent should find: 500 errors on /send with "connection refused"
// or "deadline exceeded" in logs, trace to gatewayURL configuration.

// notification-svc — Zava Power ZeroOps Lab
// (v1.2.0 — migrated gateway endpoint per INFRA-3291)

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

// BUG: Wrong port — should be 8443, not 9443
// This was a typo during the INFRA-3291 network migration.
// The old URL was: http://notification-gateway.internal:8443/api/v2/send
const gatewayURL = "http://notification-gateway.internal:9443/api/v2/send"

type HealthResponse struct {
	Status  string `json:"status"`
	Service string `json:"service"`
	Version string `json:"version"`
}

type Notification struct {
	ID         string `json:"id"`
	Type       string `json:"type"`
	CustomerID string `json:"customer_id"`
	Message    string `json:"message"`
	Channel    string `json:"channel"`
	SentAt     string `json:"sent_at"`
	Status     string `json:"status"`
}

type SendRequest struct {
	Type       string `json:"type"`
	CustomerID string `json:"customer_id"`
	Message    string `json:"message"`
}

type SendResponse struct {
	Success        bool   `json:"success"`
	NotificationID string `json:"notification_id"`
	Message        string `json:"message"`
	Timestamp      string `json:"timestamp"`
}

type ErrorResponse struct {
	Error   string `json:"error"`
	Details string `json:"details,omitempty"`
}

func logJSON(level, msg string, fields map[string]string) {
	entry := map[string]string{
		"timestamp": time.Now().UTC().Format(time.RFC3339),
		"level":     level,
		"service":   "notification-svc",
		"message":   msg,
	}
	for k, v := range fields {
		entry[k] = v
	}
	data, _ := json.Marshal(entry)
	fmt.Fprintln(os.Stdout, string(data))
}

func sampleNotifications() []Notification {
	return []Notification{
		{ID: "NOTIF-1001", Type: "outage_alert", CustomerID: "CUST-5001", Message: "Power outage reported in your area (Sector 12). Estimated restoration: 2 hours.", Channel: "sms", SentAt: "2025-01-15T08:30:00Z", Status: "delivered"},
		{ID: "NOTIF-1002", Type: "restoration_update", CustomerID: "CUST-5001", Message: "Power has been restored in Sector 12. Thank you for your patience.", Channel: "sms", SentAt: "2025-01-15T10:45:00Z", Status: "delivered"},
		{ID: "NOTIF-1003", Type: "billing_reminder", CustomerID: "CUST-5002", Message: "Your electricity bill of $142.50 is due on 2025-01-20.", Channel: "email", SentAt: "2025-01-14T09:00:00Z", Status: "delivered"},
		{ID: "NOTIF-1004", Type: "high_usage_warning", CustomerID: "CUST-5003", Message: "Your energy usage this month is 40% higher than average.", Channel: "push", SentAt: "2025-01-15T12:00:00Z", Status: "delivered"},
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	logJSON("info", "health check", map[string]string{"method": r.Method, "path": r.URL.Path})
	w.Header().Set("Content-Type", "application/json")
	// BUG: Health check passes even though gateway is unreachable.
	// A proper health check would verify downstream connectivity.
	json.NewEncoder(w).Encode(HealthResponse{
		Status:  "healthy",
		Service: "notification-svc",
		Version: "1.2.0",
	})
}

func notificationsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "method not allowed"})
		return
	}
	logJSON("info", "listing notifications", map[string]string{"method": r.Method})
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(sampleNotifications())
}

func sendHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "method not allowed"})
		return
	}

	var req SendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "invalid request body", Details: err.Error()})
		return
	}

	if req.Type == "" || req.CustomerID == "" || req.Message == "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "type, customer_id, and message are required"})
		return
	}

	// v1.2.0: Forward to the notification gateway (INFRA-3291)
	logJSON("info", "forwarding notification to gateway", map[string]string{
		"gateway": gatewayURL,
		"type":    req.Type,
	})

	payload, _ := json.Marshal(req)
	client := &http.Client{Timeout: 10 * time.Second}  // BUG: 10s timeout before failing
	resp, err := client.Post(gatewayURL, "application/json", bytes.NewReader(payload))
	if err != nil {
		// BUG: This fires on every /send request because port 9443 is wrong
		logJSON("error", "gateway request failed", map[string]string{
			"error":   err.Error(),
			"gateway": gatewayURL,
		})
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		json.NewEncoder(w).Encode(ErrorResponse{
			Error:   "notification gateway unavailable",
			Details: fmt.Sprintf("Failed to reach %s: %s", gatewayURL, err.Error()),
		})
		return
	}
	defer resp.Body.Close()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(SendResponse{
		Success:        true,
		NotificationID: fmt.Sprintf("NOTIF-%d", time.Now().UnixNano()%100000),
		Message:        "Notification delivered via gateway",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	})
}

func main() {
	if os.Getenv("REQUIRED_CONFIG") == "" {
		logJSON("fatal", "REQUIRED_CONFIG not set — cannot connect to notification gateway", nil)
		log.Fatal("FATAL: REQUIRED_CONFIG not set")
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/notifications", notificationsHandler)
	mux.HandleFunc("/send", sendHandler)

	logJSON("info", "notification-svc starting", map[string]string{
		"port":        port,
		"gateway_url": gatewayURL,
		"version":     "1.2.0",
	})

	addr := fmt.Sprintf(":%s", port)
	if err := http.ListenAndServe(addr, mux); err != nil {
		logJSON("fatal", "server failed to start", map[string]string{"error": err.Error()})
		os.Exit(1)
	}
}
