// nanostack perf gate.
//
// Spawns ReleaseFast nanostack, drives bucket-level operations through the
// official aws-sdk-go-v2 client, and emits a JSON report comparing every
// PRD §12 metric against its budget. Exits non-zero if any gated metric
// regresses past budget.
//
// Run locally: `zig build bench` (which wraps `bench/run.sh`).
// Run in CI: same.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// -----------------------------------------------------------------------------
// Budget schema (matches bench/budgets.json)

type Metric struct {
	Key        string  `json:"key"`
	Label      string  `json:"label"`
	Unit       string  `json:"unit"`
	Target     float64 `json:"target,omitempty"`
	TargetMin  float64 `json:"target_min,omitempty"`
	Comparison string  `json:"comparison,omitempty"` // "le" (default) or "ge"
	Gate       bool    `json:"gate"`
	How        string  `json:"how,omitempty"`

	Measured *float64 `json:"measured,omitempty"`
	Pass     *bool    `json:"pass,omitempty"`
}

// effectiveTarget returns the budget to compare against. Single-backend
// nanostack only has one storage path; per-backend maps were dropped
// when the in-memory backend was removed.
func (m *Metric) effectiveTarget() (target float64, comparison string, ok bool) {
	if m.Comparison == "ge" {
		if m.TargetMin > 0 {
			return m.TargetMin, "ge", true
		}
		return 0, "ge", false
	}
	if m.Target > 0 {
		return m.Target, "le", true
	}
	return 0, "le", false
}

type Budgets struct {
	SchemaVersion int      `json:"schema_version"`
	Source        string   `json:"source"`
	Notes         []string `json:"notes,omitempty"`
	Backend       string   `json:"backend,omitempty"`
	Metrics       []Metric `json:"metrics"`
	Informational []Metric `json:"informational_metrics,omitempty"`
}

func loadBudgets(path string) (*Budgets, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var b Budgets
	if err := json.Unmarshal(data, &b); err != nil {
		return nil, err
	}
	return &b, nil
}

func recordMetric(metrics []Metric, key string, measured float64) []Metric {
	for i := range metrics {
		if metrics[i].Key != key {
			continue
		}
		v := measured
		metrics[i].Measured = &v
		pass := true
		target, comparison, ok := metrics[i].effectiveTarget()
		if ok {
			if comparison == "ge" {
				pass = v >= target
			} else {
				pass = v <= target
			}
		}
		metrics[i].Pass = &pass
		return metrics
	}
	return metrics
}

func anyGateFailed(b *Budgets) bool {
	for _, m := range b.Metrics {
		if !m.Gate {
			continue
		}
		if m.Pass == nil || !*m.Pass {
			return true
		}
	}
	return false
}

// -----------------------------------------------------------------------------
// Process / measurement helpers

func spawnNanostack(binPath string, port int, extra ...string) (*exec.Cmd, error) {
	args := append([]string{"--port", strconv.Itoa(port)}, extra...)
	cmd := exec.Command(binPath, args...)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return cmd, nil
}

// backendArgs returns the flags to spawn the fs backend with a fresh
// data dir. Mode is retained for forward compatibility with future
// backends; today only "fs" is accepted.
func backendArgs(mode string, tempBase string) ([]string, error) {
	switch mode {
	case "fs", "":
		dir, err := os.MkdirTemp(tempBase, "ns-bench-fs-")
		if err != nil {
			return nil, err
		}
		return []string{"--data-dir", dir}, nil
	default:
		return nil, fmt.Errorf("unknown --backend %q (only fs is supported)", mode)
	}
}

func waitTCP(port int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 25*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
	}
	return fmt.Errorf("nanostack did not bind :%d within %s", port, timeout)
}

func killProcessGroup(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	_, _ = cmd.Process.Wait()
}

// measureColdStart spawns nanostack with `--self-test-ready` `samples` times.
// Returns median wall time in ms (process spawn → clean exit after binding).
// `tempBase` is used to pick a fresh `--data-dir` per probe so we measure
// the cold path consistently.
func measureColdStart(binPath string, port int, samples int, tempBase string) (float64, error) {
	durs := make([]float64, 0, samples)
	for i := 0; i < samples; i++ {
		dir, err := os.MkdirTemp(tempBase, "ns-coldstart-")
		if err != nil {
			return 0, err
		}
		cmd := exec.Command(binPath, "--port", strconv.Itoa(port+i), "--self-test-ready", "--data-dir", dir)
		cmd.Stdout = nil
		cmd.Stderr = nil
		start := time.Now()
		if err := cmd.Run(); err != nil {
			return 0, fmt.Errorf("self-test-ready failed: %w", err)
		}
		durs = append(durs, ms(time.Since(start)))
	}
	return median(durs), nil
}

