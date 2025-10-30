import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleeunit
import reki

pub fn main() -> Nil {
  gleeunit.main()
}

const timeout = 10

pub type TestMessage {
  Incr
  Get(reply: process.Subject(Int))
  Crash
}

fn test_start_fn() -> Result(
  actor.Started(process.Subject(TestMessage)),
  actor.StartError,
) {
  0
  |> actor.new
  |> actor.on_message(fn(state, message) {
    case message {
      Incr -> state + 1 |> actor.continue
      Get(reply:) -> {
        process.send(reply, state)
        actor.continue(state)
      }
      Crash -> actor.stop_abnormal("crash")
    }
  })
  |> actor.start
}

fn create_registry() -> reki.Registry(String, TestMessage) {
  let registry = reki.new("test_registry")
  let assert Ok(actor.Started(pid: _, data: registry)) = reki.start(registry)
  registry
}

pub fn lookup_or_start_test() {
  let registry = create_registry()

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "test_key", timeout, test_start_fn)
  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "test_key", timeout, test_start_fn)

  assert actor1 == actor2
}

pub fn different_keys_test() {
  let registry = create_registry()

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "key1", timeout, test_start_fn)
  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "key2", timeout, test_start_fn)

  assert actor1 != actor2
}

pub fn lookup_or_start_multiple_keys_test() {
  let registry = create_registry()

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "key1", timeout, test_start_fn)
  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "key2", timeout, test_start_fn)
  let assert Ok(actor3) =
    reki.lookup_or_start(registry, "key1", timeout, test_start_fn)

  assert actor1 == actor3
  assert actor1 != actor2
  assert actor2 != actor3
  assert actor1 == actor3
}

fn get_state(actor: process.Subject(TestMessage)) -> Int {
  let reply = process.new_subject()
  process.send(actor, Get(reply:))
  process.receive(reply, timeout) |> result.unwrap(0)
}

pub fn state_operations_test() {
  let registry = create_registry()

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "counter", timeout, test_start_fn)

  assert get_state(actor) == 0

  process.send(actor, Incr)
  process.send(actor, Incr)
  process.send(actor, Incr)

  assert get_state(actor) == 3
}

pub fn state_preserved_across_lookups_test() {
  let registry = create_registry()

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "counter", timeout, test_start_fn)

  process.send(actor1, Incr)
  process.send(actor1, Incr)

  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "counter", timeout, test_start_fn)

  assert actor1 == actor2
  assert get_state(actor2) == 2

  process.send(actor2, Incr)
  assert get_state(actor1) == 3
}

pub fn state_operations_in_order_test() {
  let registry = create_registry()

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "counter", timeout, test_start_fn)

  assert get_state(actor) == 0

  process.send(actor, Incr)
  let state1 = get_state(actor)
  assert state1 == 1

  process.send(actor, Incr)
  let state2 = get_state(actor)
  assert state2 == 2

  process.send(actor, Incr)
  process.send(actor, Incr)
  let state4 = get_state(actor)
  assert state4 == 4
}

pub fn concurrent_lookups_test() {
  let registry = create_registry()
  let results = process.new_subject()

  let do = fn() {
    case
      reki.lookup_or_start(registry, "concurrent_key", timeout, test_start_fn)
    {
      Ok(actor) -> process.send(results, Ok(actor))
      Error(e) -> process.send(results, Error(e))
    }
  }

  process.spawn(do)
  process.spawn(do)
  process.spawn(do)

  let assert Ok(actor1) = process.receive(results, 100)
  let assert Ok(actor2) = process.receive(results, 100)
  let assert Ok(actor3) = process.receive(results, 100)

  assert actor1 == actor2
  assert actor2 == actor3
}

pub fn concurrent_state_operations_test() {
  let registry = create_registry()

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "concurrent_counter", timeout, test_start_fn)

  let results = process.new_subject()

  process.spawn(fn() {
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(results, Nil)
  })

  process.spawn(fn() {
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(results, Nil)
  })

  process.spawn(fn() {
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(results, Nil)
  })

  let assert Ok(Nil) = process.receive(results, 100)
  let assert Ok(Nil) = process.receive(results, 100)
  let assert Ok(Nil) = process.receive(results, 100)

  let final_state = get_state(actor)
  assert final_state == 9
}

pub fn readme_example_test() {
  let registry = reki.new("readme_registry")

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(reki.supervised(registry))
    |> supervisor.start

  let assert Ok(counter) =
    reki.lookup_or_start(registry, "user_123", timeout, fn() {
      actor.new(0)
      |> actor.on_message(fn(state, msg) {
        case msg {
          Incr -> state + 1 |> actor.continue
          Get(reply:) -> {
            process.send(reply, state)
            actor.continue(state)
          }
          Crash -> actor.continue(state)
        }
      })
      |> actor.start
    })

  process.send(counter, Incr)
  process.send(counter, Incr)

  let reply = process.new_subject()
  process.send(counter, Get(reply:))
  let assert Ok(2) = process.receive(reply, 1000)

  let assert Ok(same_counter) =
    reki.lookup_or_start(registry, "user_123", timeout, fn() {
      actor.new(0)
      |> actor.on_message(fn(state, msg) {
        case msg {
          Incr -> state + 1 |> actor.continue
          Get(reply:) -> {
            process.send(reply, state)
            actor.continue(state)
          }
          Crash -> actor.continue(state)
        }
      })
      |> actor.start
    })

  assert same_counter == counter
}

fn create_supervised_registry() -> reki.Registry(String, TestMessage) {
  let registry = reki.new("supervised_test_registry")
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(reki.supervised(registry))
    |> supervisor.start
  registry
}

