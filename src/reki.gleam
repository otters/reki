import gleam/dict
import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision

/// A registry that manages actors by key.
/// Similar to Discord's gen_registry, this allows you to look up or start actors
/// on demand, ensuring only one actor exists per key.
pub opaque type Registry(key, msg) {
  Registry(name: process.Name(RegistryMessage(key, msg)))
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

/// Start the registry with the given name. You likely want to use the
/// `supervised` function instead, to add the registry to your supervision
/// tree, but this may still be useful in your tests.
///
/// Remember that names must be created at the start of your program, and must
/// not be created dynamically such as within your supervision tree (it may
/// restart, creating new names) or in a loop.
pub fn start(
  name: process.Name(RegistryMessage(key, msg)),
) -> Result(actor.Started(Registry(key, msg)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(monitor: _, pid: down_pid, reason: _) ->
            ProcessDown(pid: down_pid)
          process.PortDown(..) -> ProcessDown(pid: process.self())
        }
      })

    actor.initialised(dict.new())
    |> actor.selecting(selector)
    |> actor.returning(Registry(name:))
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(registry_loop)
  |> actor.start
}

/// A specification for starting the registry under a supervisor, using the
/// given name. You should likely use this function in applications.
///
/// Remember that names must be created at the start of your program, and must
/// not be created dynamically such as within your supervision tree (it may
/// restart, creating new names) or in a loop.
pub fn supervised(
  name: process.Name(RegistryMessage(key, msg)),
) -> supervision.ChildSpecification(Registry(key, msg)) {
  supervision.worker(fn() { start(name) })
}

/// Create a Registry from a name. Use this when you've started the registry
/// via supervision and need to get a Registry value to pass to lookup_or_start.
pub fn from_name(
  name: process.Name(RegistryMessage(key, msg)),
) -> Registry(key, msg) {
  Registry(name:)
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
  let Registry(name) = registry

  actor.call(process.named_subject(name), timeout, fn(reply_to) {
    LookupOrStart(key:, start_fn:, reply_to:)
  })
}

fn registry_loop(
  state: dict.Dict(key, RegistryEntry(msg)),
  message: RegistryMessage(key, msg),
) -> actor.Next(dict.Dict(key, RegistryEntry(msg)), RegistryMessage(key, msg)) {
  case message {
    LookupOrStart(key:, start_fn:, reply_to:) ->
      handle_lookup(state, key, start_fn, reply_to)
    ProcessDown(pid:) -> handle_process_down(state, pid)
  }
}

fn handle_process_down(
  state: dict.Dict(key, RegistryEntry(msg)),
  pid: process.Pid,
) -> actor.Next(dict.Dict(key, RegistryEntry(msg)), RegistryMessage(key, msg)) {
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

fn handle_lookup(
  state: dict.Dict(key, RegistryEntry(msg)),
  key: key,
  start_fn: fn() ->
    Result(actor.Started(process.Subject(msg)), actor.StartError),
  reply_to: process.Subject(Result(process.Subject(msg), actor.StartError)),
) -> actor.Next(dict.Dict(key, RegistryEntry(msg)), RegistryMessage(key, msg)) {
  case dict.get(state, key) {
    Ok(RegistryEntry(subject: existing_subject, pid: _, monitor: _)) -> {
      process.send(reply_to, Ok(existing_subject))
      actor.continue(state)
    }

    Error(Nil) -> {
      case start_fn() {
        Ok(actor.Started(pid:, data: subject)) -> {
          let monitor = process.monitor(pid)
          let entry = RegistryEntry(subject:, pid:, monitor:)
          process.send(reply_to, Ok(subject))

          dict.insert(state, key, entry) |> actor.continue
        }
        Error(e) -> {
          process.send(reply_to, Error(e))
          actor.continue(state)
        }
      }
    }
  }
}