// measureBinarySize returns size in MB.
func measureBinarySize(binPath string) (float64, error) {
	info, err := os.Stat(binPath)
	if err != nil {
		return 0, err
	}
	return float64(info.Size()) / (1024 * 1024), nil
}

// measureIdleRSS samples VmRSS at 1s intervals for `samples` after a 5s
// warm-up. Returns max sample in MB. Linux only (uses /proc); on macOS we
// fall back to `ps`.
func measureIdleRSS(pid int, samples int) (float64, error) {
	time.Sleep(5 * time.Second)
	var max float64
	for i := 0; i < samples; i++ {
		rss, err := readRSSMB(pid)
		if err != nil {
			return 0, err
		}
		if rss > max {
			max = rss
		}
		time.Sleep(1 * time.Second)
	}
	return max, nil
}

func readRSSMB(pid int) (float64, error) {
	if runtime.GOOS == "linux" {
		data, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
		if err != nil {
			return 0, err
		}
		for _, line := range strings.Split(string(data), "\n") {
			if !strings.HasPrefix(line, "VmRSS:") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) < 2 {
				continue
			}
			kb, err := strconv.ParseFloat(fields[1], 64)
			if err != nil {
				return 0, err
			}
			return kb / 1024, nil
		}
		return 0, errors.New("VmRSS not found in /proc/<pid>/status")
	}
	// macOS / generic fallback via ps.
	out, err := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0, err
	}
	field := strings.TrimSpace(string(out))
	kb, err := strconv.ParseFloat(field, 64)
	if err != nil {
		return 0, err
	}
	return kb / 1024, nil
}

// measureWipeRestart kills `cmd`, respawns nanostack on the same port, and
// returns median time-to-bind in ms across `samples` cycles. Backend args
// are forwarded so we measure the configured storage path. The returned
// final cmd is owned by the caller.
func measureWipeRestart(binPath string, port int, samples int, extra []string) (float64, *exec.Cmd, error) {
	durs := make([]float64, 0, samples)
	var current *exec.Cmd
	for i := 0; i < samples; i++ {
		if current != nil {
			killProcessGroup(current)
			time.Sleep(20 * time.Millisecond)
		}
		start := time.Now()
		cmd, err := spawnNanostack(binPath, port, extra...)
		if err != nil {
			return 0, nil, err
		}
		if err := waitTCP(port, 5*time.Second); err != nil {
			killProcessGroup(cmd)
			return 0, nil, err
		}
		durs = append(durs, ms(time.Since(start)))
		current = cmd
	}
	return median(durs), current, nil
}

// -----------------------------------------------------------------------------
// Latency / throughput via AWS SDK (real signed requests)

func newS3Client(port int) *s3.Client {
	return s3.New(s3.Options{
		Region:       "us-east-1",
		Credentials:  credentials.NewStaticCredentialsProvider("test", "test", ""),
		BaseEndpoint: aws.String(fmt.Sprintf("http://127.0.0.1:%d", port)),
		UsePathStyle: true,
		HTTPClient:   &http.Client{Timeout: 5 * time.Second},
	})
}

func measureLatency(c *s3.Client, bucket string, n int) (p50, p99 float64) {
	durs := make([]float64, 0, n)
	for i := 0; i < n; i++ {
		start := time.Now()
		_, err := c.HeadBucket(context.Background(), &s3.HeadBucketInput{Bucket: aws.String(bucket)})
		if err != nil {
			continue
		}
		durs = append(durs, ms(time.Since(start)))
	}
	return percentile(durs, 50), percentile(durs, 99)
}

func measureListBucketsLatency(c *s3.Client, n int) (p50, p99 float64) {
	durs := make([]float64, 0, n)
	for i := 0; i < n; i++ {
		start := time.Now()
		_, err := c.ListBuckets(context.Background(), &s3.ListBucketsInput{})
		if err != nil {
			continue
		}
		durs = append(durs, ms(time.Since(start)))
	}
	return percentile(durs, 50), percentile(durs, 99)
}

func measureHeadBucketThroughput(c *s3.Client, bucket string, workers int, dur time.Duration) float64 {
	var ops atomic.Int64
	end := time.Now().Add(dur)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for time.Now().Before(end) {
				_, err := c.HeadBucket(context.Background(), &s3.HeadBucketInput{Bucket: aws.String(bucket)})
				if err == nil {
					ops.Add(1)
				}
			}
		}()
	}
	wg.Wait()
	return float64(ops.Load()) / dur.Seconds()
}

