package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"hooks-store/internal/ingest"
	"hooks-store/internal/store"
)

var version = "dev"

func main() {
	port := flag.String("port", envOrDefault("HOOKS_STORE_PORT", "9800"), "HTTP listen port")
	meiliURL := flag.String("meili-url", envOrDefault("MEILI_URL", "http://localhost:7700"), "MeiliSearch endpoint")
	meiliKey := flag.String("meili-key", envOrDefault("MEILI_KEY", ""), "MeiliSearch API key")
	meiliIndex := flag.String("meili-index", envOrDefault("MEILI_INDEX", "hook-events"), "MeiliSearch index name")
	flag.Parse()

	// Connect to MeiliSearch — fail fast if unreachable.
	fmt.Printf("Connecting to MeiliSearch at %s...\n", *meiliURL)
	ms, err := store.NewMeiliStore(*meiliURL, *meiliKey, *meiliIndex)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer ms.Close()

	srv := ingest.New(ms)

	httpSrv := &http.Server{
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ln, err := net.Listen("tcp", "127.0.0.1:"+*port)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	actualPort := ln.Addr().(*net.TCPAddr).Port

	printBanner(actualPort, *meiliURL, *meiliIndex)

	// Graceful shutdown.
	ctx, cancel := context.WithCancel(context.Background())
	var shutdownOnce sync.Once
	doShutdown := func() {
		cancel()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		httpSrv.Shutdown(shutdownCtx)
	}

	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		defer signal.Stop(sig)
		select {
		case <-sig:
			fmt.Println("\nShutting down...")
			shutdownOnce.Do(doShutdown)
		case <-ctx.Done():
		}
	}()

	if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	shutdownOnce.Do(doShutdown)
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func printBanner(port int, meiliURL, index string) {
	title := fmt.Sprintf("hooks-store %s", version)
	sep := strings.Repeat("─", 50)
	fmt.Println(sep)
	fmt.Printf("  %s\n", title)
	fmt.Println(sep)
	fmt.Printf("  MeiliSearch: %s (index: %s)\n", meiliURL, index)
	fmt.Printf("  Listening:   http://localhost:%d\n", port)
	fmt.Println("  Endpoints:   POST /ingest  GET /health  GET /stats")
	fmt.Println(sep)
	fmt.Println("  Waiting for events...")
	fmt.Println()
}
