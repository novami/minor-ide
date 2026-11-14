// Package jsonrpc implements JSON-RPC 2.0 over a byte stream with
// LSP-style Content-Length framing.
package jsonrpc

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/textproto"
	"strconv"
	"strings"
	"sync"
)

// Standard error codes.
const (
	CodeParseError     = -32700
	CodeInvalidRequest = -32600
	CodeMethodNotFound = -32601
	CodeInvalidParams  = -32602
	CodeInternalError  = -32603
)

type Message struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      *json.RawMessage `json:"id,omitempty"`
	Method  string           `json:"method,omitempty"`
	Params  json.RawMessage  `json:"params,omitempty"`
	Result  json.RawMessage  `json:"result,omitempty"`
	Error   *Error           `json:"error,omitempty"`
}

type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return fmt.Sprintf("jsonrpc %d: %s", e.Code, e.Message) }

// Errorf creates an error that is reported to the client with the given code.
func Errorf(code int, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}

// ReadMessage reads one framed message.
func ReadMessage(r *bufio.Reader) (*Message, error) {
	tp := textproto.NewReader(r)
	header, err := tp.ReadMIMEHeader()
	if err != nil {
		return nil, err
	}
	length, err := strconv.Atoi(strings.TrimSpace(header.Get("Content-Length")))
	if err != nil || length < 0 {
		return nil, fmt.Errorf("invalid Content-Length %q", header.Get("Content-Length"))
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}
	var m Message
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, Errorf(CodeParseError, "%v", err)
	}
	return &m, nil
}

// WriteMessage writes one framed message.
func WriteMessage(w io.Writer, m *Message) error {
	m.JSONRPC = "2.0"
	body, err := json.Marshal(m)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(w, "Content-Length: %d\r\n\r\n", len(body)); err != nil {
		return err
	}
	_, err = w.Write(body)
	return err
}

// Handler handles one request or notification. For notifications the result is ignored.
type Handler func(params json.RawMessage) (any, error)

// Server dispatches incoming requests to handlers. Each request runs in its own goroutine.
type Server struct {
	handlers map[string]Handler
	writeMu  sync.Mutex
	w        io.Writer
}

func NewServer(w io.Writer) *Server {
	return &Server{handlers: map[string]Handler{}, w: w}
}

func (s *Server) Handle(method string, h Handler) { s.handlers[method] = h }

// Notify sends a notification to the client.
func (s *Server) Notify(method string, params any) error {
	raw, err := json.Marshal(params)
	if err != nil {
		return err
	}
	return s.write(&Message{Method: method, Params: raw})
}

func (s *Server) write(m *Message) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return WriteMessage(s.w, m)
}

// Serve reads messages until EOF. It returns nil on clean EOF.
func (s *Server) Serve(r io.Reader) error {
	br := bufio.NewReader(r)
	var wg sync.WaitGroup
	defer wg.Wait()
	for {
		m, err := ReadMessage(br)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			var rpcErr *Error
			if errors.As(err, &rpcErr) {
				_ = s.write(&Message{ID: nullID(), Error: rpcErr})
				continue
			}
			return err
		}
		if m.Method == "" {
			continue // responses to server-initiated requests are not used yet
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.dispatch(m)
		}()
	}
}

func (s *Server) dispatch(m *Message) {
	h, ok := s.handlers[m.Method]
	if !ok {
		if m.ID != nil {
			_ = s.write(&Message{ID: m.ID, Error: Errorf(CodeMethodNotFound, "method not found: %s", m.Method)})
		}
		return
	}
	result, err := h(m.Params)
	if m.ID == nil {
		return
	}
	if err != nil {
		var rpcErr *Error
		if !errors.As(err, &rpcErr) {
			rpcErr = &Error{Code: CodeInternalError, Message: err.Error()}
		}
		_ = s.write(&Message{ID: m.ID, Error: rpcErr})
		return
	}
	raw, err := json.Marshal(result)
	if err != nil {
		_ = s.write(&Message{ID: m.ID, Error: Errorf(CodeInternalError, "%v", err)})
		return
	}
	_ = s.write(&Message{ID: m.ID, Result: raw})
}

func nullID() *json.RawMessage {
	raw := json.RawMessage("null")
	return &raw
}
