package main

import (
	"context"
	"fmt"
	"log"
	"sync/atomic"
	"time"

	clientv3 "go.etcd.io/etcd/client/v3"
)

var totalWatchEvents atomic.Int64

func startWatchers(cfg *Config, startDelay time.Duration) (*clientv3.Client, error) {
	client, err := clientv3.New(clientv3.Config{
		Endpoints:   cfg.Endpoints,
		DialTimeout: 5 * time.Second,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to create etcd client: %w", err)
	}

	var reconnectInterval time.Duration
	if cfg.WatchReconnectIntv != "" {
		reconnectInterval, err = time.ParseDuration(cfg.WatchReconnectIntv)
		if err != nil {
			return nil, fmt.Errorf("invalid watchReconnectInterval %q: %w", cfg.WatchReconnectIntv, err)
		}
	}

	var reconnectSleep time.Duration
	if cfg.WatchReconnectSleep != "" {
		reconnectSleep, err = time.ParseDuration(cfg.WatchReconnectSleep)
		if err != nil {
			return nil, fmt.Errorf("invalid watchReconnectSleep %q: %w", cfg.WatchReconnectSleep, err)
		}
	} else {
		reconnectSleep = 60 * time.Second
	}

	totalWatchers := cfg.NumControllers * cfg.WatchersPerCtrl
	initialRev := cfg.WatchInitialRev
	log.Printf("Starting %d watchers (%d controllers x %d watchers, withPrevKV=%v, reconnect=%v, reconnectSleep=%v, startDelay=%v, initialRev=%d)",
		totalWatchers, cfg.NumControllers, cfg.WatchersPerCtrl, cfg.WithPrevKV, reconnectInterval, reconnectSleep, startDelay, initialRev)

	go func() {
		if startDelay > 0 {
			log.Printf("Watchers will start after %v delay", startDelay)
			time.Sleep(startDelay)
			log.Printf("Watcher start delay elapsed, launching watchers now")
		}

		watcherID := 0
		for c := 0; c < cfg.NumControllers; c++ {
			for w := 0; w < cfg.WatchersPerCtrl; w++ {
				bucket := watcherID % cfg.NumWatchBuckets
				prefix := fmt.Sprintf("/buildfarmsim/watcher-%d/", bucket)
				go runWatcher(client, prefix, cfg.WithPrevKV, watcherID, reconnectInterval, reconnectSleep, initialRev)
				watcherID++
			}
		}
	}()

	return client, nil
}

func runWatcher(client *clientv3.Client, prefix string, withPrevKV bool, id int, reconnectInterval, reconnectSleep time.Duration, initialRev int64) {
	lastRev := initialRev

	for {
		watchOpts := []clientv3.OpOption{clientv3.WithPrefix()}
		if withPrevKV {
			watchOpts = append(watchOpts, clientv3.WithPrevKV())
		}
		if lastRev > 0 {
			watchOpts = append(watchOpts, clientv3.WithRev(lastRev+1))
		}

		ctx := context.Background()
		var cancel context.CancelFunc
		if reconnectInterval > 0 {
			ctx, cancel = context.WithTimeout(ctx, reconnectInterval)
		}

		watchCh := client.Watch(ctx, prefix, watchOpts...)

		for resp := range watchCh {
			if resp.Err() != nil {
				log.Printf("Watcher %d error on prefix %s: %v", id, prefix, resp.Err())
				break
			}
			totalWatchEvents.Add(int64(len(resp.Events)))
			if resp.Header.Revision > lastRev {
				lastRev = resp.Header.Revision
			}
		}

		if cancel != nil {
			cancel()
		}

		// Delay before reconnecting — events accumulate during this gap,
		// so the watcher is "unsynced" and must catch up through
		// syncWatchers → rangeEventsWithReuse on reconnect.
		time.Sleep(reconnectSleep)
	}
}
