//! you're looking at my hopeless attempt to implement
//! my dream database. it will be embedded and immutable.
//! it will be practical for both on-disk and in-memory use.
//! there is so much work to do, and so much to learn. we're
//! gonna leeroy jenkins our way through this.

const std = @import("std");
const builtin = @import("builtin");

const BIT_COUNT = 4;
pub const SLOT_COUNT = 1 << BIT_COUNT;
pub const MASK: u64 = SLOT_COUNT - 1;

const SlotInt = u72;
pub const Slot = packed struct {
    value: u64 = 0,
    tag: Tag = .none,
    // "full" means different things depending on the tag:
    // 1. if `none`, it means the slot should be treated as
    //    being used. this allows us to distinguish between
    //    an unused slot (whose tag is always `none`) and
    //    a slot that was explicitly set to `none`.
    // 2. if `bytes` or `short_bytes`, it means the byte
    //    array has a special format tag stored immediately
    //    after it. this format tag is two bytes long and
    //    has no special meaning to xitdb, but users can
    //    use it to interpret the bytes a certain way.
    full: bool = false,

    pub fn eql(self: Slot, other: Slot) bool {
        const self_int: SlotInt = @bitCast(self);
        const other_int: SlotInt = @bitCast(other);
        return self_int == other_int;
    }

    pub fn empty(self: Slot) bool {
        return self.tag == .none and !self.full;
    }
};

pub const SlotPointer = struct {
    position: ?u64,
    slot: Slot,
};

// reordering is a breaking change
pub const Tag = enum(u7) {
    none,
    index,
    array_list,
    linked_array_list,
    hash_map,
    kv_pair,
    bytes,
    short_bytes,
    uint,
    int,
    float,
    hash_set,
    counted_hash_map,
    counted_hash_set,
    sorted_map,
    sorted_set,

    pub fn validate(self: Tag) !void {
        if (null == std.enums.fromInt(Tag, @intFromEnum(self))) {
            return error.InvalidEnumTag;
        }
    }
};

const DATABASE_START = byteSizeOf(DatabaseHeader);
const MAGIC_NUMBER: u24 = std.mem.readInt(u24, "xit", .big);
pub const VERSION: u16 = 0;

const DatabaseHeaderInt = u96;
pub const DatabaseHeader = packed struct {
    // id of the hash algorithm being used. xitdb never looks at
    // this, because it never hashes anything directly, so it
    // doesn't need to know the hash algorithm. it is only here
    // for the sake of readers of the db.
    hash_id: HashId,
    // the size in bytes of all hashes used by the database.
    hash_size: u16,
    // increment this number when the file format changes,
    // such as when a new Tag member is added.
    version: u16 = VERSION,
    // the root tag, representing the type of the top-level data.
    // it starts as .none but will be changed to .array_list
    // once `array_list_init` is called for the first time.
    tag: Tag = .none,
    // currently unused
    padding: u1 = 0,
    // a value that allows for a quick sanity check when determining
    // if the file is a valid database. it also provides a quick
    // visual indicator that this is a xitdb file to anyone looking
    // directly at the bytes.
    magic_number: u24 = MAGIC_NUMBER,

    pub fn read(reader: *std.Io.Reader) !DatabaseHeader {
        return @bitCast(try takeInt(reader, DatabaseHeaderInt, .big));
    }

    pub fn write(self: DatabaseHeader, writer: *std.Io.Writer) !void {
        try writer.writeInt(DatabaseHeaderInt, @bitCast(self), .big);
    }

    pub fn validate(self: DatabaseHeader) !void {
        if (self.magic_number != MAGIC_NUMBER) {
            return error.InvalidDatabase;
        }
        try self.tag.validate();
        if (self.version > VERSION) {
            return error.InvalidVersion;
        }
    }
};

pub const HashId = packed struct(u32) {
    id: u32,

    pub fn fromBytes(hash_name: *const [4]u8) HashId {
        return .{ .id = std.mem.readInt(u32, hash_name, .big) };
    }

    pub fn toBytes(self: HashId) [4]u8 {
        var bytes = [_]u8{0} ** 4;
        std.mem.writeInt(u32, &bytes, self.id, .big);
        return bytes;
    }
};

pub const WriteMode = enum {
    read_only,
    read_write,
};

pub const DatabaseKind = enum {
    memory,
    file,
    buffered_file,
};

pub const InitOptsMemory = struct {
    buffer: *std.Io.Writer.Allocating,
    max_size: ?u64 = null,
    hash_id: ?HashId = null,
};

pub const InitOptsFile = struct {
    io: std.Io,
    file: std.Io.File,
    hash_id: ?HashId = null,
};

pub const InitOptsBufferedFile = struct {
    io: std.Io,
    file: std.Io.File,
    buffer: *std.Io.Writer.Allocating,
    max_size: u64 = 2 * 1024 * 1024, // flushes when the memory is >= this size
    hash_id: ?HashId = null,
};

pub fn InitOpts(comptime db_kind: DatabaseKind) type {
    return switch (db_kind) {
        .memory => InitOptsMemory,
        .file => InitOptsFile,
        .buffered_file => InitOptsBufferedFile,
    };
}

pub fn Core(comptime db_kind: DatabaseKind) type {
    return switch (db_kind) {
        .memory => CoreMemory,
        .file => CoreFile,
        .buffered_file => CoreBufferedFile,
    };
}

