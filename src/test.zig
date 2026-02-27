const std = @import("std");
const xitdb = @import("xitdb");

const HashInt = u160;
const MAX_READ_BYTES = 1024;

test "high level api" {
    const allocator = std.testing.allocator;

    {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        try testHighLevelApi(allocator, .memory, .{ .buffer = &buffer, .max_size = 50_000 });
    }

    {
        const file = try std.fs.cwd().createFile("main.db", .{ .read = true, .truncate = true });
        defer {
            file.close();
            std.fs.cwd().deleteFile("main.db") catch {};
        }
        try testHighLevelApi(allocator, .file, .{ .file = file });
    }

    {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        const file = try std.fs.cwd().createFile("main.db", .{ .read = true, .truncate = true });
        defer {
            file.close();
            std.fs.cwd().deleteFile("main.db") catch {};
        }
        try testHighLevelApi(allocator, .buffered_file, .{ .file = file, .buffer = &buffer });
    }
}

test "low level api" {
    const allocator = std.testing.allocator;

    {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        try testLowLevelApi(allocator, .memory, .{ .buffer = &buffer, .max_size = 50_000_000 });
    }

    {
        const file = try std.fs.cwd().createFile("main.db", .{ .read = true, .truncate = true });
        defer {
            file.close();
            std.fs.cwd().deleteFile("main.db") catch {};
        }
        try testLowLevelApi(allocator, .file, .{ .file = file });
    }

    {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();
        const file = try std.fs.cwd().createFile("main.db", .{ .read = true, .truncate = true });
        defer {
            file.close();
            std.fs.cwd().deleteFile("main.db") catch {};
        }
        try testLowLevelApi(allocator, .buffered_file, .{ .file = file, .buffer = &buffer });
    }
}

test "not using arraylist at the top level" {
    // normally an arraylist makes the most sense at the top level,
    // but this test just ensures we can use other data structures
    // at the top level. in theory a top-level hash map might make
    // sense if we're using xitdb as a format to send data over a
    // network. in that case, immutability isn't important because
    // the data is just created and immediately sent over the wire.

    const allocator = std.testing.allocator;

    // hash map
    {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();

        const DB = xitdb.Database(.memory, HashInt);
        var db = try DB.init(.{ .buffer = &buffer, .max_size = 50000 });

        const map = try DB.HashMap(.read_write).init(db.rootCursor());
        try map.put(hashInt("foo"), .{ .bytes = "foo" });
        try map.put(hashInt("bar"), .{ .bytes = "bar" });

        // init inner map
        {
            const inner_map_cursor = try map.putCursor(hashInt("inner-map"));
            _ = try DB.HashMap(.read_write).init(inner_map_cursor);
        }

        // re-init inner map
        // since the top-level type isn't an arraylist, there is no concept of
        // a transaction, so this does not perform a copy of the root node
        {
            const inner_map_cursor = try map.putCursor(hashInt("inner-map"));
            _ = try DB.HashMap(.read_write).init(inner_map_cursor);
        }
    }

    // linked array list is not currently allowed at the top level
    {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();

        const DB = xitdb.Database(.memory, HashInt);
        var db = try DB.init(.{ .buffer = &buffer, .max_size = 50000 });

        try std.testing.expectError(error.InvalidTopLevelType, DB.LinkedArrayList(.read_write).init(db.rootCursor()));
    }
}

test "low level memory operations" {
    const allocator = std.testing.allocator;

    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    var db = try xitdb.Database(.memory, HashInt).init(.{ .buffer = &buffer, .max_size = 10000 });

    var writer = db.core.writer();
    try writer.seekTo(0);
    try writer.interface.writeAll("Hello");
    try std.testing.expectEqualStrings("Hello", db.core.buffer.written()[0..5]);
    try writer.interface.writeInt(u64, 42, .big);
    var bytes = [_]u8{0} ** (@bitSizeOf(u64) / 8);
    std.mem.writeInt(u64, &bytes, 42, .big);
    const hello = try std.fmt.allocPrint(allocator, "Hello{s}", .{bytes});
    defer allocator.free(hello);
    try std.testing.expectEqualStrings(hello, db.core.buffer.written()[0..13]);

    var reader = db.core.reader();
    try reader.seekTo(0);
    var block = [_]u8{0} ** 5;
    try reader.interface.readSliceAll(&block);
    try std.testing.expectEqualStrings("Hello", &block);
    try std.testing.expectEqual(42, try takeInt(&reader.interface, u64, .big));
}

test "validate tag" {
    const Slot = packed struct {
        value: u64,
        tag: u7,
        flag: u1,
    };
    const invalid: xitdb.Slot = @bitCast(Slot{ .value = 0, .tag = 127, .flag = 0 });
    try std.testing.expectEqual(error.InvalidEnumTag, invalid.tag.validate());
}

fn hashInt(buffer: []const u8) HashInt {
    var hash: [@bitSizeOf(HashInt) / 8]u8 = undefined;
    std.crypto.hash.Sha1.hash(buffer, &hash, .{});
    return std.mem.readInt(HashInt, &hash, .big);
}

fn takeInt(reader: *std.Io.Reader, comptime T: type, endian: std.builtin.Endian) !T {
    var buffer: [@bitSizeOf(T) / 8]u8 = undefined;
    try reader.readSliceAll(&buffer);
    return std.mem.readInt(T, &buffer, endian);
}

fn clearStorage(comptime db_kind: xitdb.DatabaseKind, init_opts: xitdb.InitOpts(db_kind)) !void {
    switch (db_kind) {
        .memory => {
            init_opts.buffer.shrinkRetainingCapacity(0);
        },
        .file => {
            try init_opts.file.setEndPos(0);
        },
        .buffered_file => {
            init_opts.buffer.shrinkRetainingCapacity(0);
            try init_opts.file.setEndPos(0);
        },
    }
}

