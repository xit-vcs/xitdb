<p align="center">
  xitdb is an immutable database written in Zig
  <br/>
  <br/>
  <b>Choose your flavor:</b>
  <a href="https://github.com/xit-vcs/xitdb">Zig</a> |
  <a href="https://github.com/xit-vcs/xitdb-java">Java</a> |
  <a href="https://github.com/codeboost/xitdb-clj">Clojure</a> |
  <a href="https://github.com/xit-vcs/xitdb-ts">TypeScript</a> |
  <a href="https://github.com/xit-vcs/xitdb-go">Go</a>
</p>

* Each transaction efficiently creates a new "copy" of the database, and past copies can still be read from and reverted to.
* Supports storing in a single file as well as purely in-memory use.
* Runs as a library (embedded in process).
* Incrementally reads and writes, so file-based databases can contain larger-than-memory datasets.
* Reads never block writes, and a database can be read from multiple threads/processes without locks.
* No query engine of any kind. You just write data structures (primarily an `ArrayList` and `HashMap`) that can be nested arbitrarily.
* No dependencies besides the Zig standard library (requires version 0.16.0).

This database was originally made for the [xit version control system](https://github.com/xit-vcs/xit), but I bet it has a lot of potential for other projects. The combination of being immutable and having an API similar to in-memory data structures is pretty powerful. Consider using it [instead of SQLite](https://gist.github.com/xeubie/03a0724484e1111ef4c05d72a935c42c) for your Zig projects: it's simpler, it's pure Zig, and it creates no impedance mismatch with your program the way SQL databases do.

* [Example](#example)
* [Initializing a Database](#initializing-a-database)
* [Types](#types)
* [Cloning and Undoing](#cloning-and-undoing)
* [Large Byte Arrays](#large-byte-arrays)
* [Iterators](#iterators)
* [Hashing](#hashing)
* [Compaction](#compaction)
* [Thread Safety](#thread-safety)

## Example

In this example, we create a new database, write some data in a transaction, and read the data afterwards.

```zig
// create db file
const file = try std.Io.Dir.cwd().createFile(io, "main.db", .{ .read = true });
defer file.close(io);

// init the buffer (optional, but better for performance)
var buffer = std.Io.Writer.Allocating.init(allocator);
defer buffer.deinit();

// init the db
const DB = xitdb.Database(.buffered_file, HashInt);
var db = try DB.init(.{ .io = io, .file = file, .buffer = &buffer });

// to get the benefits of immutability, the top-level data structure
// must be an ArrayList, so each transaction is stored as an item in it
const history = try DB.ArrayList(.read_write).init(db.rootCursor());

// this is how a transaction is executed. we call history.appendContext,
// providing it with the most recent copy of the db and a context
// object. the context object has a method that will run before the
// transaction has completed. this method is where we can write
// changes to the db. if any error happens in it, the transaction
// will not complete, the data added to the file will be truncated,
// and the db will be unaffected.
//
// after this transaction, the db will look like this if represented
// as JSON (in reality the format is binary):
//
// {"foo": "foo",
//  "bar": "bar",
//  "fruits": ["apple", "pear", "grape"],
//  "people": [
//    {"name": "Alice", "age": 25},
//    {"name": "Bob", "age": 42}
//  ]}
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
        try alice.put(hashInt("name"), .{ .bytes = "Alice" });
        try alice.put(hashInt("age"), .{ .uint = 25 });

        const bob_cursor = try people.appendCursor();
        const bob = try DB.HashMap(.read_write).init(bob_cursor);
        try bob.put(hashInt("name"), .{ .bytes = "Bob" });
        try bob.put(hashInt("age"), .{ .uint = 42 });
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

// to get the "fruits" list, we get the cursor to it and
// then pass it to the ArrayList init method
const fruits_cursor = (try moment.getCursor(hashInt("fruits"))).?;
const fruits = try DB.ArrayList(.read_only).init(fruits_cursor);

// now we can get the first item from the fruits list and read it
const apple_cursor = (try fruits.getCursor(0)).?;
const apple_value = try apple_cursor.readBytesAlloc(allocator, MAX_READ_BYTES);
defer allocator.free(apple_value);
try std.testing.expectEqualStrings("apple", apple_value);
```

## Initializing a Database

There are three kinds of `Database` you can create: `.buffered_file`, `.file`, and `.memory`.

* `.buffered_file` databases, like in the example above, write to a file while using an in-memory buffer to dramatically improve performance. This is highly recommended if you want to create a file-based database.
* `.file` databases use no buffering when reading and writing data. You can initialize it like in the example above, except without providing a buffer. This is almost never necessary but it's useful as a benchmark comparison with `.buffered_file` databases.
* `.memory` databases work completely in memory. You can initialize it like in the example above, except without providing a file.

Usually, you want to use a top-level `ArrayList` like in the example above, because that allows you to store a reference to each copy of the database (which I call a "moment"). This is how it supports transactions, despite not having any rollback journal or write-ahead log. It's an append-only database, so the data you are writing is invisible to any reader until the very last step, when the top-level list's header is updated.

You can also use a top-level `HashMap`, which is useful for ephemeral databases where immutability or transaction safety isn't necessary. Since xitdb supports in-memory databases, you could use it as an over-the-wire serialization format. Much like "Cap'n Proto", xitdb has no encoding/decoding step: you just give the buffer to xitdb and it can immediately read from it.

## Types

In xitdb there are a variety of immutable data structures that you can nest arbitrarily:

* `HashMap` contains key-value pairs stored with a hash
* `HashSet` is like a `HashMap` that only sets the keys; it is useful when only checking for membership
* `CountedHashMap` and `CountedHashSet` are just a `HashMap` and `HashSet` that maintain a count of their contents
* `ArrayList` is a growable array
* `LinkedArrayList` is like an `ArrayList` that can also be efficiently sliced and concatenated

All data structures use the hash array mapped trie, invented by Phil Bagwell. The `LinkedArrayList` is based on his later work on RRB trees. These data structures were originally made immutable and widely available by Rich Hickey in Clojure. To my knowledge, they haven't been available in any open source database until xitdb.

There are also scalar types you can store in the above-mentioned data structures:

* `.bytes` is a byte array
* `.uint` is an unsigned 64-bit int
* `.int` is a signed 64-bit int
* `.float` is a 64-bit float

You may also want to define custom types. For example, you may want to store a big integer that can't fit in 64 bits. You could just store this with `.bytes`, but when reading the byte array there wouldn't be any indication that it should be interpreted as a big integer.

In xitdb, you can optionally store a format tag with a byte array. A format tag is a 2 byte tag that is stored alongside the byte array. Readers can use it to decide how to interpret the byte array. Here's an example of storing a random 256-bit number with `bi` as the format tag:

```zig
var random_number_buffer: [32]u8 = undefined;
var prng = std.Random.DefaultPrng.init(12345);
std.mem.writeInt(u256, &random_number_buffer, prng.random().int(u256), .big);
try moment.put(hashInt("random-number"), .{ .bytes_object = .{ .value = &random_number_buffer, .format_tag = "bi".* } });
```

Then, you can read it like this:

```zig
const random_number_cursor = (try moment.getCursor(hashInt("random-number"))).?;
var random_number_buffer: [32]u8 = undefined;
const random_number = try random_number_cursor.readBytesObject(&random_number_buffer);
try std.testing.expectEqualStrings("bi", &random_number.format_tag.?);
const random_number_int = std.mem.readInt(u256, &random_number_buffer, .big);
```

There are many types you may want to store this way. Maybe an ISO-8601 date like `2026-01-01T18:55:48Z` could be stored with `dt` as the format tag. It's also great for storing custom structs. Just define the struct, serialize it as a byte array using whatever mechanism you wish, and store it with a format tag. Keep in mind that format tags can be *any* 2 bytes, so there are 65536 possible format tags.

## Cloning and Undoing

A powerful feature of immutable data is fast cloning. Any data structure can be instantly cloned and changed without affecting the original. Starting with the example code above, we can make a new transaction that creates a "food" list based on the existing "fruits" list:

```zig
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
```

Before we continue, let's save the latest history index, so we can revert back to this moment of the database later:

```zig
const history_index = try history.count() - 1;
```

There's one catch you'll run into when cloning. If we try cloning a data structure that was created in the same transaction, it doesn't seem to work:

```zig
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
```

The reason that `big-cities` was mutated is because all data in a given transaction is temporarily mutable. This is a very important optimization, but in this case, it's not what we want.

To show how to fix this, let's first undo the transaction we just made. Here we use the `history_index` we saved before to revert back to the older database moment:

```zig
try history.append(.{ .slot = try history.getSlot(history_index) });
```

This time, after making the "big cities" list, we call `freeze`, which tells xitdb to consider all data made so far in the transaction to be immutable. After that, we can clone it into the "cities" list and it will work the way we wanted:

```zig
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
```

## Large Byte Arrays

When reading and writing large byte arrays, you probably don't want to have all of their contents in memory at once. To incrementally write to a byte array, just get a writer from a cursor:

```zig
var long_text_cursor = try moment.putCursor(hashInt("long-text"));
var write_buffer: [1024]u8 = undefined;
var writer = try long_text_cursor.writer(&write_buffer);
for (0..50) |_| {
    try writer.interface.writeAll("hello, world!\n");
}
try writer.finish(); // remember to call this!
```

If you need to set a format tag for the byte array, put it in the `format_tag` field of the writer before you call `finish`.

To read a byte array incrementally, get a reader from a cursor:

```zig
var long_text_cursor = (try moment.getCursor(hashInt("long-text"))).?;
var read_buffer: [1024]u8 = undefined;
var reader = try long_text_cursor.reader(&read_buffer);
var count: usize = 0;
while (try reader.interface.takeDelimiter('\n')) |_| {
    count += 1;
}
try std.testing.expectEqual(50, count);
```

## Iterators

All data structures support iteration. Here's an example of iterating over an `ArrayList` and printing all of the keys and values of each `HashMap` contained in it:

```zig
const people_cursor = (try moment.getCursor(hashInt("people"))).?;
const people = try DB.ArrayList(.read_only).init(people_cursor);

var people_iter = try people.iterator();
while (try people_iter.next()) |person_cursor| {
    const person = try DB.HashMap(.read_only).init(person_cursor);
    var person_iter = try person.iterator();
    while (try person_iter.next()) |kv_pair_cursor| {
        const kv_pair = try kv_pair_cursor.readKeyValuePair();

        var key_buffer: [100]u8 = undefined;
        const key = try kv_pair.key_cursor.readBytes(&key_buffer);

        switch (kv_pair.value_cursor.slot().tag) {
            .short_bytes, .bytes => {
                var val_buffer: [100]u8 = undefined;
                const val = try kv_pair.value_cursor.readBytes(&val_buffer);
                std.debug.print("{s}: {s}\n", .{ key, val });
            },
            .uint => std.debug.print("{s}: {}\n", .{ key, try kv_pair.value_cursor.readUint() }),
            .int => std.debug.print("{s}: {}\n", .{ key, _ = try kv_pair.value_cursor.readInt() }),
            .float => std.debug.print("{s}: {}\n", .{ key, _ = try kv_pair.value_cursor.readFloat() }),
            else => return error.UnexpectedTagType,
        }
    }
}
```

The above code iterates over `people`, which is an `ArrayList`, and for each person (which is a `HashMap`), it iterates over each of its key-value pairs.

The iteration of the `HashMap` looks the same with `HashSet`, `CountedHashMap`, and `CountedHashSet`. When iterating, you call `readKeyValuePair` on the cursor and can read the `key_cursor` and `value_cursor` from it. In maps, `put` sets the value `putKey` sets the key (see the tests for examples). In sets, there is only `put` and it sets the key; the value will always have a tag type of `.none`.

## Hashing

Hashing is never done by xitdb itself. The `hashInt` function you see in the above examples is not part of the library. You can define it yourself like this:

```zig
fn hashInt(buffer: []const u8) u160 {
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(buffer, &hash, .{});
    return std.mem.readInt(u160, &hash, .big);
}
```

When initializing a database, you only tell xitdb the size of the hash via the `HashInt` parameter. If you're using SHA-1, this will be 160 bits:

```zig
const file = try std.Io.Dir.cwd().createFile(io, "main.db", .{ .read = true });
defer file.close(io);

const db = try xitdb.Database(.file, u160).init(.{ .io = io, .file = file });
```

The size of the hash in bytes will be stored in the database's header. If you try opening it later with the wrong hash size, it will return an error. If you are unsure what hash size the database uses, this creates a chicken-and-egg problem. You can read the header before initializing the database like this:

```zig
var reader = file.reader(&.{});
const header = try xitdb.DatabaseHeader.read(&reader.interface);
try std.testing.expectEqual(20, header.hash_size);
```

The hash size alone does not disambiguate hashing algorithms, though. In addition, xitdb reserves four bytes in the header that you can use to put the name of the algorithm. You must provide it in the init options:

```zig
const db = try xitdb.Database(.file, u160).init(.{ .io = io, .file = file, .hash_id = .fromBytes("sha1") });
```

The hash id is only written to the database header when it is first initialized. When you open it later, that init option is ignored. You can read the hash id of an existing database like this:

```zig
var reader = file.reader(&.{});
const header = try xitdb.DatabaseHeader.read(&reader.interface);
try std.testing.expectEqualStrings("sha1", &header.hash_id.toBytes());
```

If you want to use SHA-256, I recommend using `sha2` as the hash id. You can then distinguish between SHA-256 and SHA-512 using the hash size, like this:

```zig
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
```

## Compaction

Normally, an immutable database grows forever, because old data is never deleted. To reclaim disk space and clear the history, xitdb supports compaction. This involves completely rebuilding the database file to only contain the data accessible from the latest copy (i.e., "moment") of the database.

```zig
// create the buffer and file for the new database
var compact_buffer = std.Io.Writer.Allocating.init(allocator);
defer compact_buffer.deinit();
const compact_file = try std.Io.Dir.cwd().createFile(io, "compact.db", .{ .read = true });
defer compact_file.close(io);

// cache of offsets to make the compaction much more efficient
var offset_map = std.AutoHashMap(u64, u64).init(allocator);
defer offset_map.deinit();

var compact_db = try db.compact(.buffered_file, .{ .io = io, .file = compact_file, .buffer = &compact_buffer }, &offset_map);

// read from the new compacted db
const history = try DB.ArrayList(.read_write).init(compact_db.rootCursor());
try std.testing.expectEqual(1, try history.count());
```

This compacted database will be in a separate file. If you want to delete the original database and replace it with this one, you'll need to do that yourself. It is not possible to compact a database in-place (using the same file as the target database); doing so would fail and would render your original database unreadable.

## Thread Safety

It is possible to read a database from multiple threads without locks, even while writes are happening. This is a big benefit of immutable databases. However, each thread needs to use its own `Database` instance. Also, keep in mind that writes still need to come from one thread at a time.
