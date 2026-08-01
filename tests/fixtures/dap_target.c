#include <unistd.h>

__attribute__((noinline)) int nimculus_debug_target(int input) {
  volatile int value = input + 1;
  sleep(10);
  return value;
}

int main(void) {
  return nimculus_debug_target(41);
}