fn testHighLevelApi(allocator: std.mem.Allocator, comptime db_kind: xitdb.DatabaseKind, init_opts: xitdb.InitOpts(db_kind)) !void {
    // init the db
    const DB = xitdb.Database(db_kind, HashInt);
    var db = try DB.init(init_opts);

    {
        // to get the benefits of immutability, the top-level data structure
        // must be an ArrayList, so each transaction is stored as an item in it
        const history = try DB.ArrayList(.read_write).init(db.rootCursor());

        // this is how a transaction is executed. we call history.appendContext,
        // providing it with the most recent copy of the db and a context
        // object. the context object has a method that will run before the
        // transaction has completed. this method is where we can write
        // changes to the db. if any error happens in it, the transaction
        // will not complete and the db will be unaffected.
        const Ctx = struct {
            pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                const moment = try DB.HashMap(.read_write).init(cursor.*);

                try moment.put(hashInt("foo"), .{ .bytes = "foo" });
                try moment.put(hashInt("bar"), .{ .bytes = "bar" });

                const fruits_cursor = try moment.putCursor(hashInt("fruits"));
                const fruits = try DB.ArrayList(.read_write).init(fruits_cursor);
                try fruits.append(.{ .bytes = "apple" });
                try fruits.append(.{ .bytes = "pear" });
                try fruits.append(.{ .bytes = "grape" });

                const people_cursor = try moment.putCursor(hashInt("people"));
                const people = try DB.ArrayList(.read_write).init(people_cursor);

                const alice_cursor = try people.appendCursor();
                const alice = try DB.HashMap(.read_write).init(alice_cursor);
                try alice.putKey(hashInt("name"), .{ .bytes = "name" });
                try alice.put(hashInt("name"), .{ .bytes = "Alice" });
                try alice.putKey(hashInt("age"), .{ .bytes = "age" });
                try alice.put(hashInt("age"), .{ .uint = 25 });

                const bob_cursor = try people.appendCursor();
                const bob = try DB.HashMap(.read_write).init(bob_cursor);
                try bob.putKey(hashInt("name"), .{ .bytes = "name" });
                try bob.put(hashInt("name"), .{ .bytes = "Bob" });
                try bob.putKey(hashInt("age"), .{ .bytes = "age" });
                try bob.put(hashInt("age"), .{ .uint = 42 });

                const todos_cursor = try moment.putCursor(hashInt("todos"));
                const todos = try DB.LinkedArrayList(.read_write).init(todos_cursor);
                try todos.append(.{ .bytes = "Pay the bills" });
                try todos.append(.{ .bytes = "Get an oil change" });
                try todos.insert(1, .{ .bytes = "Wash the car" });

                // make sure `insertCursor` works as well
                const todo_cursor = try todos.insertCursor(1);
                _ = try DB.HashMap(.read_write).init(todo_cursor);
                try todos.remove(1);

                const letters_counted_map_cursor = try moment.putCursor(hashInt("letters-counted-map"));
                const letters_counted_map = try DB.CountedHashMap(.read_write).init(letters_counted_map_cursor);
                try letters_counted_map.put(hashInt("a"), .{ .uint = 1 });
                try letters_counted_map.putKey(hashInt("a"), .{ .bytes = "a" });
                try letters_counted_map.put(hashInt("a"), .{ .uint = 2 });
                try letters_counted_map.putKey(hashInt("a"), .{ .bytes = "b" });
                try letters_counted_map.put(hashInt("c"), .{ .uint = 3 });
                try letters_counted_map.putKey(hashInt("c"), .{ .bytes = "c" });

                const letters_set_cursor = try moment.putCursor(hashInt("letters-set"));
                const letters_set = try DB.HashSet(.read_write).init(letters_set_cursor);
                try letters_set.put(hashInt("a"), .{ .bytes = "a" });
                try letters_set.put(hashInt("a"), .{ .bytes = "a" });
                try letters_set.put(hashInt("c"), .{ .bytes = "c" });

                const letters_counted_set_cursor = try moment.putCursor(hashInt("letters-counted-set"));
                const letters_counted_set = try DB.CountedHashSet(.read_write).init(letters_counted_set_cursor);
                try letters_counted_set.put(hashInt("a"), .{ .bytes = "a" });
                try letters_counted_set.put(hashInt("a"), .{ .bytes = "a" });
                try letters_counted_set.put(hashInt("c"), .{ .bytes = "c" });

                var random_number_buffer: [32]u8 = undefined;
                std.mem.writeInt(u256, &random_number_buffer, std.crypto.random.int(u256), .big);
                try moment.put(hashInt("random-number"), .{ .bytes_object = .{ .value = &random_number_buffer, .format_tag = "bi".* } });

                var long_text_cursor = try moment.putCursor(hashInt("long-text"));
                var write_buffer: [1024]u8 = undefined;
                var writer = try long_text_cursor.writer(&write_buffer);
                for (0..50) |_| {
                    try writer.interface.writeAll("hello, world!\n");
                }
                try writer.finish();
            }
        };
        try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{});

        // get the most recent copy of the database, like a moment
        // in time. the -1 index will return the last index in the list.
        const moment_cursor = (try history.getCursor(-1)).?;
        const moment = try DB.HashMap(.read_only).init(moment_cursor);

        // we can read the value of "foo" from the map by getting
        // the cursor to "foo" and then calling readBytesAlloc on it
        const foo_cursor = (try moment.getCursor(hashInt("foo"))).?;
        const foo_value = try foo_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(foo_value);
        try std.testing.expectEqualStrings("foo", foo_value);

        try std.testing.expectEqual(.short_bytes, (try moment.getSlot(hashInt("foo"))).?.tag);
        try std.testing.expectEqual(.short_bytes, (try moment.getSlot(hashInt("bar"))).?.tag);

        // to get the "fruits" list, we get the cursor to it and
        // then pass it to the ArrayList.init method
        const fruits_cursor = (try moment.getCursor(hashInt("fruits"))).?;
        const fruits = try DB.ArrayList(.read_only).init(fruits_cursor);
        try std.testing.expectEqual(3, try fruits.count());

        // now we can get the first item from the fruits list and read it
        const apple_cursor = (try fruits.getCursor(0)).?;
        const apple_value = try apple_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(apple_value);
        try std.testing.expectEqualStrings("apple", apple_value);

        const people_cursor = (try moment.getCursor(hashInt("people"))).?;
        const people = try DB.ArrayList(.read_only).init(people_cursor);
        try std.testing.expectEqual(2, try people.count());

        const alice_cursor = (try people.getCursor(0)).?;
        const alice = try DB.HashMap(.read_only).init(alice_cursor);
        const alice_age_cursor = (try alice.getCursor(hashInt("age"))).?;
        try std.testing.expectEqual(25, try alice_age_cursor.readUint());

        const todos_cursor = (try moment.getCursor(hashInt("todos"))).?;
        const todos = try DB.LinkedArrayList(.read_only).init(todos_cursor);
        try std.testing.expectEqual(3, try todos.count());

        const todo_cursor = (try todos.getCursor(0)).?;
        const todo_value = try todo_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(todo_value);
        try std.testing.expectEqualStrings("Pay the bills", todo_value);

        var fruits_iter = try fruits.iterator();
        while (try fruits_iter.next()) |fruit_cursor| {
            var buffer: [100]u8 = undefined;
            _ = try fruit_cursor.readBytes(&buffer);
        }

        var people_iter = try people.iterator();
        while (try people_iter.next()) |person_cursor| {
            const person = try DB.HashMap(.read_only).init(person_cursor);
            var person_iter = try person.iterator();
            while (try person_iter.next()) |kv_pair_cursor| {
                const kv_pair = try kv_pair_cursor.readKeyValuePair();
                var key_buffer: [100]u8 = undefined;
                _ = try kv_pair.key_cursor.readBytes(&key_buffer);

                switch (kv_pair.value_cursor.slot().tag) {
                    .short_bytes, .bytes => {
                        var val_buffer: [100]u8 = undefined;
                        _ = try kv_pair.value_cursor.readBytes(&val_buffer);
                    },
                    .uint => _ = try kv_pair.value_cursor.readUint(),
                    .int => _ = try kv_pair.value_cursor.readInt(),
                    .float => _ = try kv_pair.value_cursor.readFloat(),
                    else => return error.UnexpectedTagType,
                }
            }
        }

        {
            const letters_counted_map_cursor = (try moment.getCursor(hashInt("letters-counted-map"))).?;
            const letters_counted_map = try DB.CountedHashMap(.read_only).init(letters_counted_map_cursor);
            try std.testing.expectEqual(2, try letters_counted_map.count());

            var iter = try letters_counted_map.iterator();
            var count: usize = 0;
            while (try iter.next()) |kv_pair_cursor| {
                const kv_pair = try kv_pair_cursor.readKeyValuePair();
                var letter_buf = [_]u8{0} ** 8;
                _ = try kv_pair.key_cursor.readBytes(&letter_buf);
                count += 1;
            }
            try std.testing.expectEqual(2, count);
        }

        {
            const letters_set_cursor = (try moment.getCursor(hashInt("letters-set"))).?;
            const letters_set = try DB.HashSet(.read_only).init(letters_set_cursor);
            try std.testing.expect(null != try letters_set.getCursor(hashInt("a")));
            try std.testing.expect(null != try letters_set.getCursor(hashInt("c")));

            var iter = try letters_set.iterator();
            var count: usize = 0;
            while (try iter.next()) |kv_pair_cursor| {
                const kv_pair = try kv_pair_cursor.readKeyValuePair();
                var letter_buf = [_]u8{0} ** 8;
                _ = try kv_pair.key_cursor.readBytes(&letter_buf);
                count += 1;
            }
            try std.testing.expectEqual(2, count);
        }

        {
            const letters_counted_set_cursor = (try moment.getCursor(hashInt("letters-counted-set"))).?;
            const letters_counted_set = try DB.CountedHashSet(.read_only).init(letters_counted_set_cursor);
            try std.testing.expectEqual(2, try letters_counted_set.count());

            var iter = try letters_counted_set.iterator();
            var count: usize = 0;
            while (try iter.next()) |kv_pair_cursor| {
                const kv_pair = try kv_pair_cursor.readKeyValuePair();
                var letter_buf = [_]u8{0} ** 8;
                _ = try kv_pair.key_cursor.readBytes(&letter_buf);
                count += 1;
            }
            try std.testing.expectEqual(2, count);
        }

        {
            const random_number_cursor = (try moment.getCursor(hashInt("random-number"))).?;
            var random_number_buffer: [32]u8 = undefined;
            const random_number = try random_number_cursor.readBytesObject(&random_number_buffer);
            try std.testing.expectEqualStrings("bi", &random_number.format_tag.?);
        }

        {
            var long_text_cursor = (try moment.getCursor(hashInt("long-text"))).?;
            var read_buffer: [1024]u8 = undefined;
            var reader = try long_text_cursor.reader(&read_buffer);
            var count: usize = 0;
            while (try reader.interface.takeDelimiter('\n')) |_| {
                count += 1;
            }
            try std.testing.expectEqual(50, count);
        }
    }

    // make a new transaction and change the data
    {
        const history = try DB.ArrayList(.read_write).init(db.rootCursor());

        const Ctx = struct {
            pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                const moment = try DB.HashMap(.read_write).init(cursor.*);

                try std.testing.expect(try moment.remove(hashInt("bar")));
                try std.testing.expect(!try moment.remove(hashInt("doesn't exist")));

                // this associates the hash of "fruits" with the actual string.
                // hash maps use hashes directly as keys so they are not able
                // to get the original bytes of the key unless we store it
                // explicitly this way.
                try moment.putKey(hashInt("fruits"), .{ .bytes = "fruits" });

                const fruits_cursor = try moment.putCursor(hashInt("fruits"));
                const fruits = try DB.ArrayList(.read_write).init(fruits_cursor);
                try fruits.put(0, .{ .bytes = "lemon" });
                try fruits.slice(2);

                const people_cursor = try moment.putCursor(hashInt("people"));
                const people = try DB.ArrayList(.read_write).init(people_cursor);

                const alice_cursor = try people.putCursor(0);
                const alice = try DB.HashMap(.read_write).init(alice_cursor);
                try alice.put(hashInt("age"), .{ .uint = 26 });

                const todos_cursor = try moment.putCursor(hashInt("todos"));
                const todos = try DB.LinkedArrayList(.read_write).init(todos_cursor);
                try todos.concat(todos_cursor.slot());
                try todos.slice(1, 2);
                try todos.remove(1);

                const letters_counted_map_cursor = try moment.putCursor(hashInt("letters-counted-map"));
                const letters_counted_map = try DB.CountedHashMap(.read_write).init(letters_counted_map_cursor);
                _ = try letters_counted_map.remove(hashInt("b"));
                _ = try letters_counted_map.remove(hashInt("c"));

                const letters_set_cursor = try moment.putCursor(hashInt("letters-set"));
                const letters_set = try DB.HashSet(.read_write).init(letters_set_cursor);
                _ = try letters_set.remove(hashInt("b"));
                _ = try letters_set.remove(hashInt("c"));

                const letters_counted_set_cursor = try moment.putCursor(hashInt("letters-counted-set"));
                const letters_counted_set = try DB.CountedHashSet(.read_write).init(letters_counted_set_cursor);
                _ = try letters_counted_set.remove(hashInt("b"));
                _ = try letters_counted_set.remove(hashInt("c"));
            }
        };
        try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{});

        const moment_cursor = (try history.getCursor(-1)).?;
        const moment = try DB.HashMap(.read_only).init(moment_cursor);

        try std.testing.expectEqual(null, try moment.getCursor(hashInt("bar")));

        const fruits_key_cursor = (try moment.getKeyCursor(hashInt("fruits"))).?;
        const fruits_key_value = try fruits_key_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(fruits_key_value);
        try std.testing.expectEqualStrings("fruits", fruits_key_value);

        const fruits_cursor = (try moment.getCursor(hashInt("fruits"))).?;
        const fruits = try DB.ArrayList(.read_only).init(fruits_cursor);
        try std.testing.expectEqual(2, try fruits.count());

        // you can get both the key and value cursor this way
        const fruits_kv_cursor = (try moment.getKeyValuePair(hashInt("fruits"))).?;
        try std.testing.expectEqual(.short_bytes, fruits_kv_cursor.key_cursor.slot_ptr.slot.tag);
        try std.testing.expectEqual(.array_list, fruits_kv_cursor.value_cursor.slot_ptr.slot.tag);

        const lemon_cursor = (try fruits.getCursor(0)).?;
        const lemon_value = try lemon_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(lemon_value);
        try std.testing.expectEqualStrings("lemon", lemon_value);

        const people_cursor = (try moment.getCursor(hashInt("people"))).?;
        const people = try DB.ArrayList(.read_only).init(people_cursor);
        try std.testing.expectEqual(2, try people.count());

        const alice_cursor = (try people.getCursor(0)).?;
        const alice = try DB.HashMap(.read_only).init(alice_cursor);
        const alice_age_cursor = (try alice.getCursor(hashInt("age"))).?;
        try std.testing.expectEqual(26, try alice_age_cursor.readUint());

        const todos_cursor = (try moment.getCursor(hashInt("todos"))).?;
        const todos = try DB.LinkedArrayList(.read_only).init(todos_cursor);
        try std.testing.expectEqual(1, try todos.count());

        const todo_cursor = (try todos.getCursor(0)).?;
        const todo_value = try todo_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(todo_value);
        try std.testing.expectEqualStrings("Wash the car", todo_value);

        const letters_counted_map_cursor = (try moment.getCursor(hashInt("letters-counted-map"))).?;
        const letters_counted_map = try DB.CountedHashMap(.read_only).init(letters_counted_map_cursor);
        try std.testing.expectEqual(1, try letters_counted_map.count());

        const letters_set_cursor = (try moment.getCursor(hashInt("letters-set"))).?;
        const letters_set = try DB.HashSet(.read_only).init(letters_set_cursor);
        try std.testing.expect(null != try letters_set.getCursor(hashInt("a")));
        try std.testing.expect(null == try letters_set.getCursor(hashInt("b")));

        const letters_counted_set_cursor = (try moment.getCursor(hashInt("letters-counted-set"))).?;
        const letters_counted_set = try DB.CountedHashSet(.read_only).init(letters_counted_set_cursor);
        try std.testing.expectEqual(1, try letters_counted_set.count());
    }

    // the old data hasn't changed
    {
        const history = try DB.ArrayList(.read_write).init(db.rootCursor());

        const moment_cursor = (try history.getCursor(0)).?;
        const moment = try DB.HashMap(.read_only).init(moment_cursor);

        const foo_cursor = (try moment.getCursor(hashInt("foo"))).?;
        const foo_value = try foo_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(foo_value);
        try std.testing.expectEqualStrings("foo", foo_value);

        try std.testing.expectEqual(.short_bytes, (try moment.getSlot(hashInt("foo"))).?.tag);
        try std.testing.expectEqual(.short_bytes, (try moment.getSlot(hashInt("bar"))).?.tag);

        const fruits_cursor = (try moment.getCursor(hashInt("fruits"))).?;
        const fruits = try DB.ArrayList(.read_only).init(fruits_cursor);
        try std.testing.expectEqual(3, try fruits.count());

        const apple_cursor = (try fruits.getCursor(0)).?;
        const apple_value = try apple_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(apple_value);
        try std.testing.expectEqualStrings("apple", apple_value);

        const people_cursor = (try moment.getCursor(hashInt("people"))).?;
        const people = try DB.ArrayList(.read_only).init(people_cursor);
        try std.testing.expectEqual(2, try people.count());

        const alice_cursor = (try people.getCursor(0)).?;
        const alice = try DB.HashMap(.read_only).init(alice_cursor);
        const alice_age_cursor = (try alice.getCursor(hashInt("age"))).?;
        try std.testing.expectEqual(25, try alice_age_cursor.readUint());

        const todos_cursor = (try moment.getCursor(hashInt("todos"))).?;
        const todos = try DB.LinkedArrayList(.read_only).init(todos_cursor);
        try std.testing.expectEqual(3, try todos.count());

        const todo_cursor = (try todos.getCursor(0)).?;
        const todo_value = try todo_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(todo_value);
        try std.testing.expectEqualStrings("Pay the bills", todo_value);
    }

    // remove the last transaction with `slice`
    {
        const history = try DB.ArrayList(.read_write).init(db.rootCursor());

        try history.slice(1);

        const moment_cursor = (try history.getCursor(-1)).?;
        const moment = try DB.HashMap(.read_only).init(moment_cursor);

        const foo_cursor = (try moment.getCursor(hashInt("foo"))).?;
        const foo_value = try foo_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(foo_value);
        try std.testing.expectEqualStrings("foo", foo_value);

        try std.testing.expectEqual(.short_bytes, (try moment.getSlot(hashInt("foo"))).?.tag);
        try std.testing.expectEqual(.short_bytes, (try moment.getSlot(hashInt("bar"))).?.tag);

        const fruits_cursor = (try moment.getCursor(hashInt("fruits"))).?;
        const fruits = try DB.ArrayList(.read_only).init(fruits_cursor);
        try std.testing.expectEqual(3, try fruits.count());

        const apple_cursor = (try fruits.getCursor(0)).?;
        const apple_value = try apple_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(apple_value);
        try std.testing.expectEqualStrings("apple", apple_value);

        const people_cursor = (try moment.getCursor(hashInt("people"))).?;
        const people = try DB.ArrayList(.read_only).init(people_cursor);
        try std.testing.expectEqual(2, try people.count());

        const alice_cursor = (try people.getCursor(0)).?;
        const alice = try DB.HashMap(.read_only).init(alice_cursor);
        const alice_age_cursor = (try alice.getCursor(hashInt("age"))).?;
        try std.testing.expectEqual(25, try alice_age_cursor.readUint());

        const todos_cursor = (try moment.getCursor(hashInt("todos"))).?;
        const todos = try DB.LinkedArrayList(.read_only).init(todos_cursor);
        try std.testing.expectEqual(3, try todos.count());

        const todo_cursor = (try todos.getCursor(0)).?;
        const todo_value = try todo_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(todo_value);
        try std.testing.expectEqualStrings("Pay the bills", todo_value);
    }

    // the db size remains the same after writing junk data
    // and then reinitializing the db. this is useful because
    // there could be data from a transaction that never
    // completed due to an unclean shutdown.
    {
        const size_before = try db.core.length();

        var writer = db.core.writer();
        try writer.seekTo(size_before);
        try writer.interface.writeAll("this is junk data that will be deleted during init");
        try db.core.flush();

        // no error is thrown if db file is opened in read-only mode
        switch (db_kind) {
            .memory => {},
            .file => {
                const file = try std.fs.cwd().openFile("main.db", .{ .mode = .read_only });
                defer file.close();
                var new_init_opts = init_opts;
                new_init_opts.file = file;
                _ = try DB.init(new_init_opts);
            },
            .buffered_file => {
                const file = try std.fs.cwd().openFile("main.db", .{ .mode = .read_only });
                defer file.close();
                var new_init_opts = init_opts;
                new_init_opts.file = file;
                new_init_opts.buffer.shrinkRetainingCapacity(0);
                _ = try DB.init(new_init_opts);
            },
        }

        db = try DB.init(init_opts);

        const size_after = try db.core.length();

        try std.testing.expectEqual(size_before, size_after);
    }

    // cloning
    {
        const history = try DB.ArrayList(.read_write).init(db.rootCursor());

        const Ctx = struct {
            pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                const moment = try DB.HashMap(.read_write).init(cursor.*);

                const fruits_cursor = (try moment.getCursor(hashInt("fruits"))).?;
                const fruits = try DB.ArrayList(.read_only).init(fruits_cursor);

                // create a new key called "food" whose initial value is
                // based on the "fruits" list
                var food_cursor = try moment.putCursor(hashInt("food"));
                try food_cursor.write(.{ .slot = fruits.slot() });

                const food = try DB.ArrayList(.read_write).init(food_cursor);
                try food.append(.{ .bytes = "eggs" });
                try food.append(.{ .bytes = "rice" });
                try food.append(.{ .bytes = "fish" });
            }
        };
        try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{});

        const moment_cursor = (try history.getCursor(-1)).?;
        const moment = try DB.HashMap(.read_only).init(moment_cursor);

        // the food list includes the fruits
        const food_cursor = (try moment.getCursor(hashInt("food"))).?;
        const food = try DB.ArrayList(.read_only).init(food_cursor);
        try std.testing.expectEqual(6, try food.count());

        // ...but the fruits list hasn't been changed
        const fruits_cursor = (try moment.getCursor(hashInt("fruits"))).?;
        const fruits = try DB.ArrayList(.read_only).init(fruits_cursor);
        try std.testing.expectEqual(3, try fruits.count());
    }

    // accidental mutation when cloning inside a transaction
    {
        const history = try DB.ArrayList(.read_write).init(db.rootCursor());

        const history_index = try history.count() - 1;

        const Ctx = struct {
            pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                const moment = try DB.HashMap(.read_write).init(cursor.*);

                const big_cities_cursor = try moment.putCursor(hashInt("big-cities"));
                const big_cities = try DB.ArrayList(.read_write).init(big_cities_cursor);
                try big_cities.append(.{ .bytes = "New York, NY" });
                try big_cities.append(.{ .bytes = "Los Angeles, CA" });

                // create a new key called "cities" whose initial value is
                // based on the "big-cities" list
                var cities_cursor = try moment.putCursor(hashInt("cities"));
                try cities_cursor.write(.{ .slot = big_cities.slot() });

                const cities = try DB.ArrayList(.read_write).init(cities_cursor);
                try cities.append(.{ .bytes = "Charleston, SC" });
                try cities.append(.{ .bytes = "Louisville, KY" });
            }
        };
        try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{});

        const moment_cursor = (try history.getCursor(-1)).?;
        const moment = try DB.HashMap(.read_only).init(moment_cursor);

        // the cities list contains all four
        const cities_cursor = (try moment.getCursor(hashInt("cities"))).?;
        const cities = try DB.ArrayList(.read_only).init(cities_cursor);
        try std.testing.expectEqual(4, try cities.count());

        // ..but so does big-cities! we did not intend to mutate this
        const big_cities_cursor = (try moment.getCursor(hashInt("big-cities"))).?;
        const big_cities = try DB.ArrayList(.read_only).init(big_cities_cursor);
        try std.testing.expectEqual(4, try big_cities.count());

        // revert that change
        try history.append(.{ .slot = try history.getSlot(history_index) });
    }

    // preventing accidental mutation with freezing
    {
        const history = try DB.ArrayList(.read_write).init(db.rootCursor());

        const Ctx = struct {
            pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                const moment = try DB.HashMap(.read_write).init(cursor.*);

                const big_cities_cursor = try moment.putCursor(hashInt("big-cities"));
                const big_cities = try DB.ArrayList(.read_write).init(big_cities_cursor);
                try big_cities.append(.{ .bytes = "New York, NY" });
                try big_cities.append(.{ .bytes = "Los Angeles, CA" });

                // freeze here, so big-cities won't be mutated
                try cursor.db.freeze();

                // create a new key called "cities" whose initial value is
                // based on the "big-cities" list
                var cities_cursor = try moment.putCursor(hashInt("cities"));
                try cities_cursor.write(.{ .slot = big_cities.slot() });

                const cities = try DB.ArrayList(.read_write).init(cities_cursor);
                try cities.append(.{ .bytes = "Charleston, SC" });
                try cities.append(.{ .bytes = "Louisville, KY" });
            }
        };
        try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{});

        const moment_cursor = (try history.getCursor(-1)).?;
        const moment = try DB.HashMap(.read_only).init(moment_cursor);

        // the cities list contains all four
        const cities_cursor = (try moment.getCursor(hashInt("cities"))).?;
        const cities = try DB.ArrayList(.read_only).init(cities_cursor);
        try std.testing.expectEqual(4, try cities.count());

        // and big-cities only contains the original two
        const big_cities_cursor = (try moment.getCursor(hashInt("big-cities"))).?;
        const big_cities = try DB.ArrayList(.read_only).init(big_cities_cursor);
        try std.testing.expectEqual(2, try big_cities.count());
    }
}

