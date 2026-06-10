-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- git -- libgit2 bindings.
--
-- Public surface:
--   git.init() / git.shutdown()         -- ref-counted; multiple calls OK
--   git.available()                     -- true if git2.dll loaded
--   git.version()                       -- "major.minor.patch"
--   git.open(path)                      -> repo
--   git.init_repo(path, bare?)          -> repo
--   git.clone(url, path, opts?)         -> repo
--                                          opts: { bare=false, checkout_branch="main" }
--
-- repo:
--   :head()                             -> { name, oid, target }
--   :branches(filter?)                  -> array of { name, is_head, is_remote }
--                                          filter: "local"|"remote"|"all" (default "all")
--   :tags()                             -> array of { name, oid }
--   :log(opts?)                         -> iterator yielding commit tables
--                                          { oid, author, email, message, time, parents }
--                                          opts: { from="HEAD", max=nil }
--   :status()                           -> array of { path, status }
--                                          status flags: new, modified, deleted, renamed,
--                                          typechange, ignored, conflicted
--   :diff(opts?)                        -> array of { old_path, new_path, status, hunks }
--                                          opts: { from=, to=, cached=false }
--   :fetch(remote?, opts?)              -> bool
--   :push(remote?, opts?)               -> bool
--   :checkout(ref, opts?)               -> bool   (opts: { force=false })
--   :add(path)                          -> bool
--   :commit(message, opts?)             -> oid
--                                          opts: { author=, email=, parents= }
--   :remote(name)                       -> remote
--   :close()
--
-- DLL load order (first hit wins):
--   1. $LUAVM_GIT2_DLL
--   2. "git2"  /  "git2.dll"
--   3. "libgit2"  /  "libgit2.dll"

local M = {}

