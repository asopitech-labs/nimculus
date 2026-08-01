/*
 * Optional in-process Component Model boundary for macOS.
 *
 * This file intentionally does not include Wasmtime headers or link against
 * libwasmtime. The application remains buildable on a clean Apple Silicon
 * machine; when an architecture-compatible Wasmtime library is available,
 * the small C API surface below is resolved with dlopen/dlsym. This mirrors
 * Zed's WasmHost ownership boundary without making the editor's release
 * binary depend on Homebrew paths.
 */

#if defined(__APPLE__)

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <unistd.h>

extern char **environ;

typedef struct wasm_config wasm_config_t;
typedef struct wasm_engine wasm_engine_t;
typedef struct wasmtime_store wasmtime_store_t;
typedef struct wasmtime_context wasmtime_context_t;
typedef struct wasi_config wasi_config_t;
typedef struct wasmtime_component wasmtime_component_t;
typedef struct wasmtime_component_linker wasmtime_component_linker_t;
typedef struct wasmtime_component_linker_instance
    wasmtime_component_linker_instance_t;
typedef struct wasmtime_component_export_index wasmtime_component_export_index_t;
typedef struct wasmtime_error wasmtime_error_t;

typedef struct nimculus_component_job nimculus_component_job_t;

typedef struct {
  size_t size;
  uint8_t *data;
} wasm_byte_vec_t;

typedef struct {
  uint64_t store_id;
  uint32_t private_data;
} wasmtime_component_instance_t;

typedef struct {
  uint64_t store_id;
  uint32_t private_one;
  uint32_t private_two;
} wasmtime_component_func_t;

/* The component callback ABI is kept local because this boundary deliberately
 * does not require Wasmtime headers at build time. These fields mirror the
 * Wasmtime C API layout from wasmtime/component/val.h. Keep this in sync with
 * the runtime ABI before adding a new WIT type. */
typedef struct {
  size_t size;
  uint8_t *data;
} wasm_name_t;

typedef struct wasmtime_component_val wasmtime_component_val_t;
typedef struct wasmtime_component_valrecord_entry
    wasmtime_component_valrecord_entry_t;
typedef struct {
  size_t size;
  wasmtime_component_val_t *data;
} wasmtime_component_vallist_t;

typedef struct {
  size_t size;
  wasmtime_component_valrecord_entry_t *data;
} wasmtime_component_valrecord_t;

typedef struct {
  size_t size;
  wasmtime_component_val_t *data;
} wasmtime_component_valtuple_t;

typedef struct {
  bool is_ok;
  wasmtime_component_val_t *val;
} wasmtime_component_valresult_t;

typedef union {
  int32_t s32;
  uint8_t u8;
  wasm_name_t string;
  wasmtime_component_vallist_t list;
  wasmtime_component_valrecord_t record;
  wasm_name_t enumeration;
  wasmtime_component_valtuple_t tuple;
  wasmtime_component_valresult_t result;
  wasmtime_component_val_t *option;
} wasmtime_component_valunion_t;

struct wasmtime_component_val {
  uint8_t kind;
  wasmtime_component_valunion_t of;
};

struct wasmtime_component_valrecord_entry {
  wasm_name_t name;
  wasmtime_component_val_t val;
};

enum {
  NIMCULUS_COMPONENT_U8 = 2,
  NIMCULUS_COMPONENT_S32 = 5,
  NIMCULUS_COMPONENT_STRING = 12,
  NIMCULUS_COMPONENT_LIST = 13,
  NIMCULUS_COMPONENT_RECORD = 14,
  NIMCULUS_COMPONENT_TUPLE = 15,
  NIMCULUS_COMPONENT_ENUM = 17,
  NIMCULUS_COMPONENT_OPTION = 18,
  NIMCULUS_COMPONENT_RESULT = 19
};

typedef struct {
  const char *extension_root;
  int allow_process;
} nimculus_component_host_state_t;

typedef void *(*fn_wasm_config_new)(void);
typedef void (*fn_wasm_config_delete)(wasm_config_t *);
typedef void (*fn_wasmtime_config_component_set)(wasm_config_t *, bool);
typedef void (*fn_wasmtime_config_fuel_set)(wasm_config_t *, bool);
typedef void (*fn_wasmtime_config_epoch_interruption_set)(wasm_config_t *, bool);
typedef wasm_engine_t *(*fn_wasm_engine_new_with_config)(wasm_config_t *);
typedef void (*fn_wasm_engine_delete)(wasm_engine_t *);
typedef void (*fn_wasmtime_engine_increment_epoch)(const wasm_engine_t *);
typedef wasmtime_store_t *(*fn_wasmtime_store_new)(wasm_engine_t *, void *,
                                                    void (*)(void *));
typedef void (*fn_wasmtime_store_delete)(wasmtime_store_t *);
typedef wasmtime_context_t *(*fn_wasmtime_store_context)(wasmtime_store_t *);
typedef void (*fn_wasmtime_store_limiter)(wasmtime_store_t *, int64_t, int64_t,
                                          int64_t, int64_t, int64_t);
typedef void *(*fn_wasi_config_new)(void);
typedef void (*fn_wasi_config_delete)(wasi_config_t *);
typedef bool (*fn_wasi_config_set_argv)(wasi_config_t *, size_t,
                                        const char **);
typedef bool (*fn_wasi_config_set_env)(wasi_config_t *, size_t, const char **,
                                       const char **);
typedef bool (*fn_wasi_config_preopen_dir)(wasi_config_t *, const char *,
                                            const char *, size_t, size_t);
typedef wasmtime_error_t *(*fn_wasmtime_context_set_wasi)(wasmtime_context_t *,
                                                           wasi_config_t *);
typedef wasmtime_error_t *(*fn_wasmtime_context_set_fuel)(wasmtime_context_t *,
                                                           uint64_t);
typedef void (*fn_wasmtime_context_set_epoch_deadline)(wasmtime_context_t *,
                                                        uint64_t);
typedef wasmtime_error_t *(*fn_wasmtime_component_new)(
    const wasm_engine_t *, const uint8_t *, size_t, wasmtime_component_t **);
typedef void (*fn_wasmtime_component_delete)(wasmtime_component_t *);
typedef wasmtime_component_linker_t *(*fn_wasmtime_component_linker_new)(
    const wasm_engine_t *);
typedef wasmtime_component_linker_instance_t *(*fn_wasmtime_component_linker_root)(
    wasmtime_component_linker_t *);
typedef void (*fn_wasmtime_component_linker_allow_shadowing)(
    wasmtime_component_linker_t *, bool);
typedef wasmtime_error_t *(*fn_wasmtime_component_linker_instance_add_instance)(
    wasmtime_component_linker_instance_t *, const char *, size_t,
    wasmtime_component_linker_instance_t **);
typedef wasmtime_error_t *(*fn_wasmtime_component_linker_instance_add_func)(
    wasmtime_component_linker_instance_t *, const char *, size_t,
    wasmtime_error_t *(*)(void *, wasmtime_context_t *, const void *,
                          wasmtime_component_val_t *, size_t,
                          wasmtime_component_val_t *, size_t),
    void *, void (*)(void *));