pub fn Database(comptime db_kind: DatabaseKind, comptime HashInt: type) type {
    return struct {
        core: Core(db_kind),
        header: DatabaseHeader,
        tx_start: ?u64,

        // internal constants

        const HASH_SIZE = byteSizeOf(HashInt);
        const INDEX_BLOCK_SIZE = byteSizeOf(Slot) * SLOT_COUNT;
        const MAX_BRANCH_LENGTH: usize = 16;
        // the iterator pushes one stack level per tree level. the deepest
        // iterable structure is the hash trie (HASH_SIZE*8/BIT_COUNT levels) or
        // a b-tree (height is at most log2 of a u64 size = 64, given the minimum
        // fan-out of 2); the array list's radix trie is shallower than both.
        const ITERATOR_STACK_SIZE = @max(HASH_SIZE * 8 / BIT_COUNT, byteSizeOf(u64) * 8);

        const ArrayListHeaderInt = u128;
        const ArrayListHeader = packed struct {
            ptr: u64,
            size: u64,
        };

        const TopLevelArrayListHeaderInt = u192;
        const TopLevelArrayListHeader = packed struct {
            file_size: u64,
            parent: ArrayListHeader,
        };

        const KeyValuePairInt = @typeInfo(KeyValuePair).@"struct".backing_integer.?;
        const KeyValuePair = packed struct {
            value_slot: Slot,
            key_slot: Slot,
            hash: HashInt,
        };

        const BTREE_SLOT_COUNT = SLOT_COUNT; // max entries per leaf / children per branch
        const BTREE_SPLIT_COUNT = (BTREE_SLOT_COUNT + 1) / 2; // left side of a split
        // on-disk node block: [kind: u8][num: u8] followed by, for a leaf,
        // BTREE_SLOT_COUNT value slots; for a branch, BTREE_SLOT_COUNT child
        // slots then BTREE_SLOT_COUNT u64 subtree counts
        const BTREE_NODE_HEADER_SIZE = byteSizeOf(u8) * 2;
        const BTREE_LEAF_BLOCK_SIZE = BTREE_NODE_HEADER_SIZE + byteSizeOf(Slot) * BTREE_SLOT_COUNT;
        const BTREE_BRANCH_BLOCK_SIZE = BTREE_NODE_HEADER_SIZE + (byteSizeOf(Slot) + byteSizeOf(u64)) * BTREE_SLOT_COUNT;

        const BTreeHeaderInt = u128;
        const BTreeHeader = packed struct {
            root_ptr: u64,
            size: u64,
        };

        const BTreeNodeKind = enum(u8) { leaf, branch };

        const BTreeNode = struct {
            kind: BTreeNodeKind,
            num: u8,
            values: [BTREE_SLOT_COUNT]Slot = [_]Slot{.{}} ** BTREE_SLOT_COUNT, // leaf
            children: [BTREE_SLOT_COUNT]Slot = [_]Slot{.{}} ** BTREE_SLOT_COUNT, // branch
            counts: [BTREE_SLOT_COUNT]u64 = [_]u64{0} ** BTREE_SLOT_COUNT, // branch

            fn subtreeCount(self: *const BTreeNode) u64 {
                if (self.kind == .leaf) return self.num;
                var total: u64 = 0;
                for (self.counts[0..self.num]) |c| total += c;
                return total;
            }
        };

        const BTreeInsertResult = struct {
            node_ptr: u64,
            count: u64,
            // file position of the newly inserted element's value slot, so the
            // caller can write the value into it
            value_position: u64,
            // set when this node overflowed and split off a new right sibling
            split: ?struct { node_ptr: u64, count: u64 },
        };

        const HashMapSlotKind = enum {
            kv_pair,
            key,
            value,
        };

        // sorted_map / sorted_set: a count-augmented B+tree keyed on arbitrary
        // byte strings, ordered lexicographically. reuses the b-tree's capacity
        // constants, persistence model (tx_start reuse), KeyValuePair entries, and
        // the `BTreeHeader{root_ptr, size}` header (identical layout).
        const SortedNodeKind = enum(u8) { leaf, branch };

        // on-disk node block: [kind: u8][num: u8] followed by, for a leaf,
        // BTREE_SLOT_COUNT .kv_pair slots (entries in ascending key order); for a
        // branch, BTREE_SLOT_COUNT child slots (.index), then BTREE_SLOT_COUNT
        // separator slots (a bytes/short_bytes slot = the smallest key in that
        // child's subtree; separators[0] is an unused sentinel), then
        // BTREE_SLOT_COUNT u64 subtree counts.
        const SORTED_LEAF_BLOCK_SIZE = BTREE_NODE_HEADER_SIZE + byteSizeOf(Slot) * BTREE_SLOT_COUNT;
        const SORTED_BRANCH_BLOCK_SIZE = BTREE_NODE_HEADER_SIZE + (byteSizeOf(Slot) * 2 + byteSizeOf(u64)) * BTREE_SLOT_COUNT;

        const SortedNode = struct {
            kind: SortedNodeKind,
            num: u8,
            entries: [BTREE_SLOT_COUNT]Slot = [_]Slot{.{}} ** BTREE_SLOT_COUNT, // leaf
            children: [BTREE_SLOT_COUNT]Slot = [_]Slot{.{}} ** BTREE_SLOT_COUNT, // branch
            separators: [BTREE_SLOT_COUNT]Slot = [_]Slot{.{}} ** BTREE_SLOT_COUNT, // branch
            counts: [BTREE_SLOT_COUNT]u64 = [_]u64{0} ** BTREE_SLOT_COUNT, // branch

            fn subtreeCount(self: *const SortedNode) u64 {
                if (self.kind == .leaf) return self.num;
                var total: u64 = 0;
                for (self.counts[0..self.num]) |c| total += c;
                return total;
            }
        };

        // insert/replace result: where to write the value, whether a new entry was
        // added (vs replacing), and the new right sibling if this node split
        const SortedInsertResult = struct {
            node_ptr: u64,
            count: u64,
            value_position: u64,
            added: bool,
            split: ?struct { node_ptr: u64, count: u64, separator: Slot },
        };

        // remove result threaded back up the descent: the rewritten node and whether
        // the key was found. separators are stable lower-bound boundaries (not exact
        // mins), so deletions never need to refresh them; an emptied leaf is simply
        // left in place (its slot is reclaimed by compaction), which keeps every leaf
        // at equal depth with no rebalancing.
        const SortedRemoveResult = struct {
            node_ptr: u64,
            found: bool,
        };

        pub const Bytes = struct {
            value: []const u8,
            // the format tag can be any arbitrary two bytes.
            // this is never used by xitdb itself, but it is
            // stored with the byte array and can be retrieved
            // by calling `readBytesObject`. the purpose is to
            // allow users to interpret byte arrays in special
            // ways. for example, if you need to store an int
            // that is larger than 64 bits, you could store it
            // as a byte array and give it a format tag such
            // as "bi" so you can interpret it as a big integer.
            format_tag: ?[2]u8 = null,

            pub fn isShort(self: Bytes) bool {
                const total_size = if (self.format_tag != null) byteSizeOf(u64) - 2 else byteSizeOf(u64);
                return self.value.len <= total_size and null == std.mem.indexOfScalar(u8, self.value, 0);
            }
        };

        pub const WriteableData = union(enum) {
            slot: ?Slot,
            uint: u64,
            int: i64,
            float: f64,
            bytes: []const u8,
            bytes_object: Bytes,
        };

        pub fn PathPart(comptime Ctx: type) type {
            return union(enum) {
                array_list_init,
                array_list_get: i65,
                array_list_append,
                array_list_slice: struct {
                    size: u64,
                },
                linked_array_list_init,
                linked_array_list_get: i65,
                linked_array_list_append,
                linked_array_list_slice: struct {
                    offset: u64,
                    size: u64,
                },
                linked_array_list_concat: struct {
                    list: Slot,
                },
                linked_array_list_insert: i65,
                linked_array_list_remove: i65,
                hash_map_init: struct {
                    counted: bool = false,
                    set: bool = false,
                },
                hash_map_get: union(HashMapSlotKind) {
                    kv_pair: HashInt,
                    key: HashInt,
                    value: HashInt,
                },
                hash_map_remove: HashInt,
                sorted_map_init: struct {
                    set: bool = false,
                },
                sorted_map_get: union(HashMapSlotKind) {
                    kv_pair: []const u8,
                    key: []const u8,
                    value: []const u8,
                },
                sorted_map_get_index: i65,
                sorted_map_remove: []const u8,
                write: WriteableData,
                ctx: Ctx,
            };
        }

        // init

        pub fn init(opts: InitOpts(db_kind)) !Database(db_kind, HashInt) {
            var self: Database(db_kind, HashInt) = switch (db_kind) {
                .memory => .{
                    .core = .{
                        .buffer = opts.buffer,
                        .max_size = opts.max_size,
                    },
                    .header = undefined,
                    .tx_start = null,
                },
                .file => .{
                    .core = .{
                        .io = opts.io,
                        .file = opts.file,
                    },
                    .header = undefined,
                    .tx_start = null,
                },
                .buffered_file => .{
                    .core = .{
                        .memory = .{
                            .buffer = opts.buffer,
                            .max_size = null,
                        },
                        .memory_max_size = opts.max_size,
                        .file = .{
                            .io = opts.io,
                            .file = opts.file,
                        },
                    },
                    .header = undefined,
                    .tx_start = null,
                },
            };

            if (try self.core.length() == 0) {
                self.header = .{
                    .hash_id = opts.hash_id orelse .{ .id = 0 },
                    .hash_size = byteSizeOf(HashInt),
                };
                var writer = self.core.writer();
                try writer.seekTo(0);
                try self.header.write(&writer.interface);
                try self.core.flush();
            } else {
                var reader = self.core.reader();
                try reader.seekTo(0);
                self.header = try DatabaseHeader.read(&reader.interface);
                try self.header.validate();
                if (self.header.hash_size != byteSizeOf(HashInt)) {
                    return error.InvalidHashSize;
                }
                try self.truncate();
            }

            return self;
        }

        pub fn rootCursor(self: *Database(db_kind, HashInt)) Cursor(.read_write) {
            return .{
                .slot_ptr = .{ .position = null, .slot = .{ .value = DATABASE_START, .tag = self.header.tag } },
                .db = self,
            };
        }

        pub fn freeze(self: *Database(db_kind, HashInt)) !void {
            if (self.tx_start != null) {
                self.tx_start = try self.core.length();
            } else {
                return error.ExpectedTxStart;
            }
        }

        pub fn compact(self: *Database(db_kind, HashInt), comptime target_db_kind: DatabaseKind, target_opts: InitOpts(target_db_kind), offset_map: *std.AutoHashMap(u64, u64)) !Database(target_db_kind, HashInt) {
            var opts = target_opts;
            opts.hash_id = target_opts.hash_id orelse self.header.hash_id;
            var target = try Database(target_db_kind, HashInt).init(opts);

            if (self.header.tag == .none) return target;
            if (self.header.tag != .array_list) return error.UnexpectedTag;

            // read source's top-level ArrayListHeader
            var source_reader = self.core.reader();
            try source_reader.seekTo(DATABASE_START);
            const source_header: ArrayListHeader = @bitCast(try takeInt(&source_reader.interface, ArrayListHeaderInt, .big));

            if (source_header.size == 0) return target;

            // read the last moment's slot
            const last_key = source_header.size - 1;
            const shift: u6 = @intCast(if (last_key < SLOT_COUNT) 0 else std.math.log(u64, SLOT_COUNT, last_key));
            const last_slot_ptr = try self.readArrayListSlot(source_header.ptr, last_key, shift, .read_only, true);
            const moment_slot = last_slot_ptr.slot;

            // write TopLevelArrayListHeader + root index block to target
            var target_writer = target.core.writer();
            try target_writer.seekTo(DATABASE_START);
            const target_array_list_ptr = DATABASE_START + byteSizeOf(TopLevelArrayListHeader);
            try target_writer.interface.writeInt(TopLevelArrayListHeaderInt, @bitCast(TopLevelArrayListHeader{
                .file_size = 0,
                .parent = .{
                    .ptr = target_array_list_ptr,
                    .size = 1,
                },
            }), .big);
            const index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
            try target_writer.interface.writeAll(&index_block);

            // recursively remap the moment slot
            const remapped_moment = try remapSlot(&self.core, target_db_kind, &target.core, offset_map, moment_slot);

            // write remapped moment slot into position 0 of target's root index block
            try target_writer.seekTo(target_array_list_ptr);
            try target_writer.interface.writeInt(SlotInt, @bitCast(remapped_moment), .big);

            // update target's DatabaseHeader tag
            target.header.tag = .array_list;
            try target_writer.seekTo(0);
            try target.header.write(&target_writer.interface);

            // flush, update file_size, flush again
            try target.core.flush();
            const file_size = try target.core.length();
            try target_writer.seekTo(DATABASE_START + byteSizeOf(ArrayListHeader));
            try target_writer.interface.writeInt(u64, file_size, .big);
            try target.core.flush();

            return target;
        }

        // private

        fn truncate(self: *Database(db_kind, HashInt)) !void {
            if (self.header.tag != .array_list) return;

            const root_cursor = self.rootCursor();
            const list_size = try root_cursor.count();

            if (list_size == 0) return;

            var core_reader = self.core.reader();
            try core_reader.seekTo(DATABASE_START + byteSizeOf(ArrayListHeader));
            const header_file_size = try takeInt(&core_reader.interface, u64, .big);

            if (header_file_size == 0) return;

            const file_size = try self.core.length();

            if (file_size == header_file_size) return;

            try self.core.setLength(header_file_size);
        }

        fn readSlotPointer(self: *Database(db_kind, HashInt), comptime write_mode: WriteMode, comptime Ctx: type, path: []const PathPart(Ctx), slot_ptr: SlotPointer) !SlotPointer {
            const part = if (path.len > 0) path[0] else {
                if (write_mode == .read_only and slot_ptr.slot.tag == .none) {
                    return error.KeyNotFound;
                }
                return slot_ptr;
            };

            const is_top_level = slot_ptr.slot.value == DATABASE_START;

            const is_tx_start = is_top_level and self.header.tag == .array_list and self.tx_start == null;
            if (is_tx_start) {
                self.tx_start = try self.core.length();
            }
            defer {
                if (is_tx_start) {
                    self.tx_start = null;
                }
            }

            switch (part) {
                .array_list_init => {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (is_top_level) {
                        var writer = self.core.writer();

                        // if the top level array list hasn't been initialized
                        if (self.header.tag == .none) {
                            // write the array list header
                            try writer.seekTo(DATABASE_START);
                            const array_list_ptr = DATABASE_START + byteSizeOf(TopLevelArrayListHeader);
                            try writer.interface.writeInt(TopLevelArrayListHeaderInt, @bitCast(TopLevelArrayListHeader{
                                .file_size = 0,
                                .parent = .{
                                    .ptr = array_list_ptr,
                                    .size = 0,
                                },
                            }), .big);

                            // write the first block
                            const index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                            try writer.interface.writeAll(&index_block);

                            // update db header
                            try writer.seekTo(0);
                            self.header.tag = .array_list;
                            try writer.interface.writeInt(DatabaseHeaderInt, @bitCast(self.header), .big);
                        }

                        var next_slot_ptr = slot_ptr;
                        next_slot_ptr.slot.tag = .array_list;
                        return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                    }

                    const position = slot_ptr.position orelse return error.CursorNotWriteable;

                    switch (slot_ptr.slot.tag) {
                        .none => {
                            // if slot was empty, insert the new list
                            var writer = self.core.writer();
                            const array_list_start = try self.core.length();
                            const array_list_ptr = array_list_start + byteSizeOf(ArrayListHeader);
                            try writer.seekTo(array_list_start);
                            try writer.interface.writeInt(ArrayListHeaderInt, @bitCast(ArrayListHeader{
                                .ptr = array_list_ptr,
                                .size = 0,
                            }), .big);
                            const array_list_index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                            try writer.interface.writeAll(&array_list_index_block);
                            // make slot point to list
                            const next_slot_ptr = SlotPointer{ .position = position, .slot = .{ .value = array_list_start, .tag = .array_list } };
                            try writer.seekTo(position);
                            try writer.interface.writeInt(SlotInt, @bitCast(next_slot_ptr.slot), .big);
                            return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                        },
                        .array_list => {
                            var reader = self.core.reader();
                            var writer = self.core.writer();

                            var array_list_start = slot_ptr.slot.value;

                            // copy it to the end unless it was made in this transaction
                            if (self.tx_start) |tx_start| {
                                if (array_list_start < tx_start) {
                                    // read existing block
                                    try reader.seekTo(array_list_start);
                                    var header: ArrayListHeader = @bitCast(try takeInt(&reader.interface, ArrayListHeaderInt, .big));
                                    try reader.seekTo(header.ptr);
                                    var array_list_index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                                    try reader.interface.readSliceAll(&array_list_index_block);
                                    // copy to the end
                                    array_list_start = try self.core.length();
                                    const next_array_list_ptr = array_list_start + byteSizeOf(ArrayListHeader);
                                    header.ptr = next_array_list_ptr;
                                    try writer.seekTo(array_list_start);
                                    try writer.interface.writeInt(ArrayListHeaderInt, @bitCast(header), .big);
                                    try writer.interface.writeAll(&array_list_index_block);
                                }
                            } else if (self.header.tag == .array_list) {
                                return error.ExpectedTxStart;
                            }

                            // make slot point to list
                            const next_slot_ptr = SlotPointer{ .position = position, .slot = .{ .value = array_list_start, .tag = .array_list } };
                            try writer.seekTo(position);
                            try writer.interface.writeInt(SlotInt, @bitCast(next_slot_ptr.slot), .big);
                            return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                        },
                        else => return error.UnexpectedTag,
                    }
                },
                .array_list_get => |index| {
                    const tag = if (is_top_level) self.header.tag else slot_ptr.slot.tag;
                    switch (tag) {
                        .none => return error.KeyNotFound,
                        .array_list => {},
                        else => return error.UnexpectedTag,
                    }

                    const next_array_list_start = slot_ptr.slot.value;

                    var reader = self.core.reader();
                    try reader.seekTo(next_array_list_start);
                    const header: ArrayListHeader = @bitCast(try takeInt(&reader.interface, ArrayListHeaderInt, .big));
                    if (index >= header.size or index < -@as(i65, header.size)) {
                        return error.KeyNotFound;
                    }

                    const key: u64 = if (index < 0)
                        @intCast(header.size - @abs(index))
                    else
                        @intCast(index);
                    const last_key = header.size - 1;
                    const shift: u6 = @intCast(if (last_key < SLOT_COUNT) 0 else std.math.log(u64, SLOT_COUNT, last_key));
                    const final_slot_ptr = try self.readArrayListSlot(header.ptr, key, shift, write_mode, is_top_level);

                    return try self.readSlotPointer(write_mode, Ctx, path[1..], final_slot_ptr);
                },
                .array_list_append => {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    const tag = if (is_top_level) self.header.tag else slot_ptr.slot.tag;
                    if (tag != .array_list) return error.UnexpectedTag;

                    var reader = self.core.reader();
                    const next_array_list_start = slot_ptr.slot.value;

                    // read header
                    try reader.seekTo(next_array_list_start);
                    const orig_header: ArrayListHeader = @bitCast(try takeInt(&reader.interface, ArrayListHeaderInt, .big));

                    // append
                    const append_result = try self.readArrayListSlotAppend(orig_header, write_mode, is_top_level);
                    const final_slot_ptr = try self.readSlotPointer(write_mode, Ctx, path[1..], append_result.slot_ptr);

                    var writer = self.core.writer();

                    // if top level array list, put the file size in the header
                    if (is_top_level) {
                        // it is very important that we flush before updating the header,
                        // because updating the header is what completes the transaction
                        try self.core.flush();

                        const file_size = try self.core.length();
                        const header = TopLevelArrayListHeader{
                            .file_size = file_size,
                            .parent = append_result.header,
                        };

                        // update header
                        try writer.seekTo(next_array_list_start);
                        try writer.interface.writeInt(TopLevelArrayListHeaderInt, @bitCast(header), .big);
                    } else {
                        // update header
                        try writer.seekTo(next_array_list_start);
                        try writer.interface.writeInt(ArrayListHeaderInt, @bitCast(append_result.header), .big);
                    }

                    return final_slot_ptr;
                },
                .array_list_slice => |array_list_slice| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .array_list) return error.UnexpectedTag;

                    var reader = self.core.reader();
                    const next_array_list_start = slot_ptr.slot.value;

                    // read header
                    try reader.seekTo(next_array_list_start);
                    const orig_header: ArrayListHeader = @bitCast(try takeInt(&reader.interface, ArrayListHeaderInt, .big));

                    // slice
                    const slice_header = try self.readArrayListSlice(orig_header, array_list_slice.size);
                    const final_slot_ptr = try self.readSlotPointer(write_mode, Ctx, path[1..], slot_ptr);

                    // update header
                    var writer = self.core.writer();
                    try writer.seekTo(next_array_list_start);
                    try writer.interface.writeInt(ArrayListHeaderInt, @bitCast(slice_header), .big);

                    return final_slot_ptr;
                },
                .linked_array_list_init => {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (is_top_level) return error.InvalidTopLevelType;

                    const position = slot_ptr.position orelse return error.CursorNotWriteable;

                    var writer = self.core.writer();

                    switch (slot_ptr.slot.tag) {
                        .none => {
                            // create an empty tree: a single empty leaf plus a header
                            const root_ptr = try self.writeBTreeNode(.{ .kind = .leaf, .num = 0 });
                            const header_ptr = try self.core.length();
                            try writer.seekTo(header_ptr);
                            try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{ .root_ptr = root_ptr, .size = 0 }), .big);
                            const next_slot_ptr = SlotPointer{ .position = position, .slot = .{ .value = header_ptr, .tag = .linked_array_list } };
                            try writer.seekTo(position);
                            try writer.interface.writeInt(SlotInt, @bitCast(next_slot_ptr.slot), .big);
                            return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                        },
                        .linked_array_list => {
                            var header_ptr = slot_ptr.slot.value;
                            // copy the header into this transaction unless it was made in it,
                            // so past moments still pointing at the old header are unaffected.
                            // b-tree nodes are always appended, so only the header (updated in
                            // place by later operations in this tx) needs copying.
                            if (self.tx_start) |tx_start| {
                                if (header_ptr < tx_start) {
                                    var reader = self.core.reader();
                                    try reader.seekTo(header_ptr);
                                    const header_int = try takeInt(&reader.interface, BTreeHeaderInt, .big);
                                    header_ptr = try self.core.length();
                                    try writer.seekTo(header_ptr);
                                    try writer.interface.writeInt(BTreeHeaderInt, header_int, .big);
                                }
                            } else if (self.header.tag == .array_list) {
                                return error.ExpectedTxStart;
                            }
                            const next_slot_ptr = SlotPointer{ .position = position, .slot = .{ .value = header_ptr, .tag = .linked_array_list } };
                            try writer.seekTo(position);
                            try writer.interface.writeInt(SlotInt, @bitCast(next_slot_ptr.slot), .big);
                            return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                        },
                        else => return error.UnexpectedTag,
                    }
                },
                .linked_array_list_get => |index| {
                    switch (slot_ptr.slot.tag) {
                        .none => return error.KeyNotFound,
                        .linked_array_list => {},
                        else => return error.UnexpectedTag,
                    }

                    const header_ptr = slot_ptr.slot.value;
                    var reader = self.core.reader();
                    try reader.seekTo(header_ptr);
                    const header: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));
                    if (index >= header.size or index < -@as(i65, header.size)) {
                        return error.KeyNotFound;
                    }
                    const rank: u64 = if (index < 0)
                        @intCast(header.size - @abs(index))
                    else
                        @intCast(index);

                    if (write_mode == .read_only) {
                        const final_slot_ptr = try self.readBTreeSlot(header.root_ptr, rank);
                        return try self.readSlotPointer(write_mode, Ctx, path[1..], final_slot_ptr);
                    } else {
                        // path-copy down to the value slot so the write is persistent
                        const write_slot = try self.btreeGetForWrite(header.root_ptr, rank);
                        const final_slot_ptr = try self.readSlotPointer(write_mode, Ctx, path[1..], .{ .position = write_slot.value_position, .slot = write_slot.slot });
                        // the header only needs rewriting if the root actually moved
                        // (it stays put when the whole path was already this-transaction)
                        if (write_slot.node_ptr != header.root_ptr) {
                            var writer = self.core.writer();
                            try writer.seekTo(header_ptr);
                            try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{ .root_ptr = write_slot.node_ptr, .size = header.size }), .big);
                        }
                        return final_slot_ptr;
                    }
                },
                .linked_array_list_append => {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .linked_array_list) return error.UnexpectedTag;

                    const header_ptr = slot_ptr.slot.value;
                    var reader = self.core.reader();
                    try reader.seekTo(header_ptr);
                    const header: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));

                    const result = try self.btreeInsert(header.root_ptr, header.size);
                    const new_root_ptr = try self.btreeGrowRoot(result);

                    // update the header before filling in the value, so that a failure
                    // in the rest of the path leaves the tree and header consistent
                    var writer = self.core.writer();
                    try writer.seekTo(header_ptr);
                    try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{ .root_ptr = new_root_ptr, .size = header.size + 1 }), .big);

                    // fill in the value via the rest of the path
                    return self.readSlotPointer(write_mode, Ctx, path[1..], .{ .position = result.value_position, .slot = .{} });
                },
                .linked_array_list_slice => |linked_array_list_slice| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .linked_array_list) return error.UnexpectedTag;

                    const header_ptr = slot_ptr.slot.value;
                    var reader = self.core.reader();
                    try reader.seekTo(header_ptr);
                    const header: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));

                    // bounds-checked without overflow (offset + size could wrap)
                    if (linked_array_list_slice.offset > header.size or
                        linked_array_list_slice.size > header.size - linked_array_list_slice.offset)
                    {
                        return error.KeyNotFound;
                    }

                    // slice = drop [0, offset) then keep [0, size) of what's left
                    const after_offset = try self.btreeSplit(header.root_ptr, linked_array_list_slice.offset);
                    const sliced = try self.btreeSplit(after_offset.right, linked_array_list_slice.size);
                    const new_root_ptr = sliced.left;

                    // update the header before recursing into the rest of the path, so
                    // that a failure there leaves the tree and header consistent
                    var writer = self.core.writer();
                    try writer.seekTo(header_ptr);
                    try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{ .root_ptr = new_root_ptr, .size = linked_array_list_slice.size }), .big);

                    return self.readSlotPointer(write_mode, Ctx, path[1..], slot_ptr);
                },
                .linked_array_list_concat => |linked_array_list_concat| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .linked_array_list) return error.UnexpectedTag;

                    if (linked_array_list_concat.list.tag != .linked_array_list) return error.UnexpectedTag;

                    const header_ptr = slot_ptr.slot.value;
                    var reader = self.core.reader();
                    try reader.seekTo(header_ptr);
                    const header_a: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));
                    try reader.seekTo(linked_array_list_concat.list.value);
                    const header_b: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));

                    // the join result shares subtrees with both operands (and the
                    // second operand stays live), so freeze everything created so far:
                    // later in-place mutations will then copy those nodes instead of
                    // overwriting a node that is still referenced elsewhere.
                    self.tx_start = try self.core.length();
                    const new_root_ptr = try self.btreeJoin(header_a.root_ptr, header_b.root_ptr);

                    // update the header before recursing into the rest of the path, so
                    // that a failure there leaves the tree and header consistent
                    var writer = self.core.writer();
                    try writer.seekTo(header_ptr);
                    try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{ .root_ptr = new_root_ptr, .size = header_a.size + header_b.size }), .big);

                    return self.readSlotPointer(write_mode, Ctx, path[1..], slot_ptr);
                },
                .linked_array_list_insert => |index| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .linked_array_list) return error.UnexpectedTag;

                    const header_ptr = slot_ptr.slot.value;
                    var reader = self.core.reader();
                    try reader.seekTo(header_ptr);
                    const header: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));

                    if (index >= header.size or index < -@as(i65, header.size)) {
                        return error.KeyNotFound;
                    }
                    const rank: u64 = if (index < 0)
                        @intCast(header.size - @abs(index))
                    else
                        @intCast(index);

                    const result = try self.btreeInsert(header.root_ptr, rank);
                    const new_root_ptr = try self.btreeGrowRoot(result);

                    // update the header before filling in the value, so that a failure
                    // in the rest of the path leaves the tree and header consistent
                    var writer = self.core.writer();
                    try writer.seekTo(header_ptr);
                    try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{ .root_ptr = new_root_ptr, .size = header.size + 1 }), .big);

                    return self.readSlotPointer(write_mode, Ctx, path[1..], .{ .position = result.value_position, .slot = .{} });
                },
                .linked_array_list_remove => |index| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .linked_array_list) return error.UnexpectedTag;

                    const header_ptr = slot_ptr.slot.value;
                    var reader = self.core.reader();
                    try reader.seekTo(header_ptr);
                    const header: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));

                    if (index >= header.size or index < -@as(i65, header.size)) {
                        return error.KeyNotFound;
                    }
                    const rank: u64 = if (index < 0)
                        @intCast(header.size - @abs(index))
                    else
                        @intCast(index);

                    // remove = join the parts before and after the removed element
                    const before = try self.btreeSplit(header.root_ptr, rank);
                    const after = try self.btreeSplit(before.right, 1);
                    const new_root_ptr = try self.btreeJoin(before.left, after.right);

                    // update the header before recursing into the rest of the path, so
                    // that a failure there leaves the tree and header consistent
                    var writer = self.core.writer();
                    try writer.seekTo(header_ptr);
                    try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{ .root_ptr = new_root_ptr, .size = header.size - 1 }), .big);

                    return self.readSlotPointer(write_mode, Ctx, path[1..], slot_ptr);
                },
                .hash_map_init => |hash_map_init| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    const tag: Tag = if (hash_map_init.counted)
                        (if (hash_map_init.set) .counted_hash_set else .counted_hash_map)
                    else
                        (if (hash_map_init.set) .hash_set else .hash_map);

                    if (is_top_level) {
                        var writer = self.core.writer();

                        // if the top level hash map hasn't been initialized
                        if (self.header.tag == .none) {
                            try writer.seekTo(DATABASE_START);

                            if (hash_map_init.counted) {
                                try writer.interface.writeInt(u64, 0, .big);
                            }

                            // write the first block
                            const map_index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                            try writer.interface.writeAll(&map_index_block);

                            // update db header
                            try writer.seekTo(0);
                            self.header.tag = tag;
                            try writer.interface.writeInt(DatabaseHeaderInt, @bitCast(self.header), .big);
                        }

                        var next_slot_ptr = slot_ptr;
                        next_slot_ptr.slot.tag = tag;
                        return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                    }

                    const position = slot_ptr.position orelse return error.CursorNotWriteable;

                    switch (slot_ptr.slot.tag) {
                        .none => {
                            // if slot was empty, insert the new map
                            var writer = self.core.writer();
                            const map_start = try self.core.length();
                            try writer.seekTo(map_start);
                            if (hash_map_init.counted) {
                                try writer.interface.writeInt(u64, 0, .big);
                            }
                            const map_index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                            try writer.interface.writeAll(&map_index_block);
                            // make slot point to map
                            const next_slot_ptr = SlotPointer{ .position = position, .slot = .{ .value = map_start, .tag = tag } };
                            try writer.seekTo(position);
                            try writer.interface.writeInt(SlotInt, @bitCast(next_slot_ptr.slot), .big);
                            return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                        },
                        .hash_map, .hash_set, .counted_hash_map, .counted_hash_set => {
                            if (hash_map_init.counted) {
                                switch (slot_ptr.slot.tag) {
                                    .counted_hash_map, .counted_hash_set => {},
                                    else => return error.UnexpectedTag,
                                }
                            } else {
                                switch (slot_ptr.slot.tag) {
                                    .hash_map, .hash_set => {},
                                    else => return error.UnexpectedTag,
                                }
                            }

                            var reader = self.core.reader();
                            var writer = self.core.writer();

                            var map_start = slot_ptr.slot.value;

                            // copy it to the end unless it was made in this transaction
                            if (self.tx_start) |tx_start| {
                                if (map_start < tx_start) {
                                    // read existing block
                                    try reader.seekTo(map_start);
                                    const map_count_maybe = if (hash_map_init.counted) try takeInt(&reader.interface, u64, .big) else null;
                                    var map_index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                                    try reader.interface.readSliceAll(&map_index_block);
                                    // copy to the end
                                    map_start = try self.core.length();
                                    try writer.seekTo(map_start);
                                    if (map_count_maybe) |map_count| try writer.interface.writeInt(u64, map_count, .big);
                                    try writer.interface.writeAll(&map_index_block);
                                }
                            } else if (self.header.tag == .array_list) {
                                return error.ExpectedTxStart;
                            }

                            // make slot point to map
                            const next_slot_ptr = SlotPointer{ .position = position, .slot = .{ .value = map_start, .tag = tag } };
                            try writer.seekTo(position);
                            try writer.interface.writeInt(SlotInt, @bitCast(next_slot_ptr.slot), .big);
                            return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                        },
                        else => return error.UnexpectedTag,
                    }
                },
                .hash_map_get => |hash_map_get| {
                    var counted = false;
                    switch (slot_ptr.slot.tag) {
                        .none => return error.KeyNotFound,
                        .hash_map, .hash_set => {},
                        .counted_hash_map, .counted_hash_set => counted = true,
                        else => return error.UnexpectedTag,
                    }

                    const index_pos = if (counted) slot_ptr.slot.value + byteSizeOf(u64) else slot_ptr.slot.value;

                    const res = switch (hash_map_get) {
                        .kv_pair => |kv_pair| try self.readMapSlot(index_pos, kv_pair, 0, write_mode, is_top_level, .kv_pair),
                        .key => |key| try self.readMapSlot(index_pos, key, 0, write_mode, is_top_level, .key),
                        .value => |value| try self.readMapSlot(index_pos, value, 0, write_mode, is_top_level, .value),
                    };

                    if (write_mode == .read_write and counted and res.is_empty) {
                        var reader = self.core.reader();
                        var writer = self.core.writer();
                        try reader.seekTo(slot_ptr.slot.value);
                        const map_count = try takeInt(&reader.interface, u64, .big);
                        try writer.seekTo(slot_ptr.slot.value);
                        try writer.interface.writeInt(u64, map_count + 1, .big);
                    }

                    return self.readSlotPointer(write_mode, Ctx, path[1..], res.slot_ptr);
                },
                .hash_map_remove => |key_hash| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    var counted = false;
                    switch (slot_ptr.slot.tag) {
                        .none => return error.KeyNotFound,
                        .hash_map, .hash_set => {},
                        .counted_hash_map, .counted_hash_set => counted = true,
                        else => return error.UnexpectedTag,
                    }

                    const index_pos = if (counted) slot_ptr.slot.value + byteSizeOf(u64) else slot_ptr.slot.value;

                    var key_found = true;
                    _ = self.removeMapSlot(index_pos, key_hash, 0, is_top_level) catch |err| switch (err) {
                        error.KeyNotFound => key_found = false,
                        else => |e| return e,
                    };

                    if (write_mode == .read_write and counted and key_found) {
                        var reader = self.core.reader();
                        var writer = self.core.writer();
                        try reader.seekTo(slot_ptr.slot.value);
                        const map_count = try takeInt(&reader.interface, u64, .big);
                        try writer.seekTo(slot_ptr.slot.value);
                        try writer.interface.writeInt(u64, map_count - 1, .big);
                    }

                    if (!key_found) return error.KeyNotFound;

                    return slot_ptr;
                },
                .sorted_map_init => |opts| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;
                    if (is_top_level) return error.InvalidTopLevelType;
                    const position = slot_ptr.position orelse return error.CursorNotWriteable;
                    const tag: Tag = if (opts.set) .sorted_set else .sorted_map;
                    var writer = self.core.writer();
                    switch (slot_ptr.slot.tag) {
                        .none => {
                            const root_ptr = try self.writeSortedNode(.{ .kind = .leaf, .num = 0 });
                            const header_ptr = try self.core.length();
                            try writer.seekTo(header_ptr);
                            try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{ .root_ptr = root_ptr, .size = 0 }), .big);
                            const next_slot_ptr = SlotPointer{ .position = position, .slot = .{ .value = header_ptr, .tag = tag } };
                            try writer.seekTo(position);
                            try writer.interface.writeInt(SlotInt, @bitCast(next_slot_ptr.slot), .big);
                            return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                        },
                        .sorted_map, .sorted_set => {
                            if (slot_ptr.slot.tag != tag) return error.UnexpectedTag;
                            var header_ptr = slot_ptr.slot.value;
                            // copy the header into this transaction unless it was made in it
                            if (self.tx_start) |tx_start| {
                                if (header_ptr < tx_start) {
                                    var reader = self.core.reader();
                                    try reader.seekTo(header_ptr);
                                    const header_int = try takeInt(&reader.interface, BTreeHeaderInt, .big);
                                    header_ptr = try self.core.length();
                                    try writer.seekTo(header_ptr);
                                    try writer.interface.writeInt(BTreeHeaderInt, header_int, .big);
                                }
                            } else if (self.header.tag == .array_list) {
                                return error.ExpectedTxStart;
                            }
                            const next_slot_ptr = SlotPointer{ .position = position, .slot = .{ .value = header_ptr, .tag = tag } };
                            try writer.seekTo(position);
                            try writer.interface.writeInt(SlotInt, @bitCast(next_slot_ptr.slot), .big);
                            return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                        },
                        else => return error.UnexpectedTag,
                    }
                },
                .sorted_map_get => |sorted_map_get| {
                    switch (slot_ptr.slot.tag) {
                        .none => return error.KeyNotFound,
                        .sorted_map, .sorted_set => {},
                        else => return error.UnexpectedTag,
                    }

                    const target: HashMapSlotKind = sorted_map_get;
                    const key: []const u8 = switch (sorted_map_get) {
                        .kv_pair => |k| k,
                        .key => |k| k,
                        .value => |k| k,
                    };

                    const header_ptr = slot_ptr.slot.value;
                    var reader = self.core.reader();
                    try reader.seekTo(header_ptr);
                    const header: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));

                    if (write_mode == .read_only) {
                        const found = (try self.sortedGet(header.root_ptr, key)) orelse return error.KeyNotFound;
                        const target_slot = try self.sortedTargetSlot(found.slot.value, target);
                        return self.readSlotPointer(write_mode, Ctx, path[1..], target_slot);
                    } else {
                        const result = try self.sortedPut(header.root_ptr, key);
                        const new_root_ptr = try self.sortedGrowRoot(result);

                        // update the header before filling in the value, so that a
                        // failure in the rest of the path leaves the tree and header
                        // consistent (the entry exists with an empty value) rather
                        // than inserted-but-uncounted
                        var writer = self.core.writer();
                        try writer.seekTo(header_ptr);
                        try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{ .root_ptr = new_root_ptr, .size = header.size + @as(u64, if (result.added) 1 else 0) }), .big);

                        const kv_pos = result.value_position - byteSizeOf(HashInt) - byteSizeOf(Slot);
                        const target_slot = try self.sortedTargetSlot(kv_pos, target);
                        return self.readSlotPointer(write_mode, Ctx, path[1..], target_slot);
                    }
                },
                .sorted_map_get_index => |index| {
                    if (write_mode == .read_write) return error.WriteNotAllowed;

                    switch (slot_ptr.slot.tag) {
                        .none => return error.KeyNotFound,
                        .sorted_map, .sorted_set => {},
                        else => return error.UnexpectedTag,
                    }

                    const header_ptr = slot_ptr.slot.value;
                    var reader = self.core.reader();
                    try reader.seekTo(header_ptr);
                    const header: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));

                    if (index >= header.size or index < -@as(i65, header.size)) {
                        return error.KeyNotFound;
                    }
                    const rank: u64 = if (index < 0)
                        @intCast(header.size - @abs(index))
                    else
                        @intCast(index);

                    const found = try self.sortedGetByIndex(header.root_ptr, rank);
                    // return the kv_pair entry so the caller can read key and value
                    const target_slot = SlotPointer{ .position = found.position, .slot = found.slot };
                    return self.readSlotPointer(write_mode, Ctx, path[1..], target_slot);
                },
                .sorted_map_remove => |key| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    switch (slot_ptr.slot.tag) {
                        .none => return error.KeyNotFound,
                        .sorted_map, .sorted_set => {},
                        else => return error.UnexpectedTag,
                    }

                    const header_ptr = slot_ptr.slot.value;
                    var reader = self.core.reader();
                    try reader.seekTo(header_ptr);
                    const header: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));

                    const result = try self.sortedRemove(header.root_ptr, key);
                    if (!result.found) return error.KeyNotFound;

                    var writer = self.core.writer();
                    try writer.seekTo(header_ptr);
                    try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{ .root_ptr = result.node_ptr, .size = header.size - 1 }), .big);

                    return slot_ptr;
                },
                .write => |data| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    const position = slot_ptr.position orelse return error.CursorNotWriteable;

                    var core_writer = self.core.writer();

                    var slot: Slot = write_switch: switch (data) {
                        .slot => |slot_maybe| slot_maybe orelse .{ .tag = .none },
                        .uint => |uint| .{ .value = uint, .tag = .uint },
                        .int => |int| .{ .value = @bitCast(int), .tag = .int },
                        .float => |float| .{ .value = @bitCast(float), .tag = .float },
                        .bytes => |bytes| continue :write_switch .{ .bytes_object = .{ .value = bytes } },
                        .bytes_object => |bytes| blk: {
                            if (bytes.isShort()) {
                                var value = [_]u8{0} ** byteSizeOf(u64);
                                @memcpy(value[0..bytes.value.len], bytes.value);
                                if (bytes.format_tag) |format_tag| {
                                    @memcpy(value[value.len - 2 ..], &format_tag);
                                }
                                const value_int = std.mem.readInt(u64, &value, .big);
                                break :blk .{ .value = value_int, .tag = .short_bytes, .full = bytes.format_tag != null };
                            } else {
                                var next_cursor = Cursor(.read_write){
                                    .slot_ptr = slot_ptr,
                                    .db = self,
                                };
                                var writer = try next_cursor.writer(&.{});
                                writer.format_tag = bytes.format_tag; // the writer will write the format tag when finish is called
                                try writer.interface.writeAll(bytes.value);
                                try writer.finish();
                                break :blk writer.slot;
                            }
                        },
                    };

                    // this bit allows us to distinguish between a slot explicitly set to .none
                    // and a slot that hasn't been set yet
                    if (slot.tag == .none) {
                        slot.full = true;
                    }

                    try core_writer.seekTo(position);
                    try core_writer.interface.writeInt(SlotInt, @bitCast(slot), .big);

                    const next_slot_ptr = SlotPointer{ .position = slot_ptr.position, .slot = slot };
                    return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                },
                .ctx => |ctx| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (path.len > 1) return error.PathPartMustBeAtEnd;

                    if (@TypeOf(ctx) == void) {
                        return error.NotImplmented;
                    } else {
                        var next_cursor = Cursor(.read_write){
                            .slot_ptr = slot_ptr,
                            .db = self,
                        };
                        ctx.run(&next_cursor) catch |err| {
                            // since an error occurred, there may be inaccessible
                            // junk at the end of the db, so delete it if possible
                            self.truncate() catch {};
                            return err;
                        };
                        return next_cursor.slot_ptr;
                    }
                },
            }
        }

        // hash_map

        const HashMapGetResult = struct {
            slot_ptr: SlotPointer,
            is_empty: bool,
        };

        fn readMapSlot(self: *Database(db_kind, HashInt), index_pos: u64, key_hash: HashInt, key_offset: u8, comptime write_mode: WriteMode, is_top_level: bool, target: HashMapSlotKind) !HashMapGetResult {
            if (key_offset >= (HASH_SIZE * 8) / BIT_COUNT) {
                return error.KeyOffsetExceeded;
            }

            var reader = self.core.reader();
            var writer = self.core.writer();

            const i: u4 = @intCast((key_hash >> key_offset * BIT_COUNT) & MASK);
            const slot_pos = index_pos + (byteSizeOf(Slot) * i);
            try reader.seekTo(slot_pos);
            const slot: Slot = @bitCast(try takeInt(&reader.interface, SlotInt, .big));
            try slot.tag.validate();

            const ptr = slot.value;

            switch (slot.tag) {
                .none => {
                    switch (write_mode) {
                        .read_only => return error.KeyNotFound,
                        .read_write => {
                            // write hash and key/val slots
                            const hash_pos = try self.core.length();
                            const key_slot_pos = hash_pos + byteSizeOf(HashInt);
                            const value_slot_pos = key_slot_pos + byteSizeOf(Slot);
                            const kv_pair = KeyValuePair{
                                .value_slot = @bitCast(@as(SlotInt, 0)),
                                .key_slot = @bitCast(@as(SlotInt, 0)),
                                .hash = key_hash,
                            };
                            try writer.seekTo(hash_pos);
                            try writer.interface.writeInt(KeyValuePairInt, @bitCast(kv_pair), .big);

                            // point slot to hash pos
                            const next_slot = Slot{ .value = hash_pos, .tag = .kv_pair };
                            try writer.seekTo(slot_pos);
                            try writer.interface.writeInt(SlotInt, @bitCast(next_slot), .big);

                            return .{
                                .slot_ptr = switch (target) {
                                    .kv_pair => SlotPointer{ .position = slot_pos, .slot = next_slot },
                                    .key => SlotPointer{ .position = key_slot_pos, .slot = kv_pair.key_slot },
                                    .value => SlotPointer{ .position = value_slot_pos, .slot = kv_pair.value_slot },
                                },
                                .is_empty = true,
                            };
                        },
                    }
                },
                .index => {
                    var next_ptr = ptr;
                    if (write_mode == .read_write and !is_top_level) {
                        if (self.tx_start) |tx_start| {
                            if (next_ptr < tx_start) {
                                // read existing block
                                try reader.seekTo(ptr);
                                var index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                                try reader.interface.readSliceAll(&index_block);
                                // copy it to the end
                                next_ptr = try self.core.length();
                                try writer.seekTo(next_ptr);
                                try writer.interface.writeAll(&index_block);
                                // make slot point to block
                                try writer.seekTo(slot_pos);
                                try writer.interface.writeInt(SlotInt, @bitCast(Slot{ .value = next_ptr, .tag = .index }), .big);
                            }
                        } else if (self.header.tag == .array_list) {
                            return error.ExpectedTxStart;
                        }
                    }
                    return self.readMapSlot(next_ptr, key_hash, key_offset + 1, write_mode, is_top_level, target);
                },
                .kv_pair => {
                    try reader.seekTo(ptr);
                    const kv_pair: KeyValuePair = @bitCast(try takeInt(&reader.interface, KeyValuePairInt, .big));

                    if (kv_pair.hash == key_hash) {
                        if (write_mode == .read_write and !is_top_level) {
                            if (self.tx_start) |tx_start| {
                                if (ptr < tx_start) {
                                    // write hash and key/val slots
                                    const hash_pos = try self.core.length();
                                    const key_slot_pos = hash_pos + byteSizeOf(HashInt);
                                    const value_slot_pos = key_slot_pos + byteSizeOf(Slot);
                                    try writer.seekTo(hash_pos);
                                    try writer.interface.writeInt(KeyValuePairInt, @bitCast(kv_pair), .big);

                                    // point slot to hash pos
                                    const next_slot = Slot{ .value = hash_pos, .tag = .kv_pair };
                                    try writer.seekTo(slot_pos);
                                    try writer.interface.writeInt(SlotInt, @bitCast(next_slot), .big);

                                    return .{
                                        .slot_ptr = switch (target) {
                                            .kv_pair => SlotPointer{ .position = slot_pos, .slot = next_slot },
                                            .key => SlotPointer{ .position = key_slot_pos, .slot = kv_pair.key_slot },
                                            .value => SlotPointer{ .position = value_slot_pos, .slot = kv_pair.value_slot },
                                        },
                                        .is_empty = false,
                                    };
                                }
                            } else if (self.header.tag == .array_list) {
                                return error.ExpectedTxStart;
                            }
                        }

                        const key_slot_pos = ptr + byteSizeOf(HashInt);
                        const value_slot_pos = key_slot_pos + byteSizeOf(Slot);
                        return .{
                            .slot_ptr = switch (target) {
                                .kv_pair => SlotPointer{ .position = slot_pos, .slot = slot },
                                .key => SlotPointer{ .position = key_slot_pos, .slot = kv_pair.key_slot },
                                .value => SlotPointer{ .position = value_slot_pos, .slot = kv_pair.value_slot },
                            },
                            .is_empty = false,
                        };
                    } else {
                        switch (write_mode) {
                            .read_only => return error.KeyNotFound,
                            .read_write => {
                                // append new index block
                                if (key_offset + 1 >= (HASH_SIZE * 8) / BIT_COUNT) {
                                    return error.KeyOffsetExceeded;
                                }
                                const next_i: u4 = @intCast((kv_pair.hash >> (key_offset + 1) * BIT_COUNT) & MASK);
                                const next_index_pos = try self.core.length();
                                var index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                                try writer.seekTo(next_index_pos);
                                try writer.interface.writeAll(&index_block);
                                try writer.seekTo(next_index_pos + (byteSizeOf(Slot) * next_i));
                                try writer.interface.writeInt(SlotInt, @bitCast(slot), .big);
                                const res = try self.readMapSlot(next_index_pos, key_hash, key_offset + 1, write_mode, is_top_level, target);
                                try writer.seekTo(slot_pos);
                                try writer.interface.writeInt(SlotInt, @bitCast(Slot{ .value = next_index_pos, .tag = .index }), .big);
                                return res;
                            },
                        }
                    }
                },
                else => return error.UnexpectedTag,
            }
        }

        fn removeMapSlot(self: *Database(db_kind, HashInt), index_pos: u64, key_hash: HashInt, key_offset: u8, is_top_level: bool) !Slot {
            if (key_offset >= (HASH_SIZE * 8) / BIT_COUNT) {
                return error.KeyOffsetExceeded;
            }

            var reader = self.core.reader();
            var writer = self.core.writer();

            // read block
            var slot_block = [_]Slot{.{}} ** SLOT_COUNT;
            try reader.seekTo(index_pos);
            var index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
            try reader.interface.readSliceAll(&index_block);
            var block_reader = std.Io.Reader.fixed(&index_block);
            for (&slot_block) |*block_slot| {
                block_slot.* = @bitCast(try takeInt(&block_reader, SlotInt, .big));
                try block_slot.tag.validate();
            }

            // get the current slot
            const i: u4 = @intCast((key_hash >> key_offset * BIT_COUNT) & MASK);
            const slot_pos = index_pos + (byteSizeOf(Slot) * i);
            const slot = slot_block[i];

            // get the slot that will replace the current slot
            const next_slot: Slot = switch (slot.tag) {
                .none => return error.KeyNotFound,
                .index => try self.removeMapSlot(slot.value, key_hash, key_offset + 1, is_top_level),
                .kv_pair => blk: {
                    try reader.seekTo(slot.value);
                    const kv_pair: KeyValuePair = @bitCast(try takeInt(&reader.interface, KeyValuePairInt, .big));
                    if (kv_pair.hash == key_hash) {
                        break :blk .{ .tag = .none };
                    } else {
                        return error.KeyNotFound;
                    }
                },
                else => return error.UnexpectedTag,
            };

            // if we're the root node, just write the new slot and finish
            if (key_offset == 0) {
                try writer.seekTo(slot_pos);
                try writer.interface.writeInt(SlotInt, @bitCast(next_slot), .big);
                return .{ .value = index_pos, .tag = .index };
            }

            // get slot to return if there is only one used slot
            // in this index block
            var slot_to_return_maybe: ?Slot = .{ .tag = .none };
            slot_block[i] = next_slot;
            for (slot_block) |block_slot| {
                if (block_slot.tag == .none) continue;

                // if there is already a slot to return, that
                // means there is more than one used slot in this
                // index block, so we can't return just a single slot
                if (slot_to_return_maybe) |slot_to_return| {
                    if (slot_to_return.tag != .none) {
                        slot_to_return_maybe = null;
                        break;
                    }
                }

                slot_to_return_maybe = block_slot;
            }

            // if there were either no used slots, or a single .kv_pair
            // slot, this index block doesn't need to exist anymore
            if (slot_to_return_maybe) |slot_to_return| {
                switch (slot_to_return.tag) {
                    .none, .kv_pair => return slot_to_return,
                    else => {},
                }
            }

            // there was more than one used slot, or a single .index slot,
            // so we must keep this index block

            if (!is_top_level) {
                if (self.tx_start) |tx_start| {
                    if (index_pos < tx_start) {
                        // copy index block to the end
                        const next_index_pos = try self.core.length();
                        try writer.seekTo(next_index_pos);
                        try writer.interface.writeAll(&index_block);
                        // update the slot
                        const next_slot_pos = next_index_pos + (byteSizeOf(Slot) * i);
                        try writer.seekTo(next_slot_pos);
                        try writer.interface.writeInt(SlotInt, @bitCast(next_slot), .big);
                        return .{ .value = next_index_pos, .tag = .index };
                    }
                } else if (self.header.tag == .array_list) {
                    return error.ExpectedTxStart;
                }
            }

            try writer.seekTo(slot_pos);
            try writer.interface.writeInt(SlotInt, @bitCast(next_slot), .big);
            return .{ .value = index_pos, .tag = .index };
        }

        // array_list

        const ArrayListAppendResult = struct {
            header: ArrayListHeader,
            slot_ptr: SlotPointer,
        };

        fn readArrayListSlotAppend(self: *Database(db_kind, HashInt), header: ArrayListHeader, comptime write_mode: WriteMode, is_top_level: bool) !ArrayListAppendResult {
            var writer = self.core.writer();

            var index_pos = header.ptr;

            const key = header.size;

            const prev_shift: u6 = @intCast(if (key < SLOT_COUNT) 0 else std.math.log(u64, SLOT_COUNT, key - 1));
            const next_shift: u6 = @intCast(if (key < SLOT_COUNT) 0 else std.math.log(u64, SLOT_COUNT, key));

            if (prev_shift != next_shift) {
                // root overflow
                const next_index_pos = try self.core.length();
                var index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                try writer.seekTo(next_index_pos);
                try writer.interface.writeAll(&index_block);
                try writer.seekTo(next_index_pos);
                try writer.interface.writeInt(SlotInt, @bitCast(Slot{ .value = index_pos, .tag = .index }), .big);
                index_pos = next_index_pos;
            }

            const slot_ptr = try self.readArrayListSlot(index_pos, key, next_shift, write_mode, is_top_level);

            return .{
                .header = .{
                    .ptr = index_pos,
                    .size = header.size + 1,
                },
                .slot_ptr = slot_ptr,
            };
        }

        fn readArrayListSlot(self: *Database(db_kind, HashInt), index_pos: u64, key: u64, shift: u6, comptime write_mode: WriteMode, is_top_level: bool) !SlotPointer {
            if (shift >= MAX_BRANCH_LENGTH) return error.MaxShiftExceeded;

            var reader = self.core.reader();

            const i: u4 = @intCast(key >> (shift * BIT_COUNT) & MASK);
            const slot_pos = index_pos + (byteSizeOf(Slot) * i);
            try reader.seekTo(slot_pos);
            const slot: Slot = @bitCast(try takeInt(&reader.interface, SlotInt, .big));
            try slot.tag.validate();

            if (shift == 0) {
                return SlotPointer{ .position = slot_pos, .slot = slot };
            }

            const ptr = slot.value;

            switch (slot.tag) {
                .none => {
                    switch (write_mode) {
                        .read_only => return error.KeyNotFound,
                        .read_write => {
                            var writer = self.core.writer();
                            const next_index_pos = try self.core.length();
                            var index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                            try writer.seekTo(next_index_pos);
                            try writer.interface.writeAll(&index_block);
                            // if top level array list, update the file size in the list
                            // header to prevent truncation from destroying this block
                            if (is_top_level) {
                                const file_size = try self.core.length();
                                try writer.seekTo(DATABASE_START + byteSizeOf(ArrayListHeader));
                                try writer.interface.writeInt(u64, file_size, .big);
                            }
                            try writer.seekTo(slot_pos);
                            try writer.interface.writeInt(SlotInt, @bitCast(Slot{ .value = next_index_pos, .tag = .index }), .big);
                            return try self.readArrayListSlot(next_index_pos, key, shift - 1, write_mode, is_top_level);
                        },
                    }
                },
                .index => {
                    var next_ptr = ptr;
                    if (write_mode == .read_write and !is_top_level) {
                        if (self.tx_start) |tx_start| {
                            if (next_ptr < tx_start) {
                                // read existing block
                                try reader.seekTo(ptr);
                                var index_block = [_]u8{0} ** INDEX_BLOCK_SIZE;
                                try reader.interface.readSliceAll(&index_block);
                                // copy it to the end
                                var writer = self.core.writer();
                                next_ptr = try self.core.length();
                                try writer.seekTo(next_ptr);
                                try writer.interface.writeAll(&index_block);
                                // make slot point to block
                                try writer.seekTo(slot_pos);
                                try writer.interface.writeInt(SlotInt, @bitCast(Slot{ .value = next_ptr, .tag = .index }), .big);
                            }
                        } else if (self.header.tag == .array_list) {
                            return error.ExpectedTxStart;
                        }
                    }
                    return self.readArrayListSlot(next_ptr, key, shift - 1, write_mode, is_top_level);
                },
                else => return error.UnexpectedTag,
            }
        }

        fn readArrayListSlice(self: *Database(db_kind, HashInt), header: ArrayListHeader, size: u64) !ArrayListHeader {
            var core_reader = self.core.reader();

            if (size > header.size) {
                return error.KeyNotFound;
            }

            const prev_shift: u6 = @intCast(if (header.size < SLOT_COUNT + 1) 0 else std.math.log(u64, SLOT_COUNT, header.size - 1));
            const next_shift: u6 = @intCast(if (size < SLOT_COUNT + 1) 0 else std.math.log(u64, SLOT_COUNT, size - 1));

            if (prev_shift == next_shift) {
                // the root node doesn't need to change
                return .{
                    .ptr = header.ptr,
                    .size = size,
                };
            } else {
                // keep following the first slot until we are at the correct shift
                var shift = prev_shift;
                var index_pos = header.ptr;
                while (shift > next_shift) {
                    try core_reader.seekTo(index_pos);
                    const slot: Slot = @bitCast(try takeInt(&core_reader.interface, SlotInt, .big));
                    try slot.tag.validate();
                    shift -= 1;
                    index_pos = slot.value;
                }
                return .{
                    .ptr = index_pos,
                    .size = size,
                };
            }
        }

        // b-tree

        fn readBTreeNode(self: *Database(db_kind, HashInt), ptr: u64) !BTreeNode {
            var reader = self.core.reader();
            try reader.seekTo(ptr);
            const kind_int = try takeInt(&reader.interface, u8, .big);
            const kind = std.enums.fromInt(BTreeNodeKind, kind_int) orelse return error.InvalidBTreeNodeKind;
            const num = try takeInt(&reader.interface, u8, .big);
            if (num > BTREE_SLOT_COUNT) return error.InvalidBTreeNode;
            var node = BTreeNode{ .kind = kind, .num = num };
            switch (kind) {
                .leaf => {
                    for (&node.values) |*s| {
                        s.* = @bitCast(try takeInt(&reader.interface, SlotInt, .big));
                        try s.tag.validate();
                    }
                },
                .branch => {
                    for (&node.children) |*s| {
                        s.* = @bitCast(try takeInt(&reader.interface, SlotInt, .big));
                        try s.tag.validate();
                    }
                    for (&node.counts) |*c| {
                        c.* = try takeInt(&reader.interface, u64, .big);
                    }
                },
            }
            return node;
        }

        // always appends the node as a fresh block and returns its position.
        // b-tree mutations are persistent: every node on the path from the root
        // is rewritten, while untouched subtrees are shared by pointer.
        fn writeBTreeNodeAt(self: *Database(db_kind, HashInt), node: BTreeNode, ptr: u64) !void {
            var writer = self.core.writer();
            try writer.seekTo(ptr);
            try writer.interface.writeInt(u8, @intFromEnum(node.kind), .big);
            try writer.interface.writeInt(u8, node.num, .big);
            switch (node.kind) {
                .leaf => {
                    for (node.values) |s| try writer.interface.writeInt(SlotInt, @bitCast(s), .big);
                },
                .branch => {
                    for (node.children) |s| try writer.interface.writeInt(SlotInt, @bitCast(s), .big);
                    for (node.counts) |c| try writer.interface.writeInt(u64, c, .big);
                },
            }
        }

        // appends `node` as a fresh block and returns its position.
        fn writeBTreeNode(self: *Database(db_kind, HashInt), node: BTreeNode) !u64 {
            const ptr = try self.core.length();
            try self.writeBTreeNodeAt(node, ptr);
            return ptr;
        }

        // a node is safe to mutate in place when it was created in the current
        // transaction (offset >= tx_start), since no committed moment and no
        // pre-`concat` sharing can reference it. `concat` advances tx_start (an
        // implicit freeze) precisely so its shared subtrees fall below it here.
        // for an ephemeral (non-array-list) top level there is no transaction, so
        // everything is mutable in place until a `concat` first sets tx_start.
        fn btreeReusable(self: *Database(db_kind, HashInt), ptr: u64) bool {
            if (self.tx_start) |tx_start| return ptr >= tx_start;
            return self.header.tag != .array_list;
        }

        // write a new version of a node, reusing `old_ptr`'s position in place if
        // that node belongs to this transaction, otherwise appending a copy
        fn btreeWriteNode(self: *Database(db_kind, HashInt), node: BTreeNode, old_ptr: u64) !u64 {
            if (self.btreeReusable(old_ptr)) {
                try self.writeBTreeNodeAt(node, old_ptr);
                return old_ptr;
            }
            return try self.writeBTreeNode(node);
        }

        // descend to the value slot at the given rank (0-based), returning a
        // pointer to it (its file position and current slot).
        fn readBTreeSlot(self: *Database(db_kind, HashInt), root_ptr: u64, rank: u64) !SlotPointer {
            var node_ptr = root_ptr;
            var rem = rank;
            while (true) {
                const node = try self.readBTreeNode(node_ptr);
                switch (node.kind) {
                    .leaf => {
                        const position = node_ptr + BTREE_NODE_HEADER_SIZE + rem * byteSizeOf(Slot);
                        return .{ .position = position, .slot = node.values[@intCast(rem)] };
                    },
                    .branch => {
                        var i: u8 = 0;
                        while (i + 1 < node.num and rem >= node.counts[i]) : (i += 1) {
                            rem -= node.counts[i];
                        }
                        node_ptr = node.children[i].value;
                    },
                }
            }
        }

        // insert a placeholder slot at `rank` within the subtree at node_ptr,
        // writing new nodes along the path. the caller fills in the value at the
        // returned `value_position`.
        fn btreeInsert(self: *Database(db_kind, HashInt), node_ptr: u64, rank: u64) anyerror!BTreeInsertResult {
            const node = try self.readBTreeNode(node_ptr);
            switch (node.kind) {
                .leaf => {
                    // build the entries with a placeholder spliced in at `rank`.
                    // the placeholder is a `.none` slot marked `full` so that, if the
                    // caller never writes a value (e.g. appendCursor), iteration still
                    // counts it as an element rather than skipping it as padding.
                    var vals = [_]Slot{.{}} ** (BTREE_SLOT_COUNT + 1);
                    const r: usize = @intCast(rank);
                    @memcpy(vals[0..r], node.values[0..r]);
                    vals[r] = .{ .full = true };
                    @memcpy(vals[r + 1 .. node.num + 1], node.values[r..node.num]);
                    const total: usize = node.num + 1;

                    if (total <= BTREE_SLOT_COUNT) {
                        var leaf = BTreeNode{ .kind = .leaf, .num = @intCast(total) };
                        @memcpy(leaf.values[0..total], vals[0..total]);
                        const ptr = try self.btreeWriteNode(leaf, node_ptr);
                        return .{
                            .node_ptr = ptr,
                            .count = total,
                            .value_position = ptr + BTREE_NODE_HEADER_SIZE + r * byteSizeOf(Slot),
                            .split = null,
                        };
                    }

                    // overflow: split into two leaves (reuse this node for the left half)
                    const left_n = BTREE_SPLIT_COUNT;
                    const right_n = total - left_n;
                    var left = BTreeNode{ .kind = .leaf, .num = @intCast(left_n) };
                    @memcpy(left.values[0..left_n], vals[0..left_n]);
                    var right = BTreeNode{ .kind = .leaf, .num = @intCast(right_n) };
                    @memcpy(right.values[0..right_n], vals[left_n..total]);
                    const left_ptr = try self.btreeWriteNode(left, node_ptr);
                    const right_ptr = try self.writeBTreeNode(right);
                    const value_position = if (r < left_n)
                        left_ptr + BTREE_NODE_HEADER_SIZE + r * byteSizeOf(Slot)
                    else
                        right_ptr + BTREE_NODE_HEADER_SIZE + (r - left_n) * byteSizeOf(Slot);
                    return .{
                        .node_ptr = left_ptr,
                        .count = left_n,
                        .value_position = value_position,
                        .split = .{ .node_ptr = right_ptr, .count = right_n },
                    };
                },
                .branch => {
                    // pick the child that contains `rank`
                    var i: u8 = 0;
                    var rem = rank;
                    while (i + 1 < node.num and rem > node.counts[i]) : (i += 1) {
                        rem -= node.counts[i];
                    }
                    const child = try self.btreeInsert(node.children[i].value, rem);

                    // rebuild this branch with the (possibly split) child
                    var children = [_]Slot{.{}} ** (BTREE_SLOT_COUNT + 1);
                    var counts = [_]u64{0} ** (BTREE_SLOT_COUNT + 1);
                    @memcpy(children[0..node.num], node.children[0..node.num]);
                    @memcpy(counts[0..node.num], node.counts[0..node.num]);
                    children[i] = .{ .value = child.node_ptr, .tag = .index };
                    counts[i] = child.count;
                    var total: usize = node.num;
                    if (child.split) |split| {
                        var j: usize = node.num;
                        while (j > i + 1) : (j -= 1) {
                            children[j] = children[j - 1];
                            counts[j] = counts[j - 1];
                        }
                        children[i + 1] = .{ .value = split.node_ptr, .tag = .index };
                        counts[i + 1] = split.count;
                        total = node.num + 1;
                    }

                    if (total <= BTREE_SLOT_COUNT) {
                        var branch = BTreeNode{ .kind = .branch, .num = @intCast(total) };
                        @memcpy(branch.children[0..total], children[0..total]);
                        @memcpy(branch.counts[0..total], counts[0..total]);
                        const ptr = try self.btreeWriteNode(branch, node_ptr);
                        return .{
                            .node_ptr = ptr,
                            .count = branch.subtreeCount(),
                            .value_position = child.value_position,
                            .split = null,
                        };
                    }

                    // overflow: split into two branches (reuse this node for the left half)
                    const left_n = BTREE_SPLIT_COUNT;
                    const right_n = total - left_n;
                    var left = BTreeNode{ .kind = .branch, .num = @intCast(left_n) };
                    @memcpy(left.children[0..left_n], children[0..left_n]);
                    @memcpy(left.counts[0..left_n], counts[0..left_n]);
                    var right = BTreeNode{ .kind = .branch, .num = @intCast(right_n) };
                    @memcpy(right.children[0..right_n], children[left_n..total]);
                    @memcpy(right.counts[0..right_n], counts[left_n..total]);
                    const left_ptr = try self.btreeWriteNode(left, node_ptr);
                    const right_ptr = try self.writeBTreeNode(right);
                    return .{
                        .node_ptr = left_ptr,
                        .count = left.subtreeCount(),
                        .value_position = child.value_position,
                        .split = .{ .node_ptr = right_ptr, .count = right.subtreeCount() },
                    };
                },
            }
        }

        // create a new, empty tree (a single empty leaf) and return its root pointer
        fn btreeNewRoot(self: *Database(db_kind, HashInt)) !u64 {
            return try self.writeBTreeNode(.{ .kind = .leaf, .num = 0 });
        }

        // turn an insert result into a root pointer, growing the tree a level if
        // the old root split (shares the root-building logic with btreeMakeRoot)
        fn btreeGrowRoot(self: *Database(db_kind, HashInt), result: BTreeInsertResult) !u64 {
            return try self.btreeMakeRoot(.{
                .node_ptr = result.node_ptr,
                .count = result.count,
                .split = if (result.split) |split| .{ .node_ptr = split.node_ptr, .count = split.count } else null,
            });
        }

        const BTreeWriteSlot = struct {
            node_ptr: u64,
            value_position: u64,
            slot: Slot,
        };

        // descend to the value slot at `rank` for writing, copy-on-writing only the
        // nodes that belong to a past transaction. the element count is unchanged,
        // so when the whole path is already this-transaction nothing is rewritten
        // and the caller writes straight into the existing leaf.
        fn btreeGetForWrite(self: *Database(db_kind, HashInt), node_ptr: u64, rank: u64) anyerror!BTreeWriteSlot {
            const node = try self.readBTreeNode(node_ptr);
            switch (node.kind) {
                .leaf => {
                    const new_ptr = if (self.btreeReusable(node_ptr)) node_ptr else try self.writeBTreeNode(node);
                    return .{
                        .node_ptr = new_ptr,
                        .value_position = new_ptr + BTREE_NODE_HEADER_SIZE + rank * byteSizeOf(Slot),
                        .slot = node.values[@intCast(rank)],
                    };
                },
                .branch => {
                    var i: u8 = 0;
                    var rem = rank;
                    while (i + 1 < node.num and rem >= node.counts[i]) : (i += 1) {
                        rem -= node.counts[i];
                    }
                    const child = try self.btreeGetForWrite(node.children[i].value, rem);
                    // if the child stayed put, this branch is unchanged too
                    if (child.node_ptr == node.children[i].value) {
                        return .{ .node_ptr = node_ptr, .value_position = child.value_position, .slot = child.slot };
                    }
                    var new_node = node;
                    new_node.children[i] = .{ .value = child.node_ptr, .tag = .index };
                    const new_ptr = try self.btreeWriteNode(new_node, node_ptr);
                    return .{ .node_ptr = new_ptr, .value_position = child.value_position, .slot = child.slot };
                },
            }
        }

        // join (concat): a true O(log n), structure-sharing concatenation of two
        // trees where every element of `a` precedes every element of `b`. unlike
        // the rebuild helpers above, untouched subtrees are shared by pointer, so
        // concatenating a list with itself stays cheap.

        const BTreeJoinResult = struct {
            node_ptr: u64,
            count: u64,
            // set if assembling overflowed and produced a right sibling
            split: ?struct { node_ptr: u64, count: u64 },
        };

        // height of a tree = number of branch levels above the leaves
        fn btreeHeight(self: *Database(db_kind, HashInt), root_ptr: u64) !u8 {
            var ptr = root_ptr;
            var height: u8 = 0;
            while (true) {
                const node = try self.readBTreeNode(ptr);
                if (node.kind == .leaf) return height;
                height += 1;
                ptr = node.children[0].value;
            }
        }

        fn btreeMakeRoot(self: *Database(db_kind, HashInt), result: BTreeJoinResult) !u64 {
            if (result.split) |split| {
                var root = BTreeNode{ .kind = .branch, .num = 2 };
                root.children[0] = .{ .value = result.node_ptr, .tag = .index };
                root.children[1] = .{ .value = split.node_ptr, .tag = .index };
                root.counts[0] = result.count;
                root.counts[1] = split.count;
                return try self.writeBTreeNode(root);
            }
            return result.node_ptr;
        }

        // write `vals` as one leaf, or split into two balanced leaves if it
        // exceeds the node capacity
        fn btreeAssembleLeaf(self: *Database(db_kind, HashInt), vals: []const Slot) !BTreeJoinResult {
            const total = vals.len;
            if (total <= BTREE_SLOT_COUNT) {
                var leaf = BTreeNode{ .kind = .leaf, .num = @intCast(total) };
                @memcpy(leaf.values[0..total], vals);
                return .{ .node_ptr = try self.writeBTreeNode(leaf), .count = total, .split = null };
            }
            const left_n = total / 2;
            var left = BTreeNode{ .kind = .leaf, .num = @intCast(left_n) };
            @memcpy(left.values[0..left_n], vals[0..left_n]);
            var right = BTreeNode{ .kind = .leaf, .num = @intCast(total - left_n) };
            @memcpy(right.values[0 .. total - left_n], vals[left_n..]);
            return .{
                .node_ptr = try self.writeBTreeNode(left),
                .count = left_n,
                .split = .{ .node_ptr = try self.writeBTreeNode(right), .count = total - left_n },
            };
        }

        // write `children`/`counts` as one branch, or split into two balanced branches
        fn btreeAssembleBranch(self: *Database(db_kind, HashInt), children: []const Slot, counts: []const u64) !BTreeJoinResult {
            const total = children.len;
            if (total <= BTREE_SLOT_COUNT) {
                var branch = BTreeNode{ .kind = .branch, .num = @intCast(total) };
                @memcpy(branch.children[0..total], children);
                @memcpy(branch.counts[0..total], counts);
                return .{ .node_ptr = try self.writeBTreeNode(branch), .count = branch.subtreeCount(), .split = null };
            }
            const left_n = total / 2;
            var left = BTreeNode{ .kind = .branch, .num = @intCast(left_n) };
            @memcpy(left.children[0..left_n], children[0..left_n]);
            @memcpy(left.counts[0..left_n], counts[0..left_n]);
            var right = BTreeNode{ .kind = .branch, .num = @intCast(total - left_n) };
            @memcpy(right.children[0 .. total - left_n], children[left_n..]);
            @memcpy(right.counts[0 .. total - left_n], counts[left_n..]);
            return .{
                .node_ptr = try self.writeBTreeNode(left),
                .count = left.subtreeCount(),
                .split = .{ .node_ptr = try self.writeBTreeNode(right), .count = right.subtreeCount() },
            };
        }

        // merge two nodes of equal height (a precedes b) into one or two nodes
        fn btreeMergeNodes(self: *Database(db_kind, HashInt), a: BTreeNode, b: BTreeNode) !BTreeJoinResult {
            switch (a.kind) {
                .leaf => {
                    var vals: [2 * BTREE_SLOT_COUNT]Slot = undefined;
                    @memcpy(vals[0..a.num], a.values[0..a.num]);
                    @memcpy(vals[a.num .. a.num + b.num], b.values[0..b.num]);
                    return try self.btreeAssembleLeaf(vals[0 .. a.num + b.num]);
                },
                .branch => {
                    var children: [2 * BTREE_SLOT_COUNT]Slot = undefined;
                    var counts: [2 * BTREE_SLOT_COUNT]u64 = undefined;
                    @memcpy(children[0..a.num], a.children[0..a.num]);
                    @memcpy(counts[0..a.num], a.counts[0..a.num]);
                    @memcpy(children[a.num .. a.num + b.num], b.children[0..b.num]);
                    @memcpy(counts[a.num .. a.num + b.num], b.counts[0..b.num]);
                    return try self.btreeAssembleBranch(children[0 .. a.num + b.num], counts[0 .. a.num + b.num]);
                },
            }
        }

        // join b (shorter) into the rightmost spine of a (taller), at height hb
        fn btreeJoinRight(self: *Database(db_kind, HashInt), a_ptr: u64, ha: u8, b_ptr: u64, hb: u8) anyerror!BTreeJoinResult {
            const a = try self.readBTreeNode(a_ptr);
            const last = a.num - 1;
            const sub = if (ha - 1 == hb)
                try self.btreeMergeNodes(try self.readBTreeNode(a.children[last].value), try self.readBTreeNode(b_ptr))
            else
                try self.btreeJoinRight(a.children[last].value, ha - 1, b_ptr, hb);

            var children: [BTREE_SLOT_COUNT + 1]Slot = undefined;
            var counts: [BTREE_SLOT_COUNT + 1]u64 = undefined;
            @memcpy(children[0..a.num], a.children[0..a.num]);
            @memcpy(counts[0..a.num], a.counts[0..a.num]);
            children[last] = .{ .value = sub.node_ptr, .tag = .index };
            counts[last] = sub.count;
            var total: usize = a.num;
            if (sub.split) |split| {
                children[total] = .{ .value = split.node_ptr, .tag = .index };
                counts[total] = split.count;
                total += 1;
            }
            return try self.btreeAssembleBranch(children[0..total], counts[0..total]);
        }

        // join a (shorter) into the leftmost spine of b (taller), at height ha
        fn btreeJoinLeft(self: *Database(db_kind, HashInt), a_ptr: u64, ha: u8, b_ptr: u64, hb: u8) anyerror!BTreeJoinResult {
            const b = try self.readBTreeNode(b_ptr);
            const sub = if (hb - 1 == ha)
                try self.btreeMergeNodes(try self.readBTreeNode(a_ptr), try self.readBTreeNode(b.children[0].value))
            else
                try self.btreeJoinLeft(a_ptr, ha, b.children[0].value, hb - 1);

            var children: [BTREE_SLOT_COUNT + 1]Slot = undefined;
            var counts: [BTREE_SLOT_COUNT + 1]u64 = undefined;
            children[0] = .{ .value = sub.node_ptr, .tag = .index };
            counts[0] = sub.count;
            var head: usize = 1;
            if (sub.split) |split| {
                children[1] = .{ .value = split.node_ptr, .tag = .index };
                counts[1] = split.count;
                head = 2;
            }
            @memcpy(children[head .. head + b.num - 1], b.children[1..b.num]);
            @memcpy(counts[head .. head + b.num - 1], b.counts[1..b.num]);
            return try self.btreeAssembleBranch(children[0 .. head + b.num - 1], counts[0 .. head + b.num - 1]);
        }

        fn btreeJoin(self: *Database(db_kind, HashInt), root_a: u64, root_b: u64) !u64 {
            const ha = try self.btreeHeight(root_a);
            const hb = try self.btreeHeight(root_b);
            const result = if (ha == hb)
                try self.btreeMergeNodes(try self.readBTreeNode(root_a), try self.readBTreeNode(root_b))
            else if (ha > hb)
                try self.btreeJoinRight(root_a, ha, root_b, hb)
            else
                try self.btreeJoinLeft(root_a, ha, root_b, hb);
            return try self.btreeMakeRoot(result);
        }

        // split (used by slice and remove): a true O(log n), structure-sharing
        // split of a tree into [0, rank) and [rank, size). partial nodes along the
        // path are reassembled with join, so the result trees stay balanced.

        const BTreeSplitResult = struct { left: u64, right: u64 };

        // build a tree from a run of sibling children (already height-h-1 subtrees):
        // empty -> a new empty leaf, one -> that child unwrapped, many -> a branch
        fn btreeSubtree(self: *Database(db_kind, HashInt), children: []const Slot, counts: []const u64) !u64 {
            if (children.len == 0) return try self.btreeNewRoot();
            if (children.len == 1) return children[0].value;
            // children.len <= BTREE_SLOT_COUNT here, so this never splits
            const result = try self.btreeAssembleBranch(children, counts);
            return result.node_ptr;
        }

        fn btreeSplit(self: *Database(db_kind, HashInt), root_ptr: u64, rank: u64) anyerror!BTreeSplitResult {
            const node = try self.readBTreeNode(root_ptr);
            switch (node.kind) {
                .leaf => {
                    const r: usize = @intCast(rank);
                    var left = BTreeNode{ .kind = .leaf, .num = @intCast(r) };
                    @memcpy(left.values[0..r], node.values[0..r]);
                    var right = BTreeNode{ .kind = .leaf, .num = @intCast(node.num - r) };
                    @memcpy(right.values[0 .. node.num - r], node.values[r..node.num]);
                    return .{ .left = try self.writeBTreeNode(left), .right = try self.writeBTreeNode(right) };
                },
                .branch => {
                    var i: u8 = 0;
                    var rem = rank;
                    while (i + 1 < node.num and rem > node.counts[i]) : (i += 1) {
                        rem -= node.counts[i];
                    }
                    const child = try self.btreeSplit(node.children[i].value, rem);
                    const left_sub = try self.btreeSubtree(node.children[0..i], node.counts[0..i]);
                    const right_sub = try self.btreeSubtree(node.children[i + 1 .. node.num], node.counts[i + 1 .. node.num]);
                    return .{
                        .left = try self.btreeJoin(left_sub, child.left),
                        .right = try self.btreeJoin(child.right, right_sub),
                    };
                },
            }
        }

        // sorted_map / sorted_set

        fn readSortedNode(self: *Database(db_kind, HashInt), ptr: u64) !SortedNode {
            var reader = self.core.reader();
            try reader.seekTo(ptr);
            const kind_int = try takeInt(&reader.interface, u8, .big);
            const kind = std.enums.fromInt(SortedNodeKind, kind_int) orelse return error.InvalidBTreeNodeKind;
            const num = try takeInt(&reader.interface, u8, .big);
            if (num > BTREE_SLOT_COUNT) return error.InvalidBTreeNode;
            var node = SortedNode{ .kind = kind, .num = num };
            switch (kind) {
                .leaf => {
                    for (&node.entries) |*s| {
                        s.* = @bitCast(try takeInt(&reader.interface, SlotInt, .big));
                        try s.tag.validate();
                    }
                },
                .branch => {
                    for (&node.children) |*s| {
                        s.* = @bitCast(try takeInt(&reader.interface, SlotInt, .big));
                        try s.tag.validate();
                    }
                    for (&node.separators) |*s| {
                        s.* = @bitCast(try takeInt(&reader.interface, SlotInt, .big));
                        try s.tag.validate();
                    }
                    for (&node.counts) |*c| {
                        c.* = try takeInt(&reader.interface, u64, .big);
                    }
                },
            }
            return node;
        }

        fn writeSortedNodeAt(self: *Database(db_kind, HashInt), node: SortedNode, ptr: u64) !void {
            var writer = self.core.writer();
            try writer.seekTo(ptr);
            try writer.interface.writeInt(u8, @intFromEnum(node.kind), .big);
            try writer.interface.writeInt(u8, node.num, .big);
            switch (node.kind) {
                .leaf => {
                    for (node.entries) |s| try writer.interface.writeInt(SlotInt, @bitCast(s), .big);
                },
                .branch => {
                    for (node.children) |s| try writer.interface.writeInt(SlotInt, @bitCast(s), .big);
                    for (node.separators) |s| try writer.interface.writeInt(SlotInt, @bitCast(s), .big);
                    for (node.counts) |c| try writer.interface.writeInt(u64, c, .big);
                },
            }
        }

        fn writeSortedNode(self: *Database(db_kind, HashInt), node: SortedNode) !u64 {
            const ptr = try self.core.length();
            try self.writeSortedNodeAt(node, ptr);
            return ptr;
        }

        // reuse old_ptr's position in place when it belongs to this transaction
        // (mirrors btreeWriteNode / the tx_start path-copying model)
        fn sortedWriteNode(self: *Database(db_kind, HashInt), node: SortedNode, old_ptr: u64) !u64 {
            if (self.btreeReusable(old_ptr)) {
                try self.writeSortedNodeAt(node, old_ptr);
                return old_ptr;
            }
            return try self.writeSortedNode(node);
        }

        fn readKvPair(self: *Database(db_kind, HashInt), kv_slot: Slot) !KeyValuePair {
            if (kv_slot.tag != .kv_pair) return error.UnexpectedTag;
            var reader = self.core.reader();
            try reader.seekTo(kv_slot.value);
            return @bitCast(try takeInt(&reader.interface, KeyValuePairInt, .big));
        }

        // lexicographic comparison of the byte key stored at `key_slot` (a bytes or
        // short_bytes slot) against the in-memory `target`. streams external bytes so
        // keys of any length work without allocation.
        fn compareKey(self: *Database(db_kind, HashInt), key_slot: Slot, target: []const u8) !std.math.Order {
            switch (key_slot.tag) {
                .short_bytes => {
                    var buf = [_]u8{0} ** byteSizeOf(u64);
                    std.mem.writeInt(u64, &buf, key_slot.value, .big);
                    const total = if (key_slot.full) byteSizeOf(u64) - 2 else byteSizeOf(u64);
                    const len = std.mem.indexOfScalar(u8, buf[0..total], 0) orelse total;
                    return std.mem.order(u8, buf[0..len], target);
                },
                .bytes => {
                    var reader = self.core.reader();
                    try reader.seekTo(key_slot.value);
                    const len = try takeInt(&reader.interface, u64, .big);
                    var i: u64 = 0;
                    var chunk: [256]u8 = undefined;
                    while (i < len) {
                        const n: usize = @intCast(@min(chunk.len, len - i));
                        try reader.interface.readSliceAll(chunk[0..n]);
                        for (chunk[0..n], 0..) |b, j| {
                            const ti = i + j;
                            if (ti >= target.len) return .gt; // stored has more, equal so far
                            if (b < target[ti]) return .lt;
                            if (b > target[ti]) return .gt;
                        }
                        i += n;
                    }
                    return if (target.len > len) .lt else .eq;
                },
                else => return error.UnexpectedTag,
            }
        }

        const SortedSlot = struct { slot: Slot, position: u64 };

        // descend by key to the matching leaf entry (the .kv_pair slot), or null
        fn sortedGet(self: *Database(db_kind, HashInt), root_ptr: u64, key: []const u8) !?SortedSlot {
            var node_ptr = root_ptr;
            while (true) {
                const node = try self.readSortedNode(node_ptr);
                switch (node.kind) {
                    .leaf => {
                        for (0..node.num) |i| {
                            const entry = node.entries[i];
                            const kv = try self.readKvPair(entry);
                            switch (try self.compareKey(kv.key_slot, key)) {
                                .eq => return .{ .slot = entry, .position = node_ptr + BTREE_NODE_HEADER_SIZE + i * byteSizeOf(Slot) },
                                .gt => return null,
                                .lt => {},
                            }
                        }
                        return null;
                    },
                    .branch => {
                        var i: u8 = 0;
                        while (i + 1 < node.num and (try self.compareKey(node.separators[i + 1], key)) != .gt) : (i += 1) {}
                        node_ptr = node.children[i].value;
                    },
                }
            }
        }

        // descend by rank to the leaf entry at the given 0-based index
        fn sortedGetByIndex(self: *Database(db_kind, HashInt), root_ptr: u64, rank: u64) !SortedSlot {
            var node_ptr = root_ptr;
            var rem = rank;
            while (true) {
                const node = try self.readSortedNode(node_ptr);
                switch (node.kind) {
                    .leaf => {
                        const i: usize = @intCast(rem);
                        return .{ .slot = node.entries[i], .position = node_ptr + BTREE_NODE_HEADER_SIZE + i * byteSizeOf(Slot) };
                    },
                    .branch => {
                        var i: u8 = 0;
                        while (i + 1 < node.num and rem >= node.counts[i]) : (i += 1) {
                            rem -= node.counts[i];
                        }
                        node_ptr = node.children[i].value;
                    },
                }
            }
        }

        // number of keys strictly less than `key` (the inverse of getByIndex)
        fn sortedRank(self: *Database(db_kind, HashInt), root_ptr: u64, key: []const u8) !u64 {
            var node_ptr = root_ptr;
            var rank: u64 = 0;
            while (true) {
                const node = try self.readSortedNode(node_ptr);
                switch (node.kind) {
                    .leaf => {
                        for (0..node.num) |i| {
                            const kv = try self.readKvPair(node.entries[i]);
                            if ((try self.compareKey(kv.key_slot, key)) == .lt) {
                                rank += 1;
                            } else break;
                        }
                        return rank;
                    },
                    .branch => {
                        var i: u8 = 0;
                        while (i + 1 < node.num and (try self.compareKey(node.separators[i + 1], key)) != .gt) : (i += 1) {
                            rank += node.counts[i];
                        }
                        node_ptr = node.children[i].value;
                    },
                }
            }
        }

        // write a byte key as a short_bytes (inline, <=8 bytes, no interior zero) or
        // external bytes slot
        fn writeKey(self: *Database(db_kind, HashInt), key: []const u8) !Slot {
            if (key.len <= byteSizeOf(u64) and std.mem.indexOfScalar(u8, key, 0) == null) {
                var value = [_]u8{0} ** byteSizeOf(u64);
                @memcpy(value[0..key.len], key);
                return .{ .value = std.mem.readInt(u64, &value, .big), .tag = .short_bytes };
            }
            var writer = self.core.writer();
            const pos = try self.core.length();
            try writer.seekTo(pos);
            try writer.interface.writeInt(u64, key.len, .big);
            try writer.interface.writeAll(key);
            return .{ .value = pos, .tag = .bytes };
        }

        const SortedEntry = struct { kv_slot: Slot, key_slot: Slot, value_position: u64 };

        // materialize a new leaf entry: write the key bytes and a KeyValuePair with an
        // empty value (the caller fills it via value_position). the hash field is unused
        // by sorted maps (navigation is by key bytes), so it is left zero.
        fn sortedNewEntry(self: *Database(db_kind, HashInt), key: []const u8) !SortedEntry {
            const key_slot = try self.writeKey(key);
            var writer = self.core.writer();
            const kv_pos = try self.core.length();
            const kv_pair = KeyValuePair{
                .value_slot = @bitCast(@as(SlotInt, 0)),
                .key_slot = key_slot,
                .hash = 0,
            };
            try writer.seekTo(kv_pos);
            try writer.interface.writeInt(KeyValuePairInt, @bitCast(kv_pair), .big);
            return .{
                .kv_slot = .{ .value = kv_pos, .tag = .kv_pair },
                .key_slot = key_slot,
                .value_position = kv_pos + byteSizeOf(HashInt) + byteSizeOf(Slot),
            };
        }

        // insert `key` (or locate it for replacement) within the subtree at node_ptr,
        // path-copying nodes and maintaining separators + counts. the caller writes the
        // value at the returned value_position.
        fn sortedPut(self: *Database(db_kind, HashInt), node_ptr: u64, key: []const u8) anyerror!SortedInsertResult {
            const node = try self.readSortedNode(node_ptr);
            var writer = self.core.writer();
            switch (node.kind) {
                .leaf => {
                    // find the matching or insertion index
                    var idx: usize = node.num;
                    var found = false;
                    for (0..node.num) |i| {
                        const kv = try self.readKvPair(node.entries[i]);
                        switch (try self.compareKey(kv.key_slot, key)) {
                            .eq => {
                                idx = i;
                                found = true;
                                break;
                            },
                            .gt => {
                                idx = i;
                                break;
                            },
                            .lt => {},
                        }
                    }

                    if (found) {
                        // replace: return a writable value slot, copy-on-writing the
                        // kv_pair if it belongs to a past moment
                        var leaf = node;
                        const kv_slot = node.entries[idx];
                        var value_position: u64 = undefined;
                        if (self.btreeReusable(kv_slot.value)) {
                            value_position = kv_slot.value + byteSizeOf(HashInt) + byteSizeOf(Slot);
                        } else {
                            const kv = try self.readKvPair(kv_slot);
                            const new_kv_pos = try self.core.length();
                            try writer.seekTo(new_kv_pos);
                            try writer.interface.writeInt(KeyValuePairInt, @bitCast(kv), .big);
                            leaf.entries[idx] = .{ .value = new_kv_pos, .tag = .kv_pair };
                            value_position = new_kv_pos + byteSizeOf(HashInt) + byteSizeOf(Slot);
                        }
                        const ptr = try self.sortedWriteNode(leaf, node_ptr);
                        return .{ .node_ptr = ptr, .count = node.num, .value_position = value_position, .added = false, .split = null };
                    }

                    // insert a new entry at idx
                    const entry = try self.sortedNewEntry(key);
                    var entries = [_]Slot{.{}} ** (BTREE_SLOT_COUNT + 1);
                    @memcpy(entries[0..idx], node.entries[0..idx]);
                    entries[idx] = entry.kv_slot;
                    @memcpy(entries[idx + 1 .. node.num + 1], node.entries[idx..node.num]);
                    const total: usize = node.num + 1;

                    if (total <= BTREE_SLOT_COUNT) {
                        var leaf = SortedNode{ .kind = .leaf, .num = @intCast(total) };
                        @memcpy(leaf.entries[0..total], entries[0..total]);
                        const ptr = try self.sortedWriteNode(leaf, node_ptr);
                        return .{ .node_ptr = ptr, .count = total, .value_position = entry.value_position, .added = true, .split = null };
                    }

                    // overflow: split into two leaves; the new sibling's separator is the
                    // key of its first entry
                    const left_n = BTREE_SPLIT_COUNT;
                    const right_n = total - left_n;
                    var left = SortedNode{ .kind = .leaf, .num = @intCast(left_n) };
                    @memcpy(left.entries[0..left_n], entries[0..left_n]);
                    var right = SortedNode{ .kind = .leaf, .num = @intCast(right_n) };
                    @memcpy(right.entries[0..right_n], entries[left_n..total]);
                    const separator = (try self.readKvPair(entries[left_n])).key_slot;
                    const left_ptr = try self.sortedWriteNode(left, node_ptr);
                    const right_ptr = try self.writeSortedNode(right);
                    return .{
                        .node_ptr = left_ptr,
                        .count = left_n,
                        .value_position = entry.value_position,
                        .added = true,
                        .split = .{ .node_ptr = right_ptr, .count = right_n, .separator = separator },
                    };
                },
                .branch => {
                    var i: u8 = 0;
                    while (i + 1 < node.num and (try self.compareKey(node.separators[i + 1], key)) != .gt) : (i += 1) {}
                    const child = try self.sortedPut(node.children[i].value, key);

                    var children = [_]Slot{.{}} ** (BTREE_SLOT_COUNT + 1);
                    var separators = [_]Slot{.{}} ** (BTREE_SLOT_COUNT + 1);
                    var counts = [_]u64{0} ** (BTREE_SLOT_COUNT + 1);
                    @memcpy(children[0..node.num], node.children[0..node.num]);
                    @memcpy(separators[0..node.num], node.separators[0..node.num]);
                    @memcpy(counts[0..node.num], node.counts[0..node.num]);
                    children[i] = .{ .value = child.node_ptr, .tag = .index };
                    counts[i] = child.count;
                    var total: usize = node.num;
                    if (child.split) |split| {
                        var j: usize = node.num;
                        while (j > i + 1) : (j -= 1) {
                            children[j] = children[j - 1];
                            separators[j] = separators[j - 1];
                            counts[j] = counts[j - 1];
                        }
                        children[i + 1] = .{ .value = split.node_ptr, .tag = .index };
                        separators[i + 1] = split.separator;
                        counts[i + 1] = split.count;
                        total = node.num + 1;
                    }

                    if (total <= BTREE_SLOT_COUNT) {
                        var branch = SortedNode{ .kind = .branch, .num = @intCast(total) };
                        @memcpy(branch.children[0..total], children[0..total]);
                        @memcpy(branch.separators[0..total], separators[0..total]);
                        @memcpy(branch.counts[0..total], counts[0..total]);
                        const ptr = try self.sortedWriteNode(branch, node_ptr);
                        return .{ .node_ptr = ptr, .count = branch.subtreeCount(), .value_position = child.value_position, .added = child.added, .split = null };
                    }

                    // overflow: split into two branches; the new sibling's separator is the
                    // smallest key of its first child (separators[left_n] of the combined)
                    const left_n = BTREE_SPLIT_COUNT;
                    const right_n = total - left_n;
                    var left = SortedNode{ .kind = .branch, .num = @intCast(left_n) };
                    @memcpy(left.children[0..left_n], children[0..left_n]);
                    @memcpy(left.separators[0..left_n], separators[0..left_n]);
                    @memcpy(left.counts[0..left_n], counts[0..left_n]);
                    var right = SortedNode{ .kind = .branch, .num = @intCast(right_n) };
                    @memcpy(right.children[0..right_n], children[left_n..total]);
                    @memcpy(right.separators[0..right_n], separators[left_n..total]);
                    @memcpy(right.counts[0..right_n], counts[left_n..total]);
                    const separator = separators[left_n];
                    const left_ptr = try self.sortedWriteNode(left, node_ptr);
                    const right_ptr = try self.writeSortedNode(right);
                    return .{
                        .node_ptr = left_ptr,
                        .count = left.subtreeCount(),
                        .value_position = child.value_position,
                        .added = child.added,
                        .split = .{ .node_ptr = right_ptr, .count = right.subtreeCount(), .separator = separator },
                    };
                },
            }
        }

        // remove `key` from the subtree at node_ptr, path-copying nodes and
        // decrementing counts. an emptied leaf is left in place (see SortedRemoveResult).
        fn sortedRemove(self: *Database(db_kind, HashInt), node_ptr: u64, key: []const u8) anyerror!SortedRemoveResult {
            const node = try self.readSortedNode(node_ptr);
            switch (node.kind) {
                .leaf => {
                    var idx: usize = node.num;
                    var found = false;
                    for (0..node.num) |i| {
                        const kv = try self.readKvPair(node.entries[i]);
                        switch (try self.compareKey(kv.key_slot, key)) {
                            .eq => {
                                idx = i;
                                found = true;
                                break;
                            },
                            .gt => break,
                            .lt => {},
                        }
                    }
                    if (!found) return .{ .node_ptr = node_ptr, .found = false };

                    var leaf = SortedNode{ .kind = .leaf, .num = node.num - 1 };
                    @memcpy(leaf.entries[0..idx], node.entries[0..idx]);
                    @memcpy(leaf.entries[idx .. node.num - 1], node.entries[idx + 1 .. node.num]);
                    const ptr = try self.sortedWriteNode(leaf, node_ptr);
                    return .{ .node_ptr = ptr, .found = true };
                },
                .branch => {
                    var i: u8 = 0;
                    while (i + 1 < node.num and (try self.compareKey(node.separators[i + 1], key)) != .gt) : (i += 1) {}
                    const child = try self.sortedRemove(node.children[i].value, key);
                    if (!child.found) return .{ .node_ptr = node_ptr, .found = false };

                    var branch = node;
                    branch.children[i] = .{ .value = child.node_ptr, .tag = .index };
                    branch.counts[i] -= 1;
                    const ptr = try self.sortedWriteNode(branch, node_ptr);
                    return .{ .node_ptr = ptr, .found = true };
                },
            }
        }

        fn sortedGrowRoot(self: *Database(db_kind, HashInt), result: SortedInsertResult) !u64 {
            if (result.split) |split| {
                var root = SortedNode{ .kind = .branch, .num = 2 };
                root.children[0] = .{ .value = result.node_ptr, .tag = .index };
                root.children[1] = .{ .value = split.node_ptr, .tag = .index };
                root.separators[1] = split.separator; // separators[0] is an unused sentinel
                root.counts[0] = result.count;
                root.counts[1] = split.count;
                return try self.writeSortedNode(root);
            }
            return result.node_ptr;
        }

        // turn a located/inserted kv_pair (at kv_pos) into the slot for the requested
        // target. only the value is writeable (that is how put works); the key and the
        // kv_pair pointer are immutable — overwriting a key would leave the entry
        // mis-ordered (it stays in place and separators aren't updated) — so they are
        // returned with no writeable position. reads use slot.value, not position.
        fn sortedTargetSlot(self: *Database(db_kind, HashInt), kv_pos: u64, target: HashMapSlotKind) !SlotPointer {
            const kv = try self.readKvPair(.{ .value = kv_pos, .tag = .kv_pair });
            return switch (target) {
                .kv_pair => .{ .position = null, .slot = .{ .value = kv_pos, .tag = .kv_pair } },
                .key => .{ .position = null, .slot = kv.key_slot },
                .value => .{ .position = kv_pos + byteSizeOf(HashInt) + byteSizeOf(Slot), .slot = kv.value_slot },
            };
        }

        // Cursor

        pub fn KeyValuePairCursor(comptime write_mode: WriteMode) type {
            return struct {
                value_cursor: Cursor(write_mode),
                key_cursor: Cursor(write_mode),
                hash: HashInt,
            };
        }

        pub fn Cursor(comptime write_mode: WriteMode) type {
            return struct {
                slot_ptr: SlotPointer,
                db: *Database(db_kind, HashInt),

                pub const Reader = struct {
                    parent: *Cursor(write_mode),
                    interface: std.Io.Reader,
                    size: u64,
                    start_position: u64,
                    pos: u64,

                    pub fn seekTo(self: *Reader, offset: u64) !void {
                        const logical_pos = self.logicalPos();
                        if (offset < logical_pos or offset >= self.pos) {
                            self.interface.seek = 0;
                            self.interface.end = 0;
                            self.pos = offset;
                        } else {
                            const logical_delta: usize = @intCast(offset - logical_pos);
                            self.interface.seek += logical_delta;
                        }
                    }

                    pub fn logicalPos(self: Reader) u64 {
                        return self.pos - self.interface.bufferedLen();
                    }

                    fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));

                        if (r.size == r.pos) return error.EndOfStream;

                        const new_limit: std.Io.Limit = @enumFromInt(@min(@intFromEnum(limit), r.size - r.pos));
                        const dest = new_limit.slice(try io_w.writableSliceGreedy(1));

                        var core_reader = r.parent.db.core.reader();
                        core_reader.seekTo(r.start_position + r.pos) catch return error.ReadFailed;
                        const size = try core_reader.interface.readSliceShort(dest);
                        r.pos += size;
                        io_w.advance(size);
                        return size;
                    }
                };

                pub const Writer = struct {
                    parent: *Cursor(.read_write),
                    interface: std.Io.Writer,
                    size: u64,
                    slot: Slot,
                    start_position: u64,
                    pos: u64,
                    format_tag: ?[2]u8,

                    pub fn finish(self: *Writer) !void {
                        try self.interface.flush();

                        var core_writer = self.parent.db.core.writer();

                        if (self.format_tag) |format_tag| {
                            self.slot.full = true; // byte arrays with format tags must have this set to true
                            const format_tag_pos = try self.parent.db.core.length();
                            try core_writer.seekTo(format_tag_pos);
                            if (self.start_position + self.size != format_tag_pos) return error.UnexpectedWriterPosition;
                            try core_writer.interface.writeAll(&format_tag);
                        }

                        try core_writer.seekTo(self.slot.value);
                        try core_writer.interface.writeInt(u64, self.size, .big);

                        const position = self.parent.slot_ptr.position orelse return error.CursorNotWriteable;
                        try core_writer.seekTo(position);
                        try core_writer.interface.writeInt(SlotInt, @bitCast(self.slot), .big);

                        self.parent.slot_ptr.slot = self.slot;
                    }

                    pub fn seekTo(self: *Writer, offset: u64) !void {
                        try self.interface.flush();
                        self.pos = offset;
                    }

                    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                        const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));

                        if (splat != 1) unreachable; // splat isn't supported

                        const bytes = io_w.buffered();
                        if (bytes.len > 0) {
                            return try w.writeAll(bytes);
                        }

                        for (data) |buf| {
                            if (buf.len == 0) continue;
                            return try w.writeAll(buf);
                        }

                        return error.WriteFailed;
                    }

                    fn writeAll(self: *Writer, bytes: []const u8) std.Io.Writer.Error!usize {
                        const n = bytes.len;

                        var core_writer = self.parent.db.core.writer();
                        core_writer.seekTo(self.start_position + self.pos) catch return error.WriteFailed;
                        try core_writer.interface.writeAll(bytes);

                        const new_position = self.pos + @as(u64, @intCast(n));
                        self.pos = new_position;
                        if (self.pos > self.size) {
                            self.size = self.pos;
                        }

                        return self.interface.consume(n);
                    }
                };

                pub fn readOnly(self: Cursor(.read_write)) Cursor(.read_only) {
                    return .{
                        .slot_ptr = self.slot_ptr,
                        .db = self.db,
                    };
                }

                pub fn readPath(self: Cursor(write_mode), comptime Ctx: type, path: []const PathPart(Ctx)) !?Cursor(.read_only) {
                    const slot_ptr = self.db.readSlotPointer(.read_only, Ctx, path, self.slot_ptr) catch |err| {
                        switch (err) {
                            error.KeyNotFound => return null,
                            else => |e| return e,
                        }
                    };
                    return .{
                        .slot_ptr = slot_ptr,
                        .db = self.db,
                    };
                }

                pub fn readPathSlot(self: Cursor(write_mode), comptime Ctx: type, path: []const PathPart(Ctx)) !?Slot {
                    const slot_ptr = self.db.readSlotPointer(.read_only, Ctx, path, self.slot_ptr) catch |err| {
                        switch (err) {
                            error.KeyNotFound => return null,
                            else => |e| return e,
                        }
                    };
                    if (!slot_ptr.slot.empty()) {
                        return slot_ptr.slot;
                    } else {
                        return null;
                    }
                }

                pub fn writePath(self: Cursor(.read_write), comptime Ctx: type, path: []const PathPart(Ctx)) !Cursor(.read_write) {
                    const slot_ptr = try self.db.readSlotPointer(.read_write, Ctx, path, self.slot_ptr);
                    if (self.db.tx_start == null) {
                        try self.db.core.sync();
                    }
                    return .{
                        .slot_ptr = slot_ptr,
                        .db = self.db,
                    };
                }

                pub fn readUint(self: Cursor(write_mode)) !u64 {
                    if (self.slot_ptr.slot.tag != .uint) {
                        return error.UnexpectedTag;
                    }
                    return self.slot_ptr.slot.value;
                }

                pub fn readInt(self: Cursor(write_mode)) !i64 {
                    if (self.slot_ptr.slot.tag != .int) {
                        return error.UnexpectedTag;
                    }
                    return @bitCast(self.slot_ptr.slot.value);
                }

                pub fn readFloat(self: Cursor(write_mode)) !f64 {
                    if (self.slot_ptr.slot.tag != .float) {
                        return error.UnexpectedTag;
                    }
                    return @bitCast(self.slot_ptr.slot.value);
                }

                pub fn readBytesAlloc(self: Cursor(write_mode), allocator: std.mem.Allocator, max_size_maybe: ?usize) ![]const u8 {
                    return (try self.readBytesObjectAlloc(allocator, max_size_maybe)).value;
                }

                pub fn readBytes(self: Cursor(write_mode), buffer: []u8) ![]const u8 {
                    return (try self.readBytesObject(buffer)).value;
                }

                pub fn readBytesObjectAlloc(self: Cursor(write_mode), allocator: std.mem.Allocator, max_size_maybe: ?usize) !Bytes {
                    var core_reader = self.db.core.reader();

                    switch (self.slot_ptr.slot.tag) {
                        .none => return .{ .value = try allocator.alloc(u8, 0) },
                        .bytes => {
                            try core_reader.seekTo(self.slot_ptr.slot.value);
                            const value_size = try takeInt(&core_reader.interface, u64, .big);

                            if (max_size_maybe) |max_size| {
                                if (value_size > max_size) {
                                    return error.StreamTooLong;
                                }
                            }

                            const start_position = core_reader.pos;

                            const value = try allocator.alloc(u8, value_size);
                            errdefer allocator.free(value);

                            try core_reader.interface.readSliceAll(value);

                            const format_tag = if (self.slot_ptr.slot.full) blk: {
                                try core_reader.seekTo(start_position + value_size);
                                var buf = [_]u8{0} ** 2;
                                try core_reader.interface.readSliceAll(&buf);
                                break :blk buf;
                            } else null;

                            return .{ .value = value, .format_tag = format_tag };
                        },
                        .short_bytes => {
                            var bytes = [_]u8{0} ** byteSizeOf(u64);
                            std.mem.writeInt(u64, &bytes, self.slot_ptr.slot.value, .big);
                            const total_size = if (self.slot_ptr.slot.full) byteSizeOf(u64) - 2 else byteSizeOf(u64);
                            const value_size = std.mem.indexOfScalar(u8, bytes[0..total_size], 0) orelse total_size;

                            if (max_size_maybe) |max_size| {
                                if (value_size > max_size) {
                                    return error.StreamTooLong;
                                }
                            }

                            const value = try allocator.alloc(u8, value_size);
                            errdefer allocator.free(value);
                            @memcpy(value, bytes[0..value_size]);

                            const format_tag = if (self.slot_ptr.slot.full) blk: {
                                var buf = [_]u8{0} ** 2;
                                @memcpy(&buf, bytes[total_size..]);
                                break :blk buf;
                            } else null;

                            return .{ .value = value, .format_tag = format_tag };
                        },
                        else => return error.UnexpectedTag,
                    }
                }

                pub fn readBytesObject(self: Cursor(write_mode), buffer: []u8) !Bytes {
                    var core_reader = self.db.core.reader();

                    switch (self.slot_ptr.slot.tag) {
                        .none => return if (buffer.len == 0) .{ .value = buffer } else error.EndOfStream,
                        .bytes => {
                            try core_reader.seekTo(self.slot_ptr.slot.value);
                            const value_size = try takeInt(&core_reader.interface, u64, .big);

                            if (value_size > buffer.len) {
                                return error.StreamTooLong;
                            }

                            const start_position = core_reader.pos;

                            try core_reader.interface.readSliceAll(buffer[0..value_size]);
                            const value = buffer[0..value_size];

                            const format_tag = if (self.slot_ptr.slot.full) blk: {
                                try core_reader.seekTo(start_position + value_size);
                                var buf = [_]u8{0} ** 2;
                                try core_reader.interface.readSliceAll(&buf);
                                break :blk buf;
                            } else null;

                            return .{ .value = value, .format_tag = format_tag };
                        },
                        .short_bytes => {
                            var bytes = [_]u8{0} ** byteSizeOf(u64);
                            std.mem.writeInt(u64, &bytes, self.slot_ptr.slot.value, .big);
                            const total_size = if (self.slot_ptr.slot.full) byteSizeOf(u64) - 2 else byteSizeOf(u64);
                            const value_size = std.mem.indexOfScalar(u8, bytes[0..total_size], 0) orelse total_size;

                            if (value_size > buffer.len) {
                                return error.StreamTooLong;
                            }

                            @memcpy(buffer[0..value_size], bytes[0..value_size]);
                            const value = buffer[0..value_size];

                            const format_tag = if (self.slot_ptr.slot.full) blk: {
                                var buf = [_]u8{0} ** 2;
                                @memcpy(&buf, bytes[total_size..]);
                                break :blk buf;
                            } else null;

                            return .{ .value = value, .format_tag = format_tag };
                        },
                        else => return error.UnexpectedTag,
                    }
                }

                pub fn readKeyValuePair(self: Cursor(write_mode)) !KeyValuePairCursor(write_mode) {
                    var core_reader = self.db.core.reader();

                    if (self.slot_ptr.slot.tag != .kv_pair) {
                        return error.UnexpectedTag;
                    }

                    try core_reader.seekTo(self.slot_ptr.slot.value);
                    const kv_pair: KeyValuePair = @bitCast(try takeInt(&core_reader.interface, KeyValuePairInt, .big));

                    try kv_pair.key_slot.tag.validate();
                    try kv_pair.value_slot.tag.validate();

                    const hash_pos = self.slot_ptr.slot.value;
                    const key_slot_pos = hash_pos + byteSizeOf(HashInt);
                    const value_slot_pos = key_slot_pos + byteSizeOf(Slot);

                    return .{
                        .value_cursor = .{ .slot_ptr = .{ .position = value_slot_pos, .slot = kv_pair.value_slot }, .db = self.db },
                        .key_cursor = .{ .slot_ptr = .{ .position = key_slot_pos, .slot = kv_pair.key_slot }, .db = self.db },
                        .hash = kv_pair.hash,
                    };
                }

                pub fn write(self: *Cursor(.read_write), data: WriteableData) !void {
                    self.* = try self.writePath(void, &.{.{ .write = data }});
                }

                pub fn writeIfEmpty(self: *Cursor(.read_write), data: WriteableData) !void {
                    if (self.slot_ptr.slot.empty()) {
                        try self.write(data);
                    }
                }

                pub fn reader(self: *Cursor(write_mode), buffer: []u8) !Reader {
                    var core_reader = self.db.core.reader();

                    switch (self.slot_ptr.slot.tag) {
                        .bytes => {
                            try core_reader.seekTo(self.slot_ptr.slot.value);
                            const size: u64 = @intCast(try takeInt(&core_reader.interface, u64, .big));
                            const start_position = core_reader.pos;
                            return .{
                                .parent = self,
                                .interface = .{
                                    .vtable = &.{ .stream = Reader.stream },
                                    .buffer = buffer,
                                    .seek = 0,
                                    .end = 0,
                                },
                                .size = size,
                                .start_position = start_position,
                                .pos = 0,
                            };
                        },
                        .short_bytes => {
                            var bytes = [_]u8{0} ** byteSizeOf(u64);
                            std.mem.writeInt(u64, &bytes, self.slot_ptr.slot.value, .big);
                            const total_size = if (self.slot_ptr.slot.full) byteSizeOf(u64) - 2 else byteSizeOf(u64);
                            const value_size = std.mem.indexOfScalar(u8, bytes[0..total_size], 0) orelse total_size;
                            return .{
                                .parent = self,
                                .interface = .{
                                    .vtable = &.{ .stream = Reader.stream },
                                    .buffer = buffer,
                                    .seek = 0,
                                    .end = 0,
                                },
                                .size = value_size,
                                // add one to get past the tag byte
                                .start_position = (self.slot_ptr.position orelse return error.ExpectedSlotPosition) + 1,
                                .pos = 0,
                            };
                        },
                        else => return error.UnexpectedTag,
                    }
                }

                pub fn writer(self: *Cursor(.read_write), buffer: []u8) !Writer {
                    var core_writer = self.db.core.writer();
                    const ptr_pos = try self.db.core.length();
                    try core_writer.seekTo(ptr_pos);
                    try core_writer.interface.writeInt(u64, 0, .big);
                    const start_position = core_writer.pos;

                    return .{
                        .parent = self,
                        .interface = .{
                            .vtable = &.{ .drain = Writer.drain },
                            .buffer = buffer,
                        },
                        .size = 0,
                        .slot = .{ .value = ptr_pos, .tag = .bytes },
                        .start_position = start_position,
                        .pos = 0,
                        .format_tag = null,
                    };
                }

                pub fn slot(self: Cursor(write_mode)) Slot {
                    return self.slot_ptr.slot;
                }

                pub fn count(self: Cursor(write_mode)) !u64 {
                    var core_reader = self.db.core.reader();
                    switch (self.slot_ptr.slot.tag) {
                        .none => return 0,
                        .array_list => {
                            try core_reader.seekTo(self.slot_ptr.slot.value);
                            const header: ArrayListHeader = @bitCast(try takeInt(&core_reader.interface, ArrayListHeaderInt, .big));
                            return header.size;
                        },
                        .linked_array_list, .sorted_map, .sorted_set => {
                            try core_reader.seekTo(self.slot_ptr.slot.value);
                            const header: BTreeHeader = @bitCast(try takeInt(&core_reader.interface, BTreeHeaderInt, .big));
                            return header.size;
                        },
                        .bytes => {
                            try core_reader.seekTo(self.slot_ptr.slot.value);
                            return try takeInt(&core_reader.interface, u64, .big);
                        },
                        .short_bytes => {
                            var bytes = [_]u8{0} ** byteSizeOf(u64);
                            std.mem.writeInt(u64, &bytes, self.slot_ptr.slot.value, .big);
                            const total_size = if (self.slot_ptr.slot.full) byteSizeOf(u64) - 2 else byteSizeOf(u64);
                            return std.mem.indexOfScalar(u8, bytes[0..total_size], 0) orelse total_size;
                        },
                        .counted_hash_map, .counted_hash_set => {
                            try core_reader.seekTo(self.slot_ptr.slot.value);
                            return try takeInt(&core_reader.interface, u64, .big);
                        },
                        else => return error.UnexpectedTag,
                    }
                }

                pub const Iter = struct {
                    cursor: Cursor(write_mode),
                    core: struct {
                        size: u64,
                        index: u64,
                        stack: BoundedArray(Level, ITERATOR_STACK_SIZE),
                    },

                    pub const Level = struct {
                        position: u64,
                        block: [SLOT_COUNT]Slot,
                        index: u8,
                    };

                    pub fn init(cursor: Cursor(write_mode)) !Iter {
                        return .{
                            .cursor = cursor,
                            .core = switch (cursor.slot_ptr.slot.tag) {
                                .none => .{
                                    .size = 0,
                                    .index = 0,
                                    .stack = try BoundedArray(Level, ITERATOR_STACK_SIZE).init(0),
                                },
                                .array_list => blk: {
                                    const position = cursor.slot_ptr.slot.value;
                                    var core_reader = cursor.db.core.reader();
                                    try core_reader.seekTo(position);
                                    const header: ArrayListHeader = @bitCast(try takeInt(&core_reader.interface, ArrayListHeaderInt, .big));
                                    break :blk .{
                                        .size = try cursor.count(),
                                        .index = 0,
                                        .stack = try initStack(cursor, header.ptr),
                                    };
                                },
                                .linked_array_list, .sorted_map, .sorted_set => blk: {
                                    const position = cursor.slot_ptr.slot.value;
                                    var core_reader = cursor.db.core.reader();
                                    try core_reader.seekTo(position);
                                    const header: BTreeHeader = @bitCast(try takeInt(&core_reader.interface, BTreeHeaderInt, .big));
                                    break :blk .{
                                        .size = try cursor.count(),
                                        .index = 0,
                                        .stack = try initStack(cursor, header.root_ptr + BTREE_NODE_HEADER_SIZE),
                                    };
                                },
                                .hash_map, .hash_set => .{
                                    .size = 0,
                                    .index = 0,
                                    .stack = try initStack(cursor, cursor.slot_ptr.slot.value),
                                },
                                .counted_hash_map, .counted_hash_set => .{
                                    .size = 0,
                                    .index = 0,
                                    .stack = try initStack(cursor, cursor.slot_ptr.slot.value + byteSizeOf(u64)),
                                },
                                else => return error.UnexpectedTag,
                            },
                        };
                    }

                    fn resolveStartIndex(index: i65, size: u64) ?u64 {
                        const ssize: i65 = @intCast(size);
                        const resolved: i65 = if (index < 0) index + ssize else index;
                        if (resolved < 0 or resolved >= ssize) return null;
                        return @intCast(resolved);
                    }

                    fn emptyIter(cursor: Cursor(write_mode)) !Iter {
                        return .{ .cursor = cursor, .core = .{ .size = 0, .index = 0, .stack = try BoundedArray(Level, ITERATOR_STACK_SIZE).init(0) } };
                    }

                    pub fn initSortedFromIndex(cursor: Cursor(write_mode), start_index: i65) !Iter {
                        // an unwritten map is .none (like iterator()): yield nothing
                        if (cursor.slot_ptr.slot.tag == .none) return emptyIter(cursor);
                        const total = try cursor.count();
                        const idx = resolveStartIndex(start_index, total) orelse return emptyIter(cursor);
                        const root_ptr = try sortedRootPtr(cursor);
                        return .{
                            .cursor = cursor,
                            .core = .{ .size = total, .index = idx, .stack = try sortedStackFromIndex(cursor, root_ptr, idx) },
                        };
                    }

                    pub fn initSortedFromKey(cursor: Cursor(write_mode), start_key: []const u8) !Iter {
                        if (cursor.slot_ptr.slot.tag == .none) {
                            return .{ .cursor = cursor, .core = .{ .size = 0, .index = 0, .stack = try BoundedArray(Level, ITERATOR_STACK_SIZE).init(0) } };
                        }
                        const total = try cursor.count();
                        const root_ptr = try sortedRootPtr(cursor);
                        const built = try sortedStackFromKey(cursor, root_ptr, start_key);
                        return .{
                            .cursor = cursor,
                            .core = .{ .size = total, .index = built.before, .stack = built.stack },
                        };
                    }

                    pub fn initArrayListFromIndex(cursor: Cursor(write_mode), start_index: i65) !Iter {
                        if (cursor.slot_ptr.slot.tag != .array_list) return emptyIter(cursor);
                        var core_reader = cursor.db.core.reader();
                        try core_reader.seekTo(cursor.slot_ptr.slot.value);
                        const header: ArrayListHeader = @bitCast(try takeInt(&core_reader.interface, ArrayListHeaderInt, .big));
                        const idx = resolveStartIndex(start_index, header.size) orelse return emptyIter(cursor);
                        const last_key = header.size - 1;
                        const shift: u6 = @intCast(if (last_key < SLOT_COUNT) 0 else std.math.log(u64, SLOT_COUNT, last_key));
                        return .{
                            .cursor = cursor,
                            .core = .{ .size = header.size, .index = idx, .stack = try arrayListStackFromIndex(cursor, header.ptr, idx, shift) },
                        };
                    }

                    pub fn initLinkedArrayListFromIndex(cursor: Cursor(write_mode), start_index: i65) !Iter {
                        if (cursor.slot_ptr.slot.tag != .linked_array_list) return emptyIter(cursor);
                        var core_reader = cursor.db.core.reader();
                        try core_reader.seekTo(cursor.slot_ptr.slot.value);
                        const header: BTreeHeader = @bitCast(try takeInt(&core_reader.interface, BTreeHeaderInt, .big));
                        const idx = resolveStartIndex(start_index, header.size) orelse return emptyIter(cursor);
                        return .{
                            .cursor = cursor,
                            .core = .{ .size = header.size, .index = idx, .stack = try btreeStackFromIndex(cursor, header.root_ptr, idx) },
                        };
                    }

                    fn sortedRootPtr(cursor: Cursor(write_mode)) !u64 {
                        switch (cursor.slot_ptr.slot.tag) {
                            .sorted_map, .sorted_set => {},
                            else => return error.UnexpectedTag,
                        }
                        var core_reader = cursor.db.core.reader();
                        try core_reader.seekTo(cursor.slot_ptr.slot.value);
                        const header: BTreeHeader = @bitCast(try takeInt(&core_reader.interface, BTreeHeaderInt, .big));
                        return header.root_ptr;
                    }

                    fn sortedStackFromIndex(cursor: Cursor(write_mode), root_ptr: u64, start_index: u64) !BoundedArray(Level, ITERATOR_STACK_SIZE) {
                        var stack = try BoundedArray(Level, ITERATOR_STACK_SIZE).init(0);
                        var node_ptr = root_ptr;
                        var rem = start_index;
                        while (true) {
                            const node = try cursor.db.readSortedNode(node_ptr);
                            const position = node_ptr + BTREE_NODE_HEADER_SIZE;
                            switch (node.kind) {
                                .leaf => {
                                    try stack.append(.{ .position = position, .block = node.entries, .index = @intCast(rem) });
                                    return stack;
                                },
                                .branch => {
                                    var i: u8 = 0;
                                    while (i + 1 < node.num and rem >= node.counts[i]) : (i += 1) {
                                        rem -= node.counts[i];
                                    }
                                    try stack.append(.{ .position = position, .block = node.children, .index = i });
                                    node_ptr = node.children[i].value;
                                },
                            }
                        }
                    }

                    fn sortedStackFromKey(cursor: Cursor(write_mode), root_ptr: u64, key: []const u8) !struct { stack: BoundedArray(Level, ITERATOR_STACK_SIZE), before: u64 } {
                        var stack = try BoundedArray(Level, ITERATOR_STACK_SIZE).init(0);
                        var node_ptr = root_ptr;
                        var before: u64 = 0;
                        while (true) {
                            const node = try cursor.db.readSortedNode(node_ptr);
                            const position = node_ptr + BTREE_NODE_HEADER_SIZE;
                            switch (node.kind) {
                                .leaf => {
                                    var li: u8 = node.num;
                                    for (0..node.num) |j| {
                                        const kv = try cursor.db.readKvPair(node.entries[j]);
                                        if ((try cursor.db.compareKey(kv.key_slot, key)) != .lt) {
                                            li = @intCast(j);
                                            break;
                                        }
                                    }
                                    before += li;
                                    try stack.append(.{ .position = position, .block = node.entries, .index = li });
                                    return .{ .stack = stack, .before = before };
                                },
                                .branch => {
                                    var i: u8 = 0;
                                    while (i + 1 < node.num and (try cursor.db.compareKey(node.separators[i + 1], key)) != .gt) : (i += 1) {
                                        before += node.counts[i];
                                    }
                                    try stack.append(.{ .position = position, .block = node.children, .index = i });
                                    node_ptr = node.children[i].value;
                                },
                            }
                        }
                    }

                    // descend the array-list radix trie to `start_index`, pushing one
                    // Level per tier with its index set to that tier's child slot.
                    // nextInternal then walks forward from there.
                    fn arrayListStackFromIndex(cursor: Cursor(write_mode), root_ptr: u64, start_index: u64, shift: u6) !BoundedArray(Level, ITERATOR_STACK_SIZE) {
                        var stack = try BoundedArray(Level, ITERATOR_STACK_SIZE).init(0);
                        var pos = root_ptr;
                        var sh = shift;
                        while (true) {
                            const block = try readSlotBlock(cursor, pos);
                            const i: u8 = @intCast(start_index >> (sh * BIT_COUNT) & MASK);
                            try stack.append(.{ .position = pos, .block = block, .index = i });
                            if (sh == 0) return stack;
                            // every tier above the leaf is a populated .index slot for
                            // any start_index < size, so this child always exists
                            pos = block[i].value;
                            sh -= 1;
                        }
                    }

                    // descend the linked-array-list count b-tree to `start_index`; the
                    // positional analog of sortedStackFromIndex (no separator keys).
                    fn btreeStackFromIndex(cursor: Cursor(write_mode), root_ptr: u64, start_index: u64) !BoundedArray(Level, ITERATOR_STACK_SIZE) {
                        var stack = try BoundedArray(Level, ITERATOR_STACK_SIZE).init(0);
                        var node_ptr = root_ptr;
                        var rem = start_index;
                        while (true) {
                            const node = try cursor.db.readBTreeNode(node_ptr);
                            const position = node_ptr + BTREE_NODE_HEADER_SIZE;
                            switch (node.kind) {
                                .leaf => {
                                    try stack.append(.{ .position = position, .block = node.values, .index = @intCast(rem) });
                                    return stack;
                                },
                                .branch => {
                                    var i: u8 = 0;
                                    while (i + 1 < node.num and rem >= node.counts[i]) : (i += 1) {
                                        rem -= node.counts[i];
                                    }
                                    try stack.append(.{ .position = position, .block = node.children, .index = i });
                                    node_ptr = node.children[i].value;
                                },
                            }
                        }
                    }

                    pub fn next(self: *Iter) !?Cursor(write_mode) {
                        switch (self.cursor.slot_ptr.slot.tag) {
                            .none => return null,
                            .array_list => {
                                if (self.core.index == self.core.size) return null;
                                self.core.index += 1;
                                return try self.nextInternal(0);
                            },
                            .linked_array_list, .sorted_map, .sorted_set => {
                                if (self.core.index == self.core.size) return null;
                                self.core.index += 1;
                                // b-tree nodes have a kind+num header before their slots,
                                // so child pointers are offset by BTREE_NODE_HEADER_SIZE
                                return try self.nextInternal(BTREE_NODE_HEADER_SIZE);
                            },
                            .hash_map, .hash_set, .counted_hash_map, .counted_hash_set => return try self.nextInternal(0),
                            else => return error.UnexpectedTag,
                        }
                    }

                    // read a 16-slot index block (the iterable structures all use
                    // 9-byte slots in their index/node blocks)
                    fn readSlotBlock(cursor: Cursor(write_mode), position: u64) ![SLOT_COUNT]Slot {
                        var core_reader = cursor.db.core.reader();
                        try core_reader.seekTo(position);
                        var index_block_bytes = [_]u8{0} ** INDEX_BLOCK_SIZE;
                        try core_reader.interface.readSliceAll(&index_block_bytes);
                        var index_block = [_]Slot{undefined} ** SLOT_COUNT;
                        var block_reader = std.Io.Reader.fixed(&index_block_bytes);
                        for (&index_block) |*block_slot| {
                            block_slot.* = @bitCast(try takeInt(&block_reader, SlotInt, .big));
                            try block_slot.tag.validate();
                        }
                        return index_block;
                    }

                    fn initStack(cursor: Cursor(write_mode), position: u64) !BoundedArray(Level, ITERATOR_STACK_SIZE) {
                        var stack = try BoundedArray(Level, ITERATOR_STACK_SIZE).init(0);
                        try stack.append(.{
                            .position = position,
                            .block = try readSlotBlock(cursor, position),
                            .index = 0,
                        });
                        return stack;
                    }

                    fn nextInternal(self: *Iter, comptime node_offset: u64) !?Cursor(write_mode) {
                        while (self.core.stack.slice().len > 0) {
                            const level = self.core.stack.slice()[self.core.stack.slice().len - 1];
                            if (level.index == level.block.len) {
                                _ = self.core.stack.pop();
                                if (self.core.stack.slice().len > 0) {
                                    self.core.stack.slice()[self.core.stack.slice().len - 1].index += 1;
                                }
                                continue;
                            } else {
                                const next_slot = level.block[level.index];
                                if (next_slot.tag == .index) {
                                    // node_offset skips a b-tree node's kind+num header
                                    const next_pos = next_slot.value + node_offset;
                                    try self.core.stack.append(.{
                                        .position = next_pos,
                                        .block = try readSlotBlock(self.cursor, next_pos),
                                        .index = 0,
                                    });
                                    continue;
                                } else {
                                    self.core.stack.slice()[self.core.stack.slice().len - 1].index += 1;
                                    // normally a slot that is .none should be skipped because it doesn't
                                    // have a value, but if it's set to full, then it is actually a valid
                                    // item that should be returned.
                                    if (!next_slot.empty()) {
                                        const position = level.position + (level.index * byteSizeOf(Slot));
                                        return .{
                                            .slot_ptr = .{ .position = position, .slot = next_slot },
                                            .db = self.cursor.db,
                                        };
                                    } else {
                                        continue;
                                    }
                                }
                            }
                        }
                        return null;
                    }
                };

                pub fn iterator(self: Cursor(write_mode)) !Iter {
                    return try Iter.init(self);
                }
            };
        }

        // high level API

        pub fn HashMap(comptime write_mode: WriteMode) type {
            return struct {
                cursor: Database(db_kind, HashInt).Cursor(write_mode),

                pub fn init(cursor: Database(db_kind, HashInt).Cursor(write_mode)) !HashMap(write_mode) {
                    return switch (write_mode) {
                        .read_only => switch (cursor.slot_ptr.slot.tag) {
                            .none, .hash_map, .hash_set => .{ .cursor = cursor },
                            else => error.UnexpectedTag,
                        },
                        .read_write => .{
                            .cursor = try cursor.writePath(void, &.{.{ .hash_map_init = .{ .counted = false, .set = false } }}),
                        },
                    };
                }

                pub fn readOnly(self: HashMap(.read_write)) HashMap(.read_only) {
                    return .{ .cursor = self.cursor.readOnly() };
                }

                pub fn slot(self: HashMap(write_mode)) Slot {
                    return self.cursor.slot();
                }

                pub fn iterator(self: HashMap(write_mode)) !Cursor(write_mode).Iter {
                    return try self.cursor.iterator();
                }

                pub fn getCursor(self: HashMap(write_mode), hash: HashInt) !?Cursor(.read_only) {
                    return try self.cursor.readPath(void, &.{
                        .{ .hash_map_get = .{ .value = hash } },
                    });
                }

                pub fn getSlot(self: HashMap(write_mode), hash: HashInt) !?Slot {
                    return try self.cursor.readPathSlot(void, &.{
                        .{ .hash_map_get = .{ .value = hash } },
                    });
                }

                pub fn getKeyCursor(self: HashMap(write_mode), hash: HashInt) !?Cursor(.read_only) {
                    return try self.cursor.readPath(void, &.{
                        .{ .hash_map_get = .{ .key = hash } },
                    });
                }

                pub fn getKeySlot(self: HashMap(write_mode), hash: HashInt) !?Slot {
                    return try self.cursor.readPathSlot(void, &.{
                        .{ .hash_map_get = .{ .key = hash } },
                    });
                }

                pub fn getKeyValuePair(self: HashMap(write_mode), hash: HashInt) !?KeyValuePairCursor(.read_only) {
                    var cursor = (try self.cursor.readPath(void, &.{
                        .{ .hash_map_get = .{ .kv_pair = hash } },
                    })) orelse return null;
                    return try cursor.readKeyValuePair();
                }

                pub fn put(self: HashMap(.read_write), hash: HashInt, data: WriteableData) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .value = hash } },
                        .{ .write = data },
                    });
                }

                pub fn putCursor(self: HashMap(.read_write), hash: HashInt) !Cursor(.read_write) {
                    return try self.cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .value = hash } },
                    });
                }

                pub fn putKey(self: HashMap(.read_write), hash: HashInt, data: WriteableData) !void {
                    var cursor = try self.cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .key = hash } },
                    });
                    // keys are only written if empty, because their value should always
                    // be the same at a given hash.
                    try cursor.writeIfEmpty(data);
                }

                pub fn putKeyCursor(self: HashMap(.read_write), hash: HashInt) !Cursor(.read_write) {
                    return try self.cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .key = hash } },
                    });
                }

                pub fn remove(self: HashMap(.read_write), hash: HashInt) !bool {
                    _ = self.cursor.writePath(void, &.{
                        .{ .hash_map_remove = hash },
                    }) catch |err| switch (err) {
                        error.KeyNotFound => return false,
                        else => |e| return e,
                    };
                    return true;
                }
            };
        }

        pub fn CountedHashMap(comptime write_mode: WriteMode) type {
            return struct {
                map: HashMap(write_mode),

                pub fn init(cursor: Database(db_kind, HashInt).Cursor(write_mode)) !CountedHashMap(write_mode) {
                    return switch (write_mode) {
                        .read_only => switch (cursor.slot_ptr.slot.tag) {
                            .none, .counted_hash_map, .counted_hash_set => .{ .map = .{ .cursor = cursor } },
                            else => error.UnexpectedTag,
                        },
                        .read_write => .{
                            .map = .{ .cursor = try cursor.writePath(void, &.{.{ .hash_map_init = .{ .counted = true, .set = false } }}) },
                        },
                    };
                }

                pub fn readOnly(self: CountedHashMap(.read_write)) CountedHashMap(.read_only) {
                    return .{ .map = self.map.readOnly() };
                }

                pub fn slot(self: CountedHashMap(write_mode)) Slot {
                    return self.map.cursor.slot();
                }

                pub fn count(self: CountedHashMap(write_mode)) !u64 {
                    return try self.map.cursor.count();
                }

                pub fn iterator(self: CountedHashMap(write_mode)) !Cursor(write_mode).Iter {
                    return try self.map.iterator();
                }

                pub fn getCursor(self: CountedHashMap(write_mode), hash: HashInt) !?Cursor(.read_only) {
                    return try self.map.getCursor(hash);
                }

                pub fn getSlot(self: CountedHashMap(write_mode), hash: HashInt) !?Slot {
                    return try self.map.getSlot(hash);
                }

                pub fn getKeyCursor(self: CountedHashMap(write_mode), hash: HashInt) !?Cursor(.read_only) {
                    return try self.map.getKeyCursor(hash);
                }

                pub fn getKeySlot(self: CountedHashMap(write_mode), hash: HashInt) !?Slot {
                    return try self.map.getKeySlot(hash);
                }

                pub fn getKeyValuePair(self: CountedHashMap(write_mode), hash: HashInt) !?KeyValuePairCursor(.read_only) {
                    return try self.map.getKeyValuePair(hash);
                }

                pub fn put(self: CountedHashMap(.read_write), hash: HashInt, data: WriteableData) !void {
                    try self.map.put(hash, data);
                }

                pub fn putCursor(self: CountedHashMap(.read_write), hash: HashInt) !Cursor(.read_write) {
                    return try self.map.putCursor(hash);
                }

                pub fn putKey(self: CountedHashMap(.read_write), hash: HashInt, data: WriteableData) !void {
                    try self.map.putKey(hash, data);
                }

                pub fn putKeyCursor(self: CountedHashMap(.read_write), hash: HashInt) !Cursor(.read_write) {
                    return try self.map.putKeyCursor(hash);
                }

                pub fn remove(self: CountedHashMap(.read_write), hash: HashInt) !bool {
                    return try self.map.remove(hash);
                }
            };
        }

        pub fn HashSet(comptime write_mode: WriteMode) type {
            return struct {
                cursor: Database(db_kind, HashInt).Cursor(write_mode),

                pub fn init(cursor: Database(db_kind, HashInt).Cursor(write_mode)) !HashSet(write_mode) {
                    return switch (write_mode) {
                        .read_only => switch (cursor.slot_ptr.slot.tag) {
                            .none, .hash_map, .hash_set => .{ .cursor = cursor },
                            else => error.UnexpectedTag,
                        },
                        .read_write => .{
                            .cursor = try cursor.writePath(void, &.{.{ .hash_map_init = .{ .counted = false, .set = true } }}),
                        },
                    };
                }

                pub fn readOnly(self: HashSet(.read_write)) HashSet(.read_only) {
                    return .{ .cursor = self.cursor.readOnly() };
                }

                pub fn slot(self: HashSet(write_mode)) Slot {
                    return self.cursor.slot();
                }

                pub fn iterator(self: HashSet(write_mode)) !Cursor(write_mode).Iter {
                    return try self.cursor.iterator();
                }

                pub fn getCursor(self: HashSet(write_mode), hash: HashInt) !?Cursor(.read_only) {
                    return try self.cursor.readPath(void, &.{
                        .{ .hash_map_get = .{ .key = hash } },
                    });
                }

                pub fn getSlot(self: HashSet(write_mode), hash: HashInt) !?Slot {
                    return try self.cursor.readPathSlot(void, &.{
                        .{ .hash_map_get = .{ .key = hash } },
                    });
                }

                pub fn put(self: HashSet(.read_write), hash: HashInt, data: WriteableData) !void {
                    var cursor = try self.cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .key = hash } },
                    });
                    // keys are only written if empty, because their value should always
                    // be the same at a given hash.
                    try cursor.writeIfEmpty(data);
                }

                pub fn putCursor(self: HashSet(.read_write), hash: HashInt) !Cursor(.read_write) {
                    return try self.cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .key = hash } },
                    });
                }

                pub fn remove(self: HashSet(.read_write), hash: HashInt) !bool {
                    _ = self.cursor.writePath(void, &.{
                        .{ .hash_map_remove = hash },
                    }) catch |err| switch (err) {
                        error.KeyNotFound => return false,
                        else => |e| return e,
                    };
                    return true;
                }
            };
        }

        pub fn CountedHashSet(comptime write_mode: WriteMode) type {
            return struct {
                set: HashSet(write_mode),

                pub fn init(cursor: Database(db_kind, HashInt).Cursor(write_mode)) !CountedHashSet(write_mode) {
                    return switch (write_mode) {
                        .read_only => switch (cursor.slot_ptr.slot.tag) {
                            .none, .counted_hash_map, .counted_hash_set => .{ .set = .{ .cursor = cursor } },
                            else => error.UnexpectedTag,
                        },
                        .read_write => .{
                            .set = .{ .cursor = try cursor.writePath(void, &.{.{ .hash_map_init = .{ .counted = true, .set = true } }}) },
                        },
                    };
                }

                pub fn readOnly(self: CountedHashSet(.read_write)) CountedHashSet(.read_only) {
                    return .{ .set = self.set.readOnly() };
                }

                pub fn slot(self: CountedHashSet(write_mode)) Slot {
                    return self.set.cursor.slot();
                }

                pub fn count(self: CountedHashSet(write_mode)) !u64 {
                    return try self.set.cursor.count();
                }

                pub fn iterator(self: CountedHashSet(write_mode)) !Cursor(write_mode).Iter {
                    return try self.set.iterator();
                }

                pub fn getCursor(self: CountedHashSet(write_mode), hash: HashInt) !?Cursor(.read_only) {
                    return try self.set.getCursor(hash);
                }

                pub fn getSlot(self: CountedHashSet(write_mode), hash: HashInt) !?Slot {
                    return try self.set.getSlot(hash);
                }

                pub fn put(self: CountedHashSet(.read_write), hash: HashInt, data: WriteableData) !void {
                    try self.set.put(hash, data);
                }

                pub fn putCursor(self: CountedHashSet(.read_write), hash: HashInt) !Cursor(.read_write) {
                    return try self.set.putCursor(hash);
                }

                pub fn remove(self: CountedHashSet(.read_write), hash: HashInt) !bool {
                    return try self.set.remove(hash);
                }
            };
        }

        // an ordered map keyed on arbitrary byte strings (lexicographic order),
        // backed by a count-augmented B+tree. supports key lookup, ordered iteration
        // (from a key or an index), and order-statistics (getByIndex / rank).
        pub fn SortedMap(comptime write_mode: WriteMode) type {
            return struct {
                cursor: Database(db_kind, HashInt).Cursor(write_mode),

                pub fn init(cursor: Database(db_kind, HashInt).Cursor(write_mode)) !SortedMap(write_mode) {
                    return switch (write_mode) {
                        .read_only => switch (cursor.slot_ptr.slot.tag) {
                            .none, .sorted_map, .sorted_set => .{ .cursor = cursor },
                            else => error.UnexpectedTag,
                        },
                        .read_write => .{
                            .cursor = try cursor.writePath(void, &.{.{ .sorted_map_init = .{ .set = false } }}),
                        },
                    };
                }

                pub fn readOnly(self: SortedMap(.read_write)) SortedMap(.read_only) {
                    return .{ .cursor = self.cursor.readOnly() };
                }

                pub fn slot(self: SortedMap(write_mode)) Slot {
                    return self.cursor.slot();
                }

                pub fn count(self: SortedMap(write_mode)) !u64 {
                    return try self.cursor.count();
                }

                pub fn iterator(self: SortedMap(write_mode)) !Cursor(write_mode).Iter {
                    return try self.cursor.iterator();
                }

                pub fn iteratorFrom(self: SortedMap(write_mode), start_key: []const u8) !Cursor(write_mode).Iter {
                    return try Cursor(write_mode).Iter.initSortedFromKey(self.cursor, start_key);
                }

                pub fn iteratorFromIndex(self: SortedMap(write_mode), start_index: i65) !Cursor(write_mode).Iter {
                    return try Cursor(write_mode).Iter.initSortedFromIndex(self.cursor, start_index);
                }

                pub fn getCursor(self: SortedMap(write_mode), key: []const u8) !?Cursor(.read_only) {
                    return try self.cursor.readPath(void, &.{
                        .{ .sorted_map_get = .{ .value = key } },
                    });
                }

                pub fn getSlot(self: SortedMap(write_mode), key: []const u8) !?Slot {
                    return try self.cursor.readPathSlot(void, &.{
                        .{ .sorted_map_get = .{ .value = key } },
                    });
                }

                pub fn getKeyValuePair(self: SortedMap(write_mode), key: []const u8) !?KeyValuePairCursor(.read_only) {
                    var cursor = (try self.cursor.readPath(void, &.{
                        .{ .sorted_map_get = .{ .kv_pair = key } },
                    })) orelse return null;
                    return try cursor.readKeyValuePair();
                }

                // the key/value pair at the given rank (negative counts from the end)
                pub fn getIndexKeyValuePair(self: SortedMap(write_mode), index: i65) !?KeyValuePairCursor(.read_only) {
                    var cursor = (try self.cursor.readPath(void, &.{
                        .{ .sorted_map_get_index = index },
                    })) orelse return null;
                    return try cursor.readKeyValuePair();
                }

                pub fn put(self: SortedMap(.read_write), key: []const u8, data: WriteableData) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .{ .sorted_map_get = .{ .value = key } },
                        .{ .write = data },
                    });
                }

                pub fn putCursor(self: SortedMap(.read_write), key: []const u8) !Cursor(.read_write) {
                    return try self.cursor.writePath(void, &.{
                        .{ .sorted_map_get = .{ .value = key } },
                    });
                }

                pub fn remove(self: SortedMap(.read_write), key: []const u8) !bool {
                    _ = self.cursor.writePath(void, &.{
                        .{ .sorted_map_remove = key },
                    }) catch |err| switch (err) {
                        error.KeyNotFound => return false,
                        else => |e| return e,
                    };
                    return true;
                }

                // number of keys strictly less than `key` (the inverse of getByIndex)
                pub fn rank(self: SortedMap(write_mode), key: []const u8) !u64 {
                    if (self.cursor.slot_ptr.slot.tag == .none) return 0;
                    var core_reader = self.cursor.db.core.reader();
                    try core_reader.seekTo(self.cursor.slot_ptr.slot.value);
                    const header: BTreeHeader = @bitCast(try takeInt(&core_reader.interface, BTreeHeaderInt, .big));
                    return try self.cursor.db.sortedRank(header.root_ptr, key);
                }
            };
        }

        // a sorted set of byte-string keys (a SortedMap with no values).
        pub fn SortedSet(comptime write_mode: WriteMode) type {
            return struct {
                map: SortedMap(write_mode),

                pub fn init(cursor: Database(db_kind, HashInt).Cursor(write_mode)) !SortedSet(write_mode) {
                    return switch (write_mode) {
                        .read_only => switch (cursor.slot_ptr.slot.tag) {
                            .none, .sorted_map, .sorted_set => .{ .map = .{ .cursor = cursor } },
                            else => error.UnexpectedTag,
                        },
                        .read_write => .{
                            .map = .{ .cursor = try cursor.writePath(void, &.{.{ .sorted_map_init = .{ .set = true } }}) },
                        },
                    };
                }

                pub fn readOnly(self: SortedSet(.read_write)) SortedSet(.read_only) {
                    return .{ .map = self.map.readOnly() };
                }

                pub fn slot(self: SortedSet(write_mode)) Slot {
                    return self.map.cursor.slot();
                }

                pub fn count(self: SortedSet(write_mode)) !u64 {
                    return try self.map.cursor.count();
                }

                pub fn iterator(self: SortedSet(write_mode)) !Cursor(write_mode).Iter {
                    return try self.map.iterator();
                }

                pub fn iteratorFrom(self: SortedSet(write_mode), start_key: []const u8) !Cursor(write_mode).Iter {
                    return try self.map.iteratorFrom(start_key);
                }

                pub fn iteratorFromIndex(self: SortedSet(write_mode), start_index: i65) !Cursor(write_mode).Iter {
                    return try self.map.iteratorFromIndex(start_index);
                }

                pub fn put(self: SortedSet(.read_write), key: []const u8) !void {
                    _ = try self.map.cursor.writePath(void, &.{
                        .{ .sorted_map_get = .{ .key = key } },
                    });
                }

                pub fn contains(self: SortedSet(write_mode), key: []const u8) !bool {
                    const cursor = try self.map.cursor.readPath(void, &.{
                        .{ .sorted_map_get = .{ .key = key } },
                    });
                    return cursor != null;
                }

                pub fn getIndexKeyValuePair(self: SortedSet(write_mode), index: i65) !?KeyValuePairCursor(.read_only) {
                    return try self.map.getIndexKeyValuePair(index);
                }

                pub fn remove(self: SortedSet(.read_write), key: []const u8) !bool {
                    return try self.map.remove(key);
                }

                pub fn rank(self: SortedSet(write_mode), key: []const u8) !u64 {
                    return try self.map.rank(key);
                }
            };
        }

        pub fn ArrayList(comptime write_mode: WriteMode) type {
            return struct {
                cursor: Database(db_kind, HashInt).Cursor(write_mode),

                pub fn init(cursor: Database(db_kind, HashInt).Cursor(write_mode)) !ArrayList(write_mode) {
                    return switch (write_mode) {
                        .read_only => switch (cursor.slot_ptr.slot.tag) {
                            .none, .array_list => .{ .cursor = cursor },
                            else => error.UnexpectedTag,
                        },
                        .read_write => .{
                            .cursor = try cursor.writePath(void, &.{.array_list_init}),
                        },
                    };
                }

                pub fn readOnly(self: ArrayList(.read_write)) ArrayList(.read_only) {
                    return .{ .cursor = self.cursor.readOnly() };
                }

                pub fn slot(self: ArrayList(write_mode)) Slot {
                    return self.cursor.slot();
                }

                pub fn count(self: ArrayList(write_mode)) !u64 {
                    return try self.cursor.count();
                }

                pub fn iterator(self: ArrayList(write_mode)) !Cursor(write_mode).Iter {
                    return try self.cursor.iterator();
                }

                pub fn iteratorFrom(self: ArrayList(write_mode), index: i65) !Cursor(write_mode).Iter {
                    return try Cursor(write_mode).Iter.initArrayListFromIndex(self.cursor, index);
                }

                pub fn getCursor(self: ArrayList(write_mode), index: i65) !?Cursor(.read_only) {
                    return try self.cursor.readPath(void, &.{
                        .{ .array_list_get = index },
                    });
                }

                pub fn getSlot(self: ArrayList(write_mode), index: i65) !?Slot {
                    return try self.cursor.readPathSlot(void, &.{
                        .{ .array_list_get = index },
                    });
                }

                pub fn put(self: ArrayList(.read_write), index: i65, data: WriteableData) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .{ .array_list_get = index },
                        .{ .write = data },
                    });
                }

                pub fn putCursor(self: ArrayList(.read_write), index: i65) !Cursor(.read_write) {
                    return try self.cursor.writePath(void, &.{
                        .{ .array_list_get = index },
                    });
                }

                pub fn append(self: ArrayList(.read_write), data: WriteableData) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .array_list_append,
                        .{ .write = data },
                    });
                }

                pub fn appendCursor(self: ArrayList(.read_write)) !Cursor(.read_write) {
                    return try self.cursor.writePath(void, &.{
                        .array_list_append,
                    });
                }

                pub fn appendContext(self: ArrayList(.read_write), data: WriteableData, ctx: anytype) !void {
                    const Ctx = @TypeOf(ctx);
                    _ = try self.cursor.writePath(Ctx, &.{
                        .array_list_append,
                        .{ .write = data },
                        .{ .ctx = ctx },
                    });
                }

                pub fn slice(self: ArrayList(.read_write), size: u64) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .{ .array_list_slice = .{ .size = size } },
                    });
                }
            };
        }

        pub fn LinkedArrayList(comptime write_mode: WriteMode) type {
            return struct {
                cursor: Database(db_kind, HashInt).Cursor(write_mode),

                pub fn init(cursor: Database(db_kind, HashInt).Cursor(write_mode)) !LinkedArrayList(write_mode) {
                    return switch (write_mode) {
                        .read_only => switch (cursor.slot_ptr.slot.tag) {
                            .none, .linked_array_list => .{ .cursor = cursor },
                            else => error.UnexpectedTag,
                        },
                        .read_write => .{
                            .cursor = try cursor.writePath(void, &.{.linked_array_list_init}),
                        },
                    };
                }

                pub fn readOnly(self: LinkedArrayList(.read_write)) LinkedArrayList(.read_only) {
                    return .{ .cursor = self.cursor.readOnly() };
                }

                pub fn slot(self: LinkedArrayList(write_mode)) Slot {
                    return self.cursor.slot();
                }

                pub fn count(self: LinkedArrayList(write_mode)) !u64 {
                    return try self.cursor.count();
                }

                pub fn iterator(self: LinkedArrayList(write_mode)) !Cursor(write_mode).Iter {
                    return try self.cursor.iterator();
                }

                pub fn iteratorFrom(self: LinkedArrayList(write_mode), index: i65) !Cursor(write_mode).Iter {
                    return try Cursor(write_mode).Iter.initLinkedArrayListFromIndex(self.cursor, index);
                }

                pub fn getCursor(self: LinkedArrayList(write_mode), index: i65) !?Cursor(.read_only) {
                    return try self.cursor.readPath(void, &.{
                        .{ .linked_array_list_get = index },
                    });
                }

                pub fn getSlot(self: LinkedArrayList(write_mode), index: i65) !?Slot {
                    return try self.cursor.readPathSlot(void, &.{
                        .{ .linked_array_list_get = index },
                    });
                }

                pub fn put(self: LinkedArrayList(.read_write), index: i65, data: WriteableData) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .{ .linked_array_list_get = index },
                        .{ .write = data },
                    });
                }

                pub fn putCursor(self: LinkedArrayList(.read_write), index: i65) !Cursor(.read_write) {
                    return try self.cursor.writePath(void, &.{
                        .{ .linked_array_list_get = index },
                    });
                }

                pub fn append(self: LinkedArrayList(.read_write), data: WriteableData) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .linked_array_list_append,
                        .{ .write = data },
                    });
                }

                pub fn appendCursor(self: LinkedArrayList(.read_write)) !Cursor(.read_write) {
                    return try self.cursor.writePath(void, &.{
                        .linked_array_list_append,
                    });
                }

                pub fn slice(self: LinkedArrayList(.read_write), offset: u64, size: u64) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .{ .linked_array_list_slice = .{ .offset = offset, .size = size } },
                    });
                }

                pub fn concat(self: LinkedArrayList(.read_write), list: Slot) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .{ .linked_array_list_concat = .{ .list = list } },
                    });
                }

                pub fn insert(self: LinkedArrayList(.read_write), index: i65, data: WriteableData) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .{ .linked_array_list_insert = index },
                        .{ .write = data },
                    });
                }

                pub fn insertCursor(self: LinkedArrayList(.read_write), index: i65) !Cursor(.read_write) {
                    return try self.cursor.writePath(void, &.{
                        .{ .linked_array_list_insert = index },
                    });
                }

                pub fn remove(self: LinkedArrayList(.read_write), index: i65) !void {
                    _ = try self.cursor.writePath(void, &.{
                        .{ .linked_array_list_remove = index },
                    });
                }
            };
        }

        // compaction helpers

        fn remapSlot(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), slot: Slot) anyerror!Slot {
            switch (slot.tag) {
                .none, .uint, .int, .float, .short_bytes => return slot,
                .bytes => {
                    if (offset_map.get(slot.value)) |mapped| {
                        return .{ .value = mapped, .tag = slot.tag, .full = slot.full };
                    }
                    const new_offset = try remapBytes(source_core, target_db_kind, target_core, slot);
                    try offset_map.put(slot.value, new_offset);
                    return .{ .value = new_offset, .tag = slot.tag, .full = slot.full };
                },
                .index => {
                    if (offset_map.get(slot.value)) |mapped| {
                        return .{ .value = mapped, .tag = slot.tag, .full = slot.full };
                    }
                    const new_offset = try remapIndex(source_core, target_db_kind, target_core, offset_map, slot);
                    try offset_map.put(slot.value, new_offset);
                    return .{ .value = new_offset, .tag = slot.tag, .full = slot.full };
                },
                .array_list => {
                    if (offset_map.get(slot.value)) |mapped| {
                        return .{ .value = mapped, .tag = slot.tag, .full = slot.full };
                    }
                    const new_offset = try remapArrayList(source_core, target_db_kind, target_core, offset_map, slot);
                    try offset_map.put(slot.value, new_offset);
                    return .{ .value = new_offset, .tag = slot.tag, .full = slot.full };
                },
                .linked_array_list => {
                    if (offset_map.get(slot.value)) |mapped| {
                        return .{ .value = mapped, .tag = slot.tag, .full = slot.full };
                    }
                    const new_offset = try remapBTree(source_core, target_db_kind, target_core, offset_map, slot);
                    try offset_map.put(slot.value, new_offset);
                    return .{ .value = new_offset, .tag = slot.tag, .full = slot.full };
                },
                .hash_map, .hash_set => {
                    if (offset_map.get(slot.value)) |mapped| {
                        return .{ .value = mapped, .tag = slot.tag, .full = slot.full };
                    }
                    const new_offset = try remapHashMapOrSet(source_core, target_db_kind, target_core, offset_map, slot, false);
                    try offset_map.put(slot.value, new_offset);
                    return .{ .value = new_offset, .tag = slot.tag, .full = slot.full };
                },
                .counted_hash_map, .counted_hash_set => {
                    if (offset_map.get(slot.value)) |mapped| {
                        return .{ .value = mapped, .tag = slot.tag, .full = slot.full };
                    }
                    const new_offset = try remapHashMapOrSet(source_core, target_db_kind, target_core, offset_map, slot, true);
                    try offset_map.put(slot.value, new_offset);
                    return .{ .value = new_offset, .tag = slot.tag, .full = slot.full };
                },
                .kv_pair => {
                    if (offset_map.get(slot.value)) |mapped| {
                        return .{ .value = mapped, .tag = slot.tag, .full = slot.full };
                    }
                    const new_offset = try remapKvPair(source_core, target_db_kind, target_core, offset_map, slot);
                    try offset_map.put(slot.value, new_offset);
                    return .{ .value = new_offset, .tag = slot.tag, .full = slot.full };
                },
                .sorted_map, .sorted_set => {
                    if (offset_map.get(slot.value)) |mapped| {
                        return .{ .value = mapped, .tag = slot.tag, .full = slot.full };
                    }
                    const new_offset = try remapSortedMap(source_core, target_db_kind, target_core, offset_map, slot);
                    try offset_map.put(slot.value, new_offset);
                    return .{ .value = new_offset, .tag = slot.tag, .full = slot.full };
                },
            }
        }

        fn remapBytes(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), slot: Slot) !u64 {
            var reader = source_core.reader();
            var writer = target_core.writer();

            try reader.seekTo(slot.value);
            const length = try takeInt(&reader.interface, u64, .big);

            // total size: u64 length + bytes + optional 2-byte format_tag
            const format_tag_size: u64 = if (slot.full) 2 else 0;
            const total_payload = length + format_tag_size;

            const new_offset = try target_core.length();
            try writer.seekTo(new_offset);
            try writer.interface.writeInt(u64, length, .big);

            // copy bytes in chunks
            var remaining = total_payload;
            var buf: [4096]u8 = undefined;
            while (remaining > 0) {
                const chunk = @min(remaining, buf.len);
                try reader.interface.readSliceAll(buf[0..chunk]);
                try writer.interface.writeAll(buf[0..chunk]);
                remaining -= chunk;
            }

            return new_offset;
        }

        fn remapIndex(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), slot: Slot) !u64 {
            var reader = source_core.reader();
            var writer = target_core.writer();

            // read 144-byte block (16 slots)
            try reader.seekTo(slot.value);
            var block_bytes = [_]u8{0} ** INDEX_BLOCK_SIZE;
            try reader.interface.readSliceAll(&block_bytes);

            // remap each slot
            var block_reader = std.Io.Reader.fixed(&block_bytes);
            var remapped_slots: [SLOT_COUNT]Slot = undefined;
            for (&remapped_slots) |*s| {
                const child_slot: Slot = @bitCast(try takeInt(&block_reader, SlotInt, .big));
                s.* = try remapSlot(source_core, target_db_kind, target_core, offset_map, child_slot);
            }

            // write remapped block to target
            const new_offset = try target_core.length();
            try writer.seekTo(new_offset);
            for (remapped_slots) |s| {
                try writer.interface.writeInt(SlotInt, @bitCast(s), .big);
            }

            return new_offset;
        }

        fn remapArrayList(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), slot: Slot) !u64 {
            var reader = source_core.reader();
            var writer = target_core.writer();

            // read ArrayListHeader (16 bytes)
            try reader.seekTo(slot.value);
            const header: ArrayListHeader = @bitCast(try takeInt(&reader.interface, ArrayListHeaderInt, .big));

            // remap root index block pointer via remapSlot as an .index slot
            const index_slot = Slot{ .value = header.ptr, .tag = .index };
            const remapped_index = try remapSlot(source_core, target_db_kind, target_core, offset_map, index_slot);

            // write new ArrayListHeader with remapped ptr
            const new_offset = try target_core.length();
            try writer.seekTo(new_offset);
            try writer.interface.writeInt(ArrayListHeaderInt, @bitCast(ArrayListHeader{
                .ptr = remapped_index.value,
                .size = header.size,
            }), .big);

            return new_offset;
        }

        fn remapBTree(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), slot: Slot) !u64 {
            var reader = source_core.reader();
            var writer = target_core.writer();

            try reader.seekTo(slot.value);
            const header: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));

            const remapped_root = try remapBTreeNode(source_core, target_db_kind, target_core, offset_map, header.root_ptr);

            const new_offset = try target_core.length();
            try writer.seekTo(new_offset);
            try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{
                .root_ptr = remapped_root,
                .size = header.size,
            }), .big);

            return new_offset;
        }

        fn remapBTreeNode(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), node_offset: u64) anyerror!u64 {
            // dedup check (subtrees are shared by pointer)
            if (offset_map.get(node_offset)) |mapped| {
                return mapped;
            }

            var reader = source_core.reader();
            var writer = target_core.writer();

            // read the whole node into memory first, so the recursion below can
            // freely create its own readers/writers
            try reader.seekTo(node_offset);
            const kind_int = try takeInt(&reader.interface, u8, .big);
            const kind = std.enums.fromInt(BTreeNodeKind, kind_int) orelse return error.InvalidBTreeNodeKind;
            const num = try takeInt(&reader.interface, u8, .big);

            switch (kind) {
                .leaf => {
                    var body = [_]u8{0} ** (BTREE_LEAF_BLOCK_SIZE - BTREE_NODE_HEADER_SIZE);
                    try reader.interface.readSliceAll(&body);
                    var body_reader = std.Io.Reader.fixed(&body);

                    var slots: [BTREE_SLOT_COUNT]Slot = undefined;
                    for (&slots) |*s| {
                        const value_slot: Slot = @bitCast(try takeInt(&body_reader, SlotInt, .big));
                        s.* = try remapSlot(source_core, target_db_kind, target_core, offset_map, value_slot);
                    }

                    const new_offset = try target_core.length();
                    try writer.seekTo(new_offset);
                    try writer.interface.writeInt(u8, kind_int, .big);
                    try writer.interface.writeInt(u8, num, .big);
                    for (slots) |s| try writer.interface.writeInt(SlotInt, @bitCast(s), .big);

                    try offset_map.put(node_offset, new_offset);
                    return new_offset;
                },
                .branch => {
                    var body = [_]u8{0} ** (BTREE_BRANCH_BLOCK_SIZE - BTREE_NODE_HEADER_SIZE);
                    try reader.interface.readSliceAll(&body);
                    var body_reader = std.Io.Reader.fixed(&body);

                    var children: [BTREE_SLOT_COUNT]Slot = undefined;
                    for (&children) |*s| {
                        const child: Slot = @bitCast(try takeInt(&body_reader, SlotInt, .big));
                        if (child.tag == .index) {
                            const remapped_ptr = try remapBTreeNode(source_core, target_db_kind, target_core, offset_map, child.value);
                            s.* = .{ .value = remapped_ptr, .tag = .index, .full = child.full };
                        } else {
                            s.* = child;
                        }
                    }
                    var counts: [BTREE_SLOT_COUNT]u64 = undefined;
                    for (&counts) |*c| c.* = try takeInt(&body_reader, u64, .big);

                    const new_offset = try target_core.length();
                    try writer.seekTo(new_offset);
                    try writer.interface.writeInt(u8, kind_int, .big);
                    try writer.interface.writeInt(u8, num, .big);
                    for (children) |s| try writer.interface.writeInt(SlotInt, @bitCast(s), .big);
                    for (counts) |c| try writer.interface.writeInt(u64, c, .big);

                    try offset_map.put(node_offset, new_offset);
                    return new_offset;
                },
            }
        }

        fn remapHashMapOrSet(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), slot: Slot, counted: bool) !u64 {
            var reader = source_core.reader();
            var writer = target_core.writer();

            try reader.seekTo(slot.value);

            const count_value: ?u64 = if (counted) try takeInt(&reader.interface, u64, .big) else null;

            // read 144-byte root index block
            var block_bytes = [_]u8{0} ** INDEX_BLOCK_SIZE;
            try reader.interface.readSliceAll(&block_bytes);

            // remap each child slot in the block
            var block_reader = std.Io.Reader.fixed(&block_bytes);
            var remapped_slots: [SLOT_COUNT]Slot = undefined;
            for (&remapped_slots) |*s| {
                const child_slot: Slot = @bitCast(try takeInt(&block_reader, SlotInt, .big));
                s.* = try remapSlot(source_core, target_db_kind, target_core, offset_map, child_slot);
            }

            // write [optional count][remapped block] contiguously to target
            const new_offset = try target_core.length();
            try writer.seekTo(new_offset);
            if (count_value) |c| {
                try writer.interface.writeInt(u64, c, .big);
            }
            for (remapped_slots) |s| {
                try writer.interface.writeInt(SlotInt, @bitCast(s), .big);
            }

            return new_offset;
        }

        fn remapKvPair(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), slot: Slot) !u64 {
            var reader = source_core.reader();
            var writer = target_core.writer();

            // read KeyValuePair
            try reader.seekTo(slot.value);
            const kv_pair: KeyValuePair = @bitCast(try takeInt(&reader.interface, KeyValuePairInt, .big));

            // remap key_slot and value_slot
            const remapped_key = try remapSlot(source_core, target_db_kind, target_core, offset_map, kv_pair.key_slot);
            const remapped_value = try remapSlot(source_core, target_db_kind, target_core, offset_map, kv_pair.value_slot);

            // write remapped KV pair (hash stays unchanged)
            const new_offset = try target_core.length();
            try writer.seekTo(new_offset);
            try writer.interface.writeInt(KeyValuePairInt, @bitCast(KeyValuePair{
                .value_slot = remapped_value,
                .key_slot = remapped_key,
                .hash = kv_pair.hash,
            }), .big);

            return new_offset;
        }

        fn remapSortedMap(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), slot: Slot) !u64 {
            var reader = source_core.reader();
            var writer = target_core.writer();

            try reader.seekTo(slot.value);
            const header: BTreeHeader = @bitCast(try takeInt(&reader.interface, BTreeHeaderInt, .big));

            const remapped_root = try remapSortedMapNode(source_core, target_db_kind, target_core, offset_map, header.root_ptr);

            const new_offset = try target_core.length();
            try writer.seekTo(new_offset);
            try writer.interface.writeInt(BTreeHeaderInt, @bitCast(BTreeHeader{
                .root_ptr = remapped_root,
                .size = header.size,
            }), .big);

            return new_offset;
        }

        fn remapSortedMapNode(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), node_offset: u64) anyerror!u64 {
            if (offset_map.get(node_offset)) |mapped| {
                return mapped;
            }

            var reader = source_core.reader();
            var writer = target_core.writer();

            try reader.seekTo(node_offset);
            const kind_int = try takeInt(&reader.interface, u8, .big);
            const kind = std.enums.fromInt(SortedNodeKind, kind_int) orelse return error.InvalidBTreeNodeKind;
            const num = try takeInt(&reader.interface, u8, .big);

            switch (kind) {
                .leaf => {
                    var body = [_]u8{0} ** (SORTED_LEAF_BLOCK_SIZE - BTREE_NODE_HEADER_SIZE);
                    try reader.interface.readSliceAll(&body);
                    var body_reader = std.Io.Reader.fixed(&body);

                    var entries: [BTREE_SLOT_COUNT]Slot = undefined;
                    for (&entries) |*s| {
                        const entry: Slot = @bitCast(try takeInt(&body_reader, SlotInt, .big));
                        s.* = try remapSlot(source_core, target_db_kind, target_core, offset_map, entry);
                    }

                    const new_offset = try target_core.length();
                    try writer.seekTo(new_offset);
                    try writer.interface.writeInt(u8, kind_int, .big);
                    try writer.interface.writeInt(u8, num, .big);
                    for (entries) |s| try writer.interface.writeInt(SlotInt, @bitCast(s), .big);

                    try offset_map.put(node_offset, new_offset);
                    return new_offset;
                },
                .branch => {
                    var body = [_]u8{0} ** (SORTED_BRANCH_BLOCK_SIZE - BTREE_NODE_HEADER_SIZE);
                    try reader.interface.readSliceAll(&body);
                    var body_reader = std.Io.Reader.fixed(&body);

                    var children: [BTREE_SLOT_COUNT]Slot = undefined;
                    for (&children) |*s| {
                        const child: Slot = @bitCast(try takeInt(&body_reader, SlotInt, .big));
                        if (child.tag == .index) {
                            const remapped_ptr = try remapSortedMapNode(source_core, target_db_kind, target_core, offset_map, child.value);
                            s.* = .{ .value = remapped_ptr, .tag = .index, .full = child.full };
                        } else {
                            s.* = child;
                        }
                    }
                    var separators: [BTREE_SLOT_COUNT]Slot = undefined;
                    for (&separators) |*s| {
                        const sep: Slot = @bitCast(try takeInt(&body_reader, SlotInt, .big));
                        s.* = try remapSlot(source_core, target_db_kind, target_core, offset_map, sep);
                    }
                    var counts: [BTREE_SLOT_COUNT]u64 = undefined;
                    for (&counts) |*c| c.* = try takeInt(&body_reader, u64, .big);

                    const new_offset = try target_core.length();
                    try writer.seekTo(new_offset);
                    try writer.interface.writeInt(u8, kind_int, .big);
                    try writer.interface.writeInt(u8, num, .big);
                    for (children) |s| try writer.interface.writeInt(SlotInt, @bitCast(s), .big);
                    for (separators) |s| try writer.interface.writeInt(SlotInt, @bitCast(s), .big);
                    for (counts) |c| try writer.interface.writeInt(u64, c, .big);

                    try offset_map.put(node_offset, new_offset);
                    return new_offset;
                },
            }
        }
    };
}

