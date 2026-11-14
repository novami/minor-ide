package db

/*
#cgo LDFLAGS: -lsqlite3
#include <sqlite3.h>
#include <stdlib.h>

// SQLITE_TRANSIENT is a macro casting -1 to a function pointer, which cgo cannot express.
static int bind_text(sqlite3_stmt *s, int i, const char *v, int n) {
	return sqlite3_bind_text(s, i, v, n, SQLITE_TRANSIENT);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"sync"
	"unsafe"
)

// sqliteConn is a thin binding to the system libsqlite3. All calls are serialized.
type sqliteConn struct {
	mu sync.Mutex
	db *C.sqlite3
}

func openSQLite(path string) (*sqliteConn, error) {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	var db *C.sqlite3
	flags := C.SQLITE_OPEN_READWRITE | C.SQLITE_OPEN_CREATE | C.SQLITE_OPEN_URI | C.SQLITE_OPEN_FULLMUTEX
	if rc := C.sqlite3_open_v2(cpath, &db, C.int(flags), nil); rc != C.SQLITE_OK {
		msg := "unable to open database"
		if db != nil {
			msg = C.GoString(C.sqlite3_errmsg(db))
			C.sqlite3_close_v2(db)
		}
		return nil, fmt.Errorf("sqlite open %q: %s", path, msg)
	}
	return &sqliteConn{db: db}, nil
}

func (c *sqliteConn) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.db == nil {
		return nil
	}
	rc := C.sqlite3_close_v2(c.db)
	c.db = nil
	if rc != C.SQLITE_OK {
		return fmt.Errorf("sqlite close: rc=%d", int(rc))
	}
	return nil
}

func (c *sqliteConn) err() error {
	return errors.New(C.GoString(C.sqlite3_errmsg(c.db)))
}

// Query runs one statement and returns all rows. Paging comes with the real query API.
func (c *sqliteConn) Query(sql string, args []any) (*Result, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.db == nil {
		return nil, errors.New("connection closed")
	}
	csql := C.CString(sql)
	defer C.free(unsafe.Pointer(csql))
	var stmt *C.sqlite3_stmt
	if rc := C.sqlite3_prepare_v2(c.db, csql, -1, &stmt, nil); rc != C.SQLITE_OK {
		return nil, c.err()
	}
	defer C.sqlite3_finalize(stmt)

	for i, a := range args {
		if err := c.bind(stmt, C.int(i+1), a); err != nil {
			return nil, err
		}
	}

	n := int(C.sqlite3_column_count(stmt))
	res := &Result{Columns: make([]Column, n), Rows: [][]Value{}}
	for i := 0; i < n; i++ {
		res.Columns[i] = Column{
			Name: C.GoString(C.sqlite3_column_name(stmt, C.int(i))),
			Type: goStringOrEmpty(C.sqlite3_column_decltype(stmt, C.int(i))),
		}
	}
	for {
		rc := C.sqlite3_step(stmt)
		if rc == C.SQLITE_DONE {
			break
		}
		if rc != C.SQLITE_ROW {
			return nil, c.err()
		}
		row := make([]Value, n)
		for i := 0; i < n; i++ {
			row[i] = columnValue(stmt, C.int(i))
		}
		res.Rows = append(res.Rows, row)
	}
	res.RowsAffected = int64(C.sqlite3_changes(c.db))
	return res, nil
}

func (c *sqliteConn) bind(stmt *C.sqlite3_stmt, i C.int, a any) error {
	var rc C.int
	switch v := a.(type) {
	case nil:
		rc = C.sqlite3_bind_null(stmt, i)
	case float64: // JSON numbers
		if v == float64(int64(v)) {
			rc = C.sqlite3_bind_int64(stmt, i, C.sqlite3_int64(v))
		} else {
			rc = C.sqlite3_bind_double(stmt, i, C.double(v))
		}
	case bool:
		b := 0
		if v {
			b = 1
		}
		rc = C.sqlite3_bind_int64(stmt, i, C.sqlite3_int64(b))
	case string:
		cs := C.CString(v)
		defer C.free(unsafe.Pointer(cs))
		rc = C.bind_text(stmt, i, cs, C.int(len(v)))
	default:
		return fmt.Errorf("unsupported parameter type %T", a)
	}
	if rc != C.SQLITE_OK {
		return c.err()
	}
	return nil
}

func columnValue(stmt *C.sqlite3_stmt, i C.int) Value {
	switch C.sqlite3_column_type(stmt, i) {
	case C.SQLITE_NULL:
		return Null()
	case C.SQLITE_INTEGER:
		return Int(int64(C.sqlite3_column_int64(stmt, i)))
	case C.SQLITE_FLOAT:
		return Float(float64(C.sqlite3_column_double(stmt, i)))
	case C.SQLITE_BLOB:
		p := C.sqlite3_column_blob(stmt, i)
		n := C.sqlite3_column_bytes(stmt, i)
		return Bytes(C.GoBytes(p, n))
	default:
		p := C.sqlite3_column_text(stmt, i)
		n := C.sqlite3_column_bytes(stmt, i)
		return Text(C.GoStringN((*C.char)(unsafe.Pointer(p)), n))
	}
}

func goStringOrEmpty(p *C.char) string {
	if p == nil {
		return ""
	}
	return C.GoString(p)
}