typedef void (*fn_wasmtime_component_linker_instance_delete)(
    wasmtime_component_linker_instance_t *);
typedef void (*fn_wasmtime_component_linker_delete)(
    wasmtime_component_linker_t *);
typedef wasmtime_error_t *(*fn_wasmtime_component_linker_define_unknown_imports_as_traps)(
    wasmtime_component_linker_t *, const wasmtime_component_t *);
typedef wasmtime_error_t *(*fn_wasmtime_component_linker_add_wasip2)(
    wasmtime_component_linker_t *);
typedef wasmtime_error_t *(*fn_wasmtime_component_linker_instantiate)(
    const wasmtime_component_linker_t *, wasmtime_context_t *,
    const wasmtime_component_t *, wasmtime_component_instance_t *);
typedef wasmtime_component_export_index_t *(*fn_wasmtime_component_get_export_index)(
    const wasmtime_component_t *, const wasmtime_component_export_index_t *,
    const char *, size_t);
typedef void (*fn_wasmtime_component_export_index_delete)(
    wasmtime_component_export_index_t *);
typedef bool (*fn_wasmtime_component_instance_get_func)(
    const wasmtime_component_instance_t *, wasmtime_context_t *,
    const wasmtime_component_export_index_t *, wasmtime_component_func_t *);
typedef wasmtime_error_t *(*fn_wasmtime_component_func_call)(
    const wasmtime_component_func_t *, wasmtime_context_t *, const void *,
    size_t, void *, size_t);
typedef void (*fn_wasmtime_error_delete)(wasmtime_error_t *);
typedef void (*fn_wasmtime_error_message)(const wasmtime_error_t *,
                                          wasm_byte_vec_t *);
typedef void (*fn_wasm_byte_vec_delete)(wasm_byte_vec_t *);

typedef struct {
  fn_wasm_config_new wasm_config_new;
  fn_wasm_config_delete wasm_config_delete;
  fn_wasmtime_config_component_set config_component_set;
  fn_wasmtime_config_fuel_set config_fuel_set;
  fn_wasmtime_config_epoch_interruption_set config_epoch_interruption_set;
  fn_wasm_engine_new_with_config engine_new_with_config;
  fn_wasm_engine_delete engine_delete;
  fn_wasmtime_engine_increment_epoch engine_increment_epoch;
  fn_wasmtime_store_new store_new;
  fn_wasmtime_store_delete store_delete;
  fn_wasmtime_store_context store_context;
  fn_wasmtime_store_limiter store_limiter;
  fn_wasi_config_new wasi_config_new;
  fn_wasi_config_delete wasi_config_delete;
  fn_wasi_config_set_argv wasi_config_set_argv;
  fn_wasi_config_set_env wasi_config_set_env;
  fn_wasi_config_preopen_dir wasi_config_preopen_dir;
  fn_wasmtime_context_set_wasi context_set_wasi;
  fn_wasmtime_context_set_fuel context_set_fuel;
  fn_wasmtime_context_set_epoch_deadline context_set_epoch_deadline;
  fn_wasmtime_component_new component_new;
  fn_wasmtime_component_delete component_delete;
  fn_wasmtime_component_linker_new linker_new;
  fn_wasmtime_component_linker_root linker_root;
  fn_wasmtime_component_linker_allow_shadowing linker_allow_shadowing;
  fn_wasmtime_component_linker_instance_add_instance linker_instance_add_instance;
  fn_wasmtime_component_linker_instance_add_func linker_instance_add_func;
  fn_wasmtime_component_linker_instance_delete linker_instance_delete;
  fn_wasmtime_component_linker_delete linker_delete;
  fn_wasmtime_component_linker_define_unknown_imports_as_traps
      linker_define_unknown_imports_as_traps;
  fn_wasmtime_component_linker_add_wasip2 linker_add_wasip2;
  fn_wasmtime_component_linker_instantiate linker_instantiate;
  fn_wasmtime_component_get_export_index component_get_export_index;
  fn_wasmtime_component_export_index_delete export_index_delete;
  fn_wasmtime_component_instance_get_func instance_get_func;
  fn_wasmtime_component_func_call func_call;
  fn_wasmtime_error_delete error_delete;
  fn_wasmtime_error_message error_message;
  fn_wasm_byte_vec_delete byte_vec_delete;
} wasmtime_api_t;

struct nimculus_component_job {
  pthread_t thread;
  pthread_mutex_t mutex;
  bool done;
  bool cancel_requested;
  int result;
  char error[4096];
  wasm_engine_t *engine;
  fn_wasmtime_engine_increment_epoch increment_epoch;
  char *library_path;
  char *module_path;
  char *extension_root;
  char *extension_id;
  char *entrypoint;
  char *capabilities;
  uint32_t api_version;
  int allow_write;
  int allow_process;
};

static void set_error(char *out, size_t capacity, const char *message) {
  if (!out || capacity == 0) return;
  if (!message) message = "unknown Wasmtime error";
  snprintf(out, capacity, "%s", message);
  out[capacity - 1] = '\0';
}

static void set_errorf(char *out, size_t capacity, const char *format,
                       const char *detail) {
  if (!out || capacity == 0) return;
  snprintf(out, capacity, format, detail ? detail : "unknown");
  out[capacity - 1] = '\0';
}

static void report_wasmtime_error(wasmtime_api_t *api, wasmtime_error_t *error,
                                  char *out, size_t capacity) {
  if (!error) return;
  wasm_byte_vec_t message = {0, NULL};
  if (api->error_message) api->error_message(error, &message);
  if (message.data && message.size > 0) {
    size_t length = message.size;
    if (length >= capacity) length = capacity - 1;
    if (out && capacity > 0) {
      memcpy(out, message.data, length);
      out[length] = '\0';
    }
  } else {
    set_error(out, capacity, "Wasmtime returned an error");
  }
  if (api->byte_vec_delete) api->byte_vec_delete(&message);
  api->error_delete(error);
}

static void *open_wasmtime_library(const char *requested) {
  const char *environment = getenv("NIMCULUS_WASMTIME_LIBRARY");
  const char *candidates[] = {
      requested,
      environment,
      "@rpath/libwasmtime.dylib",
      "/opt/homebrew/opt/wasmtime/lib/libwasmtime.dylib",
      "/opt/homebrew/lib/libwasmtime.dylib",
      "/usr/local/opt/wasmtime/lib/libwasmtime.dylib",
      "/usr/local/lib/libwasmtime.dylib",
      NULL};
  for (size_t index = 0; candidates[index]; ++index) {
    if (!candidates[index] || candidates[index][0] == '\0') continue;
    void *handle = dlopen(candidates[index], RTLD_NOW | RTLD_LOCAL);
    if (handle) return handle;
  }
  return NULL;
}

