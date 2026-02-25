package store

import (
	"context"
	"fmt"

	"github.com/meilisearch/meilisearch-go"
)

// MeiliStore implements EventStore using MeiliSearch as the backend.
// It is safe for concurrent use — the underlying SDK client is thread-safe.
type MeiliStore struct {
	client meilisearch.ServiceManager
	index  meilisearch.IndexManager
}

// NewMeiliStore creates a MeiliStore connected to the given MeiliSearch instance.
// It verifies connectivity with a health check and ensures the target index exists
// with the correct settings (searchable, filterable, sortable attributes).
// Returns an error if MeiliSearch is unreachable or index setup fails.
func NewMeiliStore(endpoint, apiKey, indexName string) (*MeiliStore, error) {
	client := meilisearch.New(endpoint, meilisearch.WithAPIKey(apiKey))

	// Health check — fail fast if MeiliSearch is down.
	if !client.IsHealthy() {
		return nil, fmt.Errorf("meilisearch at %s is not healthy", endpoint)
	}

	// Ensure the index exists. CreateIndex is idempotent — if the index
	// already exists, MeiliSearch returns a task that resolves to success.
	_, err := client.CreateIndex(&meilisearch.IndexConfig{
		Uid:        indexName,
		PrimaryKey: "id",
	})
	if err != nil {
		return nil, fmt.Errorf("create index %q: %w", indexName, err)
	}

	index := client.Index(indexName)

	// Configure index settings for optimal search and filtering.
	// These are idempotent — MeiliSearch merges settings on update.
	_, err = index.UpdateSearchableAttributes(&[]string{
		"hook_type",
		"tool_name",
		"session_id",
		"data_flat",
	})
	if err != nil {
		return nil, fmt.Errorf("update searchable attributes: %w", err)
	}

	// FilterableAttributes uses []interface{} per the SDK's API.
	filterAttrs := []interface{}{
		"hook_type",
		"session_id",
		"tool_name",
		"timestamp_unix",
	}
	_, err = index.UpdateFilterableAttributes(&filterAttrs)
	if err != nil {
		return nil, fmt.Errorf("update filterable attributes: %w", err)
	}

	_, err = index.UpdateSortableAttributes(&[]string{
		"timestamp_unix",
	})
	if err != nil {
		return nil, fmt.Errorf("update sortable attributes: %w", err)
	}

	return &MeiliStore{
		client: client,
		index:  index,
	}, nil
}

// Index persists a Document to MeiliSearch. The SDK's AddDocuments call is
// asynchronous — MeiliSearch returns a task ID immediately and indexes the
// document in the background. This method returns an error only if the
// enqueue request itself fails (e.g., network error, invalid document).
func (s *MeiliStore) Index(ctx context.Context, doc Document) error {
	pk := "id"
	_, err := s.index.AddDocumentsWithContext(ctx, []Document{doc}, &meilisearch.DocumentOptions{
		PrimaryKey: &pk,
	})
	if err != nil {
		return fmt.Errorf("index document %s: %w", doc.ID, err)
	}
	return nil
}

// Close is a no-op for MeiliStore — the SDK's HTTP client has no persistent
// resources that need explicit cleanup.
func (s *MeiliStore) Close() error {
	return nil
}
