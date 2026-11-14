package db

import (
	"encoding/json"
	"testing"
)

func TestSQLiteQuery(t *testing.T) {
	c, err := openSQLite(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	for _, q := range []string{
		"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, big INTEGER, data BLOB, score REAL)",
		"INSERT INTO t VALUES (1, 'Žluťoučký', 9007199254740993, x'00ff', 1.5)",
		"INSERT INTO t VALUES (2, NULL, 3, NULL, NULL)",
	} {
		if _, err := c.Query(q, nil); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}

	res, err := c.Query("SELECT id, name, big, data, score FROM t WHERE id >= ? ORDER BY id", []any{float64(1)})
	if err != nil {
		t.Fatal(err)
	}
	got, _ := json.Marshal(res.Rows)
	want := `[[1,"Žluťoučký",{"$int":"9007199254740993"},{"$bytes":"AP8="},1.5],[2,null,3,null,null]]`
	if string(got) != want {
		t.Fatalf("rows\n got %s\nwant %s", got, want)
	}
	if res.Columns[1].Name != "name" || res.Columns[1].Type != "TEXT" {
		t.Fatalf("columns: %+v", res.Columns)
	}

	if _, err := c.Query("SELECT * FROM missing", nil); err == nil {
		t.Fatal("expected error for missing table")
	}
}