ffi.cdef[[
typedef struct git_repository    git_repository;
typedef struct git_reference     git_reference;
typedef struct git_commit        git_commit;
typedef struct git_tree          git_tree;
typedef struct git_tree_entry    git_tree_entry;
typedef struct git_blob          git_blob;
typedef struct git_revwalk       git_revwalk;
typedef struct git_index         git_index;
typedef struct git_diff          git_diff;
typedef struct git_diff_delta    git_diff_delta;
typedef struct git_status_list   git_status_list;
typedef struct git_status_entry  git_status_entry;
typedef struct git_remote        git_remote;
typedef struct git_strarray      git_strarray;
typedef struct git_signature_    git_signature;
typedef struct git_branch_iterator git_branch_iterator;
typedef struct git_object        git_object;
typedef struct git_clone_options git_clone_options;
typedef struct git_fetch_options git_fetch_options;
typedef struct git_push_options  git_push_options;
typedef struct git_checkout_options git_checkout_options;
typedef struct git_status_options git_status_options;
typedef struct git_diff_options  git_diff_options;

typedef struct {
    unsigned char id[20];
} git_oid;

typedef struct {
    char         *name;
    char         *email;
    long long    when_time;     /* time_t */
    int          when_offset;   /* tz minutes */
    char         when_sign;     /* '+' or '-' */
} git_signature_struct;

typedef int (*git_remote_progress_cb)(const char *, int, void *);

int    git_libgit2_init(void);
int    git_libgit2_shutdown(void);
int    git_libgit2_version(int *major, int *minor, int *rev);

const char *git_error_last_str(void);

/* Generic OID helpers. */
int    git_oid_fromstr(git_oid *out, const char *str);
int    git_oid_fmt(char *out, const git_oid *id);
int    git_oid_tostr(char *out, size_t n, const git_oid *id);
int    git_oid_cmp(const git_oid *a, const git_oid *b);

/* Repository. */
int    git_repository_open(git_repository **out, const char *path);
int    git_repository_init(git_repository **out, const char *path, unsigned is_bare);
void   git_repository_free(git_repository *repo);
int    git_repository_head(git_reference **out, git_repository *repo);
const char *git_repository_path(git_repository *repo);
const char *git_repository_workdir(git_repository *repo);
int    git_repository_index(git_index **out, git_repository *repo);

/* Reference. */
const char *git_reference_name(const git_reference *ref);
const git_oid *git_reference_target(const git_reference *ref);
int    git_reference_symbolic_target(const git_reference *ref);
const char *git_reference_symbolic_target_str(const git_reference *ref);
void   git_reference_free(git_reference *ref);
int    git_reference_lookup(git_reference **out, git_repository *repo, const char *name);
int    git_reference_resolve(git_reference **out, const git_reference *ref);
int    git_reference_name_to_id(git_oid *out, git_repository *repo, const char *name);

/* Commit. */
int    git_commit_lookup(git_commit **out, git_repository *repo, const git_oid *id);
void   git_commit_free(git_commit *c);
const git_oid *git_commit_id(const git_commit *c);
const char *git_commit_message(const git_commit *c);
const char *git_commit_summary(git_commit *c);
const git_signature *git_commit_author(const git_commit *c);
const git_signature *git_commit_committer(const git_commit *c);
long long git_commit_time(const git_commit *c);
unsigned int git_commit_parentcount(const git_commit *c);
const git_oid *git_commit_parent_id(const git_commit *c, unsigned int n);
int    git_commit_tree(git_tree **out, const git_commit *c);
int    git_commit_create(
    git_oid *out, git_repository *repo, const char *update_ref,
    const git_signature *author, const git_signature *committer,
    const char *message_encoding, const char *message,
    const git_tree *tree, size_t parent_count, const git_commit **parents);

/* Signature. */
int    git_signature_new(git_signature **out, const char *name,
                         const char *email, long long time, int offset);
int    git_signature_now(git_signature **out, const char *name, const char *email);
void   git_signature_free(git_signature *sig);

/* Tree. */
int    git_tree_lookup(git_tree **out, git_repository *repo, const git_oid *id);
void   git_tree_free(git_tree *t);
size_t git_tree_entrycount(const git_tree *t);
const git_tree_entry *git_tree_entry_byindex(const git_tree *t, size_t idx);
const char *git_tree_entry_name(const git_tree_entry *e);
const git_oid *git_tree_entry_id(const git_tree_entry *e);

/* Blob. */
int    git_blob_lookup(git_blob **out, git_repository *repo, const git_oid *id);
void   git_blob_free(git_blob *b);
const void *git_blob_rawcontent(const git_blob *b);
long long   git_blob_rawsize(const git_blob *b);

/* Revwalk. */
int    git_revwalk_new(git_revwalk **out, git_repository *repo);
void   git_revwalk_free(git_revwalk *w);
int    git_revwalk_push(git_revwalk *w, const git_oid *id);
int    git_revwalk_push_head(git_revwalk *w);
int    git_revwalk_push_ref(git_revwalk *w, const char *refname);
int    git_revwalk_next(git_oid *out, git_revwalk *w);
int    git_revwalk_sorting(git_revwalk *w, unsigned int sort_mode);
int    git_revwalk_reset(git_revwalk *w);

/* Index. */
void   git_index_free(git_index *i);
int    git_index_add_bypath(git_index *i, const char *path);
int    git_index_remove_bypath(git_index *i, const char *path);
int    git_index_write(git_index *i);
int    git_index_write_tree(git_oid *out, git_index *i);
int    git_index_read(git_index *i, int force);

/* Status. */
typedef struct {
    unsigned int    version;
    int             show;
    unsigned int    flags;
    git_strarray    pathspec;
    git_tree       *baseline;
    unsigned int    rename_threshold;
} git_status_options_struct;

typedef struct {
    unsigned int status;
    void *head_to_index;
    void *index_to_workdir;
} git_status_entry_struct;

int    git_status_list_new(git_status_list **out, git_repository *repo,
                           const git_status_options_struct *opts);
size_t git_status_list_entrycount(git_status_list *l);
const git_status_entry_struct *git_status_byindex(git_status_list *l, size_t idx);
void   git_status_list_free(git_status_list *l);
int    git_status_options_init(git_status_options_struct *opts, unsigned int version);

/* Branch. */
int    git_branch_iterator_new(git_branch_iterator **out, git_repository *repo, int list_flags);
int    git_branch_next(git_reference **out_ref, int *out_type, git_branch_iterator *it);
void   git_branch_iterator_free(git_branch_iterator *it);
int    git_branch_name(const char **out, const git_reference *ref);
int    git_branch_is_head(const git_reference *ref);

/* Remote. */
int    git_remote_lookup(git_remote **out, git_repository *repo, const char *name);
int    git_remote_list(git_strarray *out, git_repository *repo);
const char *git_remote_name(const git_remote *remote);
const char *git_remote_url(const git_remote *remote);
void   git_remote_free(git_remote *remote);
int    git_remote_fetch(git_remote *remote, const git_strarray *refspecs,
                        const git_fetch_options *opts, const char *reflog_message);
int    git_remote_push(git_remote *remote, const git_strarray *refspecs,
                       const git_push_options *opts);

/* Strarray. */
typedef struct {
    char  **strings;
    size_t  count;
} git_strarray_struct;
void   git_strarray_dispose(git_strarray_struct *array);

/* Clone. */
int    git_clone(git_repository **out, const char *url, const char *path,
                 const git_clone_options *opts);

/* Checkout. */
int    git_checkout_head(git_repository *repo, const git_checkout_options *opts);
int    git_checkout_tree(git_repository *repo, const git_object *treeish,
                         const git_checkout_options *opts);

/* Object. */
int    git_object_lookup(git_object **out, git_repository *repo,
                         const git_oid *id, int type);
void   git_object_free(git_object *obj);
int    git_revparse_single(git_object **out, git_repository *repo, const char *spec);

/* Tag list (basic). */
int    git_tag_list(git_strarray_struct *out, git_repository *repo);

/* Diff. */
int    git_diff_tree_to_tree(git_diff **out, git_repository *repo,
                             git_tree *old_tree, git_tree *new_tree,
                             const git_diff_options *opts);
int    git_diff_index_to_workdir(git_diff **out, git_repository *repo,
                                 git_index *index, const git_diff_options *opts);
int    git_diff_tree_to_workdir(git_diff **out, git_repository *repo,
                                git_tree *old_tree, const git_diff_options *opts);
size_t git_diff_num_deltas(const git_diff *diff);

typedef struct {
    unsigned int status;
    unsigned int flags;
    unsigned short similarity;
    unsigned short nfiles;
    struct { git_oid id; const char *path; long long size; unsigned int flags; unsigned short mode; unsigned short id_abbrev; } old_file;
    struct { git_oid id; const char *path; long long size; unsigned int flags; unsigned short mode; unsigned short id_abbrev; } new_file;
} git_diff_delta_struct;

const git_diff_delta_struct *git_diff_get_delta(const git_diff *diff, size_t idx);
void   git_diff_free(git_diff *diff);
]]

