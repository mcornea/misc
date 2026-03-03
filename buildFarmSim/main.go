package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	cfgPath := flag.String("f", "config.json", "path to config file")
	plotFlag := flag.String("plot", "", "CSV file(s) to plot (comma-separated), e.g. metrics-v35.csv,metrics-v36.csv")
	legendFlag := flag.String("legend", "", "legend names (comma-separated), e.g. v3.5,v3.6")
	outFlag := flag.String("o", "comparison.html", "output HTML file for plot mode")
	flag.Parse()

	// Plot mode: generate charts from existing CSV files and exit
	if *plotFlag != "" {
		csvFiles := parsePlotArgs(*plotFlag)
		legends := parseLegendArgs(*legendFlag, len(csvFiles))
		if len(legends) != len(csvFiles) {
			log.Fatalf("Number of legends (%d) doesn't match number of CSV files (%d)", len(legends), len(csvFiles))
		}
		if err := generateCharts(csvFiles, legends, *outFlag); err != nil {
			log.Fatalf("Failed to generate charts: %v", err)
		}
		return
	}

	// Workload mode
	startTime := time.Now()
	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	log.Printf("Workload: %d namespaces x %d jobs/ns = %d total jobs", cfg.NumNamespaces, cfg.JobsPerNS, cfg.TotalJobs())
	log.Printf("Namespace objects: %d secrets/ns (%d KiB) + %d configmaps/ns (%d KiB)",
		cfg.SecretsPerNS, cfg.SecretSizeKB, cfg.ConfigMapsPerNS, cfg.ConfigMapSizeKB)
	log.Printf("Job lifecycle: %d KiB pod, %d KiB event, %d metadata iterations (delay %s)",
		cfg.PodSizeKB, cfg.EventSizeKB, cfg.MetadataIterations, cfg.MetadataDelay)

	// Managed mode: start local etcd cluster
	if cfg.EtcdBinPath != "" {
		log.Printf("Managed mode: starting %d-member etcd cluster from %s", cfg.ClusterSize, cfg.EtcdBinPath)
		if err := startCluster(cfg); err != nil {
			log.Fatalf("Failed to start etcd cluster: %v", err)
		}
	} else {
		log.Printf("Connect mode: connecting to existing etcd at %v", cfg.Endpoints)
	}

	// Phase tracking for metrics
	phase := "init"

	// Start metrics collector
	startMetricsCollector(cfg, &phase)

	// Parse watcher start delay
	var watchStartDelay time.Duration
	if cfg.WatchStartDelay != "" {
		watchStartDelay, err = time.ParseDuration(cfg.WatchStartDelay)
		if err != nil {
			log.Fatalf("Invalid watchStartDelay %q: %v", cfg.WatchStartDelay, err)
		}
	}

	// Start watchers (Go client) — may be delayed by WatchStartDelay
	client, err := startWatchers(cfg, watchStartDelay)
	if err != nil {
		log.Fatalf("Failed to start watchers: %v", err)
	}
	defer client.Close()

	// Create namespace objects (secrets + configmaps) — static, large, never churned
	createNamespaceObjects(client, cfg, &phase)

	// Run job lifecycles (13 PUTs per job)
	runJobLifecycles(client, cfg, &phase)

	// Hold — keep running until duration expires or Ctrl+C
	phase = "idle"
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	if cfg.RunDuration != "" {
		runDuration, err := time.ParseDuration(cfg.RunDuration)
		if err != nil {
			log.Fatalf("Invalid runDuration %q: %v", cfg.RunDuration, err)
		}
		log.Printf("Workload complete. Running for %s total (Ctrl+C to exit early)...", cfg.RunDuration)
		timer := time.NewTimer(time.Until(startTime.Add(runDuration)))
		defer timer.Stop()
		select {
		case <-timer.C:
			log.Println("Run duration reached.")
		case <-sigCh:
		}
	} else {
		log.Println("Workload complete. Holding (Ctrl+C to exit)...")
		<-sigCh
	}

	log.Println("Shutting down...")
	if cfg.EtcdBinPath != "" {
		stopCluster()
	}
	fmt.Println("Done.")
}
