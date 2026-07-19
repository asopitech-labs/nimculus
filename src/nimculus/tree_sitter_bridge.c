#include "../../references/tree-sitter/lib/include/tree_sitter/api.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_markdown(void);
const TSLanguage *tree_sitter_nim(void);

typedef void (*NimTreeNodeCallback)(uint32_t start_byte, uint32_t end_byte,
                                    const char *type, bool has_error, void *context);

static const TSLanguage *languageForName(const char *name) {
  if (strcmp(name, "json") == 0) return tree_sitter_json();
  if (strcmp(name, "python") == 0) return tree_sitter_python();
  if (strcmp(name, "rust") == 0) return tree_sitter_rust();
  if (strcmp(name, "typescript") == 0) return tree_sitter_typescript();
  if (strcmp(name, "markdown") == 0) return tree_sitter_markdown();
  if (strcmp(name, "nim") == 0) return tree_sitter_nim();
  return NULL;
}

void *nim_ts_parser_new(const char *language) {
  const TSLanguage *grammar = languageForName(language);
  if (!grammar) return NULL;
  TSParser *parser = ts_parser_new();
  if (!ts_parser_set_language(parser, grammar)) { ts_parser_delete(parser); return NULL; }
  return parser;
}

void nim_ts_parser_delete(void *value) { if (value) ts_parser_delete(value); }

void *nim_ts_parse(void *parser, void *old_tree, const char *source, uint32_t length) {
  if (!parser || !source) return NULL;
  return ts_parser_parse_string((TSParser *)parser, (TSTree *)old_tree, source, length);
}

void nim_ts_tree_delete(void *tree) { if (tree) ts_tree_delete(tree); }
const char *nim_ts_root_type(void *tree) {
  if (!tree) return "";
  return ts_node_type(ts_tree_root_node(tree));
}
bool nim_ts_has_error(void *tree) {
  if (!tree) return true;
  return ts_node_has_error(ts_tree_root_node(tree));
}

static void walkNode(TSNode node, NimTreeNodeCallback callback, void *context) {
  if (callback) callback(ts_node_start_byte(node), ts_node_end_byte(node),
                         ts_node_type(node), ts_node_has_error(node), context);
  uint32_t count = ts_node_child_count(node);
  for (uint32_t index = 0; index < count; index++) {
    walkNode(ts_node_child(node, index), callback, context);
  }
}

void nim_ts_walk(void *tree, NimTreeNodeCallback callback, void *context) {
  if (tree) walkNode(ts_tree_root_node(tree), callback, context);
}

void nim_ts_tree_edit(void *tree, uint32_t start_byte, uint32_t old_end_byte,
                      uint32_t new_end_byte, uint32_t start_row, uint32_t start_column,
                      uint32_t old_end_row, uint32_t old_end_column,
                      uint32_t new_end_row, uint32_t new_end_column) {
  if (!tree) return;
  TSInputEdit edit = {
    .start_byte = start_byte, .old_end_byte = old_end_byte, .new_end_byte = new_end_byte,
    .start_point = {start_row, start_column},
    .old_end_point = {old_end_row, old_end_column},
    .new_end_point = {new_end_row, new_end_column},
  };
  ts_tree_edit(tree, &edit);
}
