package jsonrpc

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"testing"
)

func TestServerRoundTrip(t *testing.T) {
	var in bytes.Buffer
	id := json.RawMessage(`1`)
	_ = WriteMessage(&in, &Message{ID: &id, Method: "echo", Params: json.RawMessage(`{"text":"čau"}`)})
	unknown := json.RawMessage(`2`)
	_ = WriteMessage(&in, &Message{ID: &unknown, Method: "nope"})

	var out bytes.Buffer
	s := NewServer(&out)
	s.Handle("echo", func(p json.RawMessage) (any, error) {
		var v struct{ Text string }
		if err := json.Unmarshal(p, &v); err != nil {
			return nil, err
		}
		return v, nil
	})
	if err := s.Serve(&in); err != nil {
		t.Fatal(err)
	}

	br := bufio.NewReader(&out)
	got := map[string]*Message{}
	for {
		m, err := ReadMessage(br)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		got[string(*m.ID)] = m
	}
	if r := got["1"]; r == nil || !strings.Contains(string(r.Result), "čau") {
		t.Fatalf("echo response wrong: %+v", r)
	}
	if r := got["2"]; r == nil || r.Error == nil || r.Error.Code != CodeMethodNotFound {
		t.Fatalf("expected method not found: %+v", r)
	}
}
