package scan

import (
	"os"
	"path/filepath"
	"testing"
)

// BenchmarkFile scans the PHP files of $PHPSCAN_DIR (e.g. a Composer vendor dir).
func BenchmarkFile(b *testing.B) {
	dir := os.Getenv("PHPSCAN_DIR")
	if dir == "" {
		b.Skip("set PHPSCAN_DIR")
	}
	var files [][]byte
	var size int64
	_ = filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() && filepath.Ext(p) == ".php" {
			if src, err := os.ReadFile(p); err == nil {
				files = append(files, src)
				size += int64(len(src))
			}
		}
		return nil
	})
	b.SetBytes(size)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for _, f := range files {
			File(f)
		}
	}
}
