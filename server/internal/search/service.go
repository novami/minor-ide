package search

import (
	"context"
	"encoding/json"
	"sync"

	"github.com/novami/minor-ide/server/internal/jsonrpc"
)

// Service exposes searches over JSON-RPC:
//
//	search {id, root, query, regex, caseSensitive, wholeWord, skip, maxMatches} → Summary
//	  while running: notifications "search/file" {id, path, matches}
//	cancel {id}
type Service struct {
	mu      sync.Mutex
	running map[int]context.CancelFunc
}

func NewService() *Service { return &Service{running: map[int]context.CancelFunc{}} }

type startParams struct {
	ID int `json:"id"`
	Options
}

type fileNotification struct {
	ID int `json:"id"`
	FileResult
}

func (s *Service) Register(srv *jsonrpc.Server) {
	srv.Handle("search", func(raw json.RawMessage) (any, error) {
		var p startParams
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, jsonrpc.Errorf(jsonrpc.CodeInvalidParams, "%v", err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		s.mu.Lock()
		s.running[p.ID] = cancel
		s.mu.Unlock()
		defer func() {
			s.mu.Lock()
			delete(s.running, p.ID)
			s.mu.Unlock()
			cancel()
		}()
		summary, err := Run(ctx, p.Options, func(r FileResult) {
			_ = srv.Notify("search/file", fileNotification{ID: p.ID, FileResult: r})
		})
		if err != nil {
			return nil, jsonrpc.Errorf(jsonrpc.CodeInvalidParams, "%v", err)
		}
		return summary, nil
	})
	srv.Handle("cancel", func(raw json.RawMessage) (any, error) {
		var p struct {
			ID int `json:"id"`
		}
		if err := json.Unmarshal(raw, &p); err != nil {
			return nil, jsonrpc.Errorf(jsonrpc.CodeInvalidParams, "%v", err)
		}
		s.mu.Lock()
		if cancel := s.running[p.ID]; cancel != nil {
			cancel()
		}
		s.mu.Unlock()
		return nil, nil
	})
}
