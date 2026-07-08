// XFS fdatasync P99 Latency Regression Reproducer
//
// Reproduces the etcd WAL fdatasync tail-latency regression between kernel
// 5.14 (RHEL 9) and 6.12 (RHEL 10) caused by three interacting XFS changes:
//   - CIL per-CPU lists (c0fb4765c508): aggregation storms at push time
//   - Async flush removal (919edbadebe1): 100% force_sleep ratio
//   - CIL push serialization (39823d0fac94): prevents pipelined pushes
//
// The program mimics etcd's WAL (sequential append + fdatasync) and bbolt
// (random pwrite + fdatasync) patterns, plus background metadata IO that
// fills the XFS CIL with diverse items. When the WAL's fdatasync forces a
// CIL push, per-CPU list aggregation on 6.12 takes longer, shifting the
// latency distribution into the 5-20ms range.
//
// Usage:
//
//	go build -o fdatasync-repro && sudo ./fdatasync-repro [flags]
//
// On 4-CPU systems: expect P99 ~1.2x worse, >5ms events ~2x worse on 6.12.
// On 8+ CPU systems: expect P99 ~2.2x worse (matching cluster-density).
//
// Prerequisites: XFS filesystem, root (for /proc/fs/xfs/stat)
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var (
	testDir       = flag.String("dir", "/var/tmp/xfs-fdatasync-repro", "Test directory (must be on XFS)")
	duration      = flag.Duration("duration", 60*time.Second, "Test duration")
	walRate       = flag.Int("wal-rate", 300, "Target WAL fdatasyncs per second (proposals/s)")
	walBurst      = flag.Int("wal-burst", 10, "WAL proposals per burst (0=uniform rate)")
	walEntrySize  = flag.Int("wal-entry-size", 2300, "WAL entry size in bytes")
	walSegmentMB  = flag.Int("wal-segment-mb", 64, "WAL segment size before rotation (MB)")
	bboltInterval = flag.Duration("bbolt-interval", 100*time.Millisecond, "bbolt commit interval")
	bboltPages    = flag.Int("bbolt-pages", 20, "Dirty pages per bbolt commit")
	bboltPageSize = flag.Int("bbolt-page-size", 4096, "bbolt page size")
	bgWriters     = flag.Int("bg-writers", 40, "Background metadata writer goroutines (CIL fill)")
	bgSyncers     = flag.Int("bg-syncers", 0, "Background fdatasync goroutines (journal/kubelet/CRI-O)")
	bgInterval    = flag.Duration("bg-interval", 1*time.Millisecond, "Background metadata writer pacing interval")
	reportEvery   = flag.Duration("report-interval", 10*time.Second, "Print interim report interval")
)

type latencyRecorder struct {
	mu      sync.Mutex
	samples []time.Duration
}

func newRecorder() *latencyRecorder {
	return &latencyRecorder{samples: make([]time.Duration, 0, 1<<20)}
}

func (r *latencyRecorder) record(d time.Duration) {
	r.mu.Lock()
	r.samples = append(r.samples, d)
	r.mu.Unlock()
}

type percentiles struct {
	count    int
	p50, p90 time.Duration
	p95, p99 time.Duration
	p999     time.Duration
	max, avg time.Duration
	slow5ms  int
	slow10ms int
	slow20ms int
	slow50ms int
}

func (r *latencyRecorder) stats() percentiles {
	r.mu.Lock()
	s := make([]time.Duration, len(r.samples))
	copy(s, r.samples)
	r.mu.Unlock()

	if len(s) == 0 {
		return percentiles{}
	}
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })

	var sum time.Duration
	var slow5, slow10, slow20, slow50 int
	for _, v := range s {
		sum += v
		if v > 5*time.Millisecond {
			slow5++
		}
		if v > 10*time.Millisecond {
			slow10++
		}
		if v > 20*time.Millisecond {
			slow20++
		}
		if v > 50*time.Millisecond {
			slow50++
		}
	}

	pct := func(p float64) time.Duration {
		idx := int(math.Ceil(float64(len(s))*p/100.0)) - 1
		if idx < 0 {
			idx = 0
		}
		if idx >= len(s) {
			idx = len(s) - 1
		}
		return s[idx]
	}

	return percentiles{
		count: len(s), avg: sum / time.Duration(len(s)),
		p50: pct(50), p90: pct(90), p95: pct(95),
		p99: pct(99), p999: pct(99.9), max: s[len(s)-1],
		slow5ms: slow5, slow10ms: slow10, slow20ms: slow20, slow50ms: slow50,
	}
}

