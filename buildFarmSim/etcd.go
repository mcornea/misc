package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const (
	basePeerPort   = 12380
	baseClientPort = 2379
)

var etcdProcesses []*os.Process

func startCluster(cfg *Config) error {
	// Start all members first (don't wait for readiness individually,
	// because a multi-node cluster needs quorum before any node is ready).
	for i := 0; i < cfg.ClusterSize; i++ {
		if err := launchEtcd(cfg.EtcdBinPath, i, cfg.ClusterSize, cfg.SnapshotCount); err != nil {
			return fmt.Errorf("failed to start etcd member %d: %w", i, err)
		}
	}
	// Now wait for all members to become ready
	for i := 0; i < cfg.ClusterSize; i++ {
		clientURL := fmt.Sprintf("http://127.0.0.1:%d", baseClientPort+i)
		testURL := clientURL + "/version"
		name := fmt.Sprintf("etcd-%d", i)
		log.Printf("Waiting for %s to be ready (%s)", name, testURL)
		ready := false
		for j := 0; j < 30; j++ {
			if resp, err := sanityTest(testURL); err == nil {
				log.Printf("Sanity test on %s successful: %s", name, resp)
				ready = true
				break
			}
			time.Sleep(1 * time.Second)
		}
		if !ready {
			return fmt.Errorf("sanity test on %s (%s) failed after 30s", name, testURL)
		}
	}
	return nil
}

func launchEtcd(binPath string, idx, clusterSize, snapshotCount int) error {
	etcdPath := filepath.Join(binPath, "etcd")
	name := fmt.Sprintf("etcd-%d", idx)
	dataDir := fmt.Sprintf("data-etcd-%d", idx)
	logFile := fmt.Sprintf("log-etcd-%d.log", idx)

	if err := os.MkdirAll(dataDir, 0755); err != nil {
		return fmt.Errorf("failed to create data dir (%s): %w", dataDir, err)
	}

	peerURL := fmt.Sprintf("http://127.0.0.1:%d", basePeerPort+idx)
	clientURL := fmt.Sprintf("http://127.0.0.1:%d", baseClientPort+idx)

	// Build initial-cluster string for all members
	ic := buildInitialCluster(clusterSize)

	args := []string{
		fmt.Sprintf("--name=%s", name),
		fmt.Sprintf("--data-dir=%s", dataDir),
		fmt.Sprintf("--listen-peer-urls=%s", peerURL),
		fmt.Sprintf("--listen-client-urls=%s", clientURL),
		fmt.Sprintf("--advertise-client-urls=%s", clientURL),
		fmt.Sprintf("--initial-advertise-peer-urls=%s", peerURL),
		fmt.Sprintf("--initial-cluster=%s", ic),
		"--initial-cluster-state=new",
		fmt.Sprintf("--snapshot-count=%d", snapshotCount),
		fmt.Sprintf("--log-outputs=%s", logFile),
		"--enable-pprof",
		"--quota-backend-bytes=8589934592",
	}

	cmd := exec.Command(etcdPath, args...)
	log.Printf("Starting etcd member %s: %s %v", name, etcdPath, args)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start etcd %s: %w", name, err)
	}
	etcdProcesses = append(etcdProcesses, cmd.Process)
	return nil
}

func buildInitialCluster(clusterSize int) string {
	var parts []string
	for i := 0; i < clusterSize; i++ {
		name := fmt.Sprintf("etcd-%d", i)
		peerURL := fmt.Sprintf("http://127.0.0.1:%d", basePeerPort+i)
		parts = append(parts, fmt.Sprintf("%s=%s", name, peerURL))
	}
	result := parts[0]
	for _, p := range parts[1:] {
		result = result + "," + p
	}
	return result
}

func sanityTest(url string) (string, error) {
	resp, err := http.Get(url)
	if err != nil {
		return "", fmt.Errorf("failed to GET %s: %w", url, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %w", err)
	}
	return string(body), nil
}

func stopCluster() {
	for _, p := range etcdProcesses {
		if p != nil {
			log.Printf("Killing etcd process %d", p.Pid)
			p.Kill()
		}
	}
	etcdProcesses = nil
}