#define LOAD_REQUIRED(api, handle, field, symbol)                             \
  do {                                                                        \
    *(void **)(&(api).field) = dlsym((handle), (symbol));                     \
    if (!(api).field) return false;                                           \
  } while (0)

static bool load_api(void *handle, wasmtime_api_t *api) {
  memset(api, 0, sizeof(*api));
  LOAD_REQUIRED(*api, handle, wasm_config_new, "wasm_config_new");
  LOAD_REQUIRED(*api, handle, wasm_config_delete, "wasm_config_delete");
  LOAD_REQUIRED(*api, handle, config_component_set,
                "wasmtime_config_wasm_component_model_set");
  LOAD_REQUIRED(*api, handle, config_fuel_set,
                "wasmtime_config_consume_fuel_set");
  LOAD_REQUIRED(*api, handle, config_epoch_interruption_set,
                "wasmtime_config_epoch_interruption_set");
  LOAD_REQUIRED(*api, handle, engine_new_with_config,
                "wasm_engine_new_with_config");
  LOAD_REQUIRED(*api, handle, engine_delete, "wasm_engine_delete");
  LOAD_REQUIRED(*api, handle, engine_increment_epoch,
                "wasmtime_engine_increment_epoch");
  LOAD_REQUIRED(*api, handle, store_new, "wasmtime_store_new");
  LOAD_REQUIRED(*api, handle, store_delete, "wasmtime_store_delete");
  LOAD_REQUIRED(*api, handle, store_context, "wasmtime_store_context");
  LOAD_REQUIRED(*api, handle, store_limiter, "wasmtime_store_limiter");
  LOAD_REQUIRED(*api, handle, wasi_config_new, "wasi_config_new");
  LOAD_REQUIRED(*api, handle, wasi_config_delete, "wasi_config_delete");
  LOAD_REQUIRED(*api, handle, wasi_config_set_argv, "wasi_config_set_argv");
  LOAD_REQUIRED(*api, handle, wasi_config_set_env, "wasi_config_set_env");
  LOAD_REQUIRED(*api, handle, wasi_config_preopen_dir,
                "wasi_config_preopen_dir");
  LOAD_REQUIRED(*api, handle, context_set_wasi, "wasmtime_context_set_wasi");
  LOAD_REQUIRED(*api, handle, context_set_fuel, "wasmtime_context_set_fuel");
  LOAD_REQUIRED(*api, handle, context_set_epoch_deadline,
                "wasmtime_context_set_epoch_deadline");
  LOAD_REQUIRED(*api, handle, component_new, "wasmtime_component_new");
  LOAD_REQUIRED(*api, handle, component_delete, "wasmtime_component_delete");
  LOAD_REQUIRED(*api, handle, linker_new, "wasmtime_component_linker_new");
  LOAD_REQUIRED(*api, handle, linker_root, "wasmtime_component_linker_root");
  LOAD_REQUIRED(*api, handle, linker_allow_shadowing,
                "wasmtime_component_linker_allow_shadowing");
  LOAD_REQUIRED(*api, handle, linker_instance_add_instance,
                "wasmtime_component_linker_instance_add_instance");
  LOAD_REQUIRED(*api, handle, linker_instance_add_func,
                "wasmtime_component_linker_instance_add_func");
  LOAD_REQUIRED(*api, handle, linker_instance_delete,
                "wasmtime_component_linker_instance_delete");
  LOAD_REQUIRED(*api, handle, linker_delete, "wasmtime_component_linker_delete");
  LOAD_REQUIRED(*api, handle, linker_define_unknown_imports_as_traps,
                "wasmtime_component_linker_define_unknown_imports_as_traps");
  LOAD_REQUIRED(*api, handle, linker_add_wasip2,
                "wasmtime_component_linker_add_wasip2");
  LOAD_REQUIRED(*api, handle, linker_instantiate,
                "wasmtime_component_linker_instantiate");
  LOAD_REQUIRED(*api, handle, component_get_export_index,
                "wasmtime_component_get_export_index");
  LOAD_REQUIRED(*api, handle, export_index_delete,
                "wasmtime_component_export_index_delete");
  LOAD_REQUIRED(*api, handle, instance_get_func,
                "wasmtime_component_instance_get_func");
  LOAD_REQUIRED(*api, handle, func_call, "wasmtime_component_func_call");
  LOAD_REQUIRED(*api, handle, error_delete, "wasmtime_error_delete");
  LOAD_REQUIRED(*api, handle, error_message, "wasmtime_error_message");
  LOAD_REQUIRED(*api, handle, byte_vec_delete, "wasm_byte_vec_delete");
  return true;
}

#undef LOAD_REQUIRED

static bool set_component_name_bytes(wasm_name_t *name, const uint8_t *value,
                                     size_t length);

static bool set_component_name(wasm_name_t *name, const char *value) {
  if (!value) return false;
  return set_component_name_bytes(name, (const uint8_t *)value, strlen(value));
}

static bool set_component_name_bytes(wasm_name_t *name, const uint8_t *value,
                                     size_t length) {
  if (!name || !value) return false;
  name->data = (uint8_t *)malloc(length);
  if (length > 0 && !name->data) return false;
  if (length > 0) memcpy(name->data, value, length);
  name->size = length;
  return true;
}

static void free_component_value(wasmtime_component_val_t *value) {
  if (!value) return;
  switch (value->kind) {
  case NIMCULUS_COMPONENT_STRING:
  case NIMCULUS_COMPONENT_ENUM:
    free(value->of.string.data);
    break;
  case NIMCULUS_COMPONENT_LIST:
    for (size_t index = 0; index < value->of.list.size; ++index)
      free_component_value(&value->of.list.data[index]);
    free(value->of.list.data);
    break;
  case NIMCULUS_COMPONENT_RECORD:
    for (size_t index = 0; index < value->of.record.size; ++index) {
      free(value->of.record.data[index].name.data);
      free_component_value(&value->of.record.data[index].val);
    }
    free(value->of.record.data);
    break;
  case NIMCULUS_COMPONENT_TUPLE:
    for (size_t index = 0; index < value->of.tuple.size; ++index)
      free_component_value(&value->of.tuple.data[index]);
    free(value->of.tuple.data);
    break;
  case NIMCULUS_COMPONENT_OPTION:
    free_component_value(value->of.option);
    free(value->of.option);
    break;
  case NIMCULUS_COMPONENT_RESULT:
    free_component_value(value->of.result.val);
    free(value->of.result.val);
    break;
  default:
    break;
  }
  memset(value, 0, sizeof(*value));
}

static bool component_string(const wasmtime_component_val_t *value,
                             char **out, size_t max_length) {
  if (!value || !out || value->kind != NIMCULUS_COMPONENT_STRING ||
      value->of.string.size > max_length ||
      (value->of.string.size > 0 && !value->of.string.data))
    return false;
  for (size_t index = 0; index < value->of.string.size; ++index)
    if (value->of.string.data[index] == '\0') return false;
  char *copy = (char *)malloc(value->of.string.size + 1);
  if (!copy) return false;
  if (value->of.string.size > 0)
    memcpy(copy, value->of.string.data, value->of.string.size);
  copy[value->of.string.size] = '\0';
  *out = copy;
  return true;
}