func (r *latencyRecorder) histogram() string {
	r.mu.Lock()
	s := make([]time.Duration, len(r.samples))
	copy(s, r.samples)
	r.mu.Unlock()

	if len(s) == 0 {
		return ""
	}

	var b1, b2, b3, b4, b5, b6 int // <1ms, 1-5ms, 5-10ms, 10-20ms, 20-50ms, >50ms
	for _, v := range s {
		switch {
		case v < time.Millisecond:
			b1++
		case v < 5*time.Millisecond:
			b2++
		case v < 10*time.Millisecond:
			b3++
		case v < 20*time.Millisecond:
			b4++
		case v < 50*time.Millisecond:
			b5++
		default:
			b6++
		}
	}
	n := float64(len(s))
	return fmt.Sprintf("    <1ms:    %6d (%5.1f%%)\n"+
		"    1-5ms:   %6d (%5.1f%%)\n"+
		"    5-10ms:  %6d (%5.1f%%)\n"+
		"    10-20ms: %6d (%5.1f%%)  ← regression bucket\n"+
		"    20-50ms: %6d (%5.1f%%)\n"+
		"    >50ms:   %6d (%5.1f%%)",
		b1, float64(b1)/n*100,
		b2, float64(b2)/n*100,
		b3, float64(b3)/n*100,
		b4, float64(b4)/n*100,
		b5, float64(b5)/n*100,
		b6, float64(b6)/n*100)
}

func (p percentiles) String() string {
	pctS5 := float64(p.slow5ms) * 100 / float64(p.count)
	pctS10 := float64(p.slow10ms) * 100 / float64(p.count)
	return fmt.Sprintf("    count:   %d\n"+
		"    avg:     %v\n"+
		"    P50:     %v\n"+
		"    P90:     %v\n"+
		"    P95:     %v\n"+
		"    P99:     %v\n"+
		"    P99.9:   %v\n"+
		"    max:     %v\n"+
		"    >5ms:    %d (%.2f%%)\n"+
		"    >10ms:   %d (%.2f%%)\n"+
		"    >20ms:   %d\n"+
		"    >50ms:   %d",
		p.count, p.avg, p.p50, p.p90, p.p95, p.p99, p.p999, p.max,
		p.slow5ms, pctS5, p.slow10ms, pctS10, p.slow20ms, p.slow50ms)
}

func doFdatasync(fd int) error {
	_, _, errno := syscall.Syscall(syscall.SYS_FDATASYNC, uintptr(fd), 0, 0)
	if errno != 0 {
		return errno
	}
	return nil
}

type xfsLogStats struct {
	logWrites, logForce, logForceSleep, logNoIclogs int64
}

func readXFSStats() (xfsLogStats, error) {
	data, err := os.ReadFile("/proc/fs/xfs/stat")
	if err != nil {
		return xfsLogStats{}, err
	}
	var s xfsLogStats
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "log ") {
			f := strings.Fields(line)
			if len(f) >= 6 {
				fmt.Sscanf(f[1], "%d", &s.logWrites)
				fmt.Sscanf(f[3], "%d", &s.logNoIclogs)
				fmt.Sscanf(f[4], "%d", &s.logForce)
				fmt.Sscanf(f[5], "%d", &s.logForceSleep)
			}
		}
	}
	return s, nil
}

func clearXFSStats() {
	os.WriteFile("/proc/sys/fs/xfs/stats_clear", []byte("1"), 0644)
}

