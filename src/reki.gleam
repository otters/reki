import gleam/dict
import gleam/erlang/process
import gleam/otp/actor

/// A registry that manages actors by key.
/// Similar to Discord's gen_registry, this allows you to look up or start actors
/// on demand, ensuring only one actor exists per key.
pub opaque type Registry(key, msg) {
  Registry(process.Subject(RegistryMessage(key, msg)))
}

type RegistryMessage(key, msg) {
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

pub fn create() -> Registry(key, msg) {
  let assert Ok(actor.Started(pid: _, data: subject)) =
    actor.new_with_initialiser(1000, fn(registry_subject) {
      let selector =
        process.new_selector()
        |> process.select(registry_subject)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(monitor: _, pid: down_pid, reason: _) ->
              ProcessDown(pid: down_pid)
            process.PortDown(..) -> ProcessDown(pid: process.self())
          }
        })
      actor.initialised(dict.new())
      |> actor.selecting(selector)
      |> actor.returning(registry_subject)
      |> Ok
    })
    |> actor.on_message(registry_loop)
    |> actor.start
  Registry(subject)
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
  let Registry(registry_subject) = registry
  let reply_to = process.new_subject()

  process.send(registry_subject, LookupOrStart(key:, start_fn:, reply_to:))

  case process.receive(reply_to, within: timeout) {
    Ok(result) -> result
    Error(_) -> Error(actor.InitTimeout)
  }
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
  dict.fold(state, dict.new(), fn(acc, key, entry) {
    case entry.pid == pid {
      True -> acc
      False -> dict.insert(acc, key, entry)
    }
  })
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
