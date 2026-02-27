package store

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/meilisearch/meilisearch-go"
)

// MeiliStore implements EventStore using MeiliSearch as the backend.
// It is safe for concurrent use — the underlying SDK client is thread-safe.
type MeiliStore struct {
	client       meilisearch.ServiceManager
	index        meilisearch.IndexManager
	indexPrompts meilisearch.IndexManager // nil if prompts index disabled
}

// NewMeiliStore creates a MeiliStore connected to the given MeiliSearch instance.
// It verifies connectivity with a health check and ensures the target index exists
// with the correct settings (searchable, filterable, sortable attributes).
// Waits for each settings task to complete before returning.
// Returns an error if MeiliSearch is unreachable or index setup fails.
func NewMeiliStore(endpoint, apiKey, indexName, promptsIndexName string) (*MeiliStore, error) {
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
	// We wait for each task to ensure settings are applied before returning,
	// which is required for migration to work correctly.
	taskInfo, err := index.UpdateSearchableAttributes(&[]string{
		"hook_type",
		"tool_name",
		"session_id",
		"prompt",
		"error_message",
		"data_flat",
	})
	if err != nil {
		return nil, fmt.Errorf("update searchable attributes: %w", err)
	}
	if err := waitForSettingsTask(client, taskInfo, "searchable attributes"); err != nil {
		return nil, err
	}

	// FilterableAttributes uses []interface{} per the SDK's API.
	filterAttrs := []interface{}{
		"hook_type",
		"session_id",
		"tool_name",
		"timestamp_unix",
		"has_claude_md",
		"cost_usd",
		"project_dir",
		"permission_mode",
		"file_path",
		"cwd",
	}
	taskInfo, err = index.UpdateFilterableAttributes(&filterAttrs)
	if err != nil {
		return nil, fmt.Errorf("update filterable attributes: %w", err)
	}
	if err := waitForSettingsTask(client, taskInfo, "filterable attributes"); err != nil {
		return nil, err
	}

	taskInfo, err = index.UpdateSortableAttributes(&[]string{
		"timestamp_unix",
		"cost_usd",
		"input_tokens",
		"output_tokens",
	})
	if err != nil {
		return nil, fmt.Errorf("update sortable attributes: %w", err)
	}
	if err := waitForSettingsTask(client, taskInfo, "sortable attributes"); err != nil {
		return nil, err
	}

	taskInfo, err = index.UpdatePagination(&meilisearch.Pagination{
		MaxTotalHits: 10000,
	})
	if err != nil {
		return nil, fmt.Errorf("update pagination: %w", err)
	}
	if err := waitForSettingsTask(client, taskInfo, "pagination"); err != nil {
		return nil, err
	}

	taskInfo, err = index.UpdateFaceting(&meilisearch.Faceting{
		MaxValuesPerFacet: 500,
	})
	if err != nil {
		return nil, fmt.Errorf("update faceting: %w", err)
	}
	if err := waitForSettingsTask(client, taskInfo, "faceting"); err != nil {
		return nil, err
	}

	var indexPrompts meilisearch.IndexManager
	if promptsIndexName != "" {
		indexPrompts, err = setupPromptsIndex(client, promptsIndexName)
		if err != nil {
			return nil, fmt.Errorf("prompts index: %w", err)
		}
	}

	return &MeiliStore{
		client:       client,
		index:        index,
		indexPrompts: indexPrompts,
	}, nil
}

// waitForSettingsTask waits for a settings update task to complete.
func waitForSettingsTask(client meilisearch.ServiceManager, taskInfo *meilisearch.TaskInfo, name string) error {
	task, err := client.WaitForTask(taskInfo.TaskUID, 500*time.Millisecond)
	if err != nil {
		return fmt.Errorf("wait for %s: %w", name, err)
	}
	if task.Status == meilisearch.TaskStatusFailed {
		return fmt.Errorf("%s task failed: %s", name, task.Error.Message)
	}
	return nil
}

