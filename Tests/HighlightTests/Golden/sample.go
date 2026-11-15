// Package demo shows the lexer.
package demo

import (
	"fmt"
	"strings"
)

/* Block comment
   over two lines */
type Point struct {
	X, Y float64 `json:"x"`
}

func (p *Point) Scale(f float64) *Point {
	return &Point{p.X * f, p.Y * 1.5e3}
}

func Map[T any](xs []T, fn func(T) T) []T {
	s := "tab\t\"quote\" žluť"
	r := 'x'
	raw := `first
second`
	n := 0x1F + 07 + 1_000 + 2i
	if xs == nil || len(xs) == 0 && true {
		fmt.Println(strings.ToUpper(s), r, raw, n, iota)
	}
	return xs /* inline */ // trailing
}
