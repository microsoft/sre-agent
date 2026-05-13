// notification-svc: Simulates Zava Power's customer notification system.
// Handles outage alerts, billing reminders, meter warnings, and restoration updates.
//
// *** SCENARIO 4 — CrashLoopBackOff Simulation ***
// On startup this service REQUIRES the REQUIRED_CONFIG environment variable.
// If REQUIRED_CONFIG is NOT set the process logs a fatal error and exits
// immediately (os.Exit(1)). When deployed to Kubernetes without that env var
// the container will restart repeatedly, producing a CrashLoopBackOff status
// that participants must diagnose and fix.

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

// ---------- domain types ----------

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

// ---------- structured logger ----------

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

// ---------- sample data ----------

func sampleNotifications() []Notification {
	return []Notification{
		{
			ID:         "NOTIF-1001",
			Type:       "outage_alert",
			CustomerID: "CUST-5001",
			Message:    "Power outage reported in your area (Sector 12). Estimated restoration: 2 hours.",
			Channel:    "sms",
			SentAt:     "2025-01-15T08:30:00Z",
			Status:     "delivered",
		},
		{
			ID:         "NOTIF-1002",
			Type:       "restoration_update",
			CustomerID: "CUST-5001",
			Message:    "Power has been restored in Sector 12. Thank you for your patience.",
			Channel:    "sms",
			SentAt:     "2025-01-15T10:45:00Z",
			Status:     "delivered",
		},
		{
			ID:         "NOTIF-1003",
			Type:       "billing_reminder",
			CustomerID: "CUST-5002",
			Message:    "Your electricity bill of $142.50 is due on 2025-01-20. Pay online to avoid late fees.",
			Channel:    "email",
			SentAt:     "2025-01-14T09:00:00Z",
			Status:     "delivered",
		},
		{
			ID:         "NOTIF-1004",
			Type:       "high_usage_warning",
			CustomerID: "CUST-5003",
			Message:    "Your energy usage this month is 40% higher than your 12-month average. Consider reviewing your consumption.",
			Channel:    "push",
			SentAt:     "2025-01-15T12:00:00Z",
			Status:     "delivered",
		},
		{
			ID:         "NOTIF-1005",
			Type:       "meter_tamper_alert",
			CustomerID: "CUST-5004",
			Message:    "Possible meter tampering detected at service address 742 Evergreen Terrace. A field technician has been dispatched.",
			Channel:    "email",
			SentAt:     "2025-01-15T14:22:00Z",
			Status:     "pending",
		},
	}
}

// ---------- handlers ----------

func healthHandler(w http.ResponseWriter, r *http.Request) {
	logJSON("info", "health check", map[string]string{"method": r.Method, "path": r.URL.Path})

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(HealthResponse{
		Status:  "healthy",
		Service: "notification-svc",
		Version: "1.0.0",
	})
}

func notificationsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(ErrorResponse{Error: "method not allowed"})
		return
	}

	logJSON("info", "listing notifications", map[string]string{"method": r.Method, "path": r.URL.Path})

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

	logJSON("info", "notification sent", map[string]string{
		"type":        req.Type,
		"customer_id": req.CustomerID,
	})

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(SendResponse{
		Success:        true,
		NotificationID: fmt.Sprintf("NOTIF-%d", time.Now().UnixNano()%100000),
		Message:        "Notification queued for delivery",
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	})
}

// ---------- main ----------

func main() {
	// ---------------------------------------------------------------
	// SCENARIO 4 — CrashLoopBackOff trigger
	// If REQUIRED_CONFIG is missing the service cannot connect to the
	// notification gateway and must refuse to start. In Kubernetes this
	// causes repeated restarts → CrashLoopBackOff.
	// FIX: set the REQUIRED_CONFIG env var in the Deployment manifest.
	// ---------------------------------------------------------------
	if os.Getenv("REQUIRED_CONFIG") == "" {
		logJSON("fatal", "REQUIRED_CONFIG not set — cannot connect to notification gateway", nil)
		// log.Fatal prints to stderr and calls os.Exit(1)
		log.Fatal("FATAL: REQUIRED_CONFIG not set — cannot connect to notification gateway")
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
		"port":            port,
		"required_config": os.Getenv("REQUIRED_CONFIG"),
	})

	addr := fmt.Sprintf(":%s", port)
	if err := http.ListenAndServe(addr, mux); err != nil {
		logJSON("fatal", "server failed to start", map[string]string{"error": err.Error()})
		os.Exit(1)
	}
}