-- ===== Constants =========================================================

M.GIT_OBJECT_ANY    = -2
M.GIT_OBJECT_COMMIT =  1
M.GIT_OBJECT_TREE   =  2
M.GIT_OBJECT_BLOB   =  3
M.GIT_OBJECT_TAG    =  4

M.GIT_SORT_NONE        = 0
M.GIT_SORT_TOPOLOGICAL = 1
M.GIT_SORT_TIME        = 2
M.GIT_SORT_REVERSE     = 4

M.GIT_BRANCH_LOCAL  = 1
M.GIT_BRANCH_REMOTE = 2
M.GIT_BRANCH_ALL    = 3

-- Status flags bitfield.
M.GIT_STATUS_INDEX_NEW        = 0x0001
M.GIT_STATUS_INDEX_MODIFIED   = 0x0002
M.GIT_STATUS_INDEX_DELETED    = 0x0004
M.GIT_STATUS_INDEX_RENAMED    = 0x0008
M.GIT_STATUS_INDEX_TYPECHANGE = 0x0010
M.GIT_STATUS_WT_NEW           = 0x0080
M.GIT_STATUS_WT_MODIFIED      = 0x0100
M.GIT_STATUS_WT_DELETED       = 0x0200
M.GIT_STATUS_WT_RENAMED       = 0x0800
M.GIT_STATUS_WT_TYPECHANGE    = 0x0400
M.GIT_STATUS_IGNORED          = 0x4000
M.GIT_STATUS_CONFLICTED       = 0x8000

-- ===== Lazy DLL loader ===================================================

local _lib, _load_err