static wasmtime_component_val_t *record_field(
    wasmtime_component_val_t *record, const char *name) {
  if (!record || record->kind != NIMCULUS_COMPONENT_RECORD || !name) return NULL;
  size_t name_length = strlen(name);
  for (size_t index = 0; index < record->of.record.size; ++index) {
    wasmtime_component_valrecord_entry_t *entry = &record->of.record.data[index];
    if (entry->name.size == name_length &&
        memcmp(entry->name.data, name, name_length) == 0)
      return &entry->val;
  }
  return NULL;
}

static wasmtime_error_t *component_error_result(
    wasmtime_component_val_t *results, size_t nresults, const char *message) {
  if (!results || nresults != 1) return NULL;
  wasmtime_component_val_t *error =
      (wasmtime_component_val_t *)calloc(1, sizeof(*error));
  if (!error || !set_component_name(&error->of.string, message)) {
    free(error);
    return NULL;
  }
  error->kind = NIMCULUS_COMPONENT_STRING;
  results[0].kind = NIMCULUS_COMPONENT_RESULT;
  results[0].of.result.is_ok = false;
  results[0].of.result.val = error;
  return NULL;
}

static bool append_owned_string(char ***items, size_t *count, size_t *capacity,
                                const char *value) {
  if (!items || !count || !capacity || !value) return false;
  if (*count + 1 >= *capacity) {
    size_t next = *capacity == 0 ? 8 : *capacity * 2;
    char **grown = (char **)realloc(*items, next * sizeof(*grown));
    if (!grown) return false;
    *items = grown;
    *capacity = next;
  }
  (*items)[*count] = strdup(value);
  if (!(*items)[*count]) return false;
  ++*count;
  (*items)[*count] = NULL;
  return true;
}

static void free_string_vector(char **items, size_t count) {
  if (!items) return;
  for (size_t index = 0; index < count; ++index) free(items[index]);
  free(items);
}

static bool env_key(const char *value, size_t *length) {
  if (!value || !length || value[0] == '\0') return false;
  const char *separator = strchr(value, '=');
  if (!separator || separator == value) return false;
  *length = (size_t)(separator - value);
  return true;
}

static bool build_environment(const wasmtime_component_val_t *env_value,
                              char ***environment, size_t *environment_count) {
  if (!environment || !environment_count) return false;
  char **items = NULL;
  size_t count = 0;
  size_t capacity = 0;
  for (char **entry = environ; entry && *entry; ++entry) {
    if (!append_owned_string(&items, &count, &capacity, *entry)) {
      free_string_vector(items, count);
      return false;
    }
  }
  if (env_value) {
    if (env_value->kind != NIMCULUS_COMPONENT_LIST ||
        env_value->of.list.size > 128) {
      free_string_vector(items, count);
      return false;
    }
    for (size_t index = 0; index < env_value->of.list.size; ++index) {
      const wasmtime_component_val_t *pair = &env_value->of.list.data[index];
      if (pair->kind != NIMCULUS_COMPONENT_TUPLE ||
          pair->of.tuple.size != 2) {
        free_string_vector(items, count);
        return false;
      }
      char *key = NULL;
      char *value = NULL;
      if (!component_string(&pair->of.tuple.data[0], &key, 256) ||
          !component_string(&pair->of.tuple.data[1], &value, 4096) ||
          strchr(key, '=') != NULL || key[0] == '\0') {
        free(key);
        free(value);
        free_string_vector(items, count);
        return false;
      }
      size_t key_length = strlen(key);
      size_t replacement = count;
      for (size_t candidate = 0; candidate < count; ++candidate) {
        size_t candidate_length = 0;
        if (env_key(items[candidate], &candidate_length) &&
            candidate_length == key_length &&
            memcmp(items[candidate], key, key_length) == 0) {
          replacement = candidate;
          break;
        }
      }
      size_t value_length = strlen(value);
      char *combined = (char *)malloc(key_length + value_length + 2);
      if (!combined) {
        free(key);
        free(value);
        free_string_vector(items, count);
        return false;
      }
      memcpy(combined, key, key_length);
      combined[key_length] = '=';
      memcpy(combined + key_length + 1, value, value_length + 1);
      free(key);
      free(value);
      if (replacement == count) {
        if (!append_owned_string(&items, &count, &capacity, combined)) {
          free(combined);
          free_string_vector(items, count);
          return false;
        }
        free(combined);
      } else {
        free(items[replacement]);
        items[replacement] = combined;
      }
    }
  }
  *environment = items;
  *environment_count = count;
  return true;
}

static bool read_process_pipe(int fd, char **output, size_t *length,
                              size_t *capacity, bool *overflow) {
  uint8_t buffer[8192];
  while (true) {
    ssize_t count = read(fd, buffer, sizeof(buffer));
    if (count > 0) {
      if (*length + (size_t)count > 1024 * 1024) {
        *overflow = true;
        return false;
      }
      if (*length + (size_t)count + 1 > *capacity) {
        size_t next = *capacity == 0 ? 8192 : *capacity;
        while (next < *length + (size_t)count + 1) next *= 2;
        char *grown = (char *)realloc(*output, next);
        if (!grown) return false;
        *output = grown;
        *capacity = next;
      }
      memcpy(*output + *length, buffer, (size_t)count);
      *length += (size_t)count;
      (*output)[*length] = '\0';
      continue;
    }
    if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) return count == 0;
    return true;
  }
}