// walWriter mimics etcd's WAL with bursty proposals. In real clusters, raft
// proposals arrive in bursts (e.g., 10-20 proposals from a batch of pod
// creates), not at a uniform rate. Each proposal: append ~2300B + fdatasync.
func walWriter(dir string, rec *latencyRecorder, done <-chan struct{}, wg *sync.WaitGroup) {
	defer wg.Done()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	segSize := int64(*walSegmentMB) * 1024 * 1024
	entryBuf := make([]byte, *walEntrySize)
	binary.LittleEndian.PutUint64(entryBuf[0:8], 0x0a)
	rand.Read(entryBuf[8:])

	var segNum int
	var segOffset int64
	var fd int = -1

	openSegment := func() {
		if fd >= 0 {
			syscall.Close(fd)
		}
		path := filepath.Join(dir, fmt.Sprintf("wal-%06d.wal", segNum))
		var err error
		fd, err = syscall.Open(path, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_TRUNC, 0644)
		if err != nil {
			panic(fmt.Sprintf("open WAL segment: %v", err))
		}
		syscall.Fallocate(fd, 0, 0, segSize)
		segNum++
		segOffset = 0
	}
	openSegment()
	defer func() {
		if fd >= 0 {
			syscall.Close(fd)
		}
	}()

	burstSize := *walBurst
	if burstSize <= 0 {
		burstSize = 1
	}
	// Calculate inter-burst pause to achieve target rate
	burstPause := time.Duration(float64(time.Second) * float64(burstSize) / float64(*walRate))
	// Within a burst, proposals arrive rapidly (~200µs apart, like real raft)
	intraDelay := 200 * time.Microsecond

	for {
		select {
		case <-done:
			return
		default:
		}

		// Fire a burst of proposals
		for i := 0; i < burstSize; i++ {
			if segOffset+int64(*walEntrySize) > segSize {
				openSegment()
			}
			binary.LittleEndian.PutUint64(entryBuf[8:16], uint64(time.Now().UnixNano()))
			n, err := syscall.Write(fd, entryBuf)
			if err != nil || n != len(entryBuf) {
				continue
			}
			segOffset += int64(n)

			start := time.Now()
			doFdatasync(fd)
			rec.record(time.Since(start))

			if i < burstSize-1 {
				time.Sleep(intraDelay)
			}
		}

		// Inter-burst pause (jittered ±30% to avoid lock-step)
		jitter := time.Duration(float64(burstPause) * (0.7 + 0.6*rand.Float64()))
		time.Sleep(jitter)
	}
}

// bboltWriter mimics etcd's bbolt backend: every 100ms, write N dirty 4KB
// pages at random offsets + fdatasync, then write meta page + fdatasync.
func bboltWriter(dir string, rec *latencyRecorder, done <-chan struct{}, wg *sync.WaitGroup) {
	defer wg.Done()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	dbPath := filepath.Join(dir, "snap-db")
	fd, err := syscall.Open(dbPath, syscall.O_RDWR|syscall.O_CREAT|syscall.O_TRUNC, 0644)
	if err != nil {
		panic(fmt.Sprintf("open bbolt db: %v", err))
	}
	defer syscall.Close(fd)

	dbSize := int64(256 * 1024 * 1024)
	syscall.Fallocate(fd, 0, 0, dbSize)

	pageBuf := make([]byte, *bboltPageSize)
	metaBuf := make([]byte, *bboltPageSize)
	rand.Read(pageBuf)
	rand.Read(metaBuf)
	maxPage := dbSize / int64(*bboltPageSize)

	ticker := time.NewTicker(*bboltInterval)
	defer ticker.Stop()

	for {
		select {
		case <-done:
			return
		case <-ticker.C:
		}

		pages := make([]int64, *bboltPages)
		for i := range pages {
			pages[i] = (rand.Int63n(maxPage-2) + 2) * int64(*bboltPageSize)
		}
		sort.Slice(pages, func(i, j int) bool { return pages[i] < pages[j] })
		for _, off := range pages {
			syscall.Pwrite(fd, pageBuf, off)
		}

		start := time.Now()
		doFdatasync(fd)
		rec.record(time.Since(start))

		metaOff := int64(0)
		if rand.Intn(2) == 1 {
			metaOff = int64(*bboltPageSize)
		}
		syscall.Pwrite(fd, metaBuf, metaOff)

		start = time.Now()
		doFdatasync(fd)
		rec.record(time.Since(start))
	}
}

