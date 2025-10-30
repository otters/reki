import gleam/dict
import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor
import gleam/otp/supervision

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
  )
}

pub opaque type RegistryMessage(key, msg) {
  LookupOrStart(
    key: key,
    start_fn: fn() ->
      Result(actor.Started(process.Subject(msg)), actor.StartError),
    reply_to: process.Subject(Result(process.Subject(msg), actor.StartError)),
  )
  ProcessDown(pid: process.Pid)
}

type RegistryEntry(msg) {
  RegistryEntry(
    subject: process.Subject(msg),
    pid: process.Pid,
    monitor: process.Monitor,
  )
}

fn start_registry_actor(
  registry: Registry(key, msg),
) -> Result(actor.Started(Registry(key, msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(monitor: _, pid:, reason: _) -> ProcessDown(pid:)
          process.PortDown(..) -> ProcessDown(pid: process.self())
        }
      })

    let state = dict.new()
    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(registry)
    |> Ok
  })
  |> actor.named(registry.registry_name)
  |> actor.on_message(fn(state, message) {
    on_message(state, message, registry)
  })
  |> actor.start
}

fn on_message(
  state: dict.Dict(key, RegistryEntry(msg)),
  message: RegistryMessage(key, msg),
  registry: Registry(key, msg),
) -> actor.Next(dict.Dict(key, RegistryEntry(msg)), RegistryMessage(key, msg)) {
  case message {
    LookupOrStart(key:, start_fn:, reply_to:) -> {
      case dict.get(state, key) {
        Ok(entry) -> {
          process.send(reply_to, Ok(entry.subject))
          actor.continue(state)
        }

        Error(Nil) -> {
          let supervisor =
            factory_supervisor.get_by_name(registry.factory_supervisor_name)
          case factory_supervisor.start_child(supervisor, start_fn) {
            Ok(actor.Started(pid:, data: subject)) -> {
              let monitor = process.monitor(pid)
              let entry = RegistryEntry(subject:, pid:, monitor:)
              process.send(reply_to, Ok(subject))

              dict.insert(state, key, entry)
              |> actor.continue
            }
            Error(e) -> {
              process.send(reply_to, Error(e))
              actor.continue(state)
            }
          }
        }
      }
    }

    ProcessDown(pid:) -> {
      let key_to_delete =
        dict.fold(state, option.None, fn(acc, key, entry) {
          case acc {
            option.None ->
              case entry.pid == pid {
                True -> option.Some(key)
                False -> option.None
              }
            option.Some(key) -> option.Some(key)
          }
        })

      case key_to_delete {
        option.Some(key) -> dict.delete(state, key)
        option.None -> state
      }
      |> actor.continue
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
pub fn lookup_or_start(
  registry: Registry(key, msg),
  key: key,
  timeout: Int,
  start_fn: fn() ->
    Result(actor.Started(process.Subject(msg)), actor.StartError),
) -> Result(process.Subject(msg), actor.StartError) {
  actor.call(
    process.named_subject(registry.registry_name),
    timeout,
    fn(reply_to) { LookupOrStart(key:, start_fn:, reply_to:) },
  )
}
