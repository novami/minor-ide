// Command minoride-server hosts the MinorIDE helper services.
//
//	minoride-server db              database helper over stdio (JSON-RPC)
//	minoride-server phpscan <dir>   PHP declaration scan benchmark (spike)
//	minoride-server version
package main

import (
	"fmt"
	"os"

	"github.com/novami/minor-ide/server/internal/db"
	"github.com/novami/minor-ide/server/internal/jsonrpc"
)

var version = "dev"

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "db":
		svc := db.NewService()
		srv := jsonrpc.NewServer(os.Stdout)
		svc.Register(srv)
		err = srv.Serve(os.Stdin)
		svc.CloseAll()
	case "phpscan":
		err = runPHPScan(os.Args[2:])
	case "version":
		fmt.Println(version)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "minoride-server:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: minoride-server db | phpscan <dir> | version")
	os.Exit(2)
}