// bgMetadataWriter generates diverse buffered metadata IO that fills the CIL
// without explicit syncs. Uses file create/rename/delete, directory
// create/remove, symlinks, chmod, and truncate to maximize CIL item type
// diversity — matching real cluster workloads where kubelet, CRI-O, journal,
// and containers each generate different metadata patterns. On kernel 6.12 the
// per-CPU CIL lists create aggregation storms when etcd's fdatasync forces a
// push.
func bgMetadataWriter(dir string, id int, done <-chan struct{}, wg *sync.WaitGroup, ops *atomic.Int64) {
	defer wg.Done()

	subdir := filepath.Join(dir, fmt.Sprintf("bg-%d", id))
	os.MkdirAll(subdir, 0755)

	// Create a nested directory tree for inode diversity
	for i := 0; i < 8; i++ {
		os.MkdirAll(filepath.Join(subdir, fmt.Sprintf("d%d/sub", i)), 0755)
	}

	sizes := []int{512, 1024, 2048, 4096, 8192, 16384}
	buf := make([]byte, sizes[len(sizes)-1])
	rand.Read(buf)
	writeSize := sizes[id%len(sizes)]

	var cycle int
	for {
		select {
		case <-done:
			return
		default:
		}

		// Rotate through subdirs for inode spread across AG groups
		subNum := cycle % 8
		workDir := filepath.Join(subdir, fmt.Sprintf("d%d", subNum))

		name := fmt.Sprintf("f-%d", cycle%64)
		path := filepath.Join(workDir, name)
		tmpPath := path + ".tmp"

		// Create + write (inode alloc, extent alloc, data write CIL items)
		fd, err := syscall.Open(tmpPath, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_TRUNC, 0644)
		if err != nil {
			cycle++
			continue
		}
		for w := 0; w < 4; w++ {
			syscall.Write(fd, buf[:writeSize])
		}
		syscall.Close(fd)

		// Rename (directory entry update — different CIL item type)
		syscall.Rename(tmpPath, path)
		ops.Add(1)

		// Periodic metadata diversity ops — lightweight operations that create
		// different CIL item types without heavy IO
		switch cycle % 16 {
		case 0:
			syscall.Chmod(path, 0755)
		case 4:
			syscall.Truncate(path, int64(writeSize*2))
		case 8:
			old := filepath.Join(workDir, fmt.Sprintf("f-%d", (cycle/8)%64))
			syscall.Unlink(old)
		case 12:
			link := filepath.Join(workDir, fmt.Sprintf("l-%d", cycle%16))
			syscall.Unlink(link)
			os.Symlink(path, link)
		}

		cycle++
		time.Sleep(*bgInterval)
	}
}

// bgSyncWriter simulates processes that do their own fdatasync on separate
// files — journal (systemd-journald), kubelet status writes, CRI-O image
// layer commits. These force independent XFS log pushes that compete with
// etcd. On kernel 6.12 with CIL push serialization, these create head-of-line
// blocking: etcd's fdatasync must wait for an in-progress CIL push from
// another process to complete before starting its own.
func bgSyncWriter(dir string, id int, done <-chan struct{}, wg *sync.WaitGroup) {
	defer wg.Done()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	// Each sync writer simulates a different process pattern
	switch id % 3 {
	case 0:
		// Journal-like: sequential append of variable-size records + fsync
		bgJournalWriter(dir, id, done)
	case 1:
		// kubelet-like: small writes to many files + occasional fsync
		bgKubeletWriter(dir, id, done)
	case 2:
		// CRI-O-like: large sequential writes + periodic fsync
		bgCRIOWriter(dir, id, done)
	}
}

func bgJournalWriter(dir string, id int, done <-chan struct{}) {
	path := filepath.Join(dir, fmt.Sprintf("journal-%d.log", id))
	fd, err := syscall.Open(path, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_TRUNC, 0644)
	if err != nil {
		return
	}
	defer syscall.Close(fd)

	buf := make([]byte, 2048)
	rand.Read(buf)

	var count int
	for {
		select {
		case <-done:
			return
		default:
		}

		sz := 100 + rand.Intn(1948)
		syscall.Write(fd, buf[:sz])
		count++

		// Journal syncs more frequently to create competing CIL pushes
		if count%8 == 0 {
			doFdatasync(fd)
		}

		time.Sleep(time.Duration(2+rand.Intn(8)) * time.Millisecond)
	}
}

func bgKubeletWriter(dir string, id int, done <-chan struct{}) {
	subdir := filepath.Join(dir, fmt.Sprintf("kubelet-%d", id))
	os.MkdirAll(subdir, 0755)

	buf := make([]byte, 512)
	rand.Read(buf)

	var cycle int
	for {
		select {
		case <-done:
			return
		default:
		}

		path := filepath.Join(subdir, fmt.Sprintf("pod-%d.status", cycle%32))
		fd, err := syscall.Open(path, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_TRUNC, 0644)
		if err != nil {
			cycle++
			continue
		}
		syscall.Write(fd, buf)
		doFdatasync(fd)
		syscall.Close(fd)

		cycle++
		time.Sleep(time.Duration(20+rand.Intn(80)) * time.Millisecond)
	}
}