static bool run_process(const nimculus_component_host_state_t *state,
                        const char *command, char *const *args, size_t arg_count,
                        char *const *environment, char **stdout_output,
                        size_t *stdout_length, char **stderr_output,
                        size_t *stderr_length, int *exit_status,
                        bool *terminated_by_signal, const char **error_message) {
  if (!state || !state->allow_process || !command || command[0] == '\0') {
    *error_message = "process capability is not granted";
    return false;
  }
  int stdout_pipe[2] = {-1, -1};
  int stderr_pipe[2] = {-1, -1};
  if (pipe(stdout_pipe) != 0 || pipe(stderr_pipe) != 0) {
    *error_message = "cannot create process pipes";
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
    return false;
  }
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, stdout_pipe[1], STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, stderr_pipe[1], STDERR_FILENO);
  posix_spawn_file_actions_addclose(&actions, stdout_pipe[0]);
  posix_spawn_file_actions_addclose(&actions, stderr_pipe[0]);
  posix_spawn_file_actions_addclose(&actions, stdout_pipe[1]);
  posix_spawn_file_actions_addclose(&actions, stderr_pipe[1]);
  if (posix_spawn_file_actions_addchdir(&actions, state->extension_root) != 0) {
    posix_spawn_file_actions_destroy(&actions);
    close(stdout_pipe[0]); close(stdout_pipe[1]);
    close(stderr_pipe[0]); close(stderr_pipe[1]);
    *error_message = "cannot set extension working directory";
    return false;
  }
  size_t argv_count = arg_count + 2;
  char **argv = (char **)calloc(argv_count, sizeof(*argv));
  if (!argv) {
    posix_spawn_file_actions_destroy(&actions);
    close(stdout_pipe[0]); close(stdout_pipe[1]);
    close(stderr_pipe[0]); close(stderr_pipe[1]);
    *error_message = "cannot allocate process arguments";
    return false;
  }
  argv[0] = (char *)command;
  for (size_t index = 0; index < arg_count; ++index) argv[index + 1] = args[index];
  argv[arg_count + 1] = NULL;
  pid_t pid = 0;
  int spawn_result = posix_spawnp(&pid, command, &actions, NULL, argv, environment);
  free(argv);
  posix_spawn_file_actions_destroy(&actions);
  close(stdout_pipe[1]);
  close(stderr_pipe[1]);
  if (spawn_result != 0) {
    close(stdout_pipe[0]); close(stderr_pipe[0]);
    *error_message = strerror(spawn_result);
    return false;
  }
  int flags = fcntl(stdout_pipe[0], F_GETFL, 0);
  if (flags >= 0) fcntl(stdout_pipe[0], F_SETFL, flags | O_NONBLOCK);
  flags = fcntl(stderr_pipe[0], F_GETFL, 0);
  if (flags >= 0) fcntl(stderr_pipe[0], F_SETFL, flags | O_NONBLOCK);
  char *out = NULL, *err = NULL;
  size_t out_length = 0, err_length = 0, out_capacity = 0, err_capacity = 0;
  bool overflow = false;
  int wait_status = 0;
  bool child_done = false;
  uint64_t deadline = 0;
  struct timeval now;
  gettimeofday(&now, NULL);
  deadline = (uint64_t)now.tv_sec * 1000 + now.tv_usec / 1000 + 10000;
  while (!child_done) {
    struct pollfd fds[2] = {{stdout_pipe[0], POLLIN, 0},
                            {stderr_pipe[0], POLLIN, 0}};
    poll(fds, 2, 50);
    read_process_pipe(stdout_pipe[0], &out, &out_length, &out_capacity, &overflow);
    read_process_pipe(stderr_pipe[0], &err, &err_length, &err_capacity, &overflow);
    pid_t waited = waitpid(pid, &wait_status, WNOHANG);
    if (waited == pid) child_done = true;
    gettimeofday(&now, NULL);
    uint64_t current = (uint64_t)now.tv_sec * 1000 + now.tv_usec / 1000;
    if (current >= deadline || overflow) {
      kill(pid, SIGTERM);
      usleep(100000);
      if (waitpid(pid, &wait_status, WNOHANG) == 0) {
        kill(pid, SIGKILL);
        waitpid(pid, &wait_status, 0);
      }
      child_done = true;
      if (current >= deadline) *error_message = "process timed out";
      else *error_message = "process output exceeded 1 MiB per stream";
    }
  }
  read_process_pipe(stdout_pipe[0], &out, &out_length, &out_capacity, &overflow);
  read_process_pipe(stderr_pipe[0], &err, &err_length, &err_capacity, &overflow);
  close(stdout_pipe[0]);
  close(stderr_pipe[0]);
  if (!out) out = strdup("");
  if (!err) err = strdup("");
  if (!out || !err) {
    free(out); free(err);
    *error_message = "cannot allocate process output";
    return false;
  }
  *stdout_output = out;
  *stdout_length = out_length;
  *stderr_output = err;
  *stderr_length = err_length;
  if (WIFEXITED(wait_status)) {
    *exit_status = WEXITSTATUS(wait_status);
    *terminated_by_signal = false;
  } else {
    *exit_status = -1;
    *terminated_by_signal = true;
  }
  return *error_message == NULL;
}

static bool set_component_bytes_list(wasmtime_component_val_t *value,
                                     const char *bytes, size_t length) {
  if (!value || (length > 0 && !bytes) || length > 1024 * 1024) return false;
  wasmtime_component_val_t *items =
      (wasmtime_component_val_t *)calloc(length, sizeof(*items));
  if (length > 0 && !items) return false;
  for (size_t index = 0; index < length; ++index) {
    items[index].kind = NIMCULUS_COMPONENT_U8;
    items[index].of.u8 = (uint8_t)bytes[index];
  }
  value->kind = NIMCULUS_COMPONENT_LIST;
  value->of.list.size = length;
  value->of.list.data = items;
  return true;
}

static bool set_component_record_name(wasmtime_component_valrecord_entry_t *entry,
                                      const char *name) {
  return entry && set_component_name(&entry->name, name);
}

static wasmtime_error_t *process_callback(
    void *data, wasmtime_context_t *context, const void *type,
    wasmtime_component_val_t *args, size_t nargs,
    wasmtime_component_val_t *results, size_t nresults) {
  (void)context;
  (void)type;
  if (!results || nresults != 1 || !args || nargs != 1)
    return component_error_result(results, nresults,
                                  "invalid process.run-command arguments");
  nimculus_component_host_state_t *state =
      (nimculus_component_host_state_t *)data;
  wasmtime_component_val_t *command_value = record_field(&args[0], "command");
  wasmtime_component_val_t *args_value = record_field(&args[0], "args");
  wasmtime_component_val_t *env_value = record_field(&args[0], "env");
  char *command = NULL;
  if (!component_string(command_value, &command, 256) ||
      !args_value || args_value->kind != NIMCULUS_COMPONENT_LIST ||
      args_value->of.list.size > 128) {
    free(command);
    return component_error_result(results, nresults,
                                  "invalid process command");
  }
  size_t arg_count = args_value->of.list.size;
  char **command_args = (char **)calloc(arg_count, sizeof(*command_args));
  if (arg_count > 0 && !command_args) {
    free(command);
    return component_error_result(results, nresults,
                                  "cannot allocate process arguments");
  }
  for (size_t index = 0; index < arg_count; ++index) {
    if (!component_string(&args_value->of.list.data[index],
                          &command_args[index], 4096)) {
      free(command);
      free_string_vector(command_args, index);
      return component_error_result(results, nresults,
                                    "invalid process argument");
    }
  }
  char **environment = NULL;
  size_t environment_count = 0;
  if (!build_environment(env_value, &environment, &environment_count)) {
    free(command);
    free_string_vector(command_args, arg_count);
    return component_error_result(results, nresults,
                                  "invalid process environment");
  }
  char *stdout_output = NULL;
  char *stderr_output = NULL;
  size_t stdout_length = 0;
  size_t stderr_length = 0;
  int exit_status = -1;
  bool terminated_by_signal = false;
  const char *process_error = NULL;
  bool process_succeeded = run_process(
      state, command, command_args, arg_count, environment, &stdout_output,
      &stdout_length, &stderr_output, &stderr_length, &exit_status,
      &terminated_by_signal, &process_error);
  free(command);
  free_string_vector(command_args, arg_count);
  free_string_vector(environment, environment_count);
  if (!process_succeeded) {
    free(stdout_output);
    free(stderr_output);
    return component_error_result(results, nresults,
                                  process_error ? process_error :
                                                  "process execution failed");
  }
  wasmtime_component_val_t *payload =
      (wasmtime_component_val_t *)calloc(1, sizeof(*payload));
  if (!payload) {
    free(stdout_output); free(stderr_output);
    return component_error_result(results, nresults,
                                  "cannot allocate process output");
  }
  payload->kind = NIMCULUS_COMPONENT_RECORD;
  payload->of.record.size = 3;
  payload->of.record.data =
      (wasmtime_component_valrecord_entry_t *)calloc(3, sizeof(*payload->of.record.data));
  if (!payload->of.record.data ||
      !set_component_record_name(&payload->of.record.data[0], "status") ||
      !set_component_record_name(&payload->of.record.data[1], "stdout") ||
      !set_component_record_name(&payload->of.record.data[2], "stderr")) {
    free_component_value(payload);
    free(payload);
    free(stdout_output); free(stderr_output);
    return component_error_result(results, nresults,
                                  "cannot allocate process result");
  }
  payload->of.record.data[0].val.kind = NIMCULUS_COMPONENT_OPTION;
  if (!terminated_by_signal) {
    payload->of.record.data[0].val.of.option =
        (wasmtime_component_val_t *)calloc(1, sizeof(wasmtime_component_val_t));
    if (!payload->of.record.data[0].val.of.option) {
      free_component_value(payload); free(payload);
      free(stdout_output); free(stderr_output);
      return component_error_result(results, nresults,
                                    "cannot allocate process status");
    }
    payload->of.record.data[0].val.of.option->kind = NIMCULUS_COMPONENT_S32;
    payload->of.record.data[0].val.of.option->of.s32 = exit_status;
  }
  if (!set_component_bytes_list(&payload->of.record.data[1].val,
                                stdout_output, stdout_length) ||
      !set_component_bytes_list(&payload->of.record.data[2].val,
                                stderr_output, stderr_length)) {
    free_component_value(payload); free(payload);
    free(stdout_output); free(stderr_output);
    return component_error_result(results, nresults,
                                  "cannot allocate process output");
  }
  free(stdout_output);
  free(stderr_output);
  results[0].kind = NIMCULUS_COMPONENT_RESULT;
  results[0].of.result.is_ok = true;
  results[0].of.result.val = payload;
  return NULL;
}

