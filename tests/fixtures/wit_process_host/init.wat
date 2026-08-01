(module
  (type (func (param i32 i32 i32 i32 i32 i32 i32)))
  (type (func))
  (type (func (param i32 i32 i32 i32) (result i32)))
  (import "cm32p2|zed:extension/process" "run-command"
    (func $run-command (type 0)))
  (memory (export "cm32p2_memory") 1)
  ;; The export calls the real host import. The host collects the newline from
  ;; /bin/echo into the WIT result; the test intentionally keeps the result
  ;; opaque and verifies the no-trap call boundary through the export status.
  (data (i32.const 100) "/bin/echo")
  (func $init-extension (type 1)
    (call $run-command
      (i32.const 100) (i32.const 8)
      (i32.const 0) (i32.const 0)
      (i32.const 0) (i32.const 0)
      (i32.const 200)))
  (func $init-extension-post (type 1))
  (func $realloc (type 2) (i32.const 0))
  (func $initialize (type 1))
  (export "cm32p2||init-extension" (func $init-extension))
  (export "cm32p2||init-extension_post" (func $init-extension-post))
  (export "cm32p2_realloc" (func $realloc))
  (export "cm32p2_initialize" (func $initialize))
)