// setupPromptsIndex creates and configures the dedicated prompts index
// with prompt-optimized settings. Follows the same waitForSettingsTask
// pattern as NewMeiliStore.
func setupPromptsIndex(client meilisearch.ServiceManager, indexName string) (meilisearch.IndexManager, error) {
	_, err := client.CreateIndex(&meilisearch.IndexConfig{
		Uid:        indexName,
		PrimaryKey: "id",
	})
	if err != nil {
		return nil, fmt.Errorf("create index %q: %w", indexName, err)
	}
	index := client.Index(indexName)

	// Searchable: prompt is the primary field — no data_flat noise.
	taskInfo, err := index.UpdateSearchableAttributes(&[]string{
		"prompt",
		"session_id",
	})
	if err != nil {
		return nil, fmt.Errorf("update searchable attributes: %w", err)
	}
	if err := waitForSettingsTask(client, taskInfo, "searchable attributes"); err != nil {
		return nil, err
	}

	filterAttrs := []interface{}{
		"session_id", "timestamp_unix", "project_dir",
		"permission_mode", "has_claude_md", "cwd", "prompt_length",
	}
	taskInfo, err = index.UpdateFilterableAttributes(&filterAttrs)
	if err != nil {
		return nil, fmt.Errorf("update filterable attributes: %w", err)
	}
	if err := waitForSettingsTask(client, taskInfo, "filterable attributes"); err != nil {
		return nil, err
	}

	taskInfo, err = index.UpdateSortableAttributes(&[]string{
		"timestamp_unix", "prompt_length",
	})
	if err != nil {
		return nil, fmt.Errorf("update sortable attributes: %w", err)
	}
	if err := waitForSettingsTask(client, taskInfo, "sortable attributes"); err != nil {
		return nil, err
	}

	taskInfo, err = index.UpdatePagination(&meilisearch.Pagination{
		MaxTotalHits: 10000,
	})
	if err != nil {
		return nil, fmt.Errorf("update pagination: %w", err)
	}
	if err := waitForSettingsTask(client, taskInfo, "pagination"); err != nil {
		return nil, err
	}

	taskInfo, err = index.UpdateFaceting(&meilisearch.Faceting{
		MaxValuesPerFacet: 500,
	})
	if err != nil {
		return nil, fmt.Errorf("update faceting: %w", err)
	}
	if err := waitForSettingsTask(client, taskInfo, "faceting"); err != nil {
		return nil, err
	}

	return index, nil
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

	// Dual-write UserPromptSubmit events to the dedicated prompts index.
	if s.indexPrompts != nil && doc.HookType == "UserPromptSubmit" {
		promptDoc := DocumentToPromptDocument(doc)
		if _, err := s.indexPrompts.AddDocumentsWithContext(ctx, []PromptDocument{promptDoc}, &meilisearch.DocumentOptions{
			PrimaryKey: &pk,
		}); err != nil {
			fmt.Fprintf(os.Stderr, "warning: prompts index write failed for %s: %v\n", doc.ID, err)
		}
	}

	return nil
}

// MigrateDocuments backfills top-level fields on all existing documents.
// Reads documents in pages of batchSize, extracts fields from the nested
// data map, and sends partial updates via UpdateDocuments (HTTP PUT merge).
// Returns (migrated count, error).
func (s *MeiliStore) MigrateDocuments(ctx context.Context, batchSize int) (int, error) {
	offset := int64(0)
	total := 0

	for {
		if ctx.Err() != nil {
			return total, ctx.Err()
		}

		var result meilisearch.DocumentsResult
		err := s.index.GetDocumentsWithContext(ctx, &meilisearch.DocumentsQuery{
			Offset: offset,
			Limit:  int64(batchSize),
			Fields: []string{"id", "data"},
		}, &result)
		if err != nil {
			return total, fmt.Errorf("get documents at offset %d: %w", offset, err)
		}

		if len(result.Results) == 0 {
			break
		}

		var updates []map[string]interface{}
		for _, hit := range result.Results {
			partial, err := extractMigrationFields(hit)
			if err != nil {
				continue // skip unparseable documents
			}
			if len(partial) > 1 { // more than just "id"
				updates = append(updates, partial)
			}
		}

		if len(updates) > 0 {
			taskInfo, err := s.index.UpdateDocuments(updates, nil)
			if err != nil {
				return total, fmt.Errorf("update documents at offset %d: %w", offset, err)
			}
			task, err := s.client.WaitForTask(taskInfo.TaskUID, 500*time.Millisecond)
			if err != nil {
				return total, fmt.Errorf("wait for update task at offset %d: %w", offset, err)
			}
			if task.Status == meilisearch.TaskStatusFailed {
				return total, fmt.Errorf("update task failed at offset %d: %s", offset, task.Error.Message)
			}
		}

		total += len(result.Results)
		fmt.Printf("Migrated %d/%d documents\n", total, result.Total)
		offset += int64(batchSize)

		if offset >= result.Total {
			break
		}
	}

	return total, nil
}

