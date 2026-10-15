// Sift engine C ABI (implemented in core/src/ffi.rs).
#ifndef SIFT_CORE_H
#define SIFT_CORE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct SiftEngine SiftEngine;
typedef struct SiftResults SiftResults;

enum { SIFT_OK = 0, SIFT_CANCELLED = 1, SIFT_ERROR = 2 };
// Engine states.
enum { SIFT_STARTING = 0, SIFT_LOADING = 1, SIFT_SCANNING = 2, SIFT_UPDATING = 3, SIFT_READY = 4, SIFT_STOPPED = 5, SIFT_REBUILD_REQUIRED = 6 };
// Sort keys.
enum { SIFT_SORT_NAME = 0, SIFT_SORT_PATH = 1, SIFT_SORT_SIZE = 2, SIFT_SORT_MODIFIED = 3, SIFT_SORT_CREATED = 4 };

typedef struct {
  uint8_t state;
  bool dirty;
  uint64_t files;
  uint64_t events;
  uint64_t rescans;
  uint64_t flushes;
  uint64_t last_flush;
} SiftStatus;

typedef struct {
  char *path;      // owned by the row; free with sift_rows_free
  int64_t size;    // -1 when unknown
  uint32_t mtime;  // unix seconds, 0 = unknown
  uint32_t ctime;
  uint8_t kind;    // 0 file, 1 dir, 2 symlink, 3 unknown
  uint8_t state;   // 0 metadata known, 1 not fetched, 2 inaccessible
} SiftRow;

SiftEngine *sift_engine_start(const char *support_dir);
void sift_engine_shutdown(SiftEngine *engine);
void sift_engine_status(const SiftEngine *engine, SiftStatus *out);
void sift_engine_rescan(const SiftEngine *engine);
// Rich status and runtime controls use the same Service path as the CLI socket.
char *sift_engine_details(const SiftEngine *engine);
char *sift_remote_status(const char *support_dir);
char *sift_engine_control(const SiftEngine *engine, const char *json);
char *sift_results_locate(const SiftEngine *engine, const SiftResults *results, const char *paths_json);

SiftResults *sift_search(const SiftEngine *engine, const char *query, const char *directory,
                         bool case_insensitive, int32_t *code, char **error);
// Automatic refresh: same results/cancellation, does not defer idle repair/saving.
SiftResults *sift_search_refresh(const SiftEngine *engine, const char *query, const char *directory,
                                bool case_insensitive, int32_t *code, char **error);
uint64_t sift_results_len(const SiftResults *results);
// Search time on the index thread, excluding queueing and index loading.
uint64_t sift_results_micros(const SiftResults *results);
char *sift_results_highlights(const SiftResults *results);
// Actual fallback query, or NULL for a strict search. Free with sift_string_free.
char *sift_results_loosened(const SiftResults *results);
bool sift_results_sort(const SiftEngine *engine, SiftResults *results, uint8_t key, bool descending);
uint64_t sift_results_rows(const SiftEngine *engine, const SiftResults *results, uint64_t start,
                           uint64_t count, SiftRow *out);
void sift_rows_free(SiftRow *rows, uint64_t count);
void sift_results_free(SiftResults *results);

char *sift_config_json(const SiftEngine *engine);
// Same settings-change path as `sift config set` (normalize, save, re-index when changed).
bool sift_config_update(SiftEngine *engine, const char *json, char **error);
void sift_string_free(char *s);

// Full Disk Access probe shared with `sift status` (TCC judges the calling process).
bool sift_full_disk_access(void);
// `probe` returns SMAppService.mainApp.status.rawValue; called on the CLI socket thread.
typedef int32_t (*SiftLoginItemProbe)(void);
void sift_engine_set_login_item_probe(const SiftEngine *engine, SiftLoginItemProbe probe);

// `sift trash`, `sift hotkey …`, `sift login-item …`: the app answers one JSON request with one JSON
// reply, a malloc'ed C string (strdup) that the core frees. Called on the request's socket thread.
typedef char *(*SiftAppActionHandler)(const char *request);
void sift_engine_set_action_handler(const SiftEngine *engine, SiftAppActionHandler handler);

#endif
