package main

// Dependency spike: official Go MCP SDK on Go 1.27.4, stdio transport.
// Registration: opencode mcp add ztd-spike -- <binary>
// Kept as executable evidence; not part of the product build.

import (
	"context"
	"fmt"
	"os"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type pingInput struct {
	Message string `json:"message" jsonschema:"text to echo"`
}

type pingOutput struct {
	Echo string `json:"echo"`
}

func main() {
	server := mcp.NewServer(&mcp.Implementation{Name: "ztd-spike", Version: "0.0.1"}, nil)
	mcp.AddTool(server, &mcp.Tool{Name: "ping", Description: "Echo one message"},
		func(_ context.Context, _ *mcp.CallToolRequest, in pingInput) (*mcp.CallToolResult, pingOutput, error) {
			return nil, pingOutput{Echo: in.Message}, nil
		})
	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