fn testSlice(allocator: std.mem.Allocator, comptime db_kind: xitdb.DatabaseKind, init_opts: xitdb.InitOpts(db_kind), comptime original_size: usize, comptime slice_offset: u64, comptime slice_size: u64) !void {
    try clearStorage(db_kind, init_opts);
    var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
    var root_cursor = db.rootCursor();

    const Ctx = struct {
        allocator: std.mem.Allocator,

        pub fn run(self: @This(), cursor: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
            var values = std.ArrayList(u64){};
            defer values.deinit(self.allocator);

            // create list
            for (0..original_size) |i| {
                const n = i * 2;
                try values.append(self.allocator, n);
                _ = try cursor.writePath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("even") } },
                    .linked_array_list_init,
                    .linked_array_list_append,
                    .{ .write = .{ .uint = n } },
                });
            }

            // slice list
            const even_list_cursor = (try cursor.readPath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("even") } },
            })).?;
            var even_list_slice_cursor = try cursor.writePath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("even-slice") } },
                .{ .write = .{ .slot = even_list_cursor.slot_ptr.slot } },
                .linked_array_list_init,
                .{ .linked_array_list_slice = .{ .offset = slice_offset, .size = slice_size } },
            });

            // check all values in the new slice
            for (values.items[slice_offset .. slice_offset + slice_size], 0..) |val, i| {
                const n = (try cursor.readPath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("even-slice") } },
                    .{ .linked_array_list_get = i },
                })).?.slot_ptr.slot.value;
                try std.testing.expectEqual(val, n);
            }

            // check all values in the new slice with an iterator
            {
                var iter = try even_list_slice_cursor.iterator();
                var i: u64 = 0;
                while (try iter.next()) |num_cursor| {
                    try std.testing.expectEqual(values.items[slice_offset + i], try num_cursor.readUint());
                    i += 1;
                }
                try std.testing.expectEqual(slice_size, i);
            }

            // there are no extra items
            try std.testing.expectEqual(null, try cursor.readPath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("even-slice") } },
                .{ .linked_array_list_get = slice_size },
            }));

            // concat the slice with itself
            _ = try cursor.writePath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("combo") } },
                .{ .write = .{ .slot = even_list_slice_cursor.slot_ptr.slot } },
                .linked_array_list_init,
                .{ .linked_array_list_concat = .{ .list = even_list_slice_cursor.slot_ptr.slot } },
            });

            // check all values in the combo list
            var combo_values = std.ArrayList(u64){};
            defer combo_values.deinit(self.allocator);
            try combo_values.appendSlice(self.allocator, values.items[slice_offset .. slice_offset + slice_size]);
            try combo_values.appendSlice(self.allocator, values.items[slice_offset .. slice_offset + slice_size]);
            for (combo_values.items, 0..) |val, i| {
                const n = (try cursor.readPath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("combo") } },
                    .{ .linked_array_list_get = i },
                })).?.slot_ptr.slot.value;
                try std.testing.expectEqual(val, n);
            }

            // append to the slice
            _ = try cursor.writePath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("even-slice") } },
                .linked_array_list_init,
                .linked_array_list_append,
                .{ .write = .{ .uint = 3 } },
            });

            // read the new value from the slice
            try std.testing.expectEqual(3, (try cursor.readPath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("even-slice") } },
                .{ .linked_array_list_get = -1 },
            })).?.slot_ptr.slot.value);
        }
    };
    _ = try root_cursor.writePath(Ctx, &.{
        .array_list_init,
        .array_list_append,
        .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
        .{ .hash_map_init = .{} },
        .{ .ctx = .{ .allocator = allocator } },
    });
}

fn testConcat(allocator: std.mem.Allocator, comptime db_kind: xitdb.DatabaseKind, init_opts: xitdb.InitOpts(db_kind), comptime list_a_size: usize, comptime list_b_size: usize) !void {
    try clearStorage(db_kind, init_opts);
    var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
    var root_cursor = db.rootCursor();

    var values = std.ArrayList(u64){};
    defer values.deinit(allocator);

    {
        const Ctx = struct {
            allocator: std.mem.Allocator,
            values: *std.ArrayList(u64),

            pub fn run(self: @This(), cursor: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
                // create even list
                _ = try cursor.writePath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("even") } },
                    .linked_array_list_init,
                });
                for (0..list_a_size) |i| {
                    const n = i * 2;
                    try self.values.append(self.allocator, n);
                    _ = try cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .value = hashInt("even") } },
                        .linked_array_list_init,
                        .linked_array_list_append,
                        .{ .write = .{ .uint = n } },
                    });
                }

                // create odd list
                _ = try cursor.writePath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("odd") } },
                    .linked_array_list_init,
                });
                for (0..list_b_size) |i| {
                    const n = (i * 2) + 1;
                    try self.values.append(self.allocator, n);
                    _ = try cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .value = hashInt("odd") } },
                        .linked_array_list_init,
                        .linked_array_list_append,
                        .{ .write = .{ .uint = n } },
                    });
                }
            }
        };
        _ = try root_cursor.writePath(Ctx, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .ctx = .{ .allocator = allocator, .values = &values } },
        });
    }

    {
        const Ctx = struct {
            allocator: std.mem.Allocator,
            values: *std.ArrayList(u64),

            pub fn run(self: @This(), cursor: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
                // get even list
                const even_list_cursor = (try cursor.readPath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("even") } },
                })).?;

                // get odd list
                const odd_list_cursor = (try cursor.readPath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("odd") } },
                })).?;

                // concat the lists
                const combo_list_cursor = try cursor.writePath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("combo") } },
                    .{ .write = .{ .slot = even_list_cursor.slot_ptr.slot } },
                    .linked_array_list_init,
                    .{ .linked_array_list_concat = .{ .list = odd_list_cursor.slot_ptr.slot } },
                });

                // check all values in the new list
                for (self.values.items, 0..) |val, i| {
                    const n = (try cursor.readPath(void, &.{
                        .{ .hash_map_get = .{ .value = hashInt("combo") } },
                        .{ .linked_array_list_get = i },
                    })).?.slot_ptr.slot.value;
                    try std.testing.expectEqual(val, n);
                }

                // check all values in the new list with an iterator
                {
                    var iter = try combo_list_cursor.iterator();
                    var i: u64 = 0;
                    while (try iter.next()) |num_cursor| {
                        try std.testing.expectEqual(self.values.items[i], try num_cursor.readUint());
                        i += 1;
                    }
                    try std.testing.expectEqual(try even_list_cursor.count() + try odd_list_cursor.count(), i);
                }

                // there are no extra items
                try std.testing.expectEqual(null, try cursor.readPath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("combo") } },
                    .{ .linked_array_list_get = self.values.items.len },
                }));
            }
        };
        _ = try root_cursor.writePath(Ctx, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .ctx = .{ .allocator = allocator, .values = &values } },
        });
    }
}