// extractMigrationFields extracts top-level fields from a raw MeiliSearch hit.
// Returns a partial document map suitable for UpdateDocuments (PUT merge).
func extractMigrationFields(hit meilisearch.Hit) (map[string]interface{}, error) {
	// Extract the document ID.
	idRaw, ok := hit["id"]
	if !ok {
		return nil, fmt.Errorf("document missing id field")
	}
	var id string
	if err := json.Unmarshal(idRaw, &id); err != nil {
		return nil, fmt.Errorf("unmarshal id: %w", err)
	}

	partial := map[string]interface{}{"id": id}

	// Extract the data map.
	dataRaw, ok := hit["data"]
	if !ok {
		return partial, nil
	}
	var data map[string]interface{}
	if err := json.Unmarshal(dataRaw, &data); err != nil {
		return partial, nil // data not a map, skip extraction
	}

	// Use the same extraction logic as transform.go
	if p, ok := extractString(data, "prompt"); ok {
		partial["prompt"] = p
	}
	if ti, ok := extractNestedMap(data, "tool_input"); ok {
		if fp, ok := extractString(ti, "file_path"); ok {
			partial["file_path"] = fp
		}
	}
	if em, ok := extractString(data, "error"); ok {
		partial["error_message"] = em
	}
	if pm, ok := extractString(data, "permission_mode"); ok {
		partial["permission_mode"] = pm
	}
	if monitor, ok := extractNestedMap(data, "_monitor"); ok {
		if pd, ok := extractString(monitor, "project_dir"); ok {
			partial["project_dir"] = pd
		}
		if hasMD, ok := extractBool(monitor, "has_claude_md"); ok {
			partial["has_claude_md"] = hasMD
		}
	}
	if cwd, ok := extractString(data, "cwd"); ok {
		partial["cwd"] = cwd
	}

	return partial, nil
}

// MigrateDataFlat rewrites the data_flat field on all existing documents
// using values-only extraction. Reads documents in pages of batchSize,
// extracts string leaf values from the data map, and sends partial updates.
// Idempotent: running twice produces functionally identical search behavior.
// Returns (processed count, error).
func (s *MeiliStore) MigrateDataFlat(ctx context.Context, batchSize int) (int, error) {
	offset := int64(0)
	total := 0

	for {
		if ctx.Err() != nil {
			return total, ctx.Err()
		}

		var result meilisearch.DocumentsResult
		err := s.index.GetDocumentsWithContext(ctx, &meilisearch.DocumentsQuery{
			Offset: offset,
			Limit:  int64(batchSize),
			Fields: []string{"id", "data"},
		}, &result)
		if err != nil {
			return total, fmt.Errorf("get documents at offset %d: %w", offset, err)
		}

		if len(result.Results) == 0 {
			break
		}

		var updates []map[string]interface{}
		for _, hit := range result.Results {
			idRaw, ok := hit["id"]
			if !ok {
				continue
			}
			var id string
			if err := json.Unmarshal(idRaw, &id); err != nil {
				continue
			}

			var dataFlat string
			if dataRaw, ok := hit["data"]; ok {
				var data map[string]interface{}
				if err := json.Unmarshal(dataRaw, &data); err == nil {
					dataFlat = extractStringValues(data)
				}
			}

			updates = append(updates, map[string]interface{}{
				"id":        id,
				"data_flat": dataFlat,
			})
		}

		if len(updates) > 0 {
			taskInfo, err := s.index.UpdateDocuments(updates, nil)
			if err != nil {
				return total, fmt.Errorf("update data_flat at offset %d: %w", offset, err)
			}
			task, err := s.client.WaitForTask(taskInfo.TaskUID, 500*time.Millisecond)
			if err != nil {
				return total, fmt.Errorf("wait for data_flat task at offset %d: %w", offset, err)
			}
			if task.Status == meilisearch.TaskStatusFailed {
				return total, fmt.Errorf("data_flat task failed at offset %d: %s", offset, task.Error.Message)
			}
		}

		total += len(result.Results)
		fmt.Printf("data_flat: migrated %d/%d documents\n", total, result.Total)
		offset += int64(batchSize)

		if offset >= result.Total {
			break
		}
	}

	return total, nil
}

