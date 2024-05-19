#include <fmt/core.h>

#include "lib/add.h"
#include "lib/mul.h"
#include "lib/slow_mul.h"

int main() {

  fmt::println("1 + 2 = {}", myproject::add(1, 2));
  fmt::println("4 * 3 = {}", myproject::multiply(4, 3));
  fmt::println("4 * 3 = {}", myproject::slow_multiply(4, 3));
  return 0;
}
