// Package db implements the database helper (`minoride-server db`).
package db

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"sync"
	"sync/atomic"

	"github.com/novami/minor-ide/server/internal/jsonrpc"
)

type Column struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type Result struct {
	Columns      []Column  `json:"columns"`
	Rows         [][]Value `json:"rows"`
	RowsAffected int64     `json:"rowsAffected"`
}

// Value is a lossless JSON representation of a column value:
// null, number (integers only within ±2^53), string, or {"$bytes": base64} / {"$int": "…"}.
type Value struct{ raw json.RawMessage }

func (v Value) MarshalJSON() ([]byte, error) { return v.raw, nil }

const maxSafeInt = 1 << 53

func Null() Value { return Value{json.RawMessage("null")} }

func Int(i int64) Value {
	if i > maxSafeInt || i < -maxSafeInt {
		return Value{mustJSON(map[string]string{"$int": strconv.FormatInt(i, 10)})}
	}
	return Value{json.RawMessage(strconv.FormatInt(i, 10))}
}

func Float(f float64) Value { return Value{mustJSON(f)} }
func Text(s string) Value   { return Value{mustJSON(s)} }
func Bytes(b []byte) Value {
	return Value{mustJSON(map[string]string{"$bytes": base64.StdEncoding.EncodeToString(b)})}
}

func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

type conn interface {
	Query(sql string, args []any) (*Result, error)
	Close() error
}

// Service holds open connections and registers JSON-RPC methods.
type Service struct {
	mu    sync.Mutex
	conns map[string]conn
	next  atomic.Int64
}

func NewService() *Service { return &Service{conns: map[string]conn{}} }

type ConnectParams struct {
	Driver string `json:"driver"`
	Path   string `json:"path"` // sqlite
}

type QueryParams struct {
	Conn string `json:"conn"`
	SQL  string `json:"sql"`
	Args []any  `json:"args"`
}

func (s *Service) Register(srv *jsonrpc.Server) {
	srv.Handle("ping", func(json.RawMessage) (any, error) { return "pong", nil })
	srv.Handle("connect", func(raw json.RawMessage) (any, error) {
		var p ConnectParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, jsonrpc.Errorf(jsonrpc.CodeInvalidParams, "%v", err)
		}
		c, err := s.open(p)
		if err != nil {
			return nil, err
		}
		id := fmt.Sprintf("c%d", s.next.Add(1))
		s.mu.Lock()
		s.conns[id] = c
		s.mu.Unlock()
		return map[string]string{"conn": id}, nil
	})
	srv.Handle("query", func(raw json.RawMessage) (any, error) {
		var p QueryParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, jsonrpc.Errorf(jsonrpc.CodeInvalidParams, "%v", err)
		}
		c, err := s.get(p.Conn)
		if err != nil {
			return nil, err
		}
		return c.Query(p.SQL, p.Args)
	})
	srv.Handle("disconnect", func(raw json.RawMessage) (any, error) {
		var p struct{ Conn string }
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, jsonrpc.Errorf(jsonrpc.CodeInvalidParams, "%v", err)
		}
		s.mu.Lock()
		c, ok := s.conns[p.Conn]
		delete(s.conns, p.Conn)
		s.mu.Unlock()
		if !ok {
			return nil, jsonrpc.Errorf(jsonrpc.CodeInvalidParams, "unknown connection %q", p.Conn)
		}
		return true, c.Close()
	})
}

func (s *Service) open(p ConnectParams) (conn, error) {
	switch p.Driver {
	case "sqlite":
		if p.Path == "" {
			return nil, jsonrpc.Errorf(jsonrpc.CodeInvalidParams, "sqlite: path is required")
		}
		return openSQLite(p.Path)
	default:
		return nil, jsonrpc.Errorf(jsonrpc.CodeInvalidParams, "unsupported driver %q", p.Driver)
	}
}

func (s *Service) get(id string) (conn, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.conns[id]
	if !ok {
		return nil, jsonrpc.Errorf(jsonrpc.CodeInvalidParams, "unknown connection %q", id)
	}
	return c, nil
}

// CloseAll closes every connection, used on shutdown.
func (s *Service) CloseAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, c := range s.conns {
		_ = c.Close()
		delete(s.conns, id)
	}
}
