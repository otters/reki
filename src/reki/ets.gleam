import gleam/dynamic

/// An ETS table handle. Tables are named and can be accessed by name.
pub opaque type Table {
  Table(name: String)
}

/// Create a new named ETS table with the given name.
pub fn new(name: String) -> Result(Table, Nil) {
  case new_table(name) {
    Ok(_) -> Ok(Table(name))
    Error(e) -> Error(e)
  }
}

/// Get an existing named ETS table, or create it if it doesn't exist.
pub fn get_or_create(name: String) -> Result(Table, Nil) {
  case get_or_create_table(name) {
    Ok(_) -> Ok(Table(name))
    Error(e) -> Error(e)
  }
}

/// Insert a key-value pair into the table.
pub fn insert(key: a, value: b, table: Table) -> Result(Nil, Nil) {
  insert_ets(table.name, to_dynamic(key), to_dynamic(value))
}

/// Look up a value by key in the table, returning it as a Dynamic value.
pub fn lookup_dynamic(key: a, table: Table) -> Result(dynamic.Dynamic, Nil) {
  lookup_ets(table.name, to_dynamic(key))
}

/// Delete a key-value pair from the table.
pub fn delete(key: a, table: Table) -> Result(Nil, Nil) {
  delete_ets(table.name, to_dynamic(key))
}

/// Delete using a dynamic key (useful when you have a dynamic key from another lookup).
pub fn delete_using_dynamic(
  key: dynamic.Dynamic,
  table: Table,
) -> Result(Nil, Nil) {
  delete_ets(table.name, key)
}

/// Clear all entries from the table.
pub fn clear_table(table: Table) -> Result(Nil, Nil) {
  delete_all_objects_ets(table.name)
}

// Internal FFI functions

@external(erlang, "reki_ets_ffi", "new")
fn new_table(name: String) -> Result(Nil, Nil)

@external(erlang, "reki_ets_ffi", "get_or_create")
fn get_or_create_table(name: String) -> Result(Nil, Nil)

@external(erlang, "reki_ets_ffi", "insert")
fn insert_ets(
  name: String,
  key: dynamic.Dynamic,
  value: dynamic.Dynamic,
) -> Result(Nil, Nil)

@external(erlang, "reki_ets_ffi", "lookup")
fn lookup_ets(
  name: String,
  key: dynamic.Dynamic,
) -> Result(dynamic.Dynamic, Nil)

@external(erlang, "reki_ets_ffi", "delete")
fn delete_ets(name: String, key: dynamic.Dynamic) -> Result(Nil, Nil)

@external(erlang, "reki_ets_ffi", "delete_all_objects")
fn delete_all_objects_ets(name: String) -> Result(Nil, Nil)

@external(erlang, "reki_ets_ffi", "to_dynamic")
fn to_dynamic(value: a) -> dynamic.Dynamic
