#include "lib/slow_mul.h"

#include "lib/add.h"

namespace myproject {

int slow_multiply(int a, int b) {
  int r = 0;
  for (int i = 0; i < b; ++i) {
    r = add(r, a);
  }
  return r;
}

} // namespace myproject