// measurePutObjectLatency loops n sequential PutObject calls of a fixed-size
// body, into rotating keys so we exercise the hot path (not the overwrite
// shortcut).
func measurePutObjectLatency(c *s3.Client, bucket string, body []byte, n int) (p50, p99 float64) {
	durs := make([]float64, 0, n)
	for i := 0; i < n; i++ {
		key := fmt.Sprintf("p/%d", i)
		start := time.Now()
		_, err := c.PutObject(context.Background(), &s3.PutObjectInput{
			Bucket: aws.String(bucket),
			Key:    aws.String(key),
			Body:   bytes.NewReader(body),
		})
		if err != nil {
			continue
		}
		durs = append(durs, ms(time.Since(start)))
	}
	return percentile(durs, 50), percentile(durs, 99)
}

// measureGetObjectLatency seeds one key, then loops n GetObject calls
// against it. The body is drained so the timing includes the full read.
func measureGetObjectLatency(c *s3.Client, bucket string, body []byte, n int) float64 {
	const key = "g/probe"
	if _, err := c.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
		Body:   bytes.NewReader(body),
	}); err != nil {
		return math.NaN()
	}
	durs := make([]float64, 0, n)
	for i := 0; i < n; i++ {
		start := time.Now()
		out, err := c.GetObject(context.Background(), &s3.GetObjectInput{
			Bucket: aws.String(bucket),
			Key:    aws.String(key),
		})
		if err != nil {
			continue
		}
		_, _ = bytes.NewBuffer(nil).ReadFrom(out.Body)
		_ = out.Body.Close()
		durs = append(durs, ms(time.Since(start)))
	}
	return percentile(durs, 99)
}

// measureMultipartConcurrent drives one multipart-upload iteration:
// Initiate → fire `parts` goroutines uploading `partSize` bytes in
// parallel → Complete. We record total wall time per iteration over `n`
// iterations and return the (p50, p99). Each iteration uses a fresh key
// so we exercise the cold path. Every part is exactly `partSize` bytes
// (≥ 5 MiB) to satisfy the AWS minimum-part-size rule on non-final parts.
func measureMultipartConcurrent(c *s3.Client, bucket string, parts int, partSize int, n int) (p50, p99 float64) {
	body := bytes.Repeat([]byte{'A'}, partSize)
	durs := make([]float64, 0, n)
	for i := 0; i < n; i++ {
		key := fmt.Sprintf("mp/%d", i)
		start := time.Now()

		init, err := c.CreateMultipartUpload(context.Background(), &s3.CreateMultipartUploadInput{
			Bucket: aws.String(bucket),
			Key:    aws.String(key),
		})
		if err != nil {
			continue
		}
		uploadId := aws.ToString(init.UploadId)

		etags := make([]string, parts)
		errs := make([]error, parts)
		var wg sync.WaitGroup
		for j := 0; j < parts; j++ {
			wg.Add(1)
			go func(pn int) {
				defer wg.Done()
				out, err := c.UploadPart(context.Background(), &s3.UploadPartInput{
					Bucket:     aws.String(bucket),
					Key:        aws.String(key),
					UploadId:   aws.String(uploadId),
					PartNumber: aws.Int32(int32(pn + 1)),
					Body:       bytes.NewReader(body),
				})
				if err != nil {
					errs[pn] = err
					return
				}
				etags[pn] = aws.ToString(out.ETag)
			}(j)
		}
		wg.Wait()

		// Bail on any part error — leaves a stray upload, but the bench
		// harness wipes the data dir between runs.
		failed := false
		for _, e := range errs {
			if e != nil {
				failed = true
				break
			}
		}
		if failed {
			continue
		}

		completed := make([]types.CompletedPart, parts)
		for j := 0; j < parts; j++ {
			completed[j] = types.CompletedPart{
				ETag:       aws.String(etags[j]),
				PartNumber: aws.Int32(int32(j + 1)),
			}
		}
		if _, err := c.CompleteMultipartUpload(context.Background(), &s3.CompleteMultipartUploadInput{
			Bucket:          aws.String(bucket),
			Key:             aws.String(key),
			UploadId:        aws.String(uploadId),
			MultipartUpload: &types.CompletedMultipartUpload{Parts: completed},
		}); err != nil {
			continue
		}
		durs = append(durs, ms(time.Since(start)))
	}
	return percentile(durs, 50), percentile(durs, 99)
}

