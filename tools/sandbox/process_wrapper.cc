#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <fcntl.h>
#include <filesystem>
#include <fmt/core.h>
#include <span>
#include <stdexcept>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <vector>

#include <absl/cleanup/cleanup.h>
#include <absl/strings/str_split.h>
#include <absl/strings/strip.h>
#include <fmt/format.h>

namespace {
namespace landlock {
/**
 * struct landlock_ruleset_attr - Ruleset definition
 *
 * Argument of sys_landlock_create_ruleset().  This structure can grow in
 * future versions.
 */
struct ruleset_attr {
  /**
   * @handled_access_fs: Bitmask of actions (cf. `Filesystem flags`_)
   * that is handled by this ruleset and should then be forbidden if no
   * rule explicitly allow them.  This is needed for backward
   * compatibility reasons.
   */
  __u64 handled_access_fs;
};

/*
 * sys_landlock_create_ruleset() flags:
 *
 * - %LANDLOCK_CREATE_RULESET_VERSION: Get the highest supported Landlock ABI
 *   version.
 */
#ifndef LANDLOCK_CREATE_RULESET_VERSION
#define LANDLOCK_CREATE_RULESET_VERSION (1U << 0)
#endif

/**
 * enum landlock_rule_type - Landlock rule type
 *
 * Argument of sys_landlock_add_rule().
 */
enum class rule_type {
  /**
   * @RULE_PATH_BENEATH: Type of a &struct
   * landlock_path_beneath_attr .
   */
  RULE_PATH_BENEATH = 1,
};

/**
 * struct landlock_path_beneath_attr - Path hierarchy definition
 *
 * Argument of sys_landlock_add_rule().
 */
struct path_beneath_attr {
  /**
   * @allowed_access: Bitmask of allowed actions for this file hierarchy
   * (cf. `Filesystem flags`_).
   */
  __u64 allowed_access;
  /**
   * @parent_fd: File descriptor, open with ``O_PATH``, which identifies
   * the parent directory of a file hierarchy, or just a file.
   */
  __s32 parent_fd;
  /*
   * This struct is packed to avoid trailing reserved members.
   * Cf. security/landlock/syscalls.c:build_check_abi()
   */
} __attribute__((__packed__));

#define __NR_landlock_create_ruleset 444
#define __NR_landlock_add_rule 445
#define __NR_landlock_restrict_self 446

#define LANDLOCK_ABI_FS_REFER_SUPPORTED 2

int CreateRuleset(const struct ruleset_attr *const attr, const size_t size,
                  const uint32_t flags) {
  return syscall(__NR_landlock_create_ruleset, attr, size, flags);
}

int AddRule(const int ruleset_fd, const enum rule_type rule_type,
            const void *const rule_attr, const uint32_t flags) {
  return syscall(__NR_landlock_add_rule, ruleset_fd, rule_type, rule_attr,
                 flags);
}

int RestrictSelf(const int ruleset_fd, const uint32_t flags) {
  return syscall(__NR_landlock_restrict_self, ruleset_fd, flags);
}

/* The ABI version for landlock. */
int ABIVersion() {
  return CreateRuleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
}

/* If landlock is enabled. */
bool Enabled() {
  // ABI > 0 is considered supported.
  return ABIVersion() > 0;
}

class FSAccess {
public:
  enum Value : uint64_t {
    EXECUTE = (1ULL << 0),
    WRITE_FILE = (1ULL << 1),
    READ_FILE = (1ULL << 2),
    READ_DIR = (1ULL << 3),
    REMOVE_DIR = (1ULL << 4),
    REMOVE_FILE = (1ULL << 5),
    MAKE_CHAR = (1ULL << 6),
    MAKE_DIR = (1ULL << 7),
    MAKE_REG = (1ULL << 8),
    MAKE_SOCK = (1ULL << 9),
    MAKE_FIFO = (1ULL << 10),
    MAKE_BLOCK = (1ULL << 11),
    MAKE_SYM = (1ULL << 12),
    REFER = (1ULL << 13),
  };

  FSAccess() = default;
  constexpr FSAccess(uint64_t v) : value_(v) {}
  constexpr FSAccess(Value v) : value_(v) {}

  static FSAccess Readonly() { return EXECUTE | READ_FILE | READ_DIR; }
  static FSAccess AllFile() { return EXECUTE | WRITE_FILE | READ_FILE; }
  static FSAccess AllDir() {
    uint64_t flags = READ_DIR | REMOVE_DIR | REMOVE_FILE | MAKE_CHAR |
                     MAKE_DIR | MAKE_REG | MAKE_SOCK | MAKE_FIFO | MAKE_BLOCK |
                     MAKE_SYM;
    if (ABIVersion() >= 2) {
      flags |= REFER;
    }
    return flags;
  }
  static FSAccess All() { return AllFile() | AllDir(); }

