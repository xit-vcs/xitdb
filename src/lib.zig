//! you're looking at radar's hopeless attempt to implement
//! his dream database. it will be embedded and immutable.
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
    // 2. if `index`, it means that it has no more space
    //    for children. this is only relevant for the linked
    //    array list, whose index slots must be marked as
    //    full to prevent gaps from being used.
    // 3. if `bytes` or `short_bytes`, it means the byte
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

    pub fn validate(self: Tag) !void {
        _ = try std.meta.intToEnum(Tag, @intFromEnum(self));
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
    hash_id: HashId = .{ .id = 0 },
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
    hash_id: HashId = .{ .id = 0 },
};

pub const InitOptsFile = struct {
    file: std.fs.File,
    hash_id: HashId = .{ .id = 0 },
};

pub const InitOptsBufferedFile = struct {
    file: std.fs.File,
    buffer: *std.Io.Writer.Allocating,
    max_size: u64 = 2 * 1024 * 1024, // flushes when the memory is >= this size
    hash_id: HashId = .{ .id = 0 },
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
        const LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE = byteSizeOf(LinkedArrayListSlot) * SLOT_COUNT;
        const MAX_BRANCH_LENGTH: usize = 16;

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

        const LinkedArrayListHeaderInt = u136;
        const LinkedArrayListHeader = packed struct {
            shift: u6,
            padding: u2 = 0,
            ptr: u64,
            size: u64,
        };

        const KeyValuePairInt = @typeInfo(KeyValuePair).@"struct".backing_integer.?;
        const KeyValuePair = packed struct {
            value_slot: Slot,
            key_slot: Slot,
            hash: HashInt,
        };

        const LinkedArrayListSlotInt = u136;
        const LinkedArrayListSlot = packed struct {
            size: u64,
            slot: Slot,
        };

        const LinkedArrayListSlotPointer = struct {
            slot_ptr: SlotPointer,
            leaf_count: u64,
        };

        const LinkedArrayListBlockInfo = struct {
            block: [SLOT_COUNT]LinkedArrayListSlot,
            i: u4,
            parent_slot: LinkedArrayListSlot,
        };

        const HashMapSlotKind = enum {
            kv_pair,
            key,
            value,
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
                            .file = opts.file,
                        },
                    },
                    .header = undefined,
                    .tx_start = null,
                },
            };

            if (try self.core.length() == 0) {
                self.header = .{
                    .hash_id = opts.hash_id,
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
            var target = try Database(target_db_kind, HashInt).init(target_opts);

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

                    switch (slot_ptr.slot.tag) {
                        .none => {
                            // if slot was empty, insert the new list
                            var writer = self.core.writer();
                            const array_list_start = try self.core.length();
                            const array_list_ptr = array_list_start + byteSizeOf(LinkedArrayListHeader);
                            try writer.seekTo(array_list_start);
                            try writer.interface.writeInt(LinkedArrayListHeaderInt, @bitCast(LinkedArrayListHeader{
                                .shift = 0,
                                .ptr = array_list_ptr,
                                .size = 0,
                            }), .big);
                            const array_list_index_block = [_]u8{0} ** LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE;
                            try writer.interface.writeAll(&array_list_index_block);
                            // make slot point to new list
                            const next_slot_ptr = SlotPointer{ .position = position, .slot = .{ .value = array_list_start, .tag = .linked_array_list } };
                            try writer.seekTo(position);
                            try writer.interface.writeInt(SlotInt, @bitCast(next_slot_ptr.slot), .big);
                            return self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);
                        },
                        .linked_array_list => {
                            var reader = self.core.reader();
                            var writer = self.core.writer();

                            var array_list_start = slot_ptr.slot.value;

                            // copy it to the end unless it was made in this transaction
                            if (self.tx_start) |tx_start| {
                                if (array_list_start < tx_start) {
                                    // read existing block
                                    try reader.seekTo(array_list_start);
                                    var header: LinkedArrayListHeader = @bitCast(try takeInt(&reader.interface, LinkedArrayListHeaderInt, .big));
                                    try reader.seekTo(header.ptr);
                                    var array_list_index_block = [_]u8{0} ** LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE;
                                    try reader.interface.readSliceAll(&array_list_index_block);
                                    // copy to the end
                                    array_list_start = try self.core.length();
                                    const next_array_list_ptr = array_list_start + byteSizeOf(LinkedArrayListHeader);
                                    header.ptr = next_array_list_ptr;
                                    try writer.seekTo(array_list_start);
                                    try writer.interface.writeInt(LinkedArrayListHeaderInt, @bitCast(header), .big);
                                    try writer.interface.writeAll(&array_list_index_block);
                                }
                            } else if (self.header.tag == .array_list) {
                                return error.ExpectedTxStart;
                            }

                            // make slot point to list
                            const next_slot_ptr = SlotPointer{ .position = position, .slot = .{ .value = array_list_start, .tag = .linked_array_list } };
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

                    var reader = self.core.reader();
                    try reader.seekTo(slot_ptr.slot.value);
                    const header: LinkedArrayListHeader = @bitCast(try takeInt(&reader.interface, LinkedArrayListHeaderInt, .big));
                    if (index >= header.size or index < -@as(i65, header.size)) {
                        return error.KeyNotFound;
                    }

                    const key: u64 = if (index < 0)
                        @intCast(header.size - @abs(index))
                    else
                        @intCast(index);
                    const final_slot_ptr = try self.readLinkedArrayListSlot(header.ptr, key, header.shift, write_mode, is_top_level);

                    return try self.readSlotPointer(write_mode, Ctx, path[1..], final_slot_ptr.slot_ptr);
                },
                .linked_array_list_append => {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .linked_array_list) return error.UnexpectedTag;

                    var reader = self.core.reader();
                    const next_array_list_start = slot_ptr.slot.value;

                    // read header
                    try reader.seekTo(next_array_list_start);
                    const orig_header: LinkedArrayListHeader = @bitCast(try takeInt(&reader.interface, LinkedArrayListHeaderInt, .big));

                    // append
                    const append_result = try self.readLinkedArrayListSlotAppend(orig_header, write_mode, is_top_level);
                    const final_slot_ptr = try self.readSlotPointer(write_mode, Ctx, path[1..], append_result.slot_ptr.slot_ptr);

                    // update header
                    var writer = self.core.writer();
                    try writer.seekTo(next_array_list_start);
                    try writer.interface.writeInt(LinkedArrayListHeaderInt, @bitCast(append_result.header), .big);

                    return final_slot_ptr;
                },
                .linked_array_list_slice => |linked_array_list_slice| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .linked_array_list) return error.UnexpectedTag;

                    var reader = self.core.reader();
                    const next_array_list_start = slot_ptr.slot.value;

                    // read header
                    try reader.seekTo(next_array_list_start);
                    const orig_header: LinkedArrayListHeader = @bitCast(try takeInt(&reader.interface, LinkedArrayListHeaderInt, .big));

                    // slice
                    const slice_header = try self.readLinkedArrayListSlice(orig_header, linked_array_list_slice.offset, linked_array_list_slice.size);
                    const final_slot_ptr = try self.readSlotPointer(write_mode, Ctx, path[1..], slot_ptr);

                    // update header
                    var writer = self.core.writer();
                    try writer.seekTo(next_array_list_start);
                    try writer.interface.writeInt(LinkedArrayListHeaderInt, @bitCast(slice_header), .big);

                    return final_slot_ptr;
                },
                .linked_array_list_concat => |linked_array_list_concat| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .linked_array_list) return error.UnexpectedTag;

                    if (linked_array_list_concat.list.tag != .linked_array_list) return error.UnexpectedTag;

                    var reader = self.core.reader();
                    const next_array_list_start = slot_ptr.slot.value;

                    // read headers
                    try reader.seekTo(next_array_list_start);
                    const header_a: LinkedArrayListHeader = @bitCast(try takeInt(&reader.interface, LinkedArrayListHeaderInt, .big));
                    try reader.seekTo(linked_array_list_concat.list.value);
                    const header_b: LinkedArrayListHeader = @bitCast(try takeInt(&reader.interface, LinkedArrayListHeaderInt, .big));

                    // concat
                    const concat_header = try self.readLinkedArrayListConcat(header_a, header_b);
                    const final_slot_ptr = try self.readSlotPointer(write_mode, Ctx, path[1..], slot_ptr);

                    // update header
                    var writer = self.core.writer();
                    try writer.seekTo(next_array_list_start);
                    try writer.interface.writeInt(LinkedArrayListHeaderInt, @bitCast(concat_header), .big);

                    return final_slot_ptr;
                },
                .linked_array_list_insert => |index| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .linked_array_list) return error.UnexpectedTag;

                    var reader = self.core.reader();
                    const next_array_list_start = slot_ptr.slot.value;

                    // read header
                    try reader.seekTo(next_array_list_start);
                    const orig_header: LinkedArrayListHeader = @bitCast(try takeInt(&reader.interface, LinkedArrayListHeaderInt, .big));

                    // get the key
                    if (index >= orig_header.size or index < -@as(i65, orig_header.size)) {
                        return error.KeyNotFound;
                    }
                    const key: u64 = if (index < 0)
                        @intCast(orig_header.size - @abs(index))
                    else
                        @intCast(index);

                    // split up the list
                    const header_a = try self.readLinkedArrayListSlice(orig_header, 0, key);
                    const header_b = try self.readLinkedArrayListSlice(orig_header, key, orig_header.size - key);

                    // add new slot to first list
                    const append_result = try self.readLinkedArrayListSlotAppend(header_a, write_mode, is_top_level);

                    // concat the lists
                    const concat_header = try self.readLinkedArrayListConcat(append_result.header, header_b);

                    // get pointer to the new slot
                    const next_slot_ptr = try self.readLinkedArrayListSlot(concat_header.ptr, key, concat_header.shift, .read_only, is_top_level);

                    // recur down the rest of the path
                    const final_slot_ptr = try self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr.slot_ptr);

                    // update header
                    var writer = self.core.writer();
                    try writer.seekTo(next_array_list_start);
                    try writer.interface.writeInt(LinkedArrayListHeaderInt, @bitCast(concat_header), .big);

                    return final_slot_ptr;
                },
                .linked_array_list_remove => |index| {
                    if (write_mode == .read_only) return error.WriteNotAllowed;

                    if (slot_ptr.slot.tag != .linked_array_list) return error.UnexpectedTag;

                    var reader = self.core.reader();
                    const next_array_list_start = slot_ptr.slot.value;

                    // read header
                    try reader.seekTo(next_array_list_start);
                    const orig_header: LinkedArrayListHeader = @bitCast(try takeInt(&reader.interface, LinkedArrayListHeaderInt, .big));

                    // get the key
                    if (index >= orig_header.size or index < -@as(i65, orig_header.size)) {
                        return error.KeyNotFound;
                    }
                    const key: u64 = if (index < 0)
                        @intCast(orig_header.size - @abs(index))
                    else
                        @intCast(index);

                    // split up the list
                    const header_a = try self.readLinkedArrayListSlice(orig_header, 0, key);
                    const header_b = try self.readLinkedArrayListSlice(orig_header, key + 1, orig_header.size - (key + 1));

                    // concat the lists
                    const concat_header = try self.readLinkedArrayListConcat(header_a, header_b);

                    // get pointer to the list
                    const next_slot_ptr = SlotPointer{ .position = concat_header.ptr, .slot = .{ .value = next_array_list_start, .tag = .linked_array_list } };

                    // recur down the rest of the path
                    const final_slot_ptr = try self.readSlotPointer(write_mode, Ctx, path[1..], next_slot_ptr);

                    // update header
                    var writer = self.core.writer();
                    try writer.seekTo(next_array_list_start);
                    try writer.interface.writeInt(LinkedArrayListHeaderInt, @bitCast(concat_header), .big);

                    return final_slot_ptr;
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

        // linked_array_list

        const LinkedArrayListAppendResult = struct {
            header: LinkedArrayListHeader,
            slot_ptr: LinkedArrayListSlotPointer,
        };

        fn readLinkedArrayListSlotAppend(self: *Database(db_kind, HashInt), header: LinkedArrayListHeader, comptime write_mode: WriteMode, is_top_level: bool) !LinkedArrayListAppendResult {
            var writer = self.core.writer();

            var ptr = header.ptr;
            const key = header.size;
            var shift = header.shift;

            var slot_ptr = self.readLinkedArrayListSlot(ptr, key, shift, write_mode, is_top_level) catch |err| switch (err) {
                error.NoAvailableSlots => blk: {
                    // root overflow
                    const next_ptr = try self.core.length();
                    var index_block = [_]u8{0} ** LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE;
                    try writer.seekTo(next_ptr);
                    try writer.interface.writeAll(&index_block);
                    try writer.seekTo(next_ptr);
                    try writer.interface.writeInt(LinkedArrayListSlotInt, @bitCast(LinkedArrayListSlot{
                        .slot = .{ .value = ptr, .tag = .index, .full = true },
                        .size = header.size,
                    }), .big);
                    ptr = next_ptr;
                    shift += 1;
                    break :blk try self.readLinkedArrayListSlot(ptr, key, shift, write_mode, is_top_level);
                },
                else => |e| return e,
            };

            // newly-appended slots must have full set to true
            // or else the indexing will be screwed up
            const new_slot = Slot{ .value = 0, .tag = .none, .full = true };
            slot_ptr.slot_ptr.slot = new_slot;
            const position = slot_ptr.slot_ptr.position orelse return error.CursorNotWriteable;
            try writer.seekTo(position);
            try writer.interface.writeInt(LinkedArrayListSlotInt, @bitCast(LinkedArrayListSlot{ .slot = new_slot, .size = 0 }), .big);
            if (header.size < SLOT_COUNT and shift > 0) {
                return error.MustSetNewSlotsToFull;
            }

            return .{
                .header = .{
                    .shift = shift,
                    .ptr = ptr,
                    .size = header.size + 1,
                },
                .slot_ptr = slot_ptr,
            };
        }

        fn blockLeafCount(block: []LinkedArrayListSlot, shift: u6, i: u4) u64 {
            var n: u64 = 0;
            // for leaf nodes, count all non-empty slots along with the slot being accessed
            if (shift == 0) {
                for (block, 0..) |block_slot, block_i| {
                    if (!block_slot.slot.empty() or block_i == i) {
                        n += 1;
                    }
                }
            }
            // for non-leaf nodes, add up their sizes
            else {
                for (block) |block_slot| {
                    n += block_slot.size;
                }
            }
            return n;
        }

        fn slotLeafCount(slot: LinkedArrayListSlot, shift: u6) u64 {
            if (shift == 0) {
                if (slot.slot.empty()) {
                    return 0;
                } else {
                    return 1;
                }
            } else {
                return slot.size;
            }
        }

        fn keyAndIndexForLinkedArrayList(slot_block: []LinkedArrayListSlot, key: u64, shift: u6) ?struct { key: u64, index: u4 } {
            var next_key = key;
            var i: u4 = 0;
            const max_leaf_count: u64 = if (shift == 0) 1 else std.math.pow(u64, SLOT_COUNT, shift);
            while (true) {
                const slot_leaf_count = slotLeafCount(slot_block[i], shift);
                if (next_key == slot_leaf_count) {
                    // if the slot's leaf count is at its maximum
                    // or it is full, we have to skip to the next slot
                    if (slot_leaf_count == max_leaf_count or slot_block[i].slot.full) {
                        if (i < SLOT_COUNT - 1) {
                            next_key -= slot_leaf_count;
                            i += 1;
                        } else {
                            return null;
                        }
                    }
                    break;
                } else if (next_key < slot_leaf_count) {
                    break;
                } else if (i < SLOT_COUNT - 1) {
                    next_key -= slot_leaf_count;
                    i += 1;
                } else {
                    return null;
                }
            }
            return .{ .key = next_key, .index = i };
        }

        fn readLinkedArrayListSlot(self: *Database(db_kind, HashInt), index_pos: u64, key: u64, shift: u6, comptime write_mode: WriteMode, is_top_level: bool) !LinkedArrayListSlotPointer {
            if (shift >= MAX_BRANCH_LENGTH) return error.MaxShiftExceeded;

            var reader = self.core.reader();
            var writer = self.core.writer();

            var slot_block = [_]LinkedArrayListSlot{.{ .slot = .{}, .size = 0 }} ** SLOT_COUNT;
            {
                try reader.seekTo(index_pos);
                var index_block = [_]u8{0} ** LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE;
                try reader.interface.readSliceAll(&index_block);

                var block_reader = std.Io.Reader.fixed(&index_block);
                for (&slot_block) |*block_slot| {
                    block_slot.* = @bitCast(try takeInt(&block_reader, LinkedArrayListSlotInt, .big));
                    try block_slot.slot.tag.validate();
                }
            }

            const key_and_index = keyAndIndexForLinkedArrayList(&slot_block, key, shift) orelse return error.NoAvailableSlots;
            const next_key = key_and_index.key;
            const i = key_and_index.index;
            const slot = slot_block[i];
            const slot_pos = index_pos + (byteSizeOf(LinkedArrayListSlot) * i);

            if (shift == 0) {
                const leaf_count = blockLeafCount(&slot_block, shift, i);
                return .{ .slot_ptr = .{ .position = slot_pos, .slot = slot.slot }, .leaf_count = leaf_count };
            }

            const ptr = slot.slot.value;

            switch (slot.slot.tag) {
                .none => {
                    switch (write_mode) {
                        .read_only => return error.KeyNotFound,
                        .read_write => {
                            const next_index_pos = try self.core.length();
                            var index_block = [_]u8{0} ** LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE;
                            try writer.seekTo(next_index_pos);
                            try writer.interface.writeAll(&index_block);

                            const next_slot_ptr = try self.readLinkedArrayListSlot(next_index_pos, next_key, shift - 1, write_mode, is_top_level);

                            slot_block[i].size = next_slot_ptr.leaf_count;
                            const leaf_count = blockLeafCount(&slot_block, shift, i);

                            try writer.seekTo(slot_pos);
                            try writer.interface.writeInt(LinkedArrayListSlotInt, @bitCast(LinkedArrayListSlot{ .slot = .{ .value = next_index_pos, .tag = .index }, .size = next_slot_ptr.leaf_count }), .big);
                            return .{ .slot_ptr = next_slot_ptr.slot_ptr, .leaf_count = leaf_count };
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
                                var index_block = [_]u8{0} ** LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE;
                                try reader.interface.readSliceAll(&index_block);
                                // copy it to the end
                                next_ptr = try self.core.length();
                                try writer.seekTo(next_ptr);
                                try writer.interface.writeAll(&index_block);
                            }
                        } else if (self.header.tag == .array_list) {
                            return error.ExpectedTxStart;
                        }
                    }

                    const next_slot_ptr = try self.readLinkedArrayListSlot(next_ptr, next_key, shift - 1, write_mode, is_top_level);

                    slot_block[i].size = next_slot_ptr.leaf_count;
                    const leaf_count = blockLeafCount(&slot_block, shift, i);

                    if (write_mode == .read_write and !is_top_level) {
                        // make slot point to block
                        try writer.seekTo(slot_pos);
                        try writer.interface.writeInt(LinkedArrayListSlotInt, @bitCast(LinkedArrayListSlot{ .slot = .{ .value = next_ptr, .tag = .index }, .size = next_slot_ptr.leaf_count }), .big);
                    }

                    return .{ .slot_ptr = next_slot_ptr.slot_ptr, .leaf_count = leaf_count };
                },
                else => return error.UnexpectedTag,
            }
        }

        fn readLinkedArrayListBlocks(self: *Database(db_kind, HashInt), index_pos: u64, key: u64, shift: u6, blocks: *BoundedArray(LinkedArrayListBlockInfo, MAX_BRANCH_LENGTH)) !void {
            var reader = self.core.reader();

            var slot_block = [_]LinkedArrayListSlot{.{ .slot = .{}, .size = 0 }} ** SLOT_COUNT;
            {
                try reader.seekTo(index_pos);
                var index_block = [_]u8{0} ** LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE;
                try reader.interface.readSliceAll(&index_block);

                var block_reader = std.Io.Reader.fixed(&index_block);
                for (&slot_block) |*block_slot| {
                    block_slot.* = @bitCast(try takeInt(&block_reader, LinkedArrayListSlotInt, .big));
                    try block_slot.slot.tag.validate();
                }
            }

            const key_and_index = keyAndIndexForLinkedArrayList(&slot_block, key, shift) orelse return error.NoAvailableSlots;
            const next_key = key_and_index.key;
            const i = key_and_index.index;
            const leaf_count = blockLeafCount(&slot_block, shift, i);

            try blocks.append(.{ .block = slot_block, .i = i, .parent_slot = .{ .slot = .{ .value = index_pos, .tag = .index }, .size = leaf_count } });

            if (shift == 0) {
                return;
            }

            const slot = slot_block[i];
            switch (slot.slot.tag) {
                .none => return error.EmptySlot,
                .index => {
                    try self.readLinkedArrayListBlocks(slot.slot.value, next_key, shift - 1, blocks);
                },
                else => return error.UnexpectedTag,
            }
        }

        fn readLinkedArrayListSlice(self: *Database(db_kind, HashInt), header: LinkedArrayListHeader, offset: u64, size: u64) !LinkedArrayListHeader {
            var core_writer = self.core.writer();

            if (offset + size > header.size) {
                return error.KeyNotFound;
            }

            // read the list's left blocks
            var left_blocks = try BoundedArray(LinkedArrayListBlockInfo, MAX_BRANCH_LENGTH).init(0);
            try self.readLinkedArrayListBlocks(header.ptr, offset, header.shift, &left_blocks);

            // read the list's right blocks
            var right_blocks = try BoundedArray(LinkedArrayListBlockInfo, MAX_BRANCH_LENGTH).init(0);
            const right_key = if (offset + size == 0) 0 else offset + size - 1;
            try self.readLinkedArrayListBlocks(header.ptr, right_key, header.shift, &right_blocks);

            // create the new blocks
            const block_count = left_blocks.slice().len;
            var next_slots = [_]?LinkedArrayListSlot{null} ** 2;
            var next_shift: u6 = 0;
            for (0..block_count) |i| {
                const is_leaf_node = next_slots[0] == null;

                const left_block = left_blocks.slice()[block_count - i - 1];
                const right_block = right_blocks.slice()[block_count - i - 1];
                const orig_block_infos = [_]LinkedArrayListBlockInfo{
                    left_block,
                    right_block,
                };
                var next_blocks: [2]?[SLOT_COUNT]LinkedArrayListSlot = .{ null, null };

                if (left_block.parent_slot.slot.value == right_block.parent_slot.slot.value) {
                    var slot_i: usize = 0;
                    var new_root_block = [_]LinkedArrayListSlot{.{ .slot = .{}, .size = 0 }} ** SLOT_COUNT;
                    // left slot
                    if (size > 0) {
                        if (next_slots[0]) |left_slot| {
                            new_root_block[slot_i] = left_slot;
                        } else {
                            new_root_block[slot_i] = left_block.block[left_block.i];
                        }
                        slot_i += 1;
                    }
                    if (size > 1) {
                        // middle slots
                        for (left_block.block[left_block.i + 1 .. right_block.i]) |middle_slot| {
                            new_root_block[slot_i] = middle_slot;
                            slot_i += 1;
                        }

                        // right slot
                        if (next_slots[1]) |right_slot| {
                            new_root_block[slot_i] = right_slot;
                        } else {
                            new_root_block[slot_i] = left_block.block[right_block.i];
                        }
                    }
                    next_blocks[0] = new_root_block;
                } else {
                    var slot_i: usize = 0;
                    var new_left_block = [_]LinkedArrayListSlot{.{ .slot = .{}, .size = 0 }} ** SLOT_COUNT;

                    // first slot
                    if (next_slots[0]) |first_slot| {
                        new_left_block[slot_i] = first_slot;
                    } else {
                        new_left_block[slot_i] = left_block.block[left_block.i];
                    }
                    slot_i += 1;
                    // rest of slots
                    for (left_block.block[left_block.i + 1 ..]) |next_slot| {
                        new_left_block[slot_i] = next_slot;
                        slot_i += 1;
                    }
                    next_blocks[0] = new_left_block;

                    slot_i = 0;
                    var new_right_block = [_]LinkedArrayListSlot{.{ .slot = .{}, .size = 0 }} ** SLOT_COUNT;
                    // first slots
                    for (right_block.block[0..right_block.i]) |first_slot| {
                        new_right_block[slot_i] = first_slot;
                        slot_i += 1;
                    }
                    // last slot
                    if (next_slots[1]) |last_slot| {
                        new_right_block[slot_i] = last_slot;
                    } else {
                        new_right_block[slot_i] = right_block.block[right_block.i];
                    }
                    next_blocks[1] = new_right_block;

                    next_shift += 1;
                }

                // clear the next slots
                next_slots = .{ null, null };

                const Side = enum { left, right };
                const sides = [_]Side{ .left, .right };

                // write the block(s)
                for (&next_slots, next_blocks, orig_block_infos, sides) |*next_slot, block_maybe, orig_block_info, side| {
                    if (block_maybe) |block| {
                        // determine if the block changed compared to the original block
                        var eql = true;
                        for (block, orig_block_info.block) |block_slot, orig_slot| {
                            if (!block_slot.slot.eql(orig_slot.slot)) {
                                eql = false;
                                break;
                            }
                        }
                        // if there is no change, just use the original block
                        if (eql) {
                            next_slot.* = orig_block_info.parent_slot;
                        }
                        // otherwise make a new block
                        else {
                            const next_ptr = try self.core.length();
                            try core_writer.seekTo(next_ptr);
                            var leaf_count: u64 = 0;
                            for (block) |block_slot| {
                                try core_writer.interface.writeInt(LinkedArrayListSlotInt, @bitCast(block_slot), .big);
                                if (is_leaf_node) {
                                    if (!block_slot.slot.empty()) {
                                        leaf_count += 1;
                                    }
                                } else {
                                    leaf_count += block_slot.size;
                                }
                            }
                            next_slot.* = LinkedArrayListSlot{
                                .slot = switch (side) {
                                    // only the left side needs to be set to full,
                                    // because it can have a gap that affects indexing
                                    .left => .{ .value = next_ptr, .tag = .index, .full = true },
                                    .right => .{ .value = next_ptr, .tag = .index },
                                },
                                .size = leaf_count,
                            };
                        }
                    }
                }

                // we found the root node so we can exit
                if (next_slots[0] != null and next_slots[1] == null) {
                    break;
                }
            }

            const root_slot = next_slots[0] orelse return error.ExpectedRootNode;

            return .{
                .shift = next_shift,
                .ptr = root_slot.slot.value,
                .size = size,
            };
        }

        fn readLinkedArrayListConcat(self: *Database(db_kind, HashInt), header_a: LinkedArrayListHeader, header_b: LinkedArrayListHeader) !LinkedArrayListHeader {
            var core_writer = self.core.writer();

            // read the first list's blocks
            var blocks_a = try BoundedArray(LinkedArrayListBlockInfo, MAX_BRANCH_LENGTH).init(0);
            const key_a = if (header_a.size == 0) 0 else header_a.size - 1;
            try self.readLinkedArrayListBlocks(header_a.ptr, key_a, header_a.shift, &blocks_a);

            // read the second list's blocks
            var blocks_b = try BoundedArray(LinkedArrayListBlockInfo, MAX_BRANCH_LENGTH).init(0);
            try self.readLinkedArrayListBlocks(header_b.ptr, 0, header_b.shift, &blocks_b);

            // stitch the blocks together
            var next_slots = [_]?LinkedArrayListSlot{null} ** 2;
            var next_shift: u6 = 0;
            for (0..@max(blocks_a.slice().len, blocks_b.slice().len)) |i| {
                const block_infos: [2]?LinkedArrayListBlockInfo = .{
                    if (i < blocks_a.slice().len) blocks_a.slice()[blocks_a.slice().len - 1 - i] else null,
                    if (i < blocks_b.slice().len) blocks_b.slice()[blocks_b.slice().len - 1 - i] else null,
                };
                var next_blocks: [2]?[SLOT_COUNT]LinkedArrayListSlot = .{ null, null };
                const is_leaf_node = next_slots[0] == null;

                if (!is_leaf_node) {
                    next_shift += 1;
                }

                for (block_infos, &next_blocks) |block_info_maybe, *next_block_maybe| {
                    if (block_info_maybe) |block_info| {
                        var block = [_]LinkedArrayListSlot{.{ .slot = .{}, .size = 0 }} ** SLOT_COUNT;
                        var target_i: usize = 0;
                        for (block_info.block, 0..) |block_slot, source_i| {
                            // skip i'th block if necessary
                            if (!is_leaf_node and block_info.i == source_i) {
                                continue;
                            }
                            // break on first empty slot
                            else if (block_slot.slot.empty()) {
                                break;
                            }
                            block[target_i] = block_slot;
                            target_i += 1;
                        }

                        // there are no slots in this block so don't bother writing it
                        if (target_i == 0) {
                            continue;
                        }

                        next_block_maybe.* = block;
                    }
                }

                var slots_to_write = [_]LinkedArrayListSlot{.{ .slot = .{}, .size = 0 }} ** (SLOT_COUNT * 2);
                var slot_i: usize = 0;

                // add the left block
                if (next_blocks[0]) |block| {
                    for (block) |block_slot| {
                        if (block_slot.slot.empty()) {
                            break;
                        }
                        slots_to_write[slot_i] = block_slot;
                        slot_i += 1;
                    }
                }

                // add the center block
                for (next_slots) |slot_maybe| {
                    if (slot_maybe) |block_slot| {
                        slots_to_write[slot_i] = block_slot;
                        slot_i += 1;
                    }
                }

                // add the right block
                if (next_blocks[1]) |block| {
                    for (block) |block_slot| {
                        if (block_slot.slot.empty()) {
                            break;
                        }
                        slots_to_write[slot_i] = block_slot;
                        slot_i += 1;
                    }
                }

                // clear the next slots
                next_slots = .{ null, null };

                // put the slots to write in separate blocks
                var blocks: [2][SLOT_COUNT]LinkedArrayListSlot = .{
                    [_]LinkedArrayListSlot{.{ .slot = .{}, .size = 0 }} ** SLOT_COUNT,
                    [_]LinkedArrayListSlot{.{ .slot = .{}, .size = 0 }} ** SLOT_COUNT,
                };
                if (slot_i > SLOT_COUNT) {
                    // if there are enough slots to fill two blocks,
                    // we need to decide which block to leave the gap in.
                    // if the first list is smaller, leave the gap in
                    // the first block. otherwise, leave it in the second.
                    // this will cause the gap to stay near the left or
                    // right edge of the concatenated list. we do this
                    // because if many gaps form inside the list, the
                    // branches will get long and lead to MaxShiftExceeded.
                    if (header_a.size < header_b.size) {
                        for (0..slot_i - SLOT_COUNT) |j| {
                            blocks[0][j] = slots_to_write[j];
                        }
                        for (0..SLOT_COUNT) |j| {
                            blocks[1][j] = slots_to_write[j + (slot_i - SLOT_COUNT)];
                        }
                    } else {
                        for (0..SLOT_COUNT) |j| {
                            blocks[0][j] = slots_to_write[j];
                        }
                        for (0..slot_i - SLOT_COUNT) |j| {
                            blocks[1][j] = slots_to_write[j + SLOT_COUNT];
                        }
                    }
                } else {
                    for (0..slot_i) |j| {
                        blocks[0][j] = slots_to_write[j];
                    }
                }

                // write the block(s)
                for (blocks, &next_slots) |block, *next_slot| {
                    // this block is empty so don't bother writing it
                    if (block[0].slot.empty()) {
                        break;
                    }

                    // write the block
                    const next_ptr = try self.core.length();
                    try core_writer.seekTo(next_ptr);
                    var leaf_count: u64 = 0;
                    for (block) |block_slot| {
                        try core_writer.interface.writeInt(LinkedArrayListSlotInt, @bitCast(block_slot), .big);
                        if (is_leaf_node) {
                            if (!block_slot.slot.empty()) {
                                leaf_count += 1;
                            }
                        } else {
                            leaf_count += block_slot.size;
                        }
                    }

                    next_slot.* = LinkedArrayListSlot{ .slot = .{ .value = next_ptr, .tag = .index, .full = true }, .size = leaf_count };
                }
            }

            const root_ptr = blk: {
                if (next_slots[0]) |first_slot| {
                    // if there is more than one slot, make a root node
                    if (next_slots[1]) |second_slot| {
                        var block = [_]LinkedArrayListSlot{.{ .slot = .{}, .size = 0 }} ** SLOT_COUNT;
                        block[0] = first_slot;
                        block[1] = second_slot;

                        // write the root node
                        const new_ptr = core_writer.pos;
                        for (block) |block_slot| {
                            try core_writer.interface.writeInt(LinkedArrayListSlotInt, @bitCast(block_slot), .big);
                        }

                        if (next_shift == MAX_BRANCH_LENGTH) return error.MaxShiftExceeded;
                        next_shift += 1;

                        break :blk new_ptr;
                    }
                    // otherwise the first slot is the root node
                    else {
                        break :blk first_slot.slot.value;
                    }
                }
                // lists were empty so just re-use existing empty block
                else {
                    break :blk header_a.ptr;
                }
            };

            return .{
                .shift = next_shift,
                .ptr = root_ptr,
                .size = header_a.size + header_b.size,
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
                        .linked_array_list => {
                            try core_reader.seekTo(self.slot_ptr.slot.value);
                            const header: LinkedArrayListHeader = @bitCast(try takeInt(&core_reader.interface, LinkedArrayListHeaderInt, .big));
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
                        stack: BoundedArray(Level, MAX_BRANCH_LENGTH),
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
                                    .stack = try BoundedArray(Level, MAX_BRANCH_LENGTH).init(0),
                                },
                                .array_list => blk: {
                                    const position = cursor.slot_ptr.slot.value;
                                    var core_reader = cursor.db.core.reader();
                                    try core_reader.seekTo(position);
                                    const header: ArrayListHeader = @bitCast(try takeInt(&core_reader.interface, ArrayListHeaderInt, .big));
                                    break :blk .{
                                        .size = try cursor.count(),
                                        .index = 0,
                                        .stack = try initStack(cursor, header.ptr, INDEX_BLOCK_SIZE),
                                    };
                                },
                                .linked_array_list => blk: {
                                    const position = cursor.slot_ptr.slot.value;
                                    var core_reader = cursor.db.core.reader();
                                    try core_reader.seekTo(position);
                                    const header: LinkedArrayListHeader = @bitCast(try takeInt(&core_reader.interface, LinkedArrayListHeaderInt, .big));
                                    break :blk .{
                                        .size = try cursor.count(),
                                        .index = 0,
                                        .stack = try initStack(cursor, header.ptr, LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE),
                                    };
                                },
                                .hash_map, .hash_set => .{
                                    .size = 0,
                                    .index = 0,
                                    .stack = try initStack(cursor, cursor.slot_ptr.slot.value, INDEX_BLOCK_SIZE),
                                },
                                .counted_hash_map, .counted_hash_set => .{
                                    .size = 0,
                                    .index = 0,
                                    .stack = try initStack(cursor, cursor.slot_ptr.slot.value + byteSizeOf(u64), INDEX_BLOCK_SIZE),
                                },
                                else => return error.UnexpectedTag,
                            },
                        };
                    }

                    pub fn next(self: *Iter) !?Cursor(write_mode) {
                        switch (self.cursor.slot_ptr.slot.tag) {
                            .none => return null,
                            .array_list => {
                                if (self.core.index == self.core.size) return null;
                                self.core.index += 1;
                                return try self.nextInternal(INDEX_BLOCK_SIZE);
                            },
                            .linked_array_list => {
                                if (self.core.index == self.core.size) return null;
                                self.core.index += 1;
                                return try self.nextInternal(LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE);
                            },
                            .hash_map, .hash_set, .counted_hash_map, .counted_hash_set => return try self.nextInternal(INDEX_BLOCK_SIZE),
                            else => return error.UnexpectedTag,
                        }
                    }

                    fn initStack(cursor: Cursor(write_mode), position: u64, comptime block_size: u64) !BoundedArray(Level, MAX_BRANCH_LENGTH) {
                        // find the block
                        var core_reader = cursor.db.core.reader();
                        try core_reader.seekTo(position);
                        // read the block
                        var index_block_bytes = [_]u8{0} ** block_size;
                        try core_reader.interface.readSliceAll(&index_block_bytes);
                        // convert the block into slots
                        var index_block = [_]Slot{undefined} ** SLOT_COUNT;
                        {
                            var block_reader = std.Io.Reader.fixed(&index_block_bytes);
                            for (&index_block) |*block_slot| {
                                block_slot.* = @bitCast(try takeInt(&block_reader, SlotInt, .big));
                                try block_slot.tag.validate();
                                // linked array list has larger slots so we need to skip over the rest
                                block_reader.toss((block_size / SLOT_COUNT) - byteSizeOf(Slot));
                            }
                        }
                        // init the stack
                        var stack = try BoundedArray(Level, MAX_BRANCH_LENGTH).init(0);
                        try stack.append(.{
                            .position = position,
                            .block = index_block,
                            .index = 0,
                        });
                        return stack;
                    }

                    fn nextInternal(self: *Iter, comptime block_size: u64) !?Cursor(write_mode) {
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
                                    // find the block
                                    var core_reader = self.cursor.db.core.reader();
                                    const next_pos = next_slot.value;
                                    try core_reader.seekTo(next_pos);
                                    // read the block
                                    var index_block_bytes = [_]u8{0} ** block_size;
                                    try core_reader.interface.readSliceAll(&index_block_bytes);
                                    // convert the block into slots
                                    var index_block = [_]Slot{undefined} ** SLOT_COUNT;
                                    {
                                        var block_reader = std.Io.Reader.fixed(&index_block_bytes);
                                        for (&index_block) |*block_slot| {
                                            block_slot.* = @bitCast(try takeInt(&block_reader, SlotInt, .big));
                                            try block_slot.tag.validate();
                                            // linked array list has larger slots so we need to skip over the rest
                                            block_reader.toss((block_size / SLOT_COUNT) - byteSizeOf(Slot));
                                        }
                                    }
                                    // append to the stack
                                    try self.core.stack.append(.{
                                        .position = next_pos,
                                        .block = index_block,
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
                    const new_offset = try remapLinkedArrayList(source_core, target_db_kind, target_core, offset_map, slot);
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

        fn remapLinkedArrayList(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), slot: Slot) !u64 {
            var reader = source_core.reader();
            var writer = target_core.writer();

            // read LinkedArrayListHeader (17 bytes)
            try reader.seekTo(slot.value);
            const header: LinkedArrayListHeader = @bitCast(try takeInt(&reader.interface, LinkedArrayListHeaderInt, .big));

            // remap root block
            const remapped_ptr = try remapLinkedArrayListBlock(source_core, target_db_kind, target_core, offset_map, header.ptr);

            // write new header
            const new_offset = try target_core.length();
            try writer.seekTo(new_offset);
            try writer.interface.writeInt(LinkedArrayListHeaderInt, @bitCast(LinkedArrayListHeader{
                .shift = header.shift,
                .ptr = remapped_ptr,
                .size = header.size,
            }), .big);

            return new_offset;
        }

        fn remapLinkedArrayListBlock(source_core: *Core(db_kind), comptime target_db_kind: DatabaseKind, target_core: *Core(target_db_kind), offset_map: *std.AutoHashMap(u64, u64), block_offset: u64) !u64 {
            // dedup check
            if (offset_map.get(block_offset)) |mapped| {
                return mapped;
            }

            var reader = source_core.reader();
            var writer = target_core.writer();

            // read 272-byte block (16 x LinkedArrayListSlot of 17 bytes)
            try reader.seekTo(block_offset);
            var block_bytes = [_]u8{0} ** LINKED_ARRAY_LIST_INDEX_BLOCK_SIZE;
            try reader.interface.readSliceAll(&block_bytes);

            // parse slots
            var block_reader = std.Io.Reader.fixed(&block_bytes);
            var slots: [SLOT_COUNT]LinkedArrayListSlot = undefined;
            for (&slots) |*s| {
                s.* = @bitCast(try takeInt(&block_reader, LinkedArrayListSlotInt, .big));
            }

            // remap each slot
            var remapped_slots: [SLOT_COUNT]LinkedArrayListSlot = undefined;
            for (&remapped_slots, slots) |*rs, s| {
                if (s.slot.tag == .index) {
                    // index slots point to other 272-byte blocks, recurse on ourselves
                    const remapped_ptr = try remapLinkedArrayListBlock(source_core, target_db_kind, target_core, offset_map, s.slot.value);
                    rs.* = .{
                        .size = s.size,
                        .slot = .{ .value = remapped_ptr, .tag = .index, .full = s.slot.full },
                    };
                } else if (s.slot.empty()) {
                    rs.* = s;
                } else {
                    // leaf slot - remap via remapSlot
                    const remapped = try remapSlot(source_core, target_db_kind, target_core, offset_map, s.slot);
                    rs.* = .{
                        .size = s.size,
                        .slot = remapped,
                    };
                }
            }

            // write remapped block to target
            const new_offset = try target_core.length();
            try writer.seekTo(new_offset);
            for (remapped_slots) |s| {
                try writer.interface.writeInt(LinkedArrayListSlotInt, @bitCast(s), .big);
            }

            try offset_map.put(block_offset, new_offset);
            return new_offset;
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

    pub fn setLength(self: *CoreMemory, len: usize) !void {
        var arr = self.buffer.toArrayList();
        arr.shrinkAndFree(self.buffer.allocator, len);
        self.buffer.* = std.Io.Writer.Allocating.fromArrayList(self.buffer.allocator, &arr);
    }

    pub fn sync(_: *const CoreMemory) !void {}

    pub fn flush(_: *CoreMemory) !void {}
};

const CoreFile = struct {
    file: std.fs.File,

    pub const Reader = std.fs.File.Reader;
    pub const Writer = std.fs.File.Writer;

    pub fn reader(self: *const CoreFile) Reader {
        return self.file.reader(&.{});
    }

    pub fn writer(self: *const CoreFile) Writer {
        return self.file.writer(&.{});
    }

    pub fn length(self: *const CoreFile) !u64 {
        try self.file.seekFromEnd(0);
        return try self.file.getPos();
    }

    pub fn setLength(self: *const CoreFile, len: usize) !void {
        self.file.setEndPos(len) catch |err| switch (err) {
            // the file is open in read-only mode.
            // on windows, it will return AccessDenied.
            // otherwise it will return NonResizable.
            error.AccessDenied, error.NonResizable => return,
            else => |e| return e,
        };
    }

    pub fn sync(self: *const CoreFile) !void {
        try self.file.sync();
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

    pub fn setLength(self: *CoreBufferedFile, len: usize) !void {
        try self.flush();
        try self.file.setLength(len);
    }

    pub fn sync(self: *CoreBufferedFile) !void {
        try self.flush();
        try self.file.sync();
    }

    pub fn flush(self: *CoreBufferedFile) !void {
        if (self.memory.buffer.written().len > 0) {
            var file_writer = self.file.file.writer(&.{});
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