// measurePutObjectThroughput uses `workers` goroutines for `dur`, each
// PUTting unique keys so we measure write throughput (not overwrite).
func measurePutObjectThroughput(c *s3.Client, bucket string, body []byte, workers int, dur time.Duration) float64 {
	var ops atomic.Int64
	end := time.Now().Add(dur)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			var local int64 = 0
			for time.Now().Before(end) {
				key := fmt.Sprintf("t/%d/%d", worker, local)
				_, err := c.PutObject(context.Background(), &s3.PutObjectInput{
					Bucket: aws.String(bucket),
					Key:    aws.String(key),
					Body:   bytes.NewReader(body),
				})
				if err == nil {
					ops.Add(1)
				}
				local++
			}
		}(w)
	}
	wg.Wait()
	return float64(ops.Load()) / dur.Seconds()
}

// -----------------------------------------------------------------------------
// Stats helpers

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000.0 }

func median(xs []float64) float64 { return percentile(xs, 50) }

func percentile(xs []float64, p float64) float64 {
	if len(xs) == 0 {
		return math.NaN()
	}
	sorted := append([]float64(nil), xs...)
	sort.Float64s(sorted)
	rank := (p / 100.0) * float64(len(sorted)-1)
	lo := int(math.Floor(rank))
	hi := int(math.Ceil(rank))
	if lo == hi {
		return sorted[lo]
	}
	frac := rank - float64(lo)
	return sorted[lo]*(1-frac) + sorted[hi]*frac
}

// -----------------------------------------------------------------------------
// Pretty-print

func printTable(b *Budgets) {
	fmt.Fprintln(os.Stderr)
	fmt.Fprintf(os.Stderr, "nanostack perf gate (backend=%s)\n", b.Backend)
	fmt.Fprintln(os.Stderr, strings.Repeat("-", 92))
	fmt.Fprintf(os.Stderr, "%-30s %12s %14s %10s %s\n", "metric", "measured", "target", "gate", "result")
	fmt.Fprintln(os.Stderr, strings.Repeat("-", 92))
	for _, m := range b.Metrics {
		printRow(m)
	}
	if len(b.Informational) > 0 {
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "informational (no gate)")
		fmt.Fprintln(os.Stderr, strings.Repeat("-", 92))
		for _, m := range b.Informational {
			printRow(m)
		}
	}
}

func printRow(m Metric) {
	measured := "-"
	if m.Measured != nil {
		measured = fmt.Sprintf("%.3f %s", *m.Measured, m.Unit)
	}
	target := "-"
	if t, comp, ok := m.effectiveTarget(); ok {
		if comp == "ge" {
			target = fmt.Sprintf("≥ %.0f %s", t, m.Unit)
		} else {
			target = fmt.Sprintf("≤ %.3f %s", t, m.Unit)
		}
	}
	gate := "no"
	if m.Gate {
		gate = "yes"
	}
	result := "n/a"
	if m.Pass != nil {
		if *m.Pass {
			result = "PASS"
		} else {
			result = "FAIL"
		}
	}
	fmt.Fprintf(os.Stderr, "%-30s %12s %14s %10s %s\n", m.Key, measured, target, gate, result)
}

// -----------------------------------------------------------------------------
// Main

