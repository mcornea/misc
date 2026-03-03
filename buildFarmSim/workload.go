package main

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"sync/atomic"
	"time"

	clientv3 "go.etcd.io/etcd/client/v3"
)

var totalPuts atomic.Int64

// generateValue creates a random byte string of the specified size in KB.
func generateValue(sizeKB int) string {
	size := sizeKB * 1024
	b := make([]byte, size)
	for i := range b {
		b[i] = byte('a' + rand.Intn(26))
	}
	return string(b)
}

// Key helpers — keys are structured so per-bucket watchers see only their jobs,
// while secrets/configmaps live under the namespace prefix (no watcher bucket).
//
// Layout:
//   /buildfarmsim/watcher-{B}/ns-{N}/job-{J}
//   /buildfarmsim/watcher-{B}/ns-{N}/pod-{J}
//   /buildfarmsim/watcher-{B}/ns-{N}/event-{J}-{type}
//   /buildfarmsim/ns-{N}/secret-{S}
//   /buildfarmsim/ns-{N}/configmap-{C}

func jobKey(ns, jobIdx, numBuckets int) string {
	bucket := jobIdx % numBuckets
	return fmt.Sprintf("/buildfarmsim/watcher-%d/ns-%d/job-%d", bucket, ns, jobIdx)
}

func podKey(ns, jobIdx, numBuckets int) string {
	bucket := jobIdx % numBuckets
	return fmt.Sprintf("/buildfarmsim/watcher-%d/ns-%d/pod-%d", bucket, ns, jobIdx)
}

func eventKey(ns, jobIdx, numBuckets int, eventType string) string {
	bucket := jobIdx % numBuckets
	return fmt.Sprintf("/buildfarmsim/watcher-%d/ns-%d/event-%d-%s", bucket, ns, jobIdx, eventType)
}

func secretKey(ns, idx int) string {
	return fmt.Sprintf("/buildfarmsim/ns-%d/secret-%d", ns, idx)
}

func configMapKey(ns, idx int) string {
	return fmt.Sprintf("/buildfarmsim/ns-%d/configmap-%d", ns, idx)
}

// ratePut performs a single PUT with rate limiting and error logging.
func ratePut(client *clientv3.Client, key, value string, delay time.Duration) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	_, err := client.Put(ctx, key, value)
	cancel()
	if err != nil {
		log.Printf("WARNING: PUT %s failed: %v", key, err)
		return
	}
	totalPuts.Add(1)
	time.Sleep(delay)
}

// createNamespaceObjects pre-populates each namespace with secrets and configmaps.
// These are created once and never churned, simulating the static large objects
// that inflate the etcd DB in production.
func createNamespaceObjects(client *clientv3.Client, cfg *Config, phase *string) {
	*phase = "ns-objects"
	totalSecrets := cfg.NumNamespaces * cfg.SecretsPerNS
	totalCMs := cfg.NumNamespaces * cfg.ConfigMapsPerNS
	log.Printf("Creating namespace objects: %d secrets (%d KiB each) + %d configmaps (%d KiB each) across %d namespaces...",
		totalSecrets, cfg.SecretSizeKB, totalCMs, cfg.ConfigMapSizeKB, cfg.NumNamespaces)

	secretValue := generateValue(cfg.SecretSizeKB)
	cmValue := generateValue(cfg.ConfigMapSizeKB)
	delay := time.Second / time.Duration(cfg.QPS)
	created := 0
	total := totalSecrets + totalCMs

	for ns := 0; ns < cfg.NumNamespaces; ns++ {
		for s := 0; s < cfg.SecretsPerNS; s++ {
			ratePut(client, secretKey(ns, s), secretValue, delay)
			created++
			if created%1000 == 0 {
				log.Printf("  namespace objects: %d/%d", created, total)
			}
		}
		for c := 0; c < cfg.ConfigMapsPerNS; c++ {
			ratePut(client, configMapKey(ns, c), cmValue, delay)
			created++
			if created%1000 == 0 {
				log.Printf("  namespace objects: %d/%d", created, total)
			}
		}
	}
	log.Printf("Finished creating %d namespace objects", created)
}

// runJobLifecycles simulates the full Kubernetes job lifecycle for each job.
// Each job generates 13 PUTs across 5 unique keys (job, pod, 3 events).
func runJobLifecycles(client *clientv3.Client, cfg *Config, phase *string) {
	*phase = "job-lifecycle"
	totalJobs := cfg.TotalJobs()
	log.Printf("Running job lifecycles: %d jobs (%d ns x %d jobs/ns), %d PUTs per job...",
		totalJobs, cfg.NumNamespaces, cfg.JobsPerNS, 13)

	metadataDelay, err := time.ParseDuration(cfg.MetadataDelay)
	if err != nil {
		log.Fatalf("Invalid metadataDelay %q: %v", cfg.MetadataDelay, err)
	}

	jobValue := generateValue(cfg.JobSizeKB)
	podValue := generateValue(cfg.PodSizeKB)
	eventValue := generateValue(cfg.EventSizeKB)
	delay := time.Second / time.Duration(cfg.QPS)

	completed := 0
	for ns := 0; ns < cfg.NumNamespaces; ns++ {
		for j := 0; j < cfg.JobsPerNS; j++ {
			runSingleJobLifecycle(client, cfg, ns, j, jobValue, podValue, eventValue, delay, metadataDelay)
			completed++
			if completed%500 == 0 {
				log.Printf("  job lifecycles: %d/%d", completed, totalJobs)
			}
		}
	}
	log.Printf("Finished %d job lifecycles (%d total PUTs)", completed, totalPuts.Load())
}

// runSingleJobLifecycle simulates the 13-PUT lifecycle for one job.
func runSingleJobLifecycle(client *clientv3.Client, cfg *Config, ns, jobIdx int, jobValue, podValue, eventValue string, delay, metadataDelay time.Duration) {
	jk := jobKey(ns, jobIdx, cfg.NumWatchBuckets)
	pk := podKey(ns, jobIdx, cfg.NumWatchBuckets)

	// 1. Job created
	ratePut(client, jk, jobValue, delay)
	// 2. Pod created
	ratePut(client, pk, podValue, delay)
	// 3. Event: job created
	ratePut(client, eventKey(ns, jobIdx, cfg.NumWatchBuckets, "created"), eventValue, delay)
	// 4. Event: pod scheduled
	ratePut(client, eventKey(ns, jobIdx, cfg.NumWatchBuckets, "sched"), eventValue, delay)
	// 5. Pod status → Running
	ratePut(client, pk, podValue, delay)
	// 6. Event: pod started
	ratePut(client, eventKey(ns, jobIdx, cfg.NumWatchBuckets, "started"), eventValue, delay)

	// Metadata patches (simulates build-farm-metadata-adder)
	for iter := 0; iter < cfg.MetadataIterations; iter++ {
		// 7/9. Pod metadata patch
		ratePut(client, pk, podValue, delay)
		// 8/10. Job metadata patch
		ratePut(client, jk, jobValue, delay)
		if iter < cfg.MetadataIterations-1 {
			time.Sleep(metadataDelay)
		}
	}

	// 11. Pod status → Succeeded
	ratePut(client, pk, podValue, delay)
	// 12. Job status → Complete
	ratePut(client, jk, jobValue, delay)
	// 13. Event: job completed
	ratePut(client, eventKey(ns, jobIdx, cfg.NumWatchBuckets, "done"), eventValue, delay)
}

