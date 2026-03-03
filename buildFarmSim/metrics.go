package main

import (
	"encoding/csv"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

type metricsSnapshot struct {
	Timestamp    time.Time
	RSSBytes     float64
	DBTotalBytes float64
	DBInUseBytes float64
	EventsTotal  float64
	WatcherTotal float64
}

// metricsURLsFromEndpoints derives /metrics URLs from all configured endpoints.
func metricsURLsFromEndpoints(endpoints []string) []string {
	urls := make([]string, len(endpoints))
	for i, ep := range endpoints {
		urls[i] = strings.TrimRight(ep, "/") + "/metrics"
	}
	return urls
}

func startMetricsCollector(cfg *Config, phase *string) {
	interval, err := time.ParseDuration(cfg.MetricsInterval)
	if err != nil {
		log.Fatalf("Invalid metricsInterval %q: %v", cfg.MetricsInterval, err)
	}

	f, err := os.Create(cfg.MetricsOutputFile)
	if err != nil {
		log.Fatalf("Failed to create metrics file %s: %v", cfg.MetricsOutputFile, err)
	}

	w := csv.NewWriter(f)
	w.Write([]string{"timestamp", "rss_bytes", "db_total_bytes", "db_in_use_bytes", "events_total", "watcher_total", "phase"})
	w.Flush()

	metricsURLs := metricsURLsFromEndpoints(cfg.Endpoints)
	log.Printf("Scraping metrics from %d nodes: %v", len(metricsURLs), metricsURLs)

	go func() {
		defer f.Close()
		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		for range ticker.C {
			snap, err := scrapeAllNodes(metricsURLs)
			if err != nil {
				log.Printf("WARNING: metrics scrape failed: %v", err)
				continue
			}

			currentPhase := *phase
			record := []string{
				snap.Timestamp.Format(time.RFC3339),
				fmt.Sprintf("%.0f", snap.RSSBytes),
				fmt.Sprintf("%.0f", snap.DBTotalBytes),
				fmt.Sprintf("%.0f", snap.DBInUseBytes),
				fmt.Sprintf("%.0f", snap.EventsTotal),
				fmt.Sprintf("%.0f", snap.WatcherTotal),
				currentPhase,
			}
			w.Write(record)
			w.Flush()

			rssMiB := snap.RSSBytes / 1024 / 1024
			dbMiB := snap.DBTotalBytes / 1024 / 1024
			dbInUseMiB := snap.DBInUseBytes / 1024 / 1024
			log.Printf("[metrics] phase=%s RSS=%.1fMiB DB=%.1fMiB InUse=%.1fMiB watchers=%.0f events=%.0f watchEventsRx=%d",
				currentPhase, rssMiB, dbMiB, dbInUseMiB, snap.WatcherTotal, snap.EventsTotal, totalWatchEvents.Load())
		}
	}()
}

// scrapeAllNodes scrapes metrics from all nodes and aggregates:
// - RSSBytes: max across nodes
// - DBTotalBytes, DBInUseBytes: max across nodes
// - EventsTotal, WatcherTotal: sum across nodes
func scrapeAllNodes(metricsURLs []string) (*metricsSnapshot, error) {
	agg := &metricsSnapshot{Timestamp: time.Now()}
	scraped := 0

	for _, url := range metricsURLs {
		snap, err := scrapeMetrics(url)
		if err != nil {
			log.Printf("WARNING: failed to scrape %s: %v", url, err)
			continue
		}
		scraped++

		// Take max RSS across nodes
		if snap.RSSBytes > agg.RSSBytes {
			agg.RSSBytes = snap.RSSBytes
		}
		// Take max DB sizes across nodes
		if snap.DBTotalBytes > agg.DBTotalBytes {
			agg.DBTotalBytes = snap.DBTotalBytes
		}
		if snap.DBInUseBytes > agg.DBInUseBytes {
			agg.DBInUseBytes = snap.DBInUseBytes
		}
		// Sum watchers and events across nodes
		agg.EventsTotal += snap.EventsTotal
		agg.WatcherTotal += snap.WatcherTotal
	}

	if scraped == 0 {
		return nil, fmt.Errorf("all %d metrics endpoints failed", len(metricsURLs))
	}
	return agg, nil
}

func scrapeMetrics(metricsURL string) (*metricsSnapshot, error) {
	resp, err := http.Get(metricsURL)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", metricsURL, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading metrics body: %w", err)
	}

	snap := &metricsSnapshot{Timestamp: time.Now()}
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "#") || line == "" {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) < 2 {
			continue
		}
		name := parts[0]
		value := parts[1]

		var val float64
		fmt.Sscanf(value, "%f", &val)

		switch name {
		case "process_resident_memory_bytes":
			snap.RSSBytes = val
		case "etcd_mvcc_db_total_size_in_bytes":
			snap.DBTotalBytes = val
		case "etcd_mvcc_db_total_size_in_use_in_bytes":
			snap.DBInUseBytes = val
		case "etcd_debugging_mvcc_events_total":
			snap.EventsTotal = val
		case "etcd_debugging_mvcc_watcher_total":
			snap.WatcherTotal = val
		}
	}
	return snap, nil
}
