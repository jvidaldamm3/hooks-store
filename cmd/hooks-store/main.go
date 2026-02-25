package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"hooks-store/internal/ingest"
	"hooks-store/internal/store"
	"hooks-store/internal/tui"
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

	// Event channel: owned by main, shared between ingest callback and TUI.
	eventCh := make(chan ingest.IngestEvent, 256)
	srv.SetOnIngest(func(evt ingest.IngestEvent) {
		select {
		case eventCh <- evt:
		default: // drop if TUI is slow
		}
	})

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
	listenAddr := fmt.Sprintf("http://localhost:%d", actualPort)

	// Graceful shutdown.
	ctx, cancel := context.WithCancel(context.Background())
	var shutdownOnce sync.Once
	doShutdown := func() {
		cancel()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		httpSrv.Shutdown(shutdownCtx)
		close(eventCh)
	}

	// Signal handler — SIGINT/SIGTERM triggers shutdown.
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		defer signal.Stop(sig)
		select {
		case <-sig:
			shutdownOnce.Do(doShutdown)
		case <-ctx.Done():
		}
	}()

	// Start HTTP server in the background.
	go func() {
		if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	}()

	// Run the TUI — blocks until user quits.
	m := tui.NewModel(tui.Config{
		Version:    version,
		MeiliURL:   *meiliURL,
		MeiliIndex: *meiliIndex,
		ListenAddr: listenAddr,
	}, eventCh, ctx, srv.ErrCount())

	if err := tui.Run(m); err != nil {
		fmt.Fprintf(os.Stderr, "TUI error: %v\n", err)
	}

	shutdownOnce.Do(doShutdown)
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