fn testInsertAndRemove(allocator: std.mem.Allocator, comptime db_kind: xitdb.DatabaseKind, init_opts: xitdb.InitOpts(db_kind), comptime original_size: usize, comptime insert_index: u64) !void {
    try clearStorage(db_kind, init_opts);
    var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
    var root_cursor = db.rootCursor();

    const insert_value: u64 = 12345;

    const InsertCtx = struct {
        allocator: std.mem.Allocator,

        pub fn run(self: @This(), cursor: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
            var values = std.ArrayList(u64){};
            defer values.deinit(self.allocator);

            // create list
            for (0..original_size) |i| {
                if (i == insert_index) {
                    try values.append(self.allocator, insert_value);
                }
                const n = i * 2;
                try values.append(self.allocator, n);
                _ = try cursor.writePath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("even") } },
                    .linked_array_list_init,
                    .linked_array_list_append,
                    .{ .write = .{ .uint = n } },
                });
            }

            // insert into list
            const even_list_cursor = (try cursor.readPath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("even") } },
            })).?;
            var even_list_insert_cursor = try cursor.writePath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("even-insert") } },
                .{ .write = .{ .slot = even_list_cursor.slot_ptr.slot } },
                .linked_array_list_init,
            });
            _ = try even_list_insert_cursor.writePath(void, &.{
                .{ .linked_array_list_insert = insert_index },
                .{ .write = .{ .uint = insert_value } },
            });

            // check all values in the new list
            for (values.items, 0..) |val, i| {
                const n = (try cursor.readPath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("even-insert") } },
                    .{ .linked_array_list_get = i },
                })).?.slot_ptr.slot.value;
                try std.testing.expectEqual(val, n);
            }

            // check all values in the new list with an iterator
            {
                var iter = try even_list_insert_cursor.iterator();
                var i: u64 = 0;
                while (try iter.next()) |num_cursor| {
                    try std.testing.expectEqual(values.items[i], try num_cursor.readUint());
                    i += 1;
                }
                try std.testing.expectEqual(values.items.len, i);
            }

            // there are no extra items
            try std.testing.expectEqual(null, try cursor.readPath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("even-insert") } },
                .{ .linked_array_list_get = values.items.len },
            }));
        }
    };
    _ = try root_cursor.writePath(InsertCtx, &.{
        .array_list_init,
        .array_list_append,
        .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
        .{ .hash_map_init = .{} },
        .{ .ctx = .{ .allocator = allocator } },
    });

    const RemoveCtx = struct {
        allocator: std.mem.Allocator,

        pub fn run(self: @This(), cursor: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
            var values = std.ArrayList(u64){};
            defer values.deinit(self.allocator);

            for (0..original_size) |i| {
                const n = i * 2;
                try values.append(self.allocator, n);
            }

            // remove inserted value from the list
            const even_list_insert_cursor = try cursor.writePath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("even-insert") } },
                .{ .linked_array_list_remove = insert_index },
            });

            // check all values in the new list
            for (values.items, 0..) |val, i| {
                const n = (try cursor.readPath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("even-insert") } },
                    .{ .linked_array_list_get = i },
                })).?.slot_ptr.slot.value;
                try std.testing.expectEqual(val, n);
            }

            // check all values in the new list with an iterator
            {
                var iter = try even_list_insert_cursor.iterator();
                var i: u64 = 0;
                while (try iter.next()) |num_cursor| {
                    try std.testing.expectEqual(values.items[i], try num_cursor.readUint());
                    i += 1;
                }
                try std.testing.expectEqual(values.items.len, i);
            }

            // there are no extra items
            try std.testing.expectEqual(null, try cursor.readPath(void, &.{
                .{ .hash_map_get = .{ .value = hashInt("even-insert") } },
                .{ .linked_array_list_get = values.items.len },
            }));
        }
    };
    _ = try root_cursor.writePath(RemoveCtx, &.{
        .array_list_init,
        .array_list_append,
        .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
        .{ .hash_map_init = .{} },
        .{ .ctx = .{ .allocator = allocator } },
    });
}

