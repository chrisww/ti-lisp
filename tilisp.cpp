#include "tilisp.h"
#include <iostream>

value_t *display(const value_t *value) {
  if (value->type == TYPE_INTEGER) {
    printf("%d\n", value->value.int_value);
  }

  return NULL;
}

static const char *type_name(uint8_t type) {
  switch (type) {
  case TYPE_INTEGER:
    return "integer";
  case TYPE_CHAR:
    return "char";
  case TYPE_STRING:
    return "string";
  case TYPE_CONS:
    return "cons";
  case TYPE_BOOL:
    return "boolean";
  case TYPE_FUNC:
    return "function";
  }
}

void check_type(const value_t *value, uint8_t expected_type) {
  if (value == NULL || value->type != expected_type) {
    printf("Expected variable to a %s, but got %s\n", type_name(expected_type),
           type_name(value->type));
    exit(1);
  }
}