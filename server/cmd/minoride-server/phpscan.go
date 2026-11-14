package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/novami/minor-ide/server/internal/php/scan"
)

// runPHPScan scans all .php files under a directory in parallel and prints timing (spike 0.3).
func runPHPScan(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: minoride-server phpscan <dir>")
	}
	var paths []string
	err := filepath.WalkDir(args[0], func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && (d.Name() == ".git" || d.Name() == "node_modules") {
			return filepath.SkipDir
		}
		if !d.IsDir() && strings.HasSuffix(p, ".php") {
			paths = append(paths, p)
		}
		return nil
	})
	if err != nil {
		return err
	}

	start := time.Now()
	type stat struct {
		bytes      int64
		decls      map[scan.Kind]int
		unbalanced []string
		slowest    time.Duration
		slowPath   string
	}
	jobs := make(chan string)
	workers := runtime.NumCPU()
	stats := make([]stat, workers)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		stats[w].decls = map[scan.Kind]int{}
		wg.Add(1)
		go func(s *stat) {
			defer wg.Done()
			for p := range jobs {
				src, err := os.ReadFile(p)
				if err != nil {
					continue
				}
				t0 := time.Now()
				r := scan.File(src)
				if d := time.Since(t0); d > s.slowest {
					s.slowest, s.slowPath = d, p
				}
				s.bytes += int64(len(src))
				for _, d := range r.Decls {
					s.decls[d.Kind]++
				}
				if r.Unbalanced {
					s.unbalanced = append(s.unbalanced, p)
				}
			}
		}(&stats[w])
	}
	for _, p := range paths {
		jobs <- p
	}
	close(jobs)
	wg.Wait()
	elapsed := time.Since(start)

	total := stat{decls: map[scan.Kind]int{}}
	for _, s := range stats {
		total.bytes += s.bytes
		for k, n := range s.decls {
			total.decls[k] += n
		}
		total.unbalanced = append(total.unbalanced, s.unbalanced...)
		if s.slowest > total.slowest {
			total.slowest, total.slowPath = s.slowest, s.slowPath
		}
	}
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)

	mb := float64(total.bytes) / (1 << 20)
	fmt.Printf("files:      %d (%.1f MB), %d workers\n", len(paths), mb, workers)
	fmt.Printf("time:       %v (%.0f MB/s)\n", elapsed.Round(time.Millisecond), mb/elapsed.Seconds())
	fmt.Printf("slowest:    %v %s\n", total.slowest.Round(time.Microsecond), total.slowPath)
	fmt.Printf("heap:       %.0f MB in use, %.0f MB from OS\n", float64(ms.HeapInuse)/(1<<20), float64(ms.Sys)/(1<<20))
	var kinds []string
	for k, n := range total.decls {
		kinds = append(kinds, fmt.Sprintf("%s=%d", k, n))
	}
	sort.Strings(kinds)
	fmt.Printf("decls:      %s\n", strings.Join(kinds, " "))
	fmt.Printf("unbalanced: %d\n", len(total.unbalanced))
	for i, p := range total.unbalanced {
		if i == 10 {
			fmt.Printf("  …\n")
			break
		}
		fmt.Printf("  %s\n", p)
	}
	return nil
}