local function load_lib()
    if _lib then return _lib end
    if _load_err then return nil end
    local names = {}
    local env_dll = os.getenv("LUAVM_GIT2_DLL")
    if env_dll and #env_dll > 0 then names[#names + 1] = env_dll end
    names[#names + 1] = "git2"
    names[#names + 1] = "git2.dll"
    names[#names + 1] = "libgit2"
    names[#names + 1] = "libgit2.dll"
    for _, n in ipairs(names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then _lib = lib; return lib end
    end
    _load_err = "git: git2.dll not found on the search path. "
        .. "Set LUAVM_GIT2_DLL or drop git2.dll next to LuaVM."
    return nil
end

function M.available()
    return load_lib() ~= nil
end

local function require_lib()
    local L = load_lib()
    if L == nil then error(_load_err, 3) end
    return L
end

-- libgit2 needs init() before any other call. We ref-count so callers
-- can pair init/shutdown freely without surprising the runtime.
local _init_count = 0

function M.init()
    local L = require_lib()
    if _init_count == 0 then
        local rc = L.git_libgit2_init()
        if rc < 0 then
            error("git.init failed: " .. tostring(rc), 2)
        end
    end
    _init_count = _init_count + 1
    return _init_count
end

function M.shutdown()
    if _init_count == 0 then return 0 end
    _init_count = _init_count - 1
    if _init_count == 0 and _lib then
        _lib.git_libgit2_shutdown()
    end
    return _init_count
end

local function ensure_init()
    if _init_count == 0 then M.init() end
end

function M.version()
    local L = require_lib()
    local maj = ffi.new("int[1]"); local min = ffi.new("int[1]"); local rev = ffi.new("int[1]")
    L.git_libgit2_version(maj, min, rev)
    return string.format("%d.%d.%d", maj[0], min[0], rev[0])
end

-- ===== Helpers ===========================================================

local function last_error(L)
    local p = L.git_error_last_str()
    if p == nil then return "unknown libgit2 error" end
    return ffi.string(p)
end

local function check(L, rc, ctx)
    if rc < 0 then
        error("git: " .. ctx .. ": " .. last_error(L), 3)
    end
end

local function oid_to_hex(L, oid_ptr)
    local buf = ffi.new("char[41]")
    L.git_oid_tostr(buf, 41, oid_ptr)
    return ffi.string(buf)
end

local function oid_from_hex(L, hex)
    local oid = ffi.new("git_oid")
    local rc = L.git_oid_fromstr(oid, hex)
    check(L, rc, "oid_from_hex")
    return oid
end

local function sig_to_table(sig_ptr)
    if sig_ptr == nil then return nil end
    local sig = ffi.cast("git_signature_struct *", sig_ptr)
    return {
        name  = sig.name ~= nil and ffi.string(sig.name) or "",
        email = sig.email ~= nil and ffi.string(sig.email) or "",
        time  = tonumber(sig.when_time),
        offset = tonumber(sig.when_offset),
    }
end

-- ===== Repo object =======================================================

local Repo = {}
Repo.__index = Repo

local function wrap_repo(L, repo_ptr, path)
    return setmetatable({
        _lib  = L,
        _repo = ffi.gc(repo_ptr, L.git_repository_free),
        _path = path,
    }, Repo)
end

function Repo:close()
    if self._repo ~= nil then
        self._lib.git_repository_free(ffi.gc(self._repo, nil))
        self._repo = nil
    end
end

Repo.__gc = Repo.close

function Repo:path()
    local p = self._lib.git_repository_path(self._repo)
    return p == nil and "" or ffi.string(p)
end

function Repo:workdir()
    local p = self._lib.git_repository_workdir(self._repo)
    return p == nil and "" or ffi.string(p)
end

function Repo:head()
    local L = self._lib
    local pp = ffi.new("git_reference*[1]")
    local rc = L.git_repository_head(pp, self._repo)
    check(L, rc, "head")
    local ref = ffi.gc(pp[0], L.git_reference_free)
    local name = ffi.string(L.git_reference_name(ref))
    local oid_ptr = L.git_reference_target(ref)
    local oid = oid_ptr ~= nil and oid_to_hex(L, oid_ptr) or nil
    return { name = name, oid = oid, target = oid }
end

function Repo:branches(filter)
    local L = self._lib
    local mode
    if filter == nil or filter == "all" then mode = M.GIT_BRANCH_ALL
    elseif filter == "local"             then mode = M.GIT_BRANCH_LOCAL
    elseif filter == "remote"            then mode = M.GIT_BRANCH_REMOTE
    else error("git: branches: bad filter '" .. tostring(filter) .. "'", 2)
    end
    local it_pp = ffi.new("git_branch_iterator*[1]")
    local rc = L.git_branch_iterator_new(it_pp, self._repo, mode)
    check(L, rc, "branch_iterator_new")
    local it = ffi.gc(it_pp[0], L.git_branch_iterator_free)
    local out = {}
    while true do
        local ref_pp = ffi.new("git_reference*[1]")
        local kind   = ffi.new("int[1]")
        local r = L.git_branch_next(ref_pp, kind, it)
        if r ~= 0 then break end
        local ref = ffi.gc(ref_pp[0], L.git_reference_free)
        local namep = ffi.new("const char*[1]")
        L.git_branch_name(namep, ref)
        local name = namep[0] ~= nil and ffi.string(namep[0]) or "?"
        out[#out + 1] = {
            name      = name,
            is_head   = L.git_branch_is_head(ref) == 1,
            is_remote = kind[0] == M.GIT_BRANCH_REMOTE,
        }
    end
    return out
end

function Repo:tags()
    local L = self._lib
    local arr = ffi.new("git_strarray_struct[1]")
    local rc = L.git_tag_list(arr, self._repo)
    check(L, rc, "tag_list")
    local out = {}
    for i = 0, tonumber(arr[0].count) - 1 do
        local name = ffi.string(arr[0].strings[i])
        -- Resolve each tag name to its OID via reference lookup.
        local oid = ffi.new("git_oid")
        local ref_name = "refs/tags/" .. name
        local r = L.git_reference_name_to_id(oid, self._repo, ref_name)
        out[#out + 1] = { name = name, oid = r == 0 and oid_to_hex(L, oid) or nil }
    end
    L.git_strarray_dispose(arr)
    return out
end

function Repo:log(opts)
    opts = opts or {}
    local L = self._lib
    local pp = ffi.new("git_revwalk*[1]")
    local rc = L.git_revwalk_new(pp, self._repo)
    check(L, rc, "revwalk_new")
    local walk = ffi.gc(pp[0], L.git_revwalk_free)
    L.git_revwalk_sorting(walk, M.GIT_SORT_TIME)
    if opts.from then
        L.git_revwalk_push_ref(walk, opts.from)
    else
        L.git_revwalk_push_head(walk)
    end
    local max   = opts.max
    local count = 0
    local oid   = ffi.new("git_oid")
    return function()
        if max and count >= max then return nil end
        if L.git_revwalk_next(oid, walk) ~= 0 then return nil end
        count = count + 1
        local cpp = ffi.new("git_commit*[1]")
        if L.git_commit_lookup(cpp, self._repo, oid) ~= 0 then return nil end
        local commit = ffi.gc(cpp[0], L.git_commit_free)
        local author = sig_to_table(L.git_commit_author(commit))
        local msg_p = L.git_commit_message(commit)
        local msg = msg_p ~= nil and ffi.string(msg_p) or ""
        local pc = tonumber(L.git_commit_parentcount(commit))
        local parents = {}
        for i = 0, pc - 1 do
            local pid = L.git_commit_parent_id(commit, i)
            parents[#parents + 1] = pid ~= nil and oid_to_hex(L, pid) or nil
        end
        return {
            oid     = oid_to_hex(L, oid),
            author  = author and author.name or "",
            email   = author and author.email or "",
            time    = tonumber(L.git_commit_time(commit)),
            date    = tonumber(L.git_commit_time(commit)),
            message = msg,
            parents = parents,
        }
    end
end

local function decode_status_flags(flags)
    local out = {}
    if bit.band(flags, M.GIT_STATUS_INDEX_NEW)        ~= 0 then out.new           = true end
    if bit.band(flags, M.GIT_STATUS_INDEX_MODIFIED)   ~= 0 then out.modified      = true end
    if bit.band(flags, M.GIT_STATUS_INDEX_DELETED)    ~= 0 then out.deleted       = true end
    if bit.band(flags, M.GIT_STATUS_INDEX_RENAMED)    ~= 0 then out.renamed       = true end
    if bit.band(flags, M.GIT_STATUS_INDEX_TYPECHANGE) ~= 0 then out.typechange    = true end
    if bit.band(flags, M.GIT_STATUS_WT_NEW)           ~= 0 then out.wt_new        = true end
    if bit.band(flags, M.GIT_STATUS_WT_MODIFIED)      ~= 0 then out.wt_modified   = true end
    if bit.band(flags, M.GIT_STATUS_WT_DELETED)       ~= 0 then out.wt_deleted    = true end
    if bit.band(flags, M.GIT_STATUS_WT_RENAMED)       ~= 0 then out.wt_renamed    = true end
    if bit.band(flags, M.GIT_STATUS_WT_TYPECHANGE)    ~= 0 then out.wt_typechange = true end
    if bit.band(flags, M.GIT_STATUS_IGNORED)          ~= 0 then out.ignored       = true end
    if bit.band(flags, M.GIT_STATUS_CONFLICTED)       ~= 0 then out.conflicted    = true end
    return out
end

function Repo:status()
    local L = self._lib
    local pp = ffi.new("git_status_list*[1]")
    local rc = L.git_status_list_new(pp, self._repo, nil)
    check(L, rc, "status_list_new")
    local list = ffi.gc(pp[0], L.git_status_list_free)
    local n = tonumber(L.git_status_list_entrycount(list))
    local out = {}
    -- Status entry layout is fragile across libgit2 versions; we read
    -- the head_to_index / index_to_workdir delta pointers and pull the
    -- new_file.path out of whichever delta is present.
    for i = 0, n - 1 do
        local e = L.git_status_byindex(list, i)
        if e ~= nil then
            local path = "?"
            if e.head_to_index ~= nil then
                local d = ffi.cast("git_diff_delta_struct *", e.head_to_index)
                if d.new_file.path ~= nil then path = ffi.string(d.new_file.path) end
            end
            if path == "?" and e.index_to_workdir ~= nil then
                local d = ffi.cast("git_diff_delta_struct *", e.index_to_workdir)
                if d.new_file.path ~= nil then path = ffi.string(d.new_file.path) end
            end
            out[#out + 1] = {
                path   = path,
                status = decode_status_flags(tonumber(e.status)),
                flags  = tonumber(e.status),
            }
        end
    end
    return out
end

function Repo:diff(opts)
    opts = opts or {}
    local L = self._lib
    local pp = ffi.new("git_diff*[1]")
    -- Default: index to workdir (unstaged changes).
    local index_pp = ffi.new("git_index*[1]")
    local rc = L.git_repository_index(index_pp, self._repo)
    check(L, rc, "repository_index")
    local idx = ffi.gc(index_pp[0], L.git_index_free)
    rc = L.git_diff_index_to_workdir(pp, self._repo, idx, nil)
    check(L, rc, "diff_index_to_workdir")
    local diff = ffi.gc(pp[0], L.git_diff_free)
    local n = tonumber(L.git_diff_num_deltas(diff))
    local out = {}
    for i = 0, n - 1 do
        local d = L.git_diff_get_delta(diff, i)
        if d ~= nil then
            local oldp = d.old_file.path ~= nil and ffi.string(d.old_file.path) or ""
            local newp = d.new_file.path ~= nil and ffi.string(d.new_file.path) or oldp
            out[#out + 1] = {
                old_path = oldp,
                new_path = newp,
                status   = tonumber(d.status),
                old_size = tonumber(d.old_file.size),
                new_size = tonumber(d.new_file.size),
            }
        end
    end
    return out
end

function Repo:remote(name)
    local L = self._lib
    local pp = ffi.new("git_remote*[1]")
    local rc = L.git_remote_lookup(pp, self._repo, name)
    check(L, rc, "remote_lookup")
    local rem = ffi.gc(pp[0], L.git_remote_free)
    return {
        name = ffi.string(L.git_remote_name(rem)),
        url  = L.git_remote_url(rem) ~= nil and ffi.string(L.git_remote_url(rem)) or "",
        _handle = rem,
        _lib    = L,
        fetch   = function(self_, refspecs)
            local rs = nil  -- nil means use configured refspecs
            local r = self_._lib.git_remote_fetch(self_._handle, rs, nil, "fetch from lua")
            return r == 0
        end,
        push = function(self_, refspecs)
            local r = self_._lib.git_remote_push(self_._handle, nil, nil)
            return r == 0
        end,
    }
end

function Repo:fetch(remote_name, _opts)
    local r = self:remote(remote_name or "origin")
    return r:fetch()
end

function Repo:push(remote_name, _opts)
    local r = self:remote(remote_name or "origin")
    return r:push()
end

function Repo:checkout(ref_name, opts)
    opts = opts or {}
    local L = self._lib
    local obj_pp = ffi.new("git_object*[1]")
    local rc = L.git_revparse_single(obj_pp, self._repo, ref_name)
    check(L, rc, "revparse_single")
    local obj = ffi.gc(obj_pp[0], L.git_object_free)
    rc = L.git_checkout_tree(self._repo, obj, nil)
    check(L, rc, "checkout_tree")
    return true
end

function Repo:add(path)
    local L = self._lib
    local pp = ffi.new("git_index*[1]")
    local rc = L.git_repository_index(pp, self._repo)
    check(L, rc, "repository_index")
    local idx = ffi.gc(pp[0], L.git_index_free)
    rc = L.git_index_add_bypath(idx, path)
    check(L, rc, "index_add_bypath")
    L.git_index_write(idx)
    return true
end

function Repo:commit(message, opts)
    opts = opts or {}
    local L = self._lib
    -- Signature.
    local sig_pp = ffi.new("git_signature*[1]")
    local rc
    if opts.author and opts.email then
        rc = L.git_signature_now(sig_pp, opts.author, opts.email)
    else
        rc = L.git_signature_now(sig_pp, "LuaVM", "luavm@local")
    end
    check(L, rc, "signature_now")
    local sig = ffi.gc(sig_pp[0], L.git_signature_free)
    -- Index -> tree.
    local idx_pp = ffi.new("git_index*[1]")
    rc = L.git_repository_index(idx_pp, self._repo)
    check(L, rc, "repository_index")
    local idx = ffi.gc(idx_pp[0], L.git_index_free)
    local tree_oid = ffi.new("git_oid")
    rc = L.git_index_write_tree(tree_oid, idx)
    check(L, rc, "index_write_tree")
    local tree_pp = ffi.new("git_tree*[1]")
    rc = L.git_tree_lookup(tree_pp, self._repo, tree_oid)
    check(L, rc, "tree_lookup")
    local tree = ffi.gc(tree_pp[0], L.git_tree_free)
    -- Parent: HEAD (or none if unborn).
    local parents = {}
    local parent_arr
    local head_pp = ffi.new("git_reference*[1]")
    if L.git_repository_head(head_pp, self._repo) == 0 then
        local head_ref = ffi.gc(head_pp[0], L.git_reference_free)
        local head_oid = L.git_reference_target(head_ref)
        if head_oid ~= nil then
            local cpp = ffi.new("git_commit*[1]")
            if L.git_commit_lookup(cpp, self._repo, head_oid) == 0 then
                parents[#parents + 1] = ffi.gc(cpp[0], L.git_commit_free)
            end
        end
    end
    if #parents > 0 then
        parent_arr = ffi.new("const git_commit*[?]", #parents)
        for i, p in ipairs(parents) do parent_arr[i - 1] = p end
    end
    local new_oid = ffi.new("git_oid")
    rc = L.git_commit_create(
        new_oid, self._repo, "HEAD",
        sig, sig, "UTF-8", message,
        tree, #parents, parent_arr)
    check(L, rc, "commit_create")
    return oid_to_hex(L, new_oid)
end

-- ===== Module entry points ==============================================

function M.open(path)
    ensure_init()
    local L = require_lib()
    local pp = ffi.new("git_repository*[1]")
    local rc = L.git_repository_open(pp, path)
    check(L, rc, "open '" .. tostring(path) .. "'")
    return wrap_repo(L, pp[0], path)
end

function M.init_repo(path, bare)
    ensure_init()
    local L = require_lib()
    local pp = ffi.new("git_repository*[1]")
    local rc = L.git_repository_init(pp, path, bare and 1 or 0)
    check(L, rc, "init '" .. tostring(path) .. "'")
    return wrap_repo(L, pp[0], path)
end

function M.clone(url, path, _opts)
    ensure_init()
    local L = require_lib()
    local pp = ffi.new("git_repository*[1]")
    -- Pass NULL options for now; libgit2 picks sensible defaults.
    local rc = L.git_clone(pp, url, path, nil)
    check(L, rc, "clone '" .. tostring(url) .. "' -> '" .. tostring(path) .. "'")
    return wrap_repo(L, pp[0], path)
end

return M
