// Command zigclient is a throwaway conformance client for the Zig MCP spike.
// It speaks to any MCP stdio server through the same Go SDK the v2 suite uses.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: zigclient BIN ARG...")
		os.Exit(2)
	}
	cmd := exec.Command(os.Args[1], os.Args[2:]...)
	cmd.Stderr = os.Stderr

	client := mcp.NewClient(&mcp.Implementation{Name: "zigclient", Version: "test"}, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cs, err := client.Connect(ctx, &mcp.CommandTransport{Command: cmd}, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		os.Exit(1)
	}
	defer cs.Close()

	tools, err := cs.ListTools(ctx, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "list tools: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("tools=%d", len(tools.Tools))
	for _, t := range tools.Tools {
		fmt.Printf(" %s", t.Name)
	}
	fmt.Println()

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "ping", Arguments: map[string]any{"message": "hi"}})
	if err != nil {
		fmt.Fprintf(os.Stderr, "call ping: %v\n", err)
		os.Exit(1)
	}
	if res.IsError {
		fmt.Fprintln(os.Stderr, "ping returned isError")
		os.Exit(1)
	}
	fmt.Println("ping=ok")
}