func bgCRIOWriter(dir string, id int, done <-chan struct{}) {
	path := filepath.Join(dir, fmt.Sprintf("layer-%d.tar", id))
	fd, err := syscall.Open(path, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_TRUNC, 0644)
	if err != nil {
		return
	}
	defer syscall.Close(fd)

	buf := make([]byte, 32768)
	rand.Read(buf)

	var count int
	for {
		select {
		case <-done:
			return
		default:
		}

		syscall.Write(fd, buf)
		count++

		// Sync every ~64 writes (2MB intervals)
		if count%64 == 0 {
			doFdatasync(fd)
		}

		time.Sleep(time.Duration(1+rand.Intn(3)) * time.Millisecond)
	}
}

func printHeader() {
	fmt.Println("==========================================================================")
	fmt.Println("  XFS fdatasync P99 Latency Regression Reproducer")
	fmt.Println("  Simulates etcd WAL + bbolt + cluster background IO")
	fmt.Println("==========================================================================")
	fmt.Println()

	hostname, _ := os.Hostname()
	var uname syscall.Utsname
	syscall.Uname(&uname)
	kernel := int8SliceToString(uname.Release[:])

	fmt.Printf("  Kernel:         %s\n", kernel)
	fmt.Printf("  Host:           %s\n", hostname)
	fmt.Printf("  Date:           %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Printf("  Test dir:       %s\n", *testDir)
	fmt.Printf("  Duration:       %v\n", *duration)
	fmt.Printf("  WAL rate:       %d proposals/s (burst=%d)\n", *walRate, *walBurst)
	fmt.Printf("  WAL entry:      %d bytes\n", *walEntrySize)
	fmt.Printf("  WAL segment:    %d MB\n", *walSegmentMB)
	fmt.Printf("  bbolt interval: %v\n", *bboltInterval)
	fmt.Printf("  bbolt pages:    %d x %d bytes\n", *bboltPages, *bboltPageSize)
	fmt.Printf("  BG metadata:    %d goroutines, interval=%v (buffered file create/rename/delete)\n", *bgWriters, *bgInterval)
	fmt.Printf("  BG syncers:     %d goroutines (journal/kubelet/CRI-O fdatasync)\n", *bgSyncers)
	fmt.Printf("  CPUs:           %d\n", runtime.NumCPU())
	fmt.Println()
}

func int8SliceToString(b []int8) string {
	buf := make([]byte, 0, len(b))
	for _, v := range b {
		if v == 0 {
			break
		}
		buf = append(buf, byte(v))
	}
	return string(buf)
}

func checkXFS(dir string) error {
	var statfs syscall.Statfs_t
	if err := syscall.Statfs(dir, &statfs); err != nil {
		return fmt.Errorf("statfs %s: %v", dir, err)
	}
	const XFS_SUPER_MAGIC = 0x58465342
	if statfs.Type != XFS_SUPER_MAGIC {
		return fmt.Errorf("%s is not on XFS (type=0x%x, expected 0x%x)", dir, statfs.Type, XFS_SUPER_MAGIC)
	}
	return nil
}

func main() {
	flag.Parse()

	if err := os.MkdirAll(*testDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: mkdir %s: %v\n", *testDir, err)
		os.Exit(1)
	}
	if err := checkXFS(*testDir); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		fmt.Fprintf(os.Stderr, "Use --dir to specify a directory on XFS\n")
		os.Exit(1)
	}
	if os.Getuid() != 0 {
		fmt.Fprintf(os.Stderr, "WARNING: not root, XFS log stats will be unavailable\n")
	}

	printHeader()

	walDir := filepath.Join(*testDir, "wal")
	bboltDir := filepath.Join(*testDir, "bbolt")
	bgDir := filepath.Join(*testDir, "bg")
	syncDir := filepath.Join(*testDir, "sync")
	os.MkdirAll(walDir, 0755)
	os.MkdirAll(bboltDir, 0755)
	os.MkdirAll(bgDir, 0755)
	os.MkdirAll(syncDir, 0755)

	walRec := newRecorder()
	bboltRec := newRecorder()

	done := make(chan struct{})
	var wg sync.WaitGroup
	var bgOps atomic.Int64

	clearXFSStats()
	xfsBefore, _ := readXFSStats()

	fmt.Println("--- Starting workload ---")
	fmt.Println()

	// Background metadata writers (buffered, fill CIL)
	for i := 0; i < *bgWriters; i++ {
		wg.Add(1)
		go bgMetadataWriter(bgDir, i, done, &wg, &bgOps)
	}

	// Background sync writers (journal, kubelet, CRI-O — competing fdatasyncs)
	for i := 0; i < *bgSyncers; i++ {
		wg.Add(1)
		go bgSyncWriter(syncDir, i, done, &wg)
	}

	// bbolt writer
	wg.Add(1)
	go bboltWriter(bboltDir, bboltRec, done, &wg)

	// WAL writer (started last so background is already running)
	wg.Add(1)
	go walWriter(walDir, walRec, done, &wg)

	reportTicker := time.NewTicker(*reportEvery)
	defer reportTicker.Stop()

	deadline := time.After(*duration)
	startTime := time.Now()

	for {
		select {
		case <-deadline:
			goto finish
		case <-reportTicker.C:
			elapsed := time.Since(startTime).Truncate(time.Second)
			ws := walRec.stats()
			bs := bboltRec.stats()
			fmt.Printf("[%v] WAL: count=%d P99=%v max=%v >10ms=%d | bbolt: count=%d P99=%v max=%v >10ms=%d | bgOps=%d\n",
				elapsed, ws.count, ws.p99, ws.max, ws.slow10ms,
				bs.count, bs.p99, bs.max, bs.slow10ms, bgOps.Load())
		}
	}

finish:
	fmt.Println()
	fmt.Println("--- Stopping workload ---")
	close(done)
	wg.Wait()

	xfsAfter, _ := readXFSStats()

	fmt.Println()
	fmt.Println("==========================================================================")
	fmt.Println("  RESULTS")
	fmt.Println("==========================================================================")
	fmt.Println()

	ws := walRec.stats()
	bs := bboltRec.stats()

	fmt.Println("--- WAL fdatasync (latency-critical, like etcd WAL) ---")
	fmt.Println(ws.String())
	fmt.Println()
	fmt.Println("  Distribution:")
	fmt.Println(walRec.histogram())
	fmt.Println()

	fmt.Println("--- bbolt fdatasync (background commits, like etcd bbolt) ---")
	fmt.Println(bs.String())
	fmt.Println()

	fmt.Println("--- XFS log statistics (delta) ---")
	dw := xfsAfter.logWrites - xfsBefore.logWrites
	df := xfsAfter.logForce - xfsBefore.logForce
	ds := xfsAfter.logForceSleep - xfsBefore.logForceSleep
	dn := xfsAfter.logNoIclogs - xfsBefore.logNoIclogs
	fmt.Printf("    log_writes:      %d\n", dw)
	fmt.Printf("    log_force:       %d\n", df)
	fmt.Printf("    log_force_sleep: %d\n", ds)
	fmt.Printf("    log_noiclogs:    %d\n", dn)
	if df > 0 {
		fmt.Printf("    sleep/force:     %.1f%%\n", float64(ds)*100/float64(df))
	}
	fmt.Println()

	fmt.Println("--- Regression analysis ---")
	fmt.Println("  The regression is tail-only: the latency distribution shifts into")
	fmt.Println("  higher buckets on 6.12 due to CIL per-CPU aggregation cost at push time.")
	fmt.Println()
	fmt.Printf("  CPUs: %d — regression magnitude scales with CPU count:\n", runtime.NumCPU())
	fmt.Println("    4  CPUs: P99 ~1.2x, >5ms ~2x, 5-10ms bucket ~2x,  10-20ms bucket ~3x")
	fmt.Println("    8+ CPUs: P99 ~2.2x, >5ms ~5x, 10-50ms bucket ~6x  (cluster-density)")
	fmt.Println()
	fmt.Println("  Key indicators of the regression on this run:")
	fmt.Printf("    - WAL P99 crosses 10ms on kernel 6.12: %v\n", ws.p99 > 10*time.Millisecond)
	pctSlow5_el := float64(ws.slow5ms) * 100 / float64(ws.count)
	fmt.Printf("    - WAL >5ms percentage: %.1f%% (expect ~20%% on 5.14, ~50%% on 6.12)\n", pctSlow5_el)
	fmt.Printf("    - noiclogs (log buffer exhaustion): %d (higher on 6.12 = push serialization)\n", dn)
	fmt.Println()
	fmt.Println("  Root cause: three interacting XFS kernel changes (5.15 → 6.0):")
	fmt.Println("    39823d0fac94 — CIL push serialization (prevents pipelined pushes)")
	fmt.Println("    c0fb4765c508 — CIL per-CPU lists (aggregation storms at push time)")
	fmt.Println("    919edbadebe1 — async flush removal (100% force_sleep ratio)")
	fmt.Println()

	os.RemoveAll(*testDir)
}