static wasmtime_error_t *current_platform_callback(
    void *data, wasmtime_context_t *context, const void *type,
    wasmtime_component_val_t *args, size_t nargs,
    wasmtime_component_val_t *results, size_t nresults) {
  (void)data;
  (void)context;
  (void)type;
  (void)args;
  if (!results || nargs != 0 || nresults != 1) return NULL;
#if defined(__aarch64__) || defined(__arm64__)
  const char *architecture = "aarch64";
#else
  const char *architecture = "x8664";
#endif
  wasmtime_component_val_t *tuple =
      (wasmtime_component_val_t *)calloc(2, sizeof(*tuple));
  if (!tuple) return NULL;
  tuple[0].kind = NIMCULUS_COMPONENT_ENUM;
  tuple[1].kind = NIMCULUS_COMPONENT_ENUM;
  if (!set_component_name(&tuple[0].of.enumeration, "mac") ||
      !set_component_name(&tuple[1].of.enumeration, architecture)) {
    free(tuple[0].of.enumeration.data);
    free(tuple[1].of.enumeration.data);
    free(tuple);
    return NULL;
  }
  results[0].kind = NIMCULUS_COMPONENT_TUPLE;
  results[0].of.tuple.size = 2;
  results[0].of.tuple.data = tuple;
  return NULL;
}

static bool link_platform_host(wasmtime_api_t *api,
                               wasmtime_component_linker_t *linker,
                               char *error_out, size_t error_capacity) {
  wasmtime_component_linker_instance_t *root = api->linker_root(linker);
  if (!root) {
    set_error(error_out, error_capacity,
              "cannot access Component linker root");
    return false;
  }
  wasmtime_component_linker_instance_t *platform = NULL;
  wasmtime_error_t *error = api->linker_instance_add_instance(
      root, "zed:extension/platform", strlen("zed:extension/platform"),
      &platform);
  if (error) {
    report_wasmtime_error(api, error, error_out, error_capacity);
    return false;
  }
  error = api->linker_instance_add_func(
      platform, "current-platform", strlen("current-platform"),
      current_platform_callback, NULL, NULL);
  api->linker_instance_delete(platform);
  if (error) {
    report_wasmtime_error(api, error, error_out, error_capacity);
    return false;
  }
  return true;
}

static bool link_process_host(wasmtime_api_t *api,
                              wasmtime_component_linker_t *linker,
                              nimculus_component_host_state_t *state,
                              char *error_out, size_t error_capacity) {
  wasmtime_component_linker_instance_t *root = api->linker_root(linker);
  if (!root) {
    set_error(error_out, error_capacity,
              "cannot access Component linker root");
    return false;
  }
  wasmtime_component_linker_instance_t *process = NULL;
  wasmtime_error_t *error = api->linker_instance_add_instance(
      root, "zed:extension/process", strlen("zed:extension/process"),
      &process);
  if (error) {
    report_wasmtime_error(api, error, error_out, error_capacity);
    return false;
  }
  error = api->linker_instance_add_func(
      process, "run-command", strlen("run-command"), process_callback, state,
      NULL);
  api->linker_instance_delete(process);
  if (error) {
    report_wasmtime_error(api, error, error_out, error_capacity);
    return false;
  }
  return true;
}

int nimculus_wasmtime_component_available(const char *library_path) {
  void *handle = open_wasmtime_library(library_path);
  if (!handle) return 0;
  wasmtime_api_t api;
  bool loaded = load_api(handle, &api);
  dlclose(handle);
  return loaded ? 1 : 0;
}

static bool component_job_cancel_requested(nimculus_component_job_t *job) {
  if (!job) return false;
  pthread_mutex_lock(&job->mutex);
  bool requested = job->cancel_requested;
  pthread_mutex_unlock(&job->mutex);
  return requested;
}

static void component_job_set_engine(nimculus_component_job_t *job,
                                     wasm_engine_t *engine,
                                     fn_wasmtime_engine_increment_epoch increment_epoch) {
  if (!job) return;
  pthread_mutex_lock(&job->mutex);
  job->engine = engine;
  job->increment_epoch = increment_epoch;
  pthread_mutex_unlock(&job->mutex);
}

static void component_job_clear_engine(nimculus_component_job_t *job) {
  if (!job) return;
  pthread_mutex_lock(&job->mutex);
  job->engine = NULL;
  job->increment_epoch = NULL;
  pthread_mutex_unlock(&job->mutex);
}