const CoreMemory = struct {
    buffer: *std.Io.Writer.Allocating,
    max_size: ?u64,

    pub const Reader = struct {
        parent: *CoreMemory,
        interface: std.Io.Reader,
        pos: u64 = 0,

        pub fn seekTo(self: *Reader, offset: u64) !void {
            self.pos = offset;
        }

        fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));

            if (r.parent.buffer.written().len == r.pos) return error.EndOfStream;

            const max_size = @min(@intFromEnum(limit), r.parent.buffer.written().len - r.pos);
            if (max_size == 0) return 0;

            const size = try io_w.write(r.parent.buffer.written()[r.pos..(r.pos + max_size)]);
            r.pos += size;
            return size;
        }
    };

    const Writer = struct {
        parent: *CoreMemory,
        interface: std.Io.Writer,
        pos: u64 = 0,

        fn resizeBuffer(self: Writer, new_size: u64) !void {
            if (new_size > self.parent.buffer.written().len) {
                if (self.parent.max_size) |max_size| {
                    if (new_size > max_size) {
                        return error.MaxSizeExceeded;
                    }
                }
                var arr = self.parent.buffer.toArrayList();
                try arr.ensureTotalCapacityPrecise(self.parent.buffer.allocator, new_size);
                arr.items.len = new_size;
                self.parent.buffer.* = std.Io.Writer.Allocating.fromArrayList(self.parent.buffer.allocator, &arr);
            }
        }

        pub fn seekTo(self: *Writer, offset: u64) !void {
            self.pos = offset;
        }

        pub fn logicalPos(self: Writer) u64 {
            return self.pos;
        }

        fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));

            if (splat != 1) unreachable; // splat isn't supported
            if (io_w.buffered().len > 0) unreachable; // buffering isn't supported

            for (data) |buf| {
                const n = buf.len;
                if (n == 0) continue;
                const new_position = w.pos + @as(u64, @intCast(n));
                w.resizeBuffer(new_position) catch return error.WriteFailed;
                @memcpy(w.parent.buffer.written()[w.pos..new_position], buf);
                w.pos = new_position;
                return io_w.consume(n);
            }

            return error.WriteFailed;
        }
    };

    pub fn reader(self: *CoreMemory) Reader {
        return .{
            .parent = self,
            .interface = .{
                .vtable = &.{ .stream = Reader.stream },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn writer(self: *CoreMemory) Writer {
        return .{
            .parent = self,
            .interface = .{
                .vtable = &.{ .drain = Writer.drain },
                .buffer = &.{},
            },
        };
    }

    pub fn length(self: *const CoreMemory) !u64 {
        return self.buffer.written().len;
    }

    pub fn setLength(self: *CoreMemory, len: u64) !void {
        var arr = self.buffer.toArrayList();
        arr.shrinkAndFree(self.buffer.allocator, len);
        self.buffer.* = std.Io.Writer.Allocating.fromArrayList(self.buffer.allocator, &arr);
    }

    pub fn sync(_: *const CoreMemory) !void {}

    pub fn flush(_: *CoreMemory) !void {}
};

const CoreFile = struct {
    io: std.Io,
    file: std.Io.File,

    pub const Reader = std.Io.File.Reader;
    pub const Writer = std.Io.File.Writer;

    pub fn reader(self: *const CoreFile) Reader {
        return self.file.reader(self.io, &.{});
    }

    pub fn writer(self: *const CoreFile) Writer {
        return self.file.writer(self.io, &.{});
    }

    pub fn length(self: *const CoreFile) !u64 {
        return try self.file.length(self.io);
    }

    pub fn setLength(self: *const CoreFile, len: u64) !void {
        self.file.setLength(self.io, len) catch |err| switch (err) {
            // the file is open in read-only mode.
            // on windows, it will return AccessDenied.
            // otherwise it will return NonResizable.
            error.AccessDenied, error.NonResizable => return,
            else => |e| return e,
        };
    }

    pub fn sync(self: *const CoreFile) !void {
        try self.file.sync(self.io);
    }

    pub fn flush(_: *const CoreFile) !void {}
};

const CoreBufferedFile = struct {
    memory: CoreMemory,
    memory_max_size: u64,
    memory_pos: u64 = 0,
    file: CoreFile,

    pub const Reader = struct {
        parent: *CoreBufferedFile,
        interface: std.Io.Reader,
        pos: u64 = 0,

        pub fn seekTo(self: *Reader, offset: u64) !void {
            self.pos = offset;
        }

        fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));

            const dest = limit.slice(try io_w.writableSliceGreedy(1));

            // read from the in-memory buffer
            if (r.pos >= r.parent.memory_pos and r.pos < r.parent.memory_pos + r.parent.memory.buffer.written().len) {
                const mem_pos = r.pos - r.parent.memory_pos;
                const size = @min(dest.len, r.parent.memory.buffer.written()[mem_pos..].len);
                @memcpy(dest[0..size], r.parent.memory.buffer.written()[mem_pos..][0..size]);
                r.pos += size;
                io_w.advance(size);
                return size;
            }
            // read from the disk
            else {
                var file_reader = r.parent.file.reader();
                file_reader.seekTo(r.pos) catch return error.ReadFailed;
                const max_size = if (r.pos < r.parent.memory_pos) @min(dest.len, r.parent.memory_pos - r.pos) else dest.len;
                const size = file_reader.interface.readSliceShort(dest[0..max_size]) catch return error.ReadFailed;
                r.pos += size;
                io_w.advance(size);
                return size;
            }
        }
    };

    pub const Writer = struct {
        parent: *CoreBufferedFile,
        interface: std.Io.Writer,
        pos: u64 = 0,

        pub fn seekTo(self: *Writer, offset: u64) !void {
            // flush if we are going past the end of the in-memory buffer
            if (offset > self.parent.memory_pos + self.parent.memory.buffer.written().len) {
                try self.parent.flush();
            }

            self.pos = offset;

            // if the buffer is empty, set its position to this offset as well
            if (self.parent.memory.buffer.written().len == 0) {
                self.parent.memory_pos = offset;
            }
        }

        fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));

            if (splat != 1) unreachable; // splat isn't supported
            if (io_w.buffered().len > 0) unreachable; // buffering isn't supported

            for (data) |buf| {
                const n = buf.len;
                if (n == 0) continue;

                if (w.parent.memory.buffer.written().len + n > w.parent.memory_max_size) {
                    w.parent.flush() catch return error.WriteFailed;
                }

                // write to the in-memory buffer
                if (w.pos >= w.parent.memory_pos and w.pos <= w.parent.memory_pos + w.parent.memory.buffer.written().len) {
                    var memory_writer = w.parent.memory.writer();
                    memory_writer.seekTo(w.pos - w.parent.memory_pos) catch return error.WriteFailed;
                    memory_writer.interface.writeAll(buf) catch return error.WriteFailed;
                }
                // write to the disk
                else {
                    // a direct disk write that overlaps the buffered region would be
                    // clobbered by a later flush of stale buffer bytes, so flush first
                    if (w.pos < w.parent.memory_pos + w.parent.memory.buffer.written().len and w.pos + n > w.parent.memory_pos) {
                        w.parent.flush() catch return error.WriteFailed;
                    }
                    var file_writer = w.parent.file.writer();
                    file_writer.seekTo(w.pos) catch return error.WriteFailed;
                    file_writer.interface.writeAll(buf) catch return error.WriteFailed;
                }

                w.pos += n;
                return io_w.consume(n);
            }

            return error.WriteFailed;
        }
    };

    pub fn reader(self: *CoreBufferedFile) Reader {
        return .{
            .parent = self,
            .interface = .{
                .vtable = &.{ .stream = Reader.stream },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn writer(self: *CoreBufferedFile) Writer {
        return .{
            .parent = self,
            .interface = .{
                .vtable = &.{ .drain = Writer.drain },
                .buffer = &.{},
            },
        };
    }

    pub fn length(self: *const CoreBufferedFile) !u64 {
        return @max(self.memory_pos + self.memory.buffer.written().len, try self.file.length());
    }

    pub fn setLength(self: *CoreBufferedFile, len: u64) !void {
        try self.flush();
        try self.file.setLength(len);
    }

    pub fn sync(self: *CoreBufferedFile) !void {
        try self.flush();
        try self.file.sync();
    }

    pub fn flush(self: *CoreBufferedFile) !void {
        if (self.memory.buffer.written().len > 0) {
            var file_writer = self.file.writer();
            try file_writer.seekTo(self.memory_pos);
            try file_writer.interface.writeAll(self.memory.buffer.written());

            self.memory_pos = 0;
            self.memory.buffer.clearRetainingCapacity();
        }
    }
};

fn byteSizeOf(T: type) u16 {
    return @bitSizeOf(T) / 8;
}

fn takeInt(reader: *std.Io.Reader, comptime T: type, endian: std.builtin.Endian) !T {
    var buffer: [byteSizeOf(T)]u8 = undefined;
    try reader.readSliceAll(&buffer);
    return std.mem.readInt(T, &buffer, endian);
}

fn BoundedArray(comptime T: type, comptime buffer_capacity: usize) type {
    const alignment: std.mem.Alignment = .of(T);
    return struct {
        const Self = @This();
        buffer: [buffer_capacity]T align(alignment.toByteUnits()) = undefined,
        len: usize = 0,

        pub fn init(len: usize) error{Overflow}!Self {
            if (len > buffer_capacity) return error.Overflow;
            return Self{ .len = len };
        }

        pub fn slice(self: anytype) switch (@TypeOf(&self.buffer)) {
            *align(alignment.toByteUnits()) [buffer_capacity]T => []align(alignment.toByteUnits()) T,
            *align(alignment.toByteUnits()) const [buffer_capacity]T => []align(alignment.toByteUnits()) const T,
            else => unreachable,
        } {
            return self.buffer[0..self.len];
        }

        pub fn constSlice(self: *const Self) []align(alignment.toByteUnits()) const T {
            return self.slice();
        }

        pub fn get(self: Self, i: usize) T {
            return self.constSlice()[i];
        }

        pub fn set(self: *Self, i: usize, item: T) void {
            self.slice()[i] = item;
        }

        pub fn ensureUnusedCapacity(self: Self, additional_count: usize) error{Overflow}!void {
            if (self.len + additional_count > buffer_capacity) {
                return error.Overflow;
            }
        }

        pub fn addOne(self: *Self) error{Overflow}!*T {
            try self.ensureUnusedCapacity(1);
            return self.addOneAssumeCapacity();
        }

        pub fn addOneAssumeCapacity(self: *Self) *T {
            std.debug.assert(self.len < buffer_capacity);
            self.len += 1;
            return &self.slice()[self.len - 1];
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.get(self.len - 1);
            self.len -= 1;
            return item;
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            const new_item_ptr = try self.addOne();
            new_item_ptr.* = item;
        }
    };
}
