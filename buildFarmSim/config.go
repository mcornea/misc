package main

import (
	"encoding/json"
	"fmt"
	"os"
)

type Config struct {
	// Cluster management (optional — if empty, connect to existing)
	EtcdBinPath   string   `json:"etcdBinPath"`           // path to etcd binary dir (empty = connect mode)
	ClusterSize   int      `json:"clusterSize"`           // default: 1
	SnapshotCount int      `json:"snapshotCount"`         // default: 10000

	// Connection
	Endpoints []string `json:"endpoints"` // default: ["http://127.0.0.1:2379"]

	// Namespace structure
	NumNamespaces int `json:"numNamespaces"`      // default: 100
	JobsPerNS     int `json:"jobsPerNamespace"`   // default: 100

	// Workload sizing (job objects)
	JobSizeKB int `json:"jobSizeKB"` // default: 21

	// Namespace background objects
	SecretsPerNS    int `json:"secretsPerNamespace"`    // default: 150
	ConfigMapsPerNS int `json:"configmapsPerNamespace"` // default: 50
	SecretSizeKB    int `json:"secretSizeKB"`           // default: 100
	ConfigMapSizeKB int `json:"configmapSizeKB"`        // default: 100

	// Job lifecycle simulation
	PodSizeKB          int    `json:"podSizeKB"`          // default: 10
	EventSizeKB        int    `json:"eventSizeKB"`        // default: 1
	MetadataIterations int    `json:"metadataIterations"` // default: 2
	MetadataDelay      string `json:"metadataDelay"`      // default: "1s"

	// Controller/Watcher simulation
	NumControllers     int    `json:"numControllers"`        // default: 3
	WatchersPerCtrl    int    `json:"watchersPerController"` // default: 6
	NumWatchBuckets    int    `json:"numWatchBuckets"`       // default: 32
	WithPrevKV         bool   `json:"withPrevKV"`            // default: true
	WatchReconnectIntv string `json:"watchReconnectInterval"` // default: "30s" — forces unsynced watcher path
	WatchReconnectSleep string `json:"watchReconnectSleep"`   // default: "60s" — sleep after disconnect before reconnecting
	WatchStartDelay     string `json:"watchStartDelay"`       // default: "0s" — delay before starting watchers
	WatchInitialRev     int64  `json:"watchInitialRev"`       // default: 0 — if >0, seed watcher lastRev (simulates fallen-behind watcher)

	// Rate limiting
	QPS int `json:"qps"` // default: 40

	// Run duration (optional — if set, exit after this duration instead of waiting for Ctrl+C)
	RunDuration string `json:"runDuration"` // default: "" (wait for Ctrl+C)

	// Metrics collection
	MetricsInterval   string `json:"metricsInterval"`   // default: "10s"
	MetricsOutputFile string `json:"metricsOutputFile"` // default: "metrics.csv"
}

// TotalJobs returns the derived total job count.
func (c *Config) TotalJobs() int {
	return c.NumNamespaces * c.JobsPerNS
}

func defaultConfig() *Config {
	return &Config{
		ClusterSize:        1,
		SnapshotCount:      10000,
		Endpoints:          []string{"http://127.0.0.1:2379"},
		NumNamespaces:      100,
		JobsPerNS:          100,
		JobSizeKB:          21,
		SecretsPerNS:       150,
		ConfigMapsPerNS:    50,
		SecretSizeKB:       100,
		ConfigMapSizeKB:    100,
		PodSizeKB:          10,
		EventSizeKB:        1,
		MetadataIterations: 2,
		MetadataDelay:      "1s",
		NumControllers:     3,
		WatchersPerCtrl:    6,
		NumWatchBuckets:    32,
		WithPrevKV:         true,
		WatchReconnectIntv:  "30s",
		WatchReconnectSleep: "60s",
		WatchStartDelay:     "0s",
		QPS:                40,
		MetricsInterval:    "10s",
		MetricsOutputFile:  "metrics.csv",
	}
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}
	cfg := defaultConfig()
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}
	return cfg, nil
}