  constexpr bool operator==(FSAccess a) const { return value_ == a.value_; }
  constexpr bool operator!=(FSAccess a) const { return value_ != a.value_; }
  constexpr FSAccess operator|(FSAccess a) const { return value_ | a.value_; }
  constexpr FSAccess operator&(FSAccess a) const { return value_ & a.value_; }
  constexpr uint64_t Value() const { return value_; }

private:
  uint64_t value_;
};

class Ruleset {
public:
  Ruleset(const Ruleset &) = delete;
  Ruleset(Ruleset &&) = default;
  Ruleset &operator=(const Ruleset &) = delete;
  Ruleset &operator=(Ruleset &&) = default;

  static Ruleset Create() {
    ruleset_attr ruleset_attr = {
        .handled_access_fs = FSAccess::All().Value(),
    };
    if (ABIVersion() >= LANDLOCK_ABI_FS_REFER_SUPPORTED) {
      ruleset_attr.handled_access_fs |= FSAccess::REFER;
    }
    int fd = CreateRuleset(&ruleset_attr, sizeof(ruleset_attr), 0);
    if (fd < 0) {
      throw std::system_error(errno, std::generic_category());
    }
    return Ruleset(fd);
  }

  /* Populates the landlock ruleset for a path and any needed paths beneath. */
  void Allow(const std::filesystem::path path, const FSAccess allowed_access) {
    if (!std::filesystem::exists(path)) {
      return;
    }
    int parent_fd = open(path.native().c_str(), O_PATH | O_CLOEXEC);
    auto fd_cleanup = absl::MakeCleanup([parent_fd] { close(parent_fd); });
    if (parent_fd < 0) {
      throw std::system_error(
          errno, std::generic_category(),
          fmt::format("failed to open path: {}", path.native()));
    }
    path_beneath_attr path_beneath = {
        .allowed_access = allowed_access.Value(),
        .parent_fd = parent_fd,
    };
    int error =
        AddRule(ruleset_fd_, rule_type::RULE_PATH_BENEATH, &path_beneath,
                /*flags=*/0);
    if (error) {
      throw std::system_error(
          errno, std::generic_category(),
          fmt::format("failed to update ruleset: path={}, access={}",
                      path.native(), allowed_access.Value()));
    }
  }

  void Apply() {
    int err = prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    if (err) {
      throw std::system_error(errno, std::generic_category(),
                              "failed to restrict process to new privileges");
    }
    err = RestrictSelf(ruleset_fd_, 0);
    if (err) {
      throw std::system_error(errno, std::generic_category(),
                              "failed to apply ruleset");
    }
  }

private:
  explicit Ruleset(int ruleset_fd) : ruleset_fd_(ruleset_fd) {}