// MigratePrompts reads all documents from the main index, filters for
// UserPromptSubmit events client-side, converts them to PromptDocuments,
// and indexes them into the dedicated prompts index in batches.
// Prerequisite: MigrateDocuments must run first so top-level fields are backfilled.
// Returns early with (0, nil) if the prompts index is disabled.
func (s *MeiliStore) MigratePrompts(ctx context.Context, batchSize int) (int, error) {
	if s.indexPrompts == nil {
		return 0, nil
	}

	offset := int64(0)
	total := 0

	for {
		if ctx.Err() != nil {
			return total, ctx.Err()
		}

		var result meilisearch.DocumentsResult
		err := s.index.GetDocumentsWithContext(ctx, &meilisearch.DocumentsQuery{
			Offset: offset,
			Limit:  int64(batchSize),
			Fields: []string{"id", "hook_type", "timestamp", "timestamp_unix",
				"session_id", "prompt", "cwd", "project_dir", "permission_mode", "has_claude_md"},
		}, &result)
		if err != nil {
			return total, fmt.Errorf("get documents at offset %d: %w", offset, err)
		}

		if len(result.Results) == 0 {
			break
		}

		var prompts []PromptDocument
		for _, hit := range result.Results {
			pdoc, err := extractPromptMigrationFields(hit)
			if err != nil || pdoc == nil {
				continue
			}
			prompts = append(prompts, *pdoc)
		}

		if len(prompts) > 0 {
			pk := "id"
			taskInfo, err := s.indexPrompts.AddDocuments(prompts, &meilisearch.DocumentOptions{
				PrimaryKey: &pk,
			})
			if err != nil {
				return total, fmt.Errorf("add prompts at offset %d: %w", offset, err)
			}
			task, err := s.client.WaitForTask(taskInfo.TaskUID, 500*time.Millisecond)
			if err != nil {
				return total, fmt.Errorf("wait for prompts task at offset %d: %w", offset, err)
			}
			if task.Status == meilisearch.TaskStatusFailed {
				return total, fmt.Errorf("prompts task failed at offset %d: %s", offset, task.Error.Message)
			}
		}

		total += len(prompts)
		fmt.Printf("Prompts: migrated %d so far (scanned %d/%d)\n",
			total, offset+int64(len(result.Results)), result.Total)
		offset += int64(batchSize)

		if offset >= result.Total {
			break
		}
	}

	return total, nil
}

// extractPromptMigrationFields extracts a PromptDocument from a raw
// MeiliSearch hit. Returns (nil, nil) if the document is not a UserPromptSubmit.
func extractPromptMigrationFields(hit meilisearch.Hit) (*PromptDocument, error) {
	// Check hook_type — skip non-prompt events.
	htRaw, ok := hit["hook_type"]
	if !ok {
		return nil, nil
	}
	var hookType string
	if err := json.Unmarshal(htRaw, &hookType); err != nil {
		return nil, fmt.Errorf("unmarshal hook_type: %w", err)
	}
	if hookType != "UserPromptSubmit" {
		return nil, nil
	}

	pdoc := PromptDocument{HookType: hookType}

	if raw, ok := hit["id"]; ok {
		json.Unmarshal(raw, &pdoc.ID)
	}
	if raw, ok := hit["timestamp"]; ok {
		json.Unmarshal(raw, &pdoc.Timestamp)
	}
	if raw, ok := hit["timestamp_unix"]; ok {
		json.Unmarshal(raw, &pdoc.TimestampUnix)
	}
	if raw, ok := hit["session_id"]; ok {
		json.Unmarshal(raw, &pdoc.SessionID)
	}
	if raw, ok := hit["prompt"]; ok {
		json.Unmarshal(raw, &pdoc.Prompt)
	}
	if raw, ok := hit["cwd"]; ok {
		json.Unmarshal(raw, &pdoc.Cwd)
	}
	if raw, ok := hit["project_dir"]; ok {
		json.Unmarshal(raw, &pdoc.ProjectDir)
	}
	if raw, ok := hit["permission_mode"]; ok {
		json.Unmarshal(raw, &pdoc.PermissionMode)
	}
	if raw, ok := hit["has_claude_md"]; ok {
		json.Unmarshal(raw, &pdoc.HasClaudeMD)
	}

	pdoc.PromptLength = len(pdoc.Prompt)

	return &pdoc, nil
}

// Close is a no-op for MeiliStore — the SDK's HTTP client has no persistent
// resources that need explicit cleanup.
func (s *MeiliStore) Close() error {
	return nil
}
