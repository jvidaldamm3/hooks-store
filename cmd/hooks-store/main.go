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
	promptsIndex := flag.String("prompts-index", envOrDefault("PROMPTS_INDEX", "hook-prompts"), "MeiliSearch prompts index name (empty to disable)")
	migrate := flag.Bool("migrate", false, "Backfill top-level fields on existing documents and exit")
	flag.Parse()

	// Connect to MeiliSearch — fail fast if unreachable.
	fmt.Printf("Connecting to MeiliSearch at %s...\n", *meiliURL)
	ms, err := store.NewMeiliStore(*meiliURL, *meiliKey, *meiliIndex, *promptsIndex)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer ms.Close()

	if *migrate {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()

		// Handle SIGINT during migration for clean shutdown.
		go func() {
			sig := make(chan os.Signal, 1)
			signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
			defer signal.Stop(sig)
			<-sig
			cancel()
		}()

		fmt.Println("Starting migration...")
		count, err := ms.MigrateDocuments(ctx, 100)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Migration failed: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Migration complete: %d documents processed\n", count)

		fmt.Println("Migrating data_flat format...")
		dfcount, err := ms.MigrateDataFlat(ctx, 100)
		if err != nil {
			fmt.Fprintf(os.Stderr, "data_flat migration failed: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("data_flat migration complete: %d documents processed\n", dfcount)

		fmt.Println("Migrating prompts index...")
		pcount, err := ms.MigratePrompts(ctx, 100)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Prompts migration failed: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Prompts migration complete: %d documents processed\n", pcount)
		os.Exit(0)
	}

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
