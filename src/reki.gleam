import gleam/dynamic
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import reki/ets

/// A registry that manages actors by key.
/// Similar to Discord's gen_registry, this allows you to look up or start actors
/// on demand, ensuring only one actor exists per key.
pub opaque type Registry(key, msg) {
  Registry(
    registry_name: process.Name(RegistryMessage(key, msg)),
    factory_supervisor_name: process.Name(
      factory_supervisor.Message(
        fn() -> Result(actor.Started(process.Subject(msg)), actor.StartError),
        process.Subject(msg),
      ),
    ),
    ets_table_name: String,
  )
}

pub opaque type RegistryMessage(key, msg) {
  StartIfNotExists(
    key: key,
    start_fn: fn() ->
      Result(actor.Started(process.Subject(msg)), actor.StartError),
    reply_to: process.Subject(Result(process.Subject(msg), actor.StartError)),
  )
  ProcessDown(pid: process.Pid)
}

@external(erlang, "reki_ets_ffi", "cast_subject")
fn cast_subject(value: dynamic.Dynamic) -> process.Subject(msg)

fn start_registry_actor(
  registry: Registry(key, msg),
) -> Result(actor.Started(Registry(key, msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    // Create the ETS table inside the actor initialiser so it's owned by this process.
    // When the actor dies, the table is automatically destroyed. When the actor
    // restarts, a new table will be created.
    case ets.new(registry.ets_table_name) {
      Ok(ets_table) -> {
        let selector =
          process.new_selector()
          |> process.select(subject)
          |> process.select_monitors(fn(down) {
            case down {
              process.ProcessDown(monitor: _, pid:, reason: _) ->
                ProcessDown(pid:)
              process.PortDown(..) -> ProcessDown(pid: process.self())
            }
          })

        actor.initialised(ets_table)
        |> actor.selecting(selector)
        |> actor.returning(registry)
        |> Ok
      }
      Error(Nil) -> Error("Failed to create ETS table")
    }
  })
  |> actor.named(registry.registry_name)
  |> actor.on_message(fn(state, message) {
    on_message(state, message, registry)
  })
  |> actor.start
}

fn on_message(
  ets_table: ets.Table,
  message: RegistryMessage(key, msg),
  registry: Registry(key, msg),
) -> actor.Next(ets.Table, RegistryMessage(key, msg)) {
  case message {
    StartIfNotExists(key:, start_fn:, reply_to:) -> {
      case ets.lookup_dynamic(key, ets_table) {
        Ok(subject_dynamic) -> {
          process.send(reply_to, Ok(cast_subject(subject_dynamic)))
          actor.continue(ets_table)
        }

        Error(Nil) -> {
          let supervisor =
            factory_supervisor.get_by_name(registry.factory_supervisor_name)

          case factory_supervisor.start_child(supervisor, start_fn) {
            Ok(actor.Started(pid:, data: subject)) -> {
              let _ = process.monitor(pid)

              let assert Ok(Nil) = ets.insert(key, subject, ets_table)
              let assert Ok(Nil) = ets.insert(pid, key, ets_table)

              process.send(reply_to, Ok(subject))
              actor.continue(ets_table)
            }
            Error(e) -> {
              process.send(reply_to, Error(e))
              actor.continue(ets_table)
            }
          }
        }
      }
    }

    ProcessDown(pid:) -> {
      case ets.lookup_dynamic(pid, ets_table) {
        Ok(key_dynamic) -> {
          let _ = ets.delete_using_dynamic(key_dynamic, ets_table)
          let _ = ets.delete(pid, ets_table)
          actor.continue(ets_table)
        }
        Error(Nil) -> {
          actor.continue(ets_table)
        }
      }
    }
  }
}

/// Start the registry with the given registry. You likely want to use the
/// `supervised` function instead, to add the registry to your supervision
/// tree, but this may still be useful in your tests.
///
/// Remember that names must be created at the start of your program, and must
/// not be created dynamically such as within your supervision tree (it may
/// restart, creating new names) or in a loop.
pub fn start(
  registry: Registry(key, msg),
) -> Result(actor.Started(Registry(key, msg)), actor.StartError) {
  case
    factory_supervisor.worker_child(fn(start_fn) { start_fn() })
    |> factory_supervisor.restart_strategy(supervision.Transient)
    |> factory_supervisor.named(registry.factory_supervisor_name)
    |> factory_supervisor.start
  {
    Ok(actor.Started(pid: _, data: _)) -> start_registry_actor(registry)
    Error(e) -> Error(e)
  }
}

/// Create a registry with both names. Call this at the start of
/// your program before creating the supervision tree.
pub fn new(name: String) -> Registry(key, msg) {
  Registry(
    registry_name: process.new_name(name),
    factory_supervisor_name: process.new_name(name <> "@factory@supervisor"),
    ets_table_name: name <> "@ets",
  )
}

/// A specification for starting the registry under a supervisor.
///
/// This returns a supervisor that manages both the factory supervisor (which
/// supervises dynamically started actors) and the registry actor itself.
pub fn supervised(
  registry: Registry(key, msg),
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let factory_builder =
    factory_supervisor.worker_child(fn(start_fn) { start_fn() })
    |> factory_supervisor.restart_strategy(supervision.Transient)
    |> factory_supervisor.named(registry.factory_supervisor_name)

  let worker = supervision.worker(fn() { start_registry_actor(registry) })

  supervision.supervisor(fn() {
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(factory_supervisor.supervised(factory_builder))
    |> static_supervisor.add(worker)
    |> static_supervisor.start
  })
}

/// Get the registry name from a Registry. Useful for looking up the process
/// by name or for debugging purposes.
pub fn registry_name(
  registry: Registry(key, msg),
) -> process.Name(RegistryMessage(key, msg)) {
  registry.registry_name
}

/// Looks up an actor by key in the registry, or starts it if it doesn't exist.
/// This function ensures that only one actor exists per key, even if called
/// concurrently from multiple processes.
/// Lookups are synchronous via ETS, so no timeout is needed for existing entries.
/// When starting a new actor, a default timeout of 5000ms is used.
pub fn lookup_or_start(
  registry: Registry(key, msg),
  key: key,
  start_fn: fn() ->
    Result(actor.Started(process.Subject(msg)), actor.StartError),
) -> Result(process.Subject(msg), actor.StartError) {
  case ets.get_or_create(registry.ets_table_name) {
    Ok(ets_table) -> {
      case ets.lookup_dynamic(key, ets_table) {
        Ok(subject_dynamic) -> Ok(cast_subject(subject_dynamic))
        Error(Nil) -> {
          actor.call(
            process.named_subject(registry.registry_name),
            5000,
            fn(reply_to) { StartIfNotExists(key:, start_fn:, reply_to:) },
          )
        }
      }
    }
    Error(Nil) -> {
      actor.call(
        process.named_subject(registry.registry_name),
        5000,
        fn(reply_to) { StartIfNotExists(key:, start_fn:, reply_to:) },
      )
    }
  }
}
