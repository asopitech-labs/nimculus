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
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct wasm_config wasm_config_t;
typedef struct wasm_engine wasm_engine_t;
typedef struct wasmtime_store wasmtime_store_t;
typedef struct wasmtime_context wasmtime_context_t;
typedef struct wasi_config wasi_config_t;
typedef struct wasmtime_component wasmtime_component_t;
typedef struct wasmtime_component_linker wasmtime_component_linker_t;
typedef struct wasmtime_component_export_index wasmtime_component_export_index_t;
typedef struct wasmtime_error wasmtime_error_t;

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

typedef void *(*fn_wasm_config_new)(void);
typedef void (*fn_wasm_config_delete)(wasm_config_t *);
typedef void (*fn_wasmtime_config_component_set)(wasm_config_t *, bool);
typedef void (*fn_wasmtime_config_fuel_set)(wasm_config_t *, bool);
typedef wasm_engine_t *(*fn_wasm_engine_new_with_config)(wasm_config_t *);
typedef void (*fn_wasm_engine_delete)(wasm_engine_t *);
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
typedef wasmtime_error_t *(*fn_wasmtime_component_new)(
    const wasm_engine_t *, const uint8_t *, size_t, wasmtime_component_t **);
typedef void (*fn_wasmtime_component_delete)(wasmtime_component_t *);
typedef wasmtime_component_linker_t *(*fn_wasmtime_component_linker_new)(
    const wasm_engine_t *);
typedef void (*fn_wasmtime_component_linker_delete)(
    wasmtime_component_linker_t *);
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
  fn_wasm_engine_new_with_config engine_new_with_config;
  fn_wasm_engine_delete engine_delete;
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
  fn_wasmtime_component_new component_new;
  fn_wasmtime_component_delete component_delete;
  fn_wasmtime_component_linker_new linker_new;
  fn_wasmtime_component_linker_delete linker_delete;
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
      "/opt/homebrew/lib/libwasmtime.dylib",
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
  LOAD_REQUIRED(*api, handle, engine_new_with_config,
                "wasm_engine_new_with_config");
  LOAD_REQUIRED(*api, handle, engine_delete, "wasm_engine_delete");
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
  LOAD_REQUIRED(*api, handle, component_new, "wasmtime_component_new");
  LOAD_REQUIRED(*api, handle, component_delete, "wasmtime_component_delete");
  LOAD_REQUIRED(*api, handle, linker_new, "wasmtime_component_linker_new");
  LOAD_REQUIRED(*api, handle, linker_delete, "wasmtime_component_linker_delete");
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

int nimculus_wasmtime_component_available(const char *library_path) {
  void *handle = open_wasmtime_library(library_path);
  if (!handle) return 0;
  wasmtime_api_t api;
  bool loaded = load_api(handle, &api);
  dlclose(handle);
  return loaded ? 1 : 0;
}

int nimculus_wasmtime_component_run(const char *library_path,
                                    const char *module_path,
                                    const char *extension_root,
                                    const char *extension_id,
                                    uint32_t api_version,
                                    const char *entrypoint,
                                    int allow_write,
                                    char *error_out, size_t error_capacity) {
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
  engine = api.engine_new_with_config(config);
  config = NULL;
  if (!engine) {
    set_error(error_out, error_capacity, "cannot create Wasmtime engine");
    goto cleanup;
  }
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
                         "NIMCULUS_EXTENSION_API_VERSION"};
  char api_version_text[32];
  snprintf(api_version_text, sizeof(api_version_text), "%u", api_version);
  const char *values[] = {extension_id, api_version_text};
  if (!api.wasi_config_set_argv(wasi, 1, argv) ||
      !api.wasi_config_set_env(wasi, 2, names, values)) {
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
  error = api.linker_add_wasip2(linker);
  if (error) {
    report_wasmtime_error(&api, error, error_out, error_capacity);
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
  if (engine) api.engine_delete(engine);
  if (wasi) api.wasi_config_delete(wasi);
  if (config) api.wasm_config_delete(config);
  free(bytes);
  dlclose(handle);
  return result;
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
                                    char *error_out, size_t error_capacity) {
  (void)library_path;
  (void)module_path;
  (void)extension_root;
  (void)extension_id;
  (void)api_version;
  (void)entrypoint;
  (void)allow_write;
  if (error_out && error_capacity > 0) {
    snprintf(error_out, error_capacity,
             "in-process Component Model is only available on macOS");
    error_out[error_capacity - 1] = '\0';
  }
  return 1;
}

#endif