fn testLowLevelApi(allocator: std.mem.Allocator, comptime db_kind: xitdb.DatabaseKind, init_opts: xitdb.InitOpts(db_kind)) !void {
    // open and re-open empty database
    {
        // make empty database
        try clearStorage(db_kind, init_opts);
        _ = try xitdb.Database(db_kind, HashInt).init(init_opts);

        // re-open without error
        var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
        var writer = db.core.writer();

        // modify the magic number
        try writer.seekTo(0);
        try writer.interface.writeInt(u8, 'g', .big);
        try db.core.flush();

        // re-open with error
        {
            const db_or_error = xitdb.Database(db_kind, HashInt).init(init_opts);
            if (db_or_error) |_| {
                return error.ExpectedInvalidDatabaseError;
            } else |err| {
                try std.testing.expectEqual(error.InvalidDatabase, err);
            }
        }

        // modify the version
        try writer.seekTo(0);
        try writer.interface.writeInt(u8, 'x', .big);
        try writer.seekTo(4);
        try writer.interface.writeInt(u16, xitdb.VERSION + 1, .big);
        try db.core.flush();

        // re-open with error
        {
            const db_or_error = xitdb.Database(db_kind, HashInt).init(init_opts);
            if (db_or_error) |_| {
                return error.ExpectedInvalidVersionError;
            } else |err| {
                try std.testing.expectEqual(error.InvalidVersion, err);
            }
        }
    }

    // save hash id in header
    {
        var init_opts_with_hash_id = init_opts;
        init_opts_with_hash_id.hash_id = .fromBytes("sha1");

        // make empty database
        try clearStorage(db_kind, init_opts);
        _ = try xitdb.Database(db_kind, HashInt).init(init_opts_with_hash_id);

        // read header without initializing database
        const header = blk: switch (db_kind) {
            .memory => {
                var reader = std.Io.Reader.fixed(init_opts.buffer.written());
                break :blk try xitdb.DatabaseHeader.read(&reader);
            },
            .file, .buffered_file => {
                var reader = init_opts.file.reader(&.{});
                break :blk try xitdb.DatabaseHeader.read(&reader.interface);
            },
        };
        try std.testing.expectEqual(20, header.hash_size);
        try std.testing.expectEqualStrings("sha1", &header.hash_id.toBytes());

        // determine the hashing algorithm
        const HashAlgo = enum { sha1, sha256, sha512 };
        const hash_algo: HashAlgo = switch (header.hash_id.id) {
            xitdb.HashId.fromBytes("sha1").id => .sha1,
            xitdb.HashId.fromBytes("sha2").id => switch (header.hash_size) {
                32 => .sha256,
                64 => .sha512,
                else => return error.InvalidHashSize,
            },
            else => return error.InvalidHashAlgo,
        };
        try std.testing.expectEqual(.sha1, hash_algo);
    }

    // array_list of hash_maps
    {
        try clearStorage(db_kind, init_opts);
        var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
        var root_cursor = db.rootCursor();

        // write foo -> bar with a writer
        const foo_key = hashInt("foo");
        {
            const Ctx = struct {
                pub fn run(_: @This(), cursor: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
                    try std.testing.expect(cursor.slot().tag == .none);
                    var writer = try cursor.writer(&.{});
                    try writer.interface.writeAll("bar");
                    try writer.finish();
                }
            };
            _ = try root_cursor.writePath(Ctx, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = foo_key } },
                .{ .ctx = Ctx{} },
            });
        }

        // read foo
        {
            var bar_cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = foo_key } },
            })).?;
            try std.testing.expectEqual(3, bar_cursor.count());
            const bar_value = try bar_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(bar_value);
            try std.testing.expectEqualStrings("bar", bar_value);
        }

        // read foo from ctx
        {
            const Ctx = struct {
                allocator: std.mem.Allocator,

                pub fn run(self: @This(), cursor: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
                    try std.testing.expect(cursor.slot().tag != .none);

                    const value = try cursor.readBytesAlloc(self.allocator, MAX_READ_BYTES);
                    defer self.allocator.free(value);
                    try std.testing.expectEqualStrings("bar", value);

                    var read_buffer: [1024]u8 = undefined;
                    var bar_reader = try cursor.reader(&read_buffer);

                    // read into buffer
                    var bar_bytes = [_]u8{0} ** 10;
                    try bar_reader.interface.readSliceAll(bar_bytes[0..3]);
                    try std.testing.expectEqualStrings("bar", bar_bytes[0..3]);
                    try bar_reader.seekTo(0);
                    try std.testing.expectEqual(3, try bar_reader.interface.readSliceShort(&bar_bytes));
                    try std.testing.expectEqualStrings("bar", bar_bytes[0..3]);

                    // read one char at a time
                    {
                        var char = [_]u8{0} ** 1;
                        try bar_reader.seekTo(0);

                        try bar_reader.interface.readSliceAll(&char);
                        try std.testing.expectEqualStrings("b", &char);

                        try bar_reader.interface.readSliceAll(&char);
                        try std.testing.expectEqualStrings("a", &char);

                        try bar_reader.interface.readSliceAll(&char);
                        try std.testing.expectEqualStrings("r", &char);

                        try std.testing.expectEqual(error.EndOfStream, bar_reader.interface.readSliceAll(&char));

                        try bar_reader.seekTo(1);
                        try std.testing.expectEqual('a', try bar_reader.interface.takeInt(u8, .big));

                        try bar_reader.seekTo(0);
                        try std.testing.expectEqual('b', try bar_reader.interface.takeInt(u8, .big));
                    }
                }
            };
            _ = try root_cursor.writePath(Ctx, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = foo_key } },
                .{ .ctx = Ctx{ .allocator = allocator } },
            });
        }

        // overwrite foo -> baz
        {
            const Ctx = struct {
                allocator: std.mem.Allocator,

                pub fn run(self: @This(), cursor: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
                    try std.testing.expect(cursor.slot().tag != .none);

                    var write_buffer: [1024]u8 = undefined;
                    var writer = try cursor.writer(&write_buffer);
                    try writer.interface.writeAll("x");
                    try writer.interface.writeAll("x");
                    try writer.interface.writeAll("x");
                    try writer.seekTo(0);
                    try writer.interface.writeAll("b");
                    try writer.seekTo(2);
                    try writer.interface.writeAll("z");
                    try writer.seekTo(1);
                    try writer.interface.writeAll("a");
                    try writer.finish();

                    const value = try cursor.readBytesAlloc(self.allocator, MAX_READ_BYTES);
                    defer self.allocator.free(value);
                    try std.testing.expectEqualStrings("baz", value);
                }
            };
            _ = try root_cursor.writePath(Ctx, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = foo_key } },
                .{ .ctx = Ctx{ .allocator = allocator } },
            });
        }

        // if error in ctx, db doesn't change
        {
            const size_before = try db.core.length();

            const Ctx = struct {
                allocator: std.mem.Allocator,

                pub fn run(_: @This(), cursor: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
                    var writer = try cursor.writer(&.{});
                    try writer.interface.writeAll("this value won't be visible");
                    try writer.finish();
                    return error.CancelTransaction;
                }
            };
            _ = root_cursor.writePath(Ctx, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = foo_key } },
                .{ .ctx = Ctx{ .allocator = allocator } },
            }) catch |err| switch (err) {
                error.CancelTransaction => {},
                else => |e| return e,
            };

            // read foo
            const value_cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = foo_key } },
            })).?;
            const value = try value_cursor.readBytesAlloc(allocator, null); // make sure null max size works
            defer allocator.free(value);
            try std.testing.expectEqualStrings("baz", value);

            // verify that the db is properly truncated back to its original size after error
            const size_after = try db.core.length();
            try std.testing.expectEqual(size_before, size_after);
        }

        // write bar -> longstring
        const bar_key = hashInt("bar");
        {
            var bar_cursor = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = bar_key } },
            });
            try bar_cursor.write(.{ .bytes = "longstring" });

            // the slot tag is .bytes because the byte array is > 8 bytes long
            try std.testing.expectEqual(.bytes, bar_cursor.slot().tag);

            // writing again returns the same slot
            {
                var next_bar_cursor = try root_cursor.writePath(void, &.{
                    .array_list_init,
                    .array_list_append,
                    .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                    .{ .hash_map_init = .{} },
                    .{ .hash_map_get = .{ .value = bar_key } },
                });
                try next_bar_cursor.writeIfEmpty(.{ .bytes = "longstring" });
                try std.testing.expectEqual(bar_cursor.slot_ptr.slot, next_bar_cursor.slot_ptr.slot);
            }

            // writing with write returns a new slot
            {
                var next_bar_cursor = try root_cursor.writePath(void, &.{
                    .array_list_init,
                    .array_list_append,
                    .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                    .{ .hash_map_init = .{} },
                    .{ .hash_map_get = .{ .value = bar_key } },
                });
                try next_bar_cursor.write(.{ .bytes = "longstring" });
                try std.testing.expect(!bar_cursor.slot_ptr.slot.eql(next_bar_cursor.slot_ptr.slot));
            }

            // read bar
            {
                const read_bar_cursor = (try root_cursor.readPath(void, &.{
                    .{ .array_list_get = -1 },
                    .{ .hash_map_get = .{ .value = bar_key } },
                })).?;
                const bar_value = try read_bar_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
                defer allocator.free(bar_value);
                try std.testing.expectEqualStrings("longstring", bar_value);
            }
        }

        // write bar -> shortstr
        {
            var bar_cursor = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = bar_key } },
            });
            try bar_cursor.write(.{ .bytes = "shortstr" });

            // the slot tag is .short_bytes because the byte array is <= 8 bytes long
            try std.testing.expectEqual(.short_bytes, bar_cursor.slot().tag);
            try std.testing.expectEqual(8, try bar_cursor.count());

            // make sure .short_bytes can be read with a reader
            var bar_reader = try bar_cursor.reader(&.{});
            const bar_value = try bar_reader.interface.allocRemaining(allocator, @enumFromInt(MAX_READ_BYTES));
            defer allocator.free(bar_value);
            try std.testing.expectEqualStrings("shortstr", bar_value);
        }

        // write bytes with a format tag
        {
            // shortstr
            {
                var bar_cursor = try root_cursor.writePath(void, &.{
                    .array_list_init,
                    .array_list_append,
                    .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                    .{ .hash_map_init = .{} },
                    .{ .hash_map_get = .{ .value = bar_key } },
                });
                try bar_cursor.write(.{ .bytes_object = .{ .value = "shortstr", .format_tag = "st".* } });

                // the slot tag is .bytes because the byte array is > 8 bytes long including the format tag
                try std.testing.expectEqual(.bytes, bar_cursor.slot().tag);
                try std.testing.expectEqual(8, try bar_cursor.count());

                // read bar
                const read_bar_cursor = (try root_cursor.readPath(void, &.{
                    .{ .array_list_get = -1 },
                    .{ .hash_map_get = .{ .value = bar_key } },
                })).?;
                const bytes = try read_bar_cursor.readBytesObjectAlloc(allocator, MAX_READ_BYTES);
                defer allocator.free(bytes.value);
                try std.testing.expectEqualStrings("shortstr", bytes.value);
                try std.testing.expectEqualStrings("st", &bytes.format_tag.?);

                // make sure .bytes can be read with a reader
                var bar_reader = try bar_cursor.reader(&.{});
                const bar_value = try bar_reader.interface.allocRemaining(allocator, @enumFromInt(MAX_READ_BYTES));
                defer allocator.free(bar_value);
                try std.testing.expectEqualStrings("shortstr", bar_value);
            }

            // shorts
            {
                var bar_cursor = try root_cursor.writePath(void, &.{
                    .array_list_init,
                    .array_list_append,
                    .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                    .{ .hash_map_init = .{} },
                    .{ .hash_map_get = .{ .value = bar_key } },
                });
                try bar_cursor.write(.{ .bytes_object = .{ .value = "shorts", .format_tag = "st".* } });

                // the slot tag is .short_bytes because the byte array is <= 8 bytes long including the format tag
                try std.testing.expectEqual(.short_bytes, bar_cursor.slot().tag);
                try std.testing.expectEqual(6, try bar_cursor.count());

                // read bar
                const read_bar_cursor = (try root_cursor.readPath(void, &.{
                    .{ .array_list_get = -1 },
                    .{ .hash_map_get = .{ .value = bar_key } },
                })).?;
                var buffer = [_]u8{0} ** MAX_READ_BYTES;
                const bytes = try read_bar_cursor.readBytesObject(&buffer);
                try std.testing.expectEqualStrings("shorts", bytes.value);
                try std.testing.expectEqualStrings("st", &bytes.format_tag.?);

                // make sure .short_bytes can be read with a reader
                var bar_reader = try bar_cursor.reader(&.{});
                const bar_value = try bar_reader.interface.allocRemaining(allocator, @enumFromInt(MAX_READ_BYTES));
                defer allocator.free(bar_value);
                try std.testing.expectEqualStrings("shorts", bar_value);
            }

            // short
            {
                var bar_cursor = try root_cursor.writePath(void, &.{
                    .array_list_init,
                    .array_list_append,
                    .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                    .{ .hash_map_init = .{} },
                    .{ .hash_map_get = .{ .value = bar_key } },
                });
                try bar_cursor.write(.{ .bytes_object = .{ .value = "short", .format_tag = "st".* } });

                // the slot tag is .short_bytes because the byte array is <= 8 bytes long including the format tag
                try std.testing.expectEqual(.short_bytes, bar_cursor.slot().tag);
                try std.testing.expectEqual(5, try bar_cursor.count());

                // read bar
                const read_bar_cursor = (try root_cursor.readPath(void, &.{
                    .{ .array_list_get = -1 },
                    .{ .hash_map_get = .{ .value = bar_key } },
                })).?;
                var buffer = [_]u8{0} ** MAX_READ_BYTES;
                const bytes = try read_bar_cursor.readBytesObject(&buffer);
                try std.testing.expectEqualStrings("short", bytes.value);
                try std.testing.expectEqualStrings("st", &bytes.format_tag.?);

                // make sure .short_bytes can be read with a reader
                var bar_reader = try bar_cursor.reader(&.{});
                const bar_value = try bar_reader.interface.allocRemaining(allocator, @enumFromInt(MAX_READ_BYTES));
                defer allocator.free(bar_value);
                try std.testing.expectEqualStrings("short", bar_value);
            }
        }

        // read foo into stack-allocated buffer
        {
            const bar_cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = foo_key } },
            })).?;
            var bar_buffer = [_]u8{0} ** 3;
            const bar_buffer_value = try bar_cursor.readBytes(&bar_buffer);
            try std.testing.expectEqualStrings("baz", bar_buffer_value);
        }

        // write bar and get slot to it
        const bar_slot = (try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .hash_map_get = .{ .value = bar_key } },
            .{ .write = .{ .bytes = "bar" } },
        })).slot_ptr.slot;

        // overwrite foo -> bar using the bar slot
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .hash_map_get = .{ .value = foo_key } },
            .{ .write = .{ .slot = bar_slot } },
        });
        const bar_cursor = (try root_cursor.readPath(void, &.{
            .{ .array_list_get = -1 },
            .{ .hash_map_get = .{ .value = foo_key } },
        })).?;
        const bar_value = try bar_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(bar_value);
        try std.testing.expectEqualStrings("bar", bar_value);

        // can still read the old value
        const baz_cursor = (try root_cursor.readPath(void, &.{
            .{ .array_list_get = -2 },
            .{ .hash_map_get = .{ .value = foo_key } },
        })).?;
        const baz_value = try baz_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(baz_value);
        try std.testing.expectEqualStrings("baz", baz_value);

        // key not found
        const not_found_key = hashInt("this doesn't exist");
        try std.testing.expectEqual(null, try root_cursor.readPath(void, &.{
            .{ .array_list_get = -1 },
            .{ .hash_map_get = .{ .value = not_found_key } },
        }));

        // write key that conflicts with foo the first two bytes
        const small_conflict_mask: u64 = 0b1111_1111;
        const small_conflict_key = (hashInt("small conflict") & ~small_conflict_mask) | (foo_key & small_conflict_mask);
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .hash_map_get = .{ .value = small_conflict_key } },
            .{ .write = .{ .bytes = "small" } },
        });

        // write key that conflicts with foo the first four bytes
        const conflict_mask: u64 = 0b1111_1111_1111_1111;
        const conflict_key = (hashInt("conflict") & ~conflict_mask) | (foo_key & conflict_mask);
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .hash_map_get = .{ .value = conflict_key } },
            .{ .write = .{ .bytes = "hello" } },
        });

        // read conflicting key
        const hello_cursor = (try root_cursor.readPath(void, &.{
            .{ .array_list_get = -1 },
            .{ .hash_map_get = .{ .value = conflict_key } },
        })).?;
        const hello_value = try hello_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(hello_value);
        try std.testing.expectEqualStrings("hello", hello_value);

        // we can still read foo
        const bar_cursor2 = (try root_cursor.readPath(void, &.{
            .{ .array_list_get = -1 },
            .{ .hash_map_get = .{ .value = foo_key } },
        })).?;
        const bar_value2 = try bar_cursor2.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(bar_value2);
        try std.testing.expectEqualStrings("bar", bar_value2);

        // overwrite conflicting key
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .hash_map_get = .{ .value = conflict_key } },
            .{ .write = .{ .bytes = "goodbye" } },
        });
        const goodbye_cursor = (try root_cursor.readPath(void, &.{
            .{ .array_list_get = -1 },
            .{ .hash_map_get = .{ .value = conflict_key } },
        })).?;
        const goodbye_value = try goodbye_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(goodbye_value);
        try std.testing.expectEqualStrings("goodbye", goodbye_value);

        // we can still read the old conflicting key
        const hello_cursor2 = (try root_cursor.readPath(void, &.{
            .{ .array_list_get = -2 },
            .{ .hash_map_get = .{ .value = conflict_key } },
        })).?;
        const hello_value2 = try hello_cursor2.readBytesAlloc(allocator, MAX_READ_BYTES);
        defer allocator.free(hello_value2);
        try std.testing.expectEqualStrings("hello", hello_value2);

        // remove the conflicting keys
        {
            // foo's slot is an .index slot due to the conflict
            {
                const map_cursor = (try root_cursor.readPath(void, &.{
                    .{ .array_list_get = -1 },
                })).?;
                const index_pos = map_cursor.slot().value;
                try std.testing.expectEqual(.hash_map, map_cursor.slot().tag);

                var reader = db.core.reader();
                const slot_size: u64 = @bitSizeOf(xitdb.Slot) / 8;

                const i: u4 = @intCast(foo_key & xitdb.MASK);
                const slot_pos = index_pos + (slot_size * i);
                try reader.seekTo(slot_pos);
                const slot: xitdb.Slot = @bitCast(try takeInt(&reader.interface, u72, .big));

                try std.testing.expectEqual(.index, slot.tag);
            }

            // remove the small conflict key
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_remove = small_conflict_key },
            });

            // the conflict key still exists in history
            try std.testing.expect(null != try root_cursor.readPath(void, &.{
                .{ .array_list_get = -2 },
                .{ .hash_map_get = .{ .value = small_conflict_key } },
            }));

            // the conflict key doesn't exist in the latest moment
            try std.testing.expectEqual(null, try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = small_conflict_key } },
            }));

            // the other conflict key still exists
            try std.testing.expect(null != try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = conflict_key } },
            }));

            // foo's slot is still an .index slot due to the other conflicting key
            {
                const map_cursor = (try root_cursor.readPath(void, &.{
                    .{ .array_list_get = -1 },
                })).?;
                const index_pos = map_cursor.slot().value;
                try std.testing.expectEqual(.hash_map, map_cursor.slot().tag);

                var reader = db.core.reader();
                const slot_size: u64 = @bitSizeOf(xitdb.Slot) / 8;

                const i: u4 = @intCast(foo_key & xitdb.MASK);
                const slot_pos = index_pos + (slot_size * i);
                try reader.seekTo(slot_pos);
                const slot: xitdb.Slot = @bitCast(try takeInt(&reader.interface, u72, .big));

                try std.testing.expectEqual(.index, slot.tag);
            }

            // remove the conflict key
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_remove = conflict_key },
            });

            // the conflict keys don't exist in the latest moment
            try std.testing.expectEqual(null, try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = small_conflict_key } },
            }));
            try std.testing.expectEqual(null, try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = conflict_key } },
            }));

            // foo's slot is now a .kv_pair slot, because the branch was shortened
            {
                const map_cursor = (try root_cursor.readPath(void, &.{
                    .{ .array_list_get = -1 },
                })).?;
                const index_pos = map_cursor.slot().value;
                try std.testing.expectEqual(.hash_map, map_cursor.slot().tag);

                var reader = db.core.reader();
                const slot_size: u64 = @bitSizeOf(xitdb.Slot) / 8;

                const i: u4 = @intCast(foo_key & xitdb.MASK);
                const slot_pos = index_pos + (slot_size * i);
                try reader.seekTo(slot_pos);
                const slot: xitdb.Slot = @bitCast(try takeInt(&reader.interface, u72, .big));

                try std.testing.expectEqual(.kv_pair, slot.tag);
            }
        }

        {
            // overwrite foo with a uint
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = foo_key } },
                .{ .write = .{ .uint = 42 } },
            });

            // read foo
            const uint_value = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = foo_key } },
            })).?.readUint();
            try std.testing.expectEqual(42, uint_value);
        }

        {
            // overwrite foo with an int
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = foo_key } },
                .{ .write = .{ .int = -42 } },
            });

            // read foo
            const int_value = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = foo_key } },
            })).?.readInt();
            try std.testing.expectEqual(-42, int_value);
        }

        {
            // overwrite foo with a float
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = foo_key } },
                .{ .write = .{ .float = 42.5 } },
            });

            // read foo
            const float_value = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = foo_key } },
            })).?.readFloat();
            try std.testing.expectEqual(42.5, float_value);
        }

        // remove foo
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .hash_map_remove = foo_key },
        });

        // remove key that does not exist
        try std.testing.expectError(error.KeyNotFound, root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .hash_map_remove = hashInt("doesn't exist") },
        }));

        // make sure foo doesn't exist anymore
        try std.testing.expectEqual(null, try root_cursor.readPath(void, &.{
            .{ .array_list_get = -1 },
            .{ .hash_map_get = .{ .value = foo_key } },
        }));

        // non-top-level list
        {
            // write apple
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = hashInt("fruits") } },
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .bytes = "apple" } },
            });

            // read apple
            const apple_cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = hashInt("fruits") } },
                .{ .array_list_get = -1 },
            })).?;
            const apple_value = try apple_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(apple_value);
            try std.testing.expectEqualStrings("apple", apple_value);

            // write banana
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = hashInt("fruits") } },
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .bytes = "banana" } },
            });

            // read banana
            const banana_cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = hashInt("fruits") } },
                .{ .array_list_get = -1 },
            })).?;
            const banana_value = try banana_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(banana_value);
            try std.testing.expectEqualStrings("banana", banana_value);

            // can't read banana in older array_list
            try std.testing.expectEqual(null, try root_cursor.readPath(void, &.{
                .{ .array_list_get = -2 },
                .{ .hash_map_get = .{ .value = hashInt("fruits") } },
                .{ .array_list_get = 1 },
            }));

            // write pear
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = hashInt("fruits") } },
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .bytes = "pear" } },
            });

            // write grape
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = hashInt("fruits") } },
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .bytes = "grape" } },
            });

            // read pear
            const pear_cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = hashInt("fruits") } },
                .{ .array_list_get = -2 },
            })).?;
            const pear_value = try pear_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(pear_value);
            try std.testing.expectEqualStrings("pear", pear_value);

            // read grape
            const grape_cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = hashInt("fruits") } },
                .{ .array_list_get = -1 },
            })).?;
            const grape_value = try grape_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(grape_value);
            try std.testing.expectEqualStrings("grape", grape_value);
        }
    }

    // append to top-level array_list many times, filling up the array_list until a root overflow occurs
    {
        try clearStorage(db_kind, init_opts);
        var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
        var root_cursor = db.rootCursor();

        const wat_key = hashInt("wat");
        for (0..xitdb.SLOT_COUNT + 1) |i| {
            const value = try std.fmt.allocPrint(allocator, "wat{}", .{i});
            defer allocator.free(value);
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = wat_key } },
                .{ .write = .{ .bytes = value } },
            });
        }

        for (0..xitdb.SLOT_COUNT + 1) |i| {
            const value = try std.fmt.allocPrint(allocator, "wat{}", .{i});
            defer allocator.free(value);
            const cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = i },
                .{ .hash_map_get = .{ .value = wat_key } },
            })).?;
            const value2 = try cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(value2);
            try std.testing.expectEqualStrings(value, value2);
        }

        // add more slots to cause a new index block to be created.
        // a new index block will be created when i == 32 (the 33rd append).
        // during that transaction, return an error so the transaction is
        // cancelled, causing truncation to happen. this test ensures that
        // the new index block is NOT truncated. this is prevented by updating
        // the file size in the header immediately after making a new index block.
        // see `readArrayListSlot` for more.
        {
            for (xitdb.SLOT_COUNT + 1..xitdb.SLOT_COUNT * 2 + 1) |i| {
                const value = try std.fmt.allocPrint(allocator, "wat{}", .{i});
                defer allocator.free(value);

                const Ctx = struct {
                    i: usize,
                    pub fn run(self: @This(), _: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
                        if (self.i == 32) {
                            return error.Fail;
                        }
                    }
                };
                _ = root_cursor.writePath(Ctx, &.{
                    .array_list_init,
                    .array_list_append,
                    .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                    .{ .hash_map_init = .{} },
                    .{ .hash_map_get = .{ .value = wat_key } },
                    .{ .write = .{ .bytes = value } },
                    .{ .ctx = .{ .i = i } },
                }) catch |err| switch (err) {
                    error.Fail => break,
                    else => |e| return e,
                };
            } else {
                return error.ExpectedFail;
            }

            // try another append to make sure we still can.
            // if truncation destroyed the index block, this would fail.
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = wat_key } },
                .{ .write = .{ .bytes = "wat32" } },
            });
        }

        // slice so it contains exactly SLOT_COUNT,
        // so we have the old root again
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .{ .array_list_slice = .{ .size = xitdb.SLOT_COUNT } },
        });

        // we can iterate over the remaining slots
        for (0..xitdb.SLOT_COUNT) |i| {
            const value = try std.fmt.allocPrint(allocator, "wat{}", .{i});
            defer allocator.free(value);
            const cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = i },
                .{ .hash_map_get = .{ .value = wat_key } },
            })).?;
            const value2 = try cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(value2);
            try std.testing.expectEqualStrings(value, value2);
        }

        // but we can't get the value that we sliced out of the array list
        try std.testing.expectEqual(null, root_cursor.readPath(void, &.{
            .{ .array_list_get = xitdb.SLOT_COUNT + 1 },
        }));
    }

    // append to inner array_list many times, filling up the array_list until a root overflow occurs
    {
        try clearStorage(db_kind, init_opts);
        var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
        var root_cursor = db.rootCursor();

        for (0..xitdb.SLOT_COUNT + 1) |i| {
            const value = try std.fmt.allocPrint(allocator, "wat{}", .{i});
            defer allocator.free(value);
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .bytes = value } },
            });
        }

        for (0..xitdb.SLOT_COUNT + 1) |i| {
            const value = try std.fmt.allocPrint(allocator, "wat{}", .{i});
            defer allocator.free(value);
            const cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .array_list_get = i },
            })).?;
            const value2 = try cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(value2);
            try std.testing.expectEqualStrings(value, value2);
        }

        // slice inner array list so it contains exactly SLOT_COUNT,
        // so we have the old root again
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .{ .array_list_get = -1 },
            .array_list_init,
            .{ .array_list_slice = .{ .size = xitdb.SLOT_COUNT } },
        });

        // we can iterate over the remaining slots
        for (0..xitdb.SLOT_COUNT) |i| {
            const value = try std.fmt.allocPrint(allocator, "wat{}", .{i});
            defer allocator.free(value);
            const cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .array_list_get = i },
            })).?;
            const value2 = try cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(value2);
            try std.testing.expectEqualStrings(value, value2);
        }

        // but we can't get the value that we sliced out of the array list
        try std.testing.expectEqual(null, root_cursor.readPath(void, &.{
            .{ .array_list_get = -1 },
            .{ .array_list_get = xitdb.SLOT_COUNT + 1 },
        }));

        // overwrite last value with hello
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .array_list_init,
            .{ .array_list_get = -1 },
            .{ .write = .{ .bytes = "hello" } },
        });

        // read last value
        {
            const cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .array_list_get = -1 },
            })).?;
            const value = try cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(value);
            try std.testing.expectEqualStrings("hello", value);
        }

        // overwrite last value with goodbye
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .array_list_init,
            .{ .array_list_get = -1 },
            .{ .write = .{ .bytes = "goodbye" } },
        });

        // read last value
        {
            const cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .array_list_get = -1 },
            })).?;
            const value = try cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(value);
            try std.testing.expectEqualStrings("goodbye", value);
        }

        // previous last value is still hello
        {
            const cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -2 },
                .{ .array_list_get = -1 },
            })).?;
            const value = try cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(value);
            try std.testing.expectEqualStrings("hello", value);
        }
    }

    // iterate over inner array_list
    {
        try clearStorage(db_kind, init_opts);
        var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
        var root_cursor = db.rootCursor();

        // add wats
        for (0..10) |i| {
            const value = try std.fmt.allocPrint(allocator, "wat{}", .{i});
            defer allocator.free(value);
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .bytes = value } },
            });

            const cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .array_list_get = -1 },
            })).?;
            const value2 = try cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(value2);
            try std.testing.expectEqualStrings(value, value2);
        }

        // iterate over array_list
        {
            var inner_cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
            })).?;
            var iter = try inner_cursor.iterator();
            var i: u64 = 0;
            while (try iter.next()) |*next_cursor| {
                const value = try std.fmt.allocPrint(allocator, "wat{}", .{i});
                defer allocator.free(value);
                const value2 = try next_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
                defer allocator.free(value2);
                try std.testing.expectEqualStrings(value, value2);
                i += 1;
            }
            try std.testing.expectEqual(10, i);
        }

        // set first slot to .none and make sure iteration still works.
        // this validates that it correctly returns .none slots if
        // their flag is set, rather than skipping over them.
        {
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .{ .array_list_get = -1 },
                .array_list_init,
                .{ .array_list_get = 0 },
                .{ .write = .{ .slot = null } },
            });
            var inner_cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
            })).?;
            var iter = try inner_cursor.iterator();
            var i: u64 = 0;
            while (try iter.next()) |_| {
                i += 1;
            }
            try std.testing.expectEqual(10, i);
        }

        // get list slot
        const list_cursor = (try root_cursor.readPath(void, &.{
            .{ .array_list_get = -1 },
        })).?;
        try std.testing.expectEqual(10, list_cursor.count());
    }

    // iterate over inner hash_map
    {
        try clearStorage(db_kind, init_opts);
        var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
        var root_cursor = db.rootCursor();

        // add wats
        for (0..10) |i| {
            const value = try std.fmt.allocPrint(allocator, "wat{}", .{i});
            defer allocator.free(value);
            const wat_key = hashInt(value);
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .{ .hash_map_init = .{} },
                .{ .hash_map_get = .{ .value = wat_key } },
                .{ .write = .{ .bytes = value } },
            });

            const cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
                .{ .hash_map_get = .{ .value = wat_key } },
            })).?;
            const value2 = try cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
            defer allocator.free(value2);
            try std.testing.expectEqualStrings(value, value2);
        }

        // add foo
        const foo_key = hashInt("foo");
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .hash_map_get = .{ .key = foo_key } },
            .{ .write = .{ .bytes = "foo" } },
        });
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .hash_map_get = .{ .value = foo_key } },
            .{ .write = .{ .uint = 42 } },
        });

        // remove a wat
        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .hash_map_remove = hashInt("wat0") },
        });

        // iterate over hash_map
        {
            var inner_cursor = (try root_cursor.readPath(void, &.{
                .{ .array_list_get = -1 },
            })).?;
            var iter = try inner_cursor.iterator();
            var i: u64 = 0;
            while (try iter.next()) |kv_pair_cursor| {
                const kv_pair = try kv_pair_cursor.readKeyValuePair();
                if (kv_pair.hash == foo_key) {
                    const key = try kv_pair.key_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
                    defer allocator.free(key);
                    try std.testing.expectEqualStrings("foo", key);
                    try std.testing.expectEqual(42, kv_pair.value_cursor.slot_ptr.slot.value);
                } else {
                    const value = try kv_pair.value_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
                    defer allocator.free(value);
                    try std.testing.expectEqual(kv_pair.hash, hashInt(value));
                }
                i += 1;
            }
            try std.testing.expectEqual(10, i);
        }

        // iterate over hash_map with writeable cursor
        {
            var inner_cursor = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            });
            var iter = try inner_cursor.iterator();
            var i: u64 = 0;
            while (try iter.next()) |kv_pair_cursor| {
                var kv_pair = try kv_pair_cursor.readKeyValuePair();
                if (kv_pair.hash == foo_key) {
                    try kv_pair.key_cursor.write(.{ .bytes = "bar" });
                }
                i += 1;
            }
            try std.testing.expectEqual(10, i);
        }
    }

    {
        // slice linked_array_list
        try testSlice(allocator, db_kind, init_opts, xitdb.SLOT_COUNT * 5 + 1, 10, 5);
        try testSlice(allocator, db_kind, init_opts, xitdb.SLOT_COUNT * 5 + 1, 0, xitdb.SLOT_COUNT * 2);
        try testSlice(allocator, db_kind, init_opts, xitdb.SLOT_COUNT * 5, xitdb.SLOT_COUNT * 3, xitdb.SLOT_COUNT);
        try testSlice(allocator, db_kind, init_opts, xitdb.SLOT_COUNT * 5, xitdb.SLOT_COUNT * 3, xitdb.SLOT_COUNT * 2);
        try testSlice(allocator, db_kind, init_opts, xitdb.SLOT_COUNT * 2, 10, xitdb.SLOT_COUNT);
        try testSlice(allocator, db_kind, init_opts, 2, 0, 2);
        try testSlice(allocator, db_kind, init_opts, 2, 1, 1);
        try testSlice(allocator, db_kind, init_opts, 1, 0, 0);

        // concat linked_array_list
        try testConcat(allocator, db_kind, init_opts, xitdb.SLOT_COUNT * 5 + 1, xitdb.SLOT_COUNT + 1);
        try testConcat(allocator, db_kind, init_opts, xitdb.SLOT_COUNT, xitdb.SLOT_COUNT);
        try testConcat(allocator, db_kind, init_opts, 1, 1);
        try testConcat(allocator, db_kind, init_opts, 0, 0);

        // insert linked_array_list
        try testInsertAndRemove(allocator, db_kind, init_opts, 1, 0);
        try testInsertAndRemove(allocator, db_kind, init_opts, 10, 0);
        try testInsertAndRemove(allocator, db_kind, init_opts, 10, 5);
        try testInsertAndRemove(allocator, db_kind, init_opts, 10, 9);
        try testInsertAndRemove(allocator, db_kind, init_opts, xitdb.SLOT_COUNT * 5, xitdb.SLOT_COUNT * 2);
    }

    // concat linked_array_list multiple times
    {
        try clearStorage(db_kind, init_opts);
        var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
        var root_cursor = db.rootCursor();

        const Ctx = struct {
            allocator: std.mem.Allocator,

            pub fn run(self: @This(), cursor: *xitdb.Database(db_kind, HashInt).Cursor(.read_write)) !void {
                var values = std.ArrayList(u64){};
                defer values.deinit(self.allocator);

                // create list
                for (0..xitdb.SLOT_COUNT + 1) |i| {
                    const n = i * 2;
                    try values.append(self.allocator, n);
                    _ = try cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .value = hashInt("even") } },
                        .linked_array_list_init,
                        .linked_array_list_append,
                        .{ .write = .{ .uint = n } },
                    });
                }

                // get list slot
                const even_list_cursor = (try cursor.readPath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("even") } },
                })).?;
                try std.testing.expectEqual(xitdb.SLOT_COUNT + 1, even_list_cursor.count());

                // iterate over list
                var inner_cursor = (try cursor.readPath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("even") } },
                })).?;
                var iter = try inner_cursor.iterator();
                var i: u64 = 0;
                while (try iter.next()) |_| {
                    i += 1;
                }
                try std.testing.expectEqual(xitdb.SLOT_COUNT + 1, i);

                // concat the list with itself multiple times.
                // since each list has 17 items, each concat
                // will create a gap, causing a root overflow
                // before a normal array list would've.
                var combo_list_cursor = try cursor.writePath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("combo") } },
                    .{ .write = .{ .slot = even_list_cursor.slot_ptr.slot } },
                    .linked_array_list_init,
                });
                for (0..16) |_| {
                    combo_list_cursor = try combo_list_cursor.writePath(void, &.{
                        .{ .linked_array_list_concat = .{ .list = even_list_cursor.slot_ptr.slot } },
                    });
                }

                // append to the new list
                _ = try cursor.writePath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("combo") } },
                    .linked_array_list_append,
                    .{ .write = .{ .uint = 3 } },
                });

                // read the new value from the list
                try std.testing.expectEqual(3, (try cursor.readPath(void, &.{
                    .{ .hash_map_get = .{ .value = hashInt("combo") } },
                    .{ .linked_array_list_get = -1 },
                })).?.slot_ptr.slot.value);

                // append more to the new list
                for (0..500) |_| {
                    _ = try cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .value = hashInt("combo") } },
                        .linked_array_list_append,
                        .{ .write = .{ .uint = 1 } },
                    });
                }
            }
        };
        _ = try root_cursor.writePath(Ctx, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .{ .hash_map_init = .{} },
            .{ .ctx = .{ .allocator = allocator } },
        });
    }

    // append items to linked_array_list without setting their value
    {
        try clearStorage(db_kind, init_opts);
        var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
        var root_cursor = db.rootCursor();

        // appending without setting any value should work
        for (0..8) |_| {
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .linked_array_list_init,
                .linked_array_list_append,
            });
        }

        // explicitly writing a null slot should also work
        for (0..8) |_| {
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .linked_array_list_init,
                .linked_array_list_append,
                .{ .write = .{ .slot = null } },
            });
        }
    }

    // insert at beginning of linked_array_list many times
    {
        try clearStorage(db_kind, init_opts);
        var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
        var root_cursor = db.rootCursor();

        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .linked_array_list_init,
            .linked_array_list_append,
            .{ .write = .{ .uint = 42 } },
        });

        for (0..1_000) |i| {
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .linked_array_list_init,
                .{ .linked_array_list_insert = 0 },
                .{ .write = .{ .uint = i } },
            });
        }
    }

    // insert at end of linked_array_list many times
    {
        try clearStorage(db_kind, init_opts);
        var db = try xitdb.Database(db_kind, HashInt).init(init_opts);
        var root_cursor = db.rootCursor();

        _ = try root_cursor.writePath(void, &.{
            .array_list_init,
            .array_list_append,
            .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
            .linked_array_list_init,
            .linked_array_list_append,
            .{ .write = .{ .uint = 42 } },
        });

        for (0..1_000) |i| {
            _ = try root_cursor.writePath(void, &.{
                .array_list_init,
                .array_list_append,
                .{ .write = .{ .slot = try root_cursor.readPathSlot(void, &.{.{ .array_list_get = -1 }}) } },
                .linked_array_list_init,
                .{ .linked_array_list_insert = i },
                .{ .write = .{ .uint = i } },
            });
        }
    }
}