func main() {
	binPath := flag.String("bin", "zig-out/bin/nanostack", "path to ReleaseFast nanostack binary")
	budgetsPath := flag.String("budgets", "bench/budgets.json", "path to budgets JSON")
	outPath := flag.String("out", "", "if set, write JSON to this path (default stdout)")
	port := flag.Int("port", 14990, "base port for the bench")
	backend := flag.String("backend", "fs", "storage backend (only fs is supported)")
	flag.Parse()

	b, err := loadBudgets(*budgetsPath)
	if err != nil {
		die("load budgets: %v", err)
	}
	b.Backend = *backend

	tempBase := os.Getenv("RUNNER_TEMP")
	if tempBase == "" {
		tempBase = filepath.Join(os.TempDir(), "nanostack-bench")
		_ = os.MkdirAll(tempBase, 0o755)
	}
	extraArgs, err := backendArgs(*backend, tempBase)
	if err != nil {
		die("backend: %v", err)
	}

	// 1. Binary size (no process needed).
	if size, err := measureBinarySize(*binPath); err != nil {
		die("binary size: %v", err)
	} else {
		b.Metrics = recordMetric(b.Metrics, "binary_size_mb", size)
	}

	// 2. Cold start — `--self-test-ready` binds + exits. Uses a fresh
	//    per-probe `--data-dir` so cold-path costs are realistic.
	if cs, err := measureColdStart(*binPath, *port+10, 5, tempBase); err != nil {
		die("cold start: %v", err)
	} else {
		b.Metrics = recordMetric(b.Metrics, "cold_start_ms", cs)
	}

	// 3. Spawn a long-lived nanostack for idle-RSS + latency + throughput
	//    on the configured backend.
	live, err := spawnNanostack(*binPath, *port, extraArgs...)
	if err != nil {
		die("spawn: %v", err)
	}
	defer killProcessGroup(live)
	if err := waitTCP(*port, 5*time.Second); err != nil {
		die("ready wait: %v", err)
	}

	client := newS3Client(*port)
	bucket := "bench-bucket"
	if _, err := client.CreateBucket(context.Background(), &s3.CreateBucketInput{Bucket: aws.String(bucket)}); err != nil {
		die("seed bucket: %v", err)
	}

	// 4. Idle RSS (samples while the process is otherwise idle).
	if rss, err := measureIdleRSS(live.Process.Pid, 3); err != nil {
		die("idle rss: %v", err)
	} else {
		b.Metrics = recordMetric(b.Metrics, "idle_rss_mb", rss)
	}

	// 5. Informational bucket-op latency / throughput.
	hbP50, hbP99 := measureLatency(client, bucket, 10_000)
	b.Informational = recordMetric(b.Informational, "head_bucket_p50_ms", hbP50)
	b.Informational = recordMetric(b.Informational, "head_bucket_p99_ms", hbP99)

	_, lbP99 := measureListBucketsLatency(client, 1000)
	b.Informational = recordMetric(b.Informational, "list_buckets_p99_ms", lbP99)

	rps := measureHeadBucketThroughput(client, bucket, 4, 5*time.Second)
	b.Informational = recordMetric(b.Informational, "head_bucket_throughput_rps", rps)

	// 5b. Object-op latency + throughput against a 1 KiB payload (PRD §12
	//     uses this size for the budget).
	body := bytes.Repeat([]byte{'x'}, 1024)
	poP50, poP99 := measurePutObjectLatency(client, bucket, body, 10_000)
	b.Metrics = recordMetric(b.Metrics, "put_object_p50_ms", poP50)
	b.Metrics = recordMetric(b.Metrics, "put_object_p99_ms", poP99)

	goP99 := measureGetObjectLatency(client, bucket, body, 10_000)
	b.Metrics = recordMetric(b.Metrics, "get_object_p99_ms", goP99)

	// PRD §12 calibrates against `wrk`/`bombardier` levels of concurrency,
	// not the four-worker pattern we use for HeadBucket. We push to 32
	// goroutines so the throughput number reflects "what an open-loop
	// load tester sees", which is what the budget is measuring.
	poRps := measurePutObjectThroughput(client, bucket, body, 32, 5*time.Second)
	b.Metrics = recordMetric(b.Metrics, "put_object_throughput_rps", poRps)

	// 5c. Multipart upload — 5 parts × 5 MiB each uploaded concurrently,
	//     then CompleteMultipartUpload. PRD M6 exit criterion. 20 iterations
	//     gives a stable enough p99 to gate on.
	mpP50, mpP99 := measureMultipartConcurrent(client, bucket, 5, 5*1024*1024, 20)
	b.Informational = recordMetric(b.Informational, "multipart_5x5mib_p50_ms", mpP50)
	b.Metrics = recordMetric(b.Metrics, "multipart_5x5mib_p99_ms", mpP99)

	// 6. Wipe-restart — kill the live process, respawn 5x on the same
	//    port + backend. fs has to scan the directory tree to rebuild
	//    the key index, so this metric exercises both code paths.
	killProcessGroup(live)
	live = nil
	if wr, finalCmd, err := measureWipeRestart(*binPath, *port, 5, extraArgs); err != nil {
		die("wipe-restart: %v", err)
	} else {
		b.Metrics = recordMetric(b.Metrics, "wipe_restart_ms", wr)
		killProcessGroup(finalCmd)
	}

	// 7. Emit JSON.
	out, err := json.MarshalIndent(b, "", "  ")
	if err != nil {
		die("marshal: %v", err)
	}
	if *outPath != "" {
		if err := os.WriteFile(*outPath, out, 0o644); err != nil {
			die("write: %v", err)
		}
	} else {
		os.Stdout.Write(out)
		os.Stdout.Write([]byte("\n"))
	}

	// 8. Pretty table to stderr + exit code.
	printTable(b)
	if anyGateFailed(b) {
		fmt.Fprintln(os.Stderr, "\nGATE FAILED")
		os.Exit(1)
	}
	fmt.Fprintln(os.Stderr, "\nall gated metrics within budget")
}

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "bench: "+format+"\n", a...)
	os.Exit(2)
}