  int ruleset_fd_;
};
} // namespace landlock

std::vector<std::string> MakeArgs(int argc, char **argv) {
  std::vector<std::string> args;
  args.reserve(argc);
  for (int i = 1; i < argc; ++i) {
    args.emplace_back(argv[i]);
  }
  return args;
}

int Exec(std::span<std::string> args) {
  std::vector<char *> c_args;
  c_args.reserve(args.size() + 1);
  for (const auto &arg : args) {
    c_args.push_back(const_cast<char *>(arg.c_str()));
  }
  c_args.push_back(nullptr);
  int r = execvp(args.front().c_str(), c_args.data());
  if (r) {
    auto err = std::system_error(
        errno, std::generic_category(),
        fmt::format("failed to exec \"{}\"", fmt::join(args, " ")));
    fmt::println(stderr, "{}", err.what());
    return 1;
  }
  return 0;
}

struct ParsedArgs {
  std::vector<std::filesystem::path> rw_paths;
  std::vector<std::filesystem::path> ro_paths;
  std::vector<std::filesystem::path> rw_dirs;
  std::vector<std::filesystem::path> ro_dirs;
  std::span<std::string> remainder;
  bool debug = false;
};

void ParsePathArg(std::string_view arg, std::span<std::string> *rest,
                  ParsedArgs *parsed) {
  auto original_arg = arg;
  if (!absl::ConsumePrefix(&arg, "--")) {
    throw std::runtime_error(
        fmt::format("invalid argument: \"{}\"", original_arg));
  }
  bool rw = arg.starts_with("rw");
  if (!absl::ConsumePrefix(&arg, "ro") && !absl::ConsumePrefix(&arg, "rw")) {
    throw std::runtime_error(
        fmt::format("invalid argument: \"{}\"", original_arg));
  }
  if (!absl::ConsumePrefix(&arg, "_")) {
    throw std::runtime_error(
        fmt::format("invalid argument: \"{}\"", original_arg));
  }
  bool dirs = arg.starts_with("dirs");
  if (!absl::ConsumePrefix(&arg, "paths") &&
      !absl::ConsumePrefix(&arg, "dirs")) {
    throw std::runtime_error(
        fmt::format("invalid argument: \"{}\"", original_arg));
  }
  if (!absl::ConsumePrefix(&arg, "=")) {
    if (!arg.empty()) {
      throw std::runtime_error(
          fmt::format("invalid argument: \"{}\"", original_arg));
    }
    if (rest->empty()) {
      throw std::runtime_error(
          fmt::format("missing value for: \"{}\"", original_arg));
    }
    arg = rest->front();
    *rest = rest->subspan(1);
  }
  if (arg.empty()) {
    throw std::runtime_error(
        fmt::format("missing value for: \"{}\"", original_arg));
  }
  std::vector<std::string> splits = absl::StrSplit(arg, ":");
  std::vector<std::filesystem::path> *pathnames;
  if (dirs) {
    pathnames = rw ? &parsed->rw_dirs : &parsed->ro_dirs;
  } else {
    pathnames = rw ? &parsed->rw_paths : &parsed->ro_paths;
  }
  for (const auto &split : splits) {
    pathnames->emplace_back(split);
  }
}

ParsedArgs ParseCommandLine(std::span<std::string> args) {
  ParsedArgs parsed;
  while (!args.empty()) {
    auto arg = args.front();
    args = args.subspan(1);
    if (arg == "--") {
      parsed.remainder = args;
      return parsed;
    }
    if (arg == "--debug") {
      parsed.debug = true;
      continue;
    }
    if (arg == "--help") {
      fmt::println(stderr, "A Sandbox process wrapper program, usage:\n"
                           "./process_wrapper --ro_dirs a:b:c "
                           "--rw_paths=/tmp:/usr/tmp -- ./my_program <args>\n\n"
                           "Available flags:\n"
                           "\t--ro_dirs \n\t\ta colon delimited list of "
                           "readonly directory trees\n"
                           "\t--rw_dirs \n\t\ta colon delimited list of "
                           "readwrite directory trees\n"
                           "\t--ro_paths \n\t\ta colon delimited list of "
                           "readonly directories and files\n"
                           "\t--rw_paths \n\t\ta colon delimited list of "
                           "readwrite directories and files\n\n"
                           "NOTE: All flags above refer to a path and *all* "
                           "paths below it - rules are applied recursively");
      std::exit(0);
    }
    ParsePathArg(arg, &args, &parsed);
  }
  throw std::runtime_error("invalid arguments, there must be a -- between "
                           "sandbox args and the actual program");
}

} // namespace

int main(int argc, char **argv) {
  auto args = MakeArgs(argc, argv);
  auto parsed = ParseCommandLine(args);
  if (!landlock::Enabled()) {
    return Exec(parsed.remainder);
  }
  try {
    auto ruleset = landlock::Ruleset::Create();
    // Basically all programs need to load glibc and other system libaries,
    // so make sure they are readable.
    std::vector<std::filesystem::path> automatic_readonly_paths = {
        "/usr", "/bin", "/var", "/lib", "/lib32", "/lib64",
    };
    for (const auto &p : automatic_readonly_paths) {
      ruleset.Allow(p, landlock::FSAccess::Readonly());
    }
    // Give some scratch space in tmp to all programs
    std::vector<std::filesystem::path> automatic_readwrite_paths = {
        "/tmp",
    };
    for (const auto &p : automatic_readwrite_paths) {
      ruleset.Allow(p, landlock::FSAccess::All());
    }
    for (const auto &p : parsed.ro_dirs) {
      ruleset.Allow(p, landlock::FSAccess::AllDir() &
                           landlock::FSAccess::Readonly());
    }
    for (const auto &p : parsed.rw_dirs) {
      ruleset.Allow(p, landlock::FSAccess::AllDir());
    }
    for (const auto &p : parsed.ro_paths) {
      ruleset.Allow(p, landlock::FSAccess::Readonly());
    }
    for (const auto &p : parsed.rw_paths) {
      ruleset.Allow(p, landlock::FSAccess::All());
    }
    ruleset.Apply();
  } catch (const std::exception &ex) {
    fmt::println(stderr, "Failed to apply landlock ruleset: {}", ex.what());
    return 1;
  }
  return Exec(parsed.remainder);
}