test "compaction" {
    const allocator = std.testing.allocator;

    // memory
    {
        var source_buffer = std.Io.Writer.Allocating.init(allocator);
        defer source_buffer.deinit();
        var target_buffer = std.Io.Writer.Allocating.init(allocator);
        defer target_buffer.deinit();
        try testCompaction(
            allocator,
            .memory,
            .{ .buffer = &source_buffer, .max_size = 5_000_000 },
            .memory,
            .{ .buffer = &target_buffer, .max_size = 5_000_000 },
        );
    }

    // file
    {
        const source_file = try std.fs.cwd().createFile("compact_source.db", .{ .read = true, .truncate = true });
        defer {
            source_file.close();
            std.fs.cwd().deleteFile("compact_source.db") catch {};
        }
        const target_file = try std.fs.cwd().createFile("compact_target.db", .{ .read = true, .truncate = true });
        defer {
            target_file.close();
            std.fs.cwd().deleteFile("compact_target.db") catch {};
        }
        try testCompaction(
            allocator,
            .file,
            .{ .file = source_file },
            .file,
            .{ .file = target_file },
        );
    }

    // buffered_file
    {
        var source_buffer = std.Io.Writer.Allocating.init(allocator);
        defer source_buffer.deinit();
        var target_buffer = std.Io.Writer.Allocating.init(allocator);
        defer target_buffer.deinit();
        const source_file = try std.fs.cwd().createFile("compact_source.db", .{ .read = true, .truncate = true });
        defer {
            source_file.close();
            std.fs.cwd().deleteFile("compact_source.db") catch {};
        }
        const target_file = try std.fs.cwd().createFile("compact_target.db", .{ .read = true, .truncate = true });
        defer {
            target_file.close();
            std.fs.cwd().deleteFile("compact_target.db") catch {};
        }
        try testCompaction(
            allocator,
            .buffered_file,
            .{ .file = source_file, .buffer = &source_buffer },
            .buffered_file,
            .{ .file = target_file, .buffer = &target_buffer },
        );
    }

    // buffered_file to memory
    {
        var source_buffer = std.Io.Writer.Allocating.init(allocator);
        defer source_buffer.deinit();
        var target_buffer = std.Io.Writer.Allocating.init(allocator);
        defer target_buffer.deinit();
        const source_file = try std.fs.cwd().createFile("compact_source.db", .{ .read = true, .truncate = true });
        defer {
            source_file.close();
            std.fs.cwd().deleteFile("compact_source.db") catch {};
        }
        try testCompaction(
            allocator,
            .buffered_file,
            .{ .file = source_file, .buffer = &source_buffer },
            .memory,
            .{ .buffer = &target_buffer, .max_size = 5_000_000 },
        );
    }
}