static int run_component(const char *library_path, const char *module_path,
                         const char *extension_root, const char *extension_id,
                         uint32_t api_version, const char *entrypoint,
                         int allow_write, int allow_process,
                         const char *capabilities,
                         char *error_out,
                         size_t error_capacity, nimculus_component_job_t *job) {
  if (!module_path || !extension_root || !extension_id) {
    set_error(error_out, error_capacity, "invalid Component host arguments");
    return 2;
  }
  void *handle = open_wasmtime_library(library_path);
  if (!handle) {
    set_error(error_out, error_capacity,
              "architecture-compatible Wasmtime C API is unavailable");
    return 1;
  }
  wasmtime_api_t api;
  if (!load_api(handle, &api)) {
    set_error(error_out, error_capacity,
              "Wasmtime C API is missing a required Component Model symbol");
    dlclose(handle);
    return 1;
  }

  FILE *file = fopen(module_path, "rb");
  if (!file) {
    set_error(error_out, error_capacity, "cannot open Component module");
    dlclose(handle);
    return 2;
  }
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    set_error(error_out, error_capacity, "cannot seek Component module");
    dlclose(handle);
    return 2;
  }
  long file_size = ftell(file);
  if (file_size <= 0 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    set_error(error_out, error_capacity, "invalid Component module size");
    dlclose(handle);
    return 2;
  }
  uint8_t *bytes = (uint8_t *)malloc((size_t)file_size);
  if (!bytes || fread(bytes, 1, (size_t)file_size, file) != (size_t)file_size) {
    free(bytes);
    fclose(file);
    set_error(error_out, error_capacity, "cannot read Component module");
    dlclose(handle);
    return 2;
  }
  fclose(file);

  int result = 2;
  nimculus_component_host_state_t host_state = {
      extension_root, allow_process};
  wasm_config_t *config = (wasm_config_t *)api.wasm_config_new();
  wasm_engine_t *engine = NULL;
  wasmtime_store_t *store = NULL;
  wasmtime_component_t *component = NULL;
  wasmtime_component_linker_t *linker = NULL;
  wasmtime_component_export_index_t *export_index = NULL;
  wasi_config_t *wasi = NULL;
  if (!config) {
    set_error(error_out, error_capacity, "cannot create Wasmtime config");
    goto cleanup;
  }
  api.config_component_set(config, true);
  api.config_fuel_set(config, true);
  api.config_epoch_interruption_set(config, true);
  engine = api.engine_new_with_config(config);
  config = NULL;
  if (!engine) {
    set_error(error_out, error_capacity, "cannot create Wasmtime engine");
    goto cleanup;
  }
  component_job_set_engine(job, engine, api.engine_increment_epoch);
  if (component_job_cancel_requested(job)) api.engine_increment_epoch(engine);
  store = api.store_new(engine, NULL, NULL);
  if (!store) {
    set_error(error_out, error_capacity, "cannot create Wasmtime store");
    goto cleanup;
  }
  api.store_limiter(store, 256LL * 1024LL * 1024LL, -1, 64, 64, 64);
  wasmtime_context_t *context = api.store_context(store);
  wasi = (wasi_config_t *)api.wasi_config_new();
  if (!wasi) {
    set_error(error_out, error_capacity, "cannot create WASI context");
    goto cleanup;
  }
  const char *argv[] = {extension_id};
  const char *names[] = {"NIMCULUS_EXTENSION_ID",
                         "NIMCULUS_EXTENSION_API_VERSION",
                         "NIMCULUS_EXTENSION_HOST_API_VERSION",
                         "NIMCULUS_EXTENSION_CAPABILITIES"};
  char api_version_text[32];
  snprintf(api_version_text, sizeof(api_version_text), "%u", api_version);
  const char *host_api_version = "1";
  const char *values[] = {extension_id, api_version_text, host_api_version,
                          capabilities ? capabilities : ""};
  if (!api.wasi_config_set_argv(wasi, 1, argv) ||
      !api.wasi_config_set_env(wasi, 4, names, values)) {
    set_error(error_out, error_capacity, "invalid UTF-8 in WASI arguments");
    goto cleanup;
  }
  size_t dir_permissions = 1;
  size_t file_permissions = 1;
  if (allow_write) {
    dir_permissions |= 2;
    file_permissions |= 2;
  }
  if (!api.wasi_config_preopen_dir(wasi, extension_root, "/extension",
                                   dir_permissions, file_permissions)) {
    set_error(error_out, error_capacity, "cannot preopen extension root");
    goto cleanup;
  }
  wasmtime_error_t *error = api.context_set_wasi(context, wasi);
  wasi = NULL;
  if (error) {
    report_wasmtime_error(&api, error, error_out, error_capacity);
    goto cleanup;
  }
  api.context_set_epoch_deadline(context, 1);
  if (component_job_cancel_requested(job)) {
    set_error(error_out, error_capacity, "Component execution cancelled");
    goto cleanup;
  }
  error = api.context_set_fuel(context, 50ULL * 1000ULL * 1000ULL);
  if (error) {
    report_wasmtime_error(&api, error, error_out, error_capacity);
    goto cleanup;
  }
  error = api.component_new(engine, bytes, (size_t)file_size, &component);
  if (error) {
    report_wasmtime_error(&api, error, error_out, error_capacity);
    goto cleanup;
  }
  linker = api.linker_new(engine);
  if (!linker) {
    set_error(error_out, error_capacity, "cannot create Component linker");
    goto cleanup;
  }
  /* Trap every import not implemented by this host first. Explicitly linked
   * capabilities below are allowed to replace their trap definitions. */
  api.linker_allow_shadowing(linker, true);
  error = api.linker_add_wasip2(linker);
  if (error) {
    report_wasmtime_error(&api, error, error_out, error_capacity);
    goto cleanup;
  }
  /* Zed's generated linker defines the complete versioned import world. This
   * native boundary is intentionally incremental: the first real host import
   * is platform.current-platform, while every other unknown import becomes a
   * deterministic trap instead of an accidental permissive capability. */
  error = api.linker_define_unknown_imports_as_traps(linker, component);
  if (error) {
    report_wasmtime_error(&api, error, error_out, error_capacity);
    goto cleanup;
  }
  if (!link_platform_host(&api, linker, error_out, error_capacity)) {
    goto cleanup;
  }
  if (allow_process && !link_process_host(&api, linker, &host_state, error_out,
                                           error_capacity)) {
    goto cleanup;
  }
  wasmtime_component_instance_t instance = {0, 0};
  error = api.linker_instantiate(linker, context, component, &instance);
  if (error) {
    report_wasmtime_error(&api, error, error_out, error_capacity);
    goto cleanup;
  }
  const char *export_name = entrypoint && entrypoint[0] ? entrypoint :
                            "init-extension";
  char export_buffer[256];
  snprintf(export_buffer, sizeof(export_buffer), "%s", export_name);
  char *parenthesis = strchr(export_buffer, '(');
  if (parenthesis) *parenthesis = '\0';
  size_t export_length = strlen(export_buffer);
  export_index = api.component_get_export_index(component, NULL, export_buffer,
                                                export_length);
  if (!export_index) {
    set_errorf(error_out, error_capacity,
               "Component export is unavailable: %s", export_buffer);
    goto cleanup;
  }
  wasmtime_component_func_t function = {0, 0, 0};
  if (!api.instance_get_func(&instance, context, export_index, &function)) {
    set_errorf(error_out, error_capacity,
               "Component export is not a function: %s", export_buffer);
    goto cleanup;
  }
  error = api.func_call(&function, context, NULL, 0, NULL, 0);
  if (error) {
    report_wasmtime_error(&api, error, error_out, error_capacity);
    goto cleanup;
  }
  result = 0;

