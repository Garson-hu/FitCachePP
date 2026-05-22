// Prints the deterministic cached path for (original_path, tier_base) using
// the SAME std::hash<string> + two-level hash-bin scheme as the server data
// mover (fitcache_data_mover.cpp) and the client resolver
// (fitcache_resolve_cached_path). Used to pre-stage a cache for warm-hit
// validation, decoupled from server-side promotion.
//   usage: fitcache_cached_path <original_path> <tier_base>
#include <cstdio>
#include <cstring>
#include <functional>
#include <string>
int main(int argc, char** argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s <original_path> <tier_base>\n", argv[0]); return 2; }
    std::string op(argv[1]); std::string tier(argv[2]);
    size_t h = std::hash<std::string>{}(op);
    char subdir[16];
    snprintf(subdir, sizeof(subdir), "%02zx/%02zx", (h >> 8) & 0xFF, h & 0xFF);
    size_t slash = op.find_last_of('/');
    std::string base = (slash == std::string::npos) ? op : op.substr(slash + 1);
    printf("%s/%s/%s\n", tier.c_str(), subdir, base.c_str());
    return 0;
}