fn testCompaction(
    allocator: std.mem.Allocator,
    comptime db_kind: xitdb.DatabaseKind,
    source_opts: xitdb.InitOpts(db_kind),
    comptime target_db_kind: xitdb.DatabaseKind,
    target_opts: xitdb.InitOpts(target_db_kind),
) !void {
    const DB = xitdb.Database(db_kind, HashInt);
    const TargetDB = xitdb.Database(target_db_kind, HashInt);

    // empty DB compaction
    {
        try clearStorage(db_kind, source_opts);
        try clearStorage(target_db_kind, target_opts);
        var source = try DB.init(source_opts);
        var offset_map = std.AutoHashMap(u64, u64).init(allocator);
        defer offset_map.deinit();
        const compacted = try source.compact(target_db_kind, target_opts, &offset_map);
        try std.testing.expectEqual(.none, compacted.header.tag);
    }

    // basic compaction with various data types
    {
        try clearStorage(db_kind, source_opts);
        try clearStorage(target_db_kind, target_opts);
        var source = try DB.init(source_opts);

        // moment 1
        {
            const history = try DB.ArrayList(.read_write).init(source.rootCursor());
            const Ctx1 = struct {
                pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    const moment = try DB.HashMap(.read_write).init(cursor.*);
                    try moment.put(hashInt("key1"), .{ .bytes = "value1" });
                    try moment.put(hashInt("key2"), .{ .uint = 100 });
                }
            };
            try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx1{});
        }

        // moment 2
        {
            const history = try DB.ArrayList(.read_write).init(source.rootCursor());
            const Ctx2 = struct {
                pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    const moment = try DB.HashMap(.read_write).init(cursor.*);
                    try moment.put(hashInt("key1"), .{ .bytes = "updated_value1" });
                    try moment.put(hashInt("key2"), .{ .uint = 200 });
                    try moment.put(hashInt("key3"), .{ .int = -42 });
                    try moment.put(hashInt("key4"), .{ .float = 3.14 });
                    try moment.put(hashInt("short"), .{ .bytes = "hi" });

                    // long bytes with format_tag
                    try moment.put(hashInt("tagged"), .{ .bytes_object = .{ .value = "this is a long tagged string!!", .format_tag = "bi".* } });

                    // ArrayList
                    const fruits_cursor = try moment.putCursor(hashInt("fruits"));
                    const fruits = try DB.ArrayList(.read_write).init(fruits_cursor);
                    try fruits.append(.{ .bytes = "apple" });
                    try fruits.append(.{ .bytes = "banana" });
                    try fruits.append(.{ .bytes = "cherry" });

                    // LinkedArrayList
                    const todos_cursor = try moment.putCursor(hashInt("todos"));
                    const todos = try DB.LinkedArrayList(.read_write).init(todos_cursor);
                    try todos.append(.{ .bytes = "task1" });
                    try todos.append(.{ .bytes = "task2" });
                    try todos.append(.{ .bytes = "task3" });

                    // CountedHashMap
                    const counted_cursor = try moment.putCursor(hashInt("counted"));
                    const counted = try DB.CountedHashMap(.read_write).init(counted_cursor);
                    try counted.put(hashInt("a"), .{ .uint = 1 });
                    try counted.putKey(hashInt("a"), .{ .bytes = "a" });
                    try counted.put(hashInt("b"), .{ .uint = 2 });
                    try counted.putKey(hashInt("b"), .{ .bytes = "b" });

                    // HashSet
                    const set_cursor = try moment.putCursor(hashInt("myset"));
                    const set = try DB.HashSet(.read_write).init(set_cursor);
                    try set.put(hashInt("x"), .{ .bytes = "x" });
                    try set.put(hashInt("y"), .{ .bytes = "y" });

                    // CountedHashSet
                    const cset_cursor = try moment.putCursor(hashInt("mycset"));
                    const cset = try DB.CountedHashSet(.read_write).init(cset_cursor);
                    try cset.put(hashInt("p"), .{ .bytes = "p" });
                    try cset.put(hashInt("q"), .{ .bytes = "q" });
                }
            };
            try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx2{});
        }

        // moment 3
        {
            const history = try DB.ArrayList(.read_write).init(source.rootCursor());
            const Ctx3 = struct {
                pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    const moment = try DB.HashMap(.read_write).init(cursor.*);
                    try moment.put(hashInt("key1"), .{ .bytes = "final_value" });
                }
            };
            try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx3{});
        }

        const source_size = try source.core.length();

        // compact
        var offset_map = std.AutoHashMap(u64, u64).init(allocator);
        defer offset_map.deinit();
        var compacted = try source.compact(target_db_kind, target_opts, &offset_map);

        const target_size = try compacted.core.length();

        // target should be smaller than source (3 moments vs 1)
        try std.testing.expect(target_size < source_size);

        // target should have exactly 1 moment
        const history = try TargetDB.ArrayList(.read_only).init(compacted.rootCursor().readOnly());
        try std.testing.expectEqual(1, try history.count());

        // verify all data from latest moment is correct
        const moment_cursor = (try history.getCursor(0)).?;
        const moment = try TargetDB.HashMap(.read_only).init(moment_cursor);

        // key1 should have the final value
        const key1_val = try (try moment.getCursor(hashInt("key1"))).?.readBytesAlloc(allocator, 1024);
        defer allocator.free(key1_val);
        try std.testing.expectEqualStrings("final_value", key1_val);

        // key2 from moment 2
        try std.testing.expectEqual(200, try (try moment.getCursor(hashInt("key2"))).?.readUint());

        // key3 - int
        try std.testing.expectEqual(@as(i64, -42), try (try moment.getCursor(hashInt("key3"))).?.readInt());

        // key4 - float
        try std.testing.expectEqual(@as(f64, 3.14), try (try moment.getCursor(hashInt("key4"))).?.readFloat());

        // short bytes
        const short_val = try (try moment.getCursor(hashInt("short"))).?.readBytesAlloc(allocator, 1024);
        defer allocator.free(short_val);
        try std.testing.expectEqualStrings("hi", short_val);

        // tagged bytes
        const tagged_obj = try (try moment.getCursor(hashInt("tagged"))).?.readBytesObjectAlloc(allocator, 1024);
        defer allocator.free(tagged_obj.value);
        try std.testing.expectEqualStrings("this is a long tagged string!!", tagged_obj.value);
        try std.testing.expectEqual("bi".*, tagged_obj.format_tag.?);

        // ArrayList
        const fruits_cursor = (try moment.getCursor(hashInt("fruits"))).?;
        const fruits = try TargetDB.ArrayList(.read_only).init(fruits_cursor);
        try std.testing.expectEqual(3, try fruits.count());
        const apple = try (try fruits.getCursor(0)).?.readBytesAlloc(allocator, 1024);
        defer allocator.free(apple);
        try std.testing.expectEqualStrings("apple", apple);
        const cherry = try (try fruits.getCursor(2)).?.readBytesAlloc(allocator, 1024);
        defer allocator.free(cherry);
        try std.testing.expectEqualStrings("cherry", cherry);

        // LinkedArrayList
        const todos_cursor = (try moment.getCursor(hashInt("todos"))).?;
        const todos = try TargetDB.LinkedArrayList(.read_only).init(todos_cursor);
        try std.testing.expectEqual(3, try todos.count());
        const task1 = try (try todos.getCursor(0)).?.readBytesAlloc(allocator, 1024);
        defer allocator.free(task1);
        try std.testing.expectEqualStrings("task1", task1);
        const task3 = try (try todos.getCursor(2)).?.readBytesAlloc(allocator, 1024);
        defer allocator.free(task3);
        try std.testing.expectEqualStrings("task3", task3);

        // CountedHashMap
        const counted_cursor = (try moment.getCursor(hashInt("counted"))).?;
        const counted = try TargetDB.CountedHashMap(.read_only).init(counted_cursor);
        try std.testing.expectEqual(2, try counted.count());
        try std.testing.expectEqual(1, try (try counted.getCursor(hashInt("a"))).?.readUint());
        try std.testing.expectEqual(2, try (try counted.getCursor(hashInt("b"))).?.readUint());

        // HashSet
        const set_cursor = (try moment.getCursor(hashInt("myset"))).?;
        const set = try TargetDB.HashSet(.read_only).init(set_cursor);
        const x_val = try (try set.getCursor(hashInt("x"))).?.readBytesAlloc(allocator, 1024);
        defer allocator.free(x_val);
        try std.testing.expectEqualStrings("x", x_val);

        // CountedHashSet
        const cset_cursor = (try moment.getCursor(hashInt("mycset"))).?;
        const cset = try TargetDB.CountedHashSet(.read_only).init(cset_cursor);
        try std.testing.expectEqual(2, try cset.count());
        const p_val = try (try cset.getCursor(hashInt("p"))).?.readBytesAlloc(allocator, 1024);
        defer allocator.free(p_val);
        try std.testing.expectEqualStrings("p", p_val);
    }

    // structural sharing (most data shared, only 1 key changes per moment)
    {
        try clearStorage(db_kind, source_opts);
        try clearStorage(target_db_kind, target_opts);
        var source = try DB.init(source_opts);

        // moment 1: create many keys
        {
            const history = try DB.ArrayList(.read_write).init(source.rootCursor());
            const Ctx = struct {
                pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    const moment = try DB.HashMap(.read_write).init(cursor.*);
                    for (0..20) |i| {
                        var key_buf: [32]u8 = undefined;
                        const key = std.fmt.bufPrint(&key_buf, "shared_key_{d}", .{i}) catch unreachable;
                        try moment.put(hashInt(key), .{ .uint = i });
                    }
                }
            };
            try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{});
        }

        // moments 2-5: change only one key each time
        for (0..4) |round| {
            const history = try DB.ArrayList(.read_write).init(source.rootCursor());
            const Ctx = struct {
                round_val: u64,
                pub fn run(self: @This(), cursor: *DB.Cursor(.read_write)) !void {
                    const moment = try DB.HashMap(.read_write).init(cursor.*);
                    try moment.put(hashInt("changing_key"), .{ .uint = self.round_val + 100 });
                }
            };
            try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{ .round_val = round });
        }

        var offset_map = std.AutoHashMap(u64, u64).init(allocator);
        defer offset_map.deinit();
        var compacted = try source.compact(target_db_kind, target_opts, &offset_map);

        const history = try TargetDB.ArrayList(.read_only).init(compacted.rootCursor().readOnly());
        try std.testing.expectEqual(1, try history.count());

        const moment_cursor = (try history.getCursor(0)).?;
        const moment = try TargetDB.HashMap(.read_only).init(moment_cursor);

        // verify shared keys are intact
        for (0..20) |i| {
            var key_buf: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "shared_key_{d}", .{i}) catch unreachable;
            try std.testing.expectEqual(i, try (try moment.getCursor(hashInt(key))).?.readUint());
        }

        // verify changing key has latest value
        try std.testing.expectEqual(103, try (try moment.getCursor(hashInt("changing_key"))).?.readUint());
    }

    // re-open after compact and compact-then-continue-writing
    // (only meaningful for file and buffered_file modes)
    if (db_kind != .memory) {
        // re-open after compact
        {
            try clearStorage(db_kind, source_opts);
            try clearStorage(target_db_kind, target_opts);
            var source = try DB.init(source_opts);

            // write some data
            {
                const history = try DB.ArrayList(.read_write).init(source.rootCursor());
                const Ctx = struct {
                    pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                        const moment = try DB.HashMap(.read_write).init(cursor.*);
                        try moment.put(hashInt("persist"), .{ .bytes = "persistent_value" });
                        try moment.put(hashInt("number"), .{ .uint = 999 });
                    }
                };
                try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{});
            }

            // compact
            var offset_map = std.AutoHashMap(u64, u64).init(allocator);
            defer offset_map.deinit();
            var compacted = try source.compact(target_db_kind, target_opts, &offset_map);
            _ = &compacted;

            // re-open the target
            var reopened = try TargetDB.init(target_opts);

            const history = try TargetDB.ArrayList(.read_only).init(reopened.rootCursor().readOnly());
            try std.testing.expectEqual(1, try history.count());

            const moment_cursor = (try history.getCursor(0)).?;
            const moment = try TargetDB.HashMap(.read_only).init(moment_cursor);
            const val = try (try moment.getCursor(hashInt("persist"))).?.readBytesAlloc(allocator, 1024);
            defer allocator.free(val);
            try std.testing.expectEqualStrings("persistent_value", val);
            try std.testing.expectEqual(999, try (try moment.getCursor(hashInt("number"))).?.readUint());
        }

        // compact then continue writing
        {
            try clearStorage(db_kind, source_opts);
            try clearStorage(target_db_kind, target_opts);
            var source = try DB.init(source_opts);

            // write initial data
            {
                const history = try DB.ArrayList(.read_write).init(source.rootCursor());
                const Ctx = struct {
                    pub fn run(_: @This(), cursor: *DB.Cursor(.read_write)) !void {
                        const moment = try DB.HashMap(.read_write).init(cursor.*);
                        try moment.put(hashInt("original"), .{ .bytes = "original_data" });
                    }
                };
                try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{});
            }

            // compact
            var offset_map = std.AutoHashMap(u64, u64).init(allocator);
            defer offset_map.deinit();
            var compacted = try source.compact(target_db_kind, target_opts, &offset_map);

            // add new moment to compacted DB
            {
                const history = try TargetDB.ArrayList(.read_write).init(compacted.rootCursor());
                const Ctx = struct {
                    pub fn run(_: @This(), cursor: *TargetDB.Cursor(.read_write)) !void {
                        const moment = try TargetDB.HashMap(.read_write).init(cursor.*);
                        try moment.put(hashInt("new_key"), .{ .bytes = "new_data" });
                    }
                };
                try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{});
            }

            // verify both old and new data
            const history = try TargetDB.ArrayList(.read_only).init(compacted.rootCursor().readOnly());
            try std.testing.expectEqual(2, try history.count());

            // moment 0 (compacted original)
            const m0_cursor = (try history.getCursor(0)).?;
            const m0 = try TargetDB.HashMap(.read_only).init(m0_cursor);
            const orig_val = try (try m0.getCursor(hashInt("original"))).?.readBytesAlloc(allocator, 1024);
            defer allocator.free(orig_val);
            try std.testing.expectEqualStrings("original_data", orig_val);

            // moment 1 (new data added after compact)
            const m1_cursor = (try history.getCursor(1)).?;
            const m1 = try TargetDB.HashMap(.read_only).init(m1_cursor);
            const new_val = try (try m1.getCursor(hashInt("new_key"))).?.readBytesAlloc(allocator, 1024);
            defer allocator.free(new_val);
            try std.testing.expectEqualStrings("new_data", new_val);

            // original data should still be in moment 1 (inherited)
            const orig_in_m1 = try (try m1.getCursor(hashInt("original"))).?.readBytesAlloc(allocator, 1024);
            defer allocator.free(orig_in_m1);
            try std.testing.expectEqualStrings("original_data", orig_in_m1);
        }
    }
}