fn get_pid(actor: process.Subject(TestMessage)) -> process.Pid {
  let assert Ok(pid) = process.subject_owner(actor)
  pid
}

pub fn supervised_actor_restarts_after_crash_test() {
  let registry = create_supervised_registry()

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "crash_test", timeout, test_start_fn)

  let pid = get_pid(actor)
  assert process.is_alive(pid) == True

  process.send(actor, Incr)
  process.send(actor, Incr)
  assert get_state(actor) == 2

  process.kill(pid)
  process.sleep(100)

  let assert Ok(restarted_actor) =
    reki.lookup_or_start(registry, "crash_test", timeout, test_start_fn)

  assert actor != restarted_actor

  let restarted_pid = get_pid(restarted_actor)
  assert restarted_pid != pid
  assert process.is_alive(restarted_pid) == True
  assert get_state(restarted_actor) == 0
}

pub fn supervised_actor_restarts_after_abnormal_exit_test() {
  let registry = create_supervised_registry()

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "abnormal_exit_test", timeout, test_start_fn)

  let pid = get_pid(actor)
  assert process.is_alive(pid) == True

  process.send(actor, Incr)
  assert get_state(actor) == 1

  process.send(actor, Crash)
  process.sleep(100)

  let assert Ok(restarted_actor) =
    reki.lookup_or_start(registry, "abnormal_exit_test", timeout, test_start_fn)

  let restarted_pid = get_pid(restarted_actor)
  assert restarted_pid != pid
  assert process.is_alive(restarted_pid) == True
  assert get_state(restarted_actor) == 0
}

pub fn registry_continues_working_after_actor_restart_test() {
  let registry = create_supervised_registry()

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "continues_test", timeout, test_start_fn)

  let pid1 = get_pid(actor1)

  process.send(actor1, Incr)
  process.send(actor1, Incr)
  assert get_state(actor1) == 2

  process.kill(pid1)
  process.sleep(100)

  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "continues_test", timeout, test_start_fn)

  let pid2 = get_pid(actor2)
  assert pid2 != pid1
  assert process.is_alive(pid2) == True
  assert get_state(actor2) == 0

  process.send(actor2, Incr)
  assert get_state(actor2) == 1
}

pub fn registry_restarts_after_crash_when_supervised_test() {
  let registry = reki.new("registry_restart_test")
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(reki.supervised(registry))
    |> supervisor.start

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "test_key", timeout, test_start_fn)

  process.send(actor, Incr)
  assert get_state(actor) == 1

  let registry_name = reki.registry_name(registry)
  let assert Ok(registry_pid) = process.named(registry_name)
  process.kill(registry_pid)

  process.sleep(100)

  let assert Ok(new_actor) =
    reki.lookup_or_start(registry, "test_key", timeout, test_start_fn)

  assert get_state(new_actor) == 0
  process.send(new_actor, Incr)
  assert get_state(new_actor) == 1
}

pub fn registry_cleans_up_entry_when_actor_dies_test() {
  let registry = create_registry()

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "cleanup_test", timeout, test_start_fn)

  let pid1 = get_pid(actor1)
  process.send(actor1, Incr)
  assert get_state(actor1) == 1

  process.kill(pid1)
  process.sleep(100)

  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "cleanup_test", timeout, test_start_fn)

  let pid2 = get_pid(actor2)
  assert pid2 != pid1
  assert get_state(actor2) == 0
}

pub fn start_fn_failure_propagates_error_test() {
  let registry = create_registry()

  let failing_start_fn = fn() {
    actor.new_with_initialiser(100, fn(_) { Error("initialization failed") })
    |> actor.start
  }

  let assert Error(_) =
    reki.lookup_or_start(registry, "failing_key", timeout, failing_start_fn)
}

pub fn timeout_handling_test() {
  let registry = create_registry()

  let assert Ok(_) =
    reki.lookup_or_start(registry, "timeout_test", 1, test_start_fn)
}

pub fn registry_handles_multiple_failures_test() {
  let registry = create_registry()

  let failing_start_fn = fn() {
    actor.new_with_initialiser(100, fn(_) { Error("initialization failed") })
    |> actor.start
  }

  let assert Error(_) =
    reki.lookup_or_start(registry, "fail_key", timeout, failing_start_fn)

  let assert Error(_) =
    reki.lookup_or_start(registry, "fail_key", timeout, failing_start_fn)

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "fail_key", timeout, test_start_fn)

  assert get_state(actor) == 0
}

pub fn concurrent_lookups_with_different_keys_test() {
  let registry = create_registry()
  let results = process.new_subject()

  process.spawn(fn() {
    case reki.lookup_or_start(registry, "key1", timeout, test_start_fn) {
      Ok(actor) -> process.send(results, #("key1", Ok(actor)))
      Error(e) -> process.send(results, #("key1", Error(e)))
    }
  })

  process.spawn(fn() {
    case reki.lookup_or_start(registry, "key2", timeout, test_start_fn) {
      Ok(actor) -> process.send(results, #("key2", Ok(actor)))
      Error(e) -> process.send(results, #("key2", Error(e)))
    }
  })

  process.spawn(fn() {
    case reki.lookup_or_start(registry, "key3", timeout, test_start_fn) {
      Ok(actor) -> process.send(results, #("key3", Ok(actor)))
      Error(e) -> process.send(results, #("key3", Error(e)))
    }
  })

  let assert Ok(#("key1", Ok(actor1))) = process.receive(results, 100)
  let assert Ok(#("key2", Ok(actor2))) = process.receive(results, 100)
  let assert Ok(#("key3", Ok(actor3))) = process.receive(results, 100)

  assert actor1 != actor2
  assert actor2 != actor3
  assert actor1 != actor3
}