cleanup:
  if (export_index) api.export_index_delete(export_index);
  if (linker) api.linker_delete(linker);
  if (component) api.component_delete(component);
  if (store) api.store_delete(store);
  component_job_clear_engine(job);
  if (engine) api.engine_delete(engine);
  if (wasi) api.wasi_config_delete(wasi);
  if (config) api.wasm_config_delete(config);
  free(bytes);
  dlclose(handle);
  return result;
}

int nimculus_wasmtime_component_run(const char *library_path,
                                    const char *module_path,
                                    const char *extension_root,
                                    const char *extension_id,
                                    uint32_t api_version,
                                    const char *entrypoint,
                                    int allow_write,
                                    int allow_process,
                                    const char *capabilities,
                                    char *error_out, size_t error_capacity) {
  return run_component(library_path, module_path, extension_root, extension_id,
                       api_version, entrypoint, allow_write, allow_process,
                       capabilities, error_out, error_capacity, NULL);
}

static void free_component_job_inputs(nimculus_component_job_t *job) {
  free(job->library_path);
  free(job->module_path);
  free(job->extension_root);
  free(job->extension_id);
  free(job->entrypoint);
  free(job->capabilities);
  job->library_path = NULL;
  job->module_path = NULL;
  job->extension_root = NULL;
  job->extension_id = NULL;
  job->entrypoint = NULL;
  job->capabilities = NULL;
}

static void *component_job_worker(void *opaque) {
  nimculus_component_job_t *job = (nimculus_component_job_t *)opaque;
  char error[sizeof(job->error)] = {0};
  int result = run_component(
      job->library_path, job->module_path, job->extension_root,
      job->extension_id, job->api_version, job->entrypoint, job->allow_write,
      job->allow_process, job->capabilities,
      error, sizeof(error), job);
  pthread_mutex_lock(&job->mutex);
  job->result = result;
  snprintf(job->error, sizeof(job->error), "%s", error);
  if (job->cancel_requested && result != 0 && job->error[0] == '\0') {
    snprintf(job->error, sizeof(job->error), "Component execution cancelled");
  }
  job->done = true;
  pthread_mutex_unlock(&job->mutex);
  return NULL;
}

nimculus_component_job_t *nimculus_wasmtime_component_start(
    const char *library_path, const char *module_path,
    const char *extension_root, const char *extension_id, uint32_t api_version,
    const char *entrypoint, int allow_write, int allow_process,
    const char *capabilities,
    char *error_out,
    size_t error_capacity) {
  if (!module_path || !extension_root || !extension_id) {
    set_error(error_out, error_capacity, "invalid Component host arguments");
    return NULL;
  }
  nimculus_component_job_t *job =
      (nimculus_component_job_t *)calloc(1, sizeof(*job));
  if (!job) {
    set_error(error_out, error_capacity, "cannot allocate Component job");
    return NULL;
  }
  if (pthread_mutex_init(&job->mutex, NULL) != 0) {
    free(job);
    set_error(error_out, error_capacity, "cannot initialize Component job");
    return NULL;
  }
  job->result = 2;
  job->library_path = strdup(library_path ? library_path : "");
  job->module_path = strdup(module_path);
  job->extension_root = strdup(extension_root);
  job->extension_id = strdup(extension_id);
  job->entrypoint = strdup(entrypoint ? entrypoint : "");
  job->capabilities = strdup(capabilities ? capabilities : "");
  job->api_version = api_version;
  job->allow_write = allow_write;
  job->allow_process = allow_process;
  if (!job->library_path || !job->module_path || !job->extension_root ||
      !job->extension_id || !job->entrypoint || !job->capabilities) {
    free_component_job_inputs(job);
    pthread_mutex_destroy(&job->mutex);
    free(job);
    set_error(error_out, error_capacity, "cannot allocate Component job arguments");
    return NULL;
  }
  int thread_result = pthread_create(&job->thread, NULL, component_job_worker, job);
  if (thread_result != 0) {
    free_component_job_inputs(job);
    pthread_mutex_destroy(&job->mutex);
    free(job);
    set_error(error_out, error_capacity, "cannot start Component job");
    return NULL;
  }
  return job;
}

int nimculus_wasmtime_component_poll(nimculus_component_job_t *job,
                                     char *error_out, size_t error_capacity) {
  if (!job) {
    set_error(error_out, error_capacity, "invalid Component job");
    return 2;
  }
  pthread_mutex_lock(&job->mutex);
  bool done = job->done;
  int result = job->result;
  char error[sizeof(job->error)];
  snprintf(error, sizeof(error), "%s", job->error);
  pthread_mutex_unlock(&job->mutex);
  if (!done) return 0;
  if (result == 0) return 1;
  set_error(error_out, error_capacity,
            error[0] ? error : "Component execution failed");
  return result == 1 ? 3 : 2;
}

void nimculus_wasmtime_component_cancel(nimculus_component_job_t *job) {
  if (!job) return;
  pthread_mutex_lock(&job->mutex);
  job->cancel_requested = true;
  if (job->engine && job->increment_epoch) {
    /* Wasmtime documents this call as safe from any thread. Keep the mutex
       held until the call completes so cleanup cannot unload the library. */
    job->increment_epoch(job->engine);
  }
  pthread_mutex_unlock(&job->mutex);
}

void nimculus_wasmtime_component_delete(nimculus_component_job_t *job) {
  if (!job) return;
  pthread_mutex_lock(&job->mutex);
  bool done = job->done;
  pthread_mutex_unlock(&job->mutex);
  if (!done) return;
  pthread_join(job->thread, NULL);
  free_component_job_inputs(job);
  pthread_mutex_destroy(&job->mutex);
  free(job);
}

#else

int nimculus_wasmtime_component_available(const char *library_path) {
  (void)library_path;
  return 0;
}

int nimculus_wasmtime_component_run(const char *library_path,
                                    const char *module_path,
                                    const char *extension_root,
                                    const char *extension_id,
                                    uint32_t api_version,
                                    const char *entrypoint,
                                    int allow_write,
                                    int allow_process,
                                    const char *capabilities,
                                    char *error_out, size_t error_capacity) {
  (void)library_path;
  (void)module_path;
  (void)extension_root;
  (void)extension_id;
  (void)api_version;
  (void)entrypoint;
  (void)allow_write;
  (void)allow_process;
  (void)capabilities;
  if (error_out && error_capacity > 0) {
    snprintf(error_out, error_capacity,
             "in-process Component Model is only available on macOS");
    error_out[error_capacity - 1] = '\0';
  }
  return 1;
}

#endif
