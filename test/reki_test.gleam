import gleam/erlang/process
import gleam/erlang/reference
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/string
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

fn test_start_fn() {
  actor.new(0)
  |> actor.on_message(fn(state, message) {
    case message {
      Incr -> actor.continue(state + 1)
      Get(reply:) -> {
        process.send(reply, state)
        actor.continue(state)
      }
      Crash -> actor.stop_abnormal("crash")
    }
  })
  |> actor.start
}

fn create_registry(test_name: String) {
  let unique_ref = reference.new()
  let unique_name = test_name <> "_" <> string.inspect(unique_ref)
  let registry = reki.new_named(unique_name)
  let assert Ok(started) = reki.start(registry)
  started.data
}

pub fn lookup_or_start_test() {
  let registry = create_registry("lookup_or_start")

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)
  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  assert actor1 == actor2
}

pub fn different_keys_test() {
  let registry = create_registry("different_keys")

  let assert Ok(actor1) = reki.lookup_or_start(registry, "key1", test_start_fn)
  let assert Ok(actor2) = reki.lookup_or_start(registry, "key2", test_start_fn)

  assert actor1 != actor2
}

pub fn lookup_or_start_multiple_keys_test() {
  let registry = create_registry("lookup_or_start_multiple_keys")

  let assert Ok(actor1) = reki.lookup_or_start(registry, "key1", test_start_fn)
  let assert Ok(actor2) = reki.lookup_or_start(registry, "key2", test_start_fn)
  let assert Ok(actor3) = reki.lookup_or_start(registry, "key1", test_start_fn)

  assert actor1 == actor3
  assert actor1 != actor2
  assert actor2 != actor3
}

fn get_state(actor: process.Subject(TestMessage)) -> Int {
  actor.call(actor, timeout, fn(reply) { Get(reply:) })
}

pub fn state_operations_test() {
  let registry = create_registry("state_operations")

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "counter", test_start_fn)

  assert get_state(actor) == 0

  process.send(actor, Incr)
  process.send(actor, Incr)
  process.send(actor, Incr)

  assert get_state(actor) == 3
}

pub fn state_preserved_across_lookups_test() {
  let registry = create_registry("state_preserved_across_lookups")

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "counter", test_start_fn)

  process.send(actor1, Incr)
  process.send(actor1, Incr)

  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "counter", test_start_fn)

  assert actor1 == actor2
  assert get_state(actor2) == 2

  process.send(actor2, Incr)
  assert get_state(actor1) == 3
}

pub fn state_operations_in_order_test() {
  let registry = create_registry("state_operations_in_order")

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "counter", test_start_fn)

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
  let registry = create_registry("concurrent_lookups")
  let results = process.new_subject()

  let do = fn() {
    case reki.lookup_or_start(registry, "concurrent_key", test_start_fn) {
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
  let registry = create_registry("concurrent_state_operations")

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "concurrent_counter", test_start_fn)

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
  let unique_ref = reference.new()
  let unique_name = "readme_registry_" <> string.inspect(unique_ref)
  let registry = reki.new_named(unique_name)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(reki.supervised(registry))
    |> supervisor.start

  let assert Ok(counter) =
    reki.lookup_or_start(registry, "user_123", fn() {
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
    reki.lookup_or_start(registry, "user_123", fn() {
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

fn create_supervised_registry(
  test_name: String,
) -> reki.Registry(String, TestMessage) {
  let registry = reki.new_named(test_name)
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
  let registry =
    create_supervised_registry("supervised_actor_restarts_after_crash")

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "crash_test", test_start_fn)

  let pid = get_pid(actor)
  assert process.is_alive(pid)

  process.send(actor, Incr)
  process.send(actor, Incr)
  assert get_state(actor) == 2

  process.kill(pid)
  process.sleep(100)

  let assert Ok(restarted_actor) =
    reki.lookup_or_start(registry, "crash_test", test_start_fn)

  assert actor != restarted_actor

  let restarted_pid = get_pid(restarted_actor)
  assert restarted_pid != pid
  assert process.is_alive(restarted_pid)
  assert get_state(restarted_actor) == 0
}

pub fn supervised_actor_restarts_after_abnormal_exit_test() {
  let registry =
    create_supervised_registry("supervised_actor_restarts_after_abnormal_exit")

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "abnormal_exit_test", test_start_fn)

  let pid = get_pid(actor)
  assert process.is_alive(pid)
  process.send(actor, Incr)
  assert get_state(actor) == 1

  process.send(actor, Crash)
  process.sleep(100)

  let assert Ok(restarted_actor) =
    reki.lookup_or_start(registry, "abnormal_exit_test", test_start_fn)

  let restarted_pid = get_pid(restarted_actor)
  assert restarted_pid != pid
  assert process.is_alive(restarted_pid)
  assert get_state(restarted_actor) == 0
}

pub fn actor_crash_does_not_affect_other_actors_test() {
  let registry =
    create_supervised_registry("actor_crash_does_not_affect_other_actors")

  let assert Ok(actor_a) =
    reki.lookup_or_start(registry, "channel_a", test_start_fn)

  let assert Ok(actor_b) =
    reki.lookup_or_start(registry, "channel_b", test_start_fn)

  assert actor_a != actor_b

  // a
  process.send(actor_a, Incr)
  process.send(actor_a, Incr)
  // b
  process.send(actor_b, Incr)
  process.send(actor_b, Incr)
  process.send(actor_b, Incr)

  assert get_state(actor_a) == 2
  assert get_state(actor_b) == 3

  let pid_a = get_pid(actor_a)
  process.kill(pid_a)
  process.sleep(100)

  assert !process.is_alive(pid_a)

  let pid_b = get_pid(actor_b)
  assert process.is_alive(pid_b)
  assert get_state(actor_b) == 3

  let assert Ok(restarted_actor_a) =
    reki.lookup_or_start(registry, "channel_a", test_start_fn)

  let restarted_pid_a = get_pid(restarted_actor_a)
  assert restarted_pid_a != pid_a
  assert get_state(restarted_actor_a) == 0
  assert get_state(actor_b) == 3
}

pub fn registry_continues_working_after_actor_restart_test() {
  let registry =
    create_supervised_registry("registry_continues_working_after_actor_restart")

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "continues_test", test_start_fn)

  let pid1 = get_pid(actor1)

  process.send(actor1, Incr)
  process.send(actor1, Incr)
  assert get_state(actor1) == 2

  process.kill(pid1)
  process.sleep(100)

  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "continues_test", test_start_fn)

  let pid2 = get_pid(actor2)
  assert pid2 != pid1
  assert process.is_alive(pid2)
  assert get_state(actor2) == 0

  process.send(actor2, Incr)
  assert get_state(actor2) == 1
}

pub fn registry_restarts_after_crash_when_supervised_test() {
  let registry = reki.new_named("registry_restart_test")
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(reki.supervised(registry))
    |> supervisor.start

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  process.send(actor, Incr)
  assert get_state(actor) == 1

  let assert Ok(registry_pid) = reki.get_pid(registry)
  process.kill(registry_pid)

  process.sleep(100)

  let assert Ok(new_actor) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  assert get_state(new_actor) == 0
  process.send(new_actor, Incr)
  assert get_state(new_actor) == 1
}

pub fn registry_ets_table_cleared_on_restart_test() {
  let registry =
    create_supervised_registry("registry_ets_table_cleared_on_restart")

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  let pid1 = get_pid(actor1)
  process.send(actor1, Incr)
  process.send(actor1, Incr)
  process.send(actor1, Incr)
  assert get_state(actor1) == 3

  let assert Ok(registry_pid) = reki.get_pid(registry)
  process.kill(registry_pid)

  process.sleep(100)

  assert !process.is_alive(pid1)

  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  let pid2 = get_pid(actor2)

  assert pid2 != pid1
  assert get_state(actor2) == 0
}

pub fn registry_cleans_up_entry_when_actor_dies_test() {
  let registry = create_registry("registry_cleans_up_entry_when_actor_dies")

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "cleanup_test", test_start_fn)

  let pid1 = get_pid(actor1)
  process.send(actor1, Incr)
  assert get_state(actor1) == 1

  process.kill(pid1)
  process.sleep(100)

  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "cleanup_test", test_start_fn)

  let pid2 = get_pid(actor2)
  assert pid2 != pid1
  assert get_state(actor2) == 0
}

pub fn start_fn_failure_propagates_error_test() {
  let registry = create_registry("start_fn_failure_propagates_error")

  let failing_start_fn = fn() {
    actor.new_with_initialiser(100, fn(_) { Error("initialization failed") })
    |> actor.start
  }

  let assert Error(_) =
    reki.lookup_or_start(registry, "failing_key", failing_start_fn)
}

pub fn registry_handles_multiple_failures_test() {
  let registry = create_registry("registry_handles_multiple_failures")

  let failing_start_fn = fn() {
    actor.new_with_initialiser(100, fn(_) { Error("initialization failed") })
    |> actor.start
  }

  let assert Error(_) =
    reki.lookup_or_start(registry, "fail_key", failing_start_fn)

  let assert Error(_) =
    reki.lookup_or_start(registry, "fail_key", failing_start_fn)

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "fail_key", test_start_fn)

  assert get_state(actor) == 0
}

pub fn concurrent_lookups_with_different_keys_test() {
  let registry = create_registry("concurrent_lookups_with_different_keys")
  let results = process.new_subject()

  let do = fn(key: String) {
    use <- process.spawn
    case reki.lookup_or_start(registry, key, test_start_fn) {
      Ok(actor) -> process.send(results, #(key, Ok(actor)))
      Error(e) -> process.send(results, #(key, Error(e)))
    }
  }

  do("key1")
  do("key2")
  do("key3")

  let assert Ok(#("key1", Ok(actor1))) = process.receive(results, timeout)
  let assert Ok(#("key2", Ok(actor2))) = process.receive(results, timeout)
  let assert Ok(#("key3", Ok(actor3))) = process.receive(results, timeout)

  assert actor1 != actor2
  assert actor2 != actor3
  assert actor1 != actor3
}

pub fn actor_crashes_immediately_after_start_test() {
  let registry =
    create_supervised_registry("actor_crashes_immediately_after_start")

  let crash_immediately_fn = fn() {
    actor.new(0)
    |> actor.on_message(fn(state, message) {
      case message {
        Incr -> actor.continue(state + 1)
        Get(reply:) -> {
          process.send(reply, state)
          actor.continue(state)
        }
        Crash -> actor.stop_abnormal("crash")
      }
    })
    |> actor.start
    |> fn(result) {
      case result {
        Ok(actor.Started(pid:, data: subject)) -> {
          process.spawn(fn() {
            process.sleep(10)
            process.send(subject, Crash)
          })
          Ok(actor.Started(pid:, data: subject))
        }
        Error(e) -> Error(e)
      }
    }
  }

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "crash_test", crash_immediately_fn)

  process.sleep(200)

  let assert Ok(new_actor) =
    reki.lookup_or_start(registry, "crash_test", test_start_fn)

  assert actor != new_actor
  assert get_state(new_actor) == 0
}

pub fn concurrent_lookups_during_startup_test() {
  let registry = create_supervised_registry("concurrent_lookups_during_startup")

  let slow_start_fn = fn() {
    process.sleep(100)
    test_start_fn()
  }

  let results = process.new_subject()

  process.spawn(fn() {
    case reki.lookup_or_start(registry, "slow_key", slow_start_fn) {
      Ok(actor) -> process.send(results, Ok(actor))
      Error(e) -> process.send(results, Error(e))
    }
  })

  process.spawn(fn() {
    case reki.lookup_or_start(registry, "slow_key", slow_start_fn) {
      Ok(actor) -> process.send(results, Ok(actor))
      Error(e) -> process.send(results, Error(e))
    }
  })

  process.spawn(fn() {
    case reki.lookup_or_start(registry, "slow_key", slow_start_fn) {
      Ok(actor) -> process.send(results, Ok(actor))
      Error(e) -> process.send(results, Error(e))
    }
  })

  let assert Ok(actor1) = process.receive(results, 500)
  let assert Ok(actor2) = process.receive(results, 500)
  let assert Ok(actor3) = process.receive(results, 500)

  assert actor1 == actor2
  assert actor2 == actor3
}

pub fn many_keys_stress_test() {
  let registry = create_registry("many_keys_stress")
  let keys = [
    "key1", "key2", "key3", "key4", "key5", "key6", "key7", "key8", "key9",
    "key10",
  ]

  let actors =
    list.fold(keys, [], fn(accum, key) {
      case reki.lookup_or_start(registry, key, test_start_fn) {
        Ok(actor) -> [actor, ..accum]
        Error(_) -> accum
      }
    })

  assert list.length(actors) == 10

  let unique_actors = list.unique(actors)
  assert list.length(unique_actors) == 10
}

pub fn lookup_after_registry_restart_test() {
  let registry = create_supervised_registry("lookup_after_registry_restart")

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  process.send(actor1, Incr)
  process.send(actor1, Incr)
  assert get_state(actor1) == 2

  let assert Ok(registry_pid) = reki.get_pid(registry)
  process.kill(registry_pid)
  process.sleep(200)

  let _pid1 = get_pid(actor1)

  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  let _pid2 = get_pid(actor2)
  assert get_state(actor2) == 0
}

pub fn factory_supervisor_restart_test() {
  let registry = create_supervised_registry("factory_supervisor_restart")

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  process.send(actor1, Incr)
  assert get_state(actor1) == 1

  let assert Ok(registry_pid) = reki.get_pid(registry)
  process.kill(registry_pid)
  process.sleep(200)

  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  assert get_state(actor2) == 0
}

pub fn actor_exits_normally_test() {
  let registry = create_registry("actor_exits_normally")

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "normal_exit", test_start_fn)

  process.send(actor, Incr)
  assert get_state(actor) == 1

  let pid = get_pid(actor)
  process.kill(pid)
  process.sleep(100)

  let assert Ok(new_actor) =
    reki.lookup_or_start(registry, "normal_exit", test_start_fn)

  assert get_pid(actor) != get_pid(new_actor)
  assert get_state(new_actor) == 0
}

pub fn multiple_actors_crash_simultaneously_test() {
  let registry =
    create_supervised_registry("multiple_actors_crash_simultaneously")

  let assert Ok(actor1) = reki.lookup_or_start(registry, "key1", test_start_fn)
  let assert Ok(actor2) = reki.lookup_or_start(registry, "key2", test_start_fn)
  let assert Ok(actor3) = reki.lookup_or_start(registry, "key3", test_start_fn)

  process.send(actor1, Incr)
  process.send(actor2, Incr)
  process.send(actor3, Incr)

  assert get_state(actor1) == 1
  assert get_state(actor2) == 1
  assert get_state(actor3) == 1

  process.kill(get_pid(actor1))
  process.kill(get_pid(actor2))
  process.kill(get_pid(actor3))
  process.sleep(200)

  let assert Ok(new_actor1) =
    reki.lookup_or_start(registry, "key1", test_start_fn)
  let assert Ok(new_actor2) =
    reki.lookup_or_start(registry, "key2", test_start_fn)
  let assert Ok(new_actor3) =
    reki.lookup_or_start(registry, "key3", test_start_fn)

  assert get_state(new_actor1) == 0
  assert get_state(new_actor2) == 0
  assert get_state(new_actor3) == 0
}

pub fn process_down_message_idempotency_test() {
  let registry = create_registry("process_down_idempotency")

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  let pid = get_pid(actor)
  process.kill(pid)
  process.sleep(200)

  let assert Ok(new_actor) =
    reki.lookup_or_start(registry, "test_key", test_start_fn)

  assert get_state(new_actor) == 0
}

pub fn high_concurrency_stress_test() {
  let registry = create_registry("high_concurrency_stress")
  let results = process.new_subject()
  let num_requests = 50

  list.range(0, num_requests)
  |> list.each(fn(i) {
    process.spawn(fn() {
      case
        reki.lookup_or_start(
          registry,
          "stress_key" <> string.inspect(i),
          test_start_fn,
        )
      {
        Ok(actor) -> process.send(results, Ok(actor))
        Error(e) -> process.send(results, Error(e))
      }
    })
  })

  list.range(0, num_requests)
  |> list.each(fn(_) {
    let assert Ok(Ok(_)) = process.receive(results, 1000)
  })
}

pub fn same_key_high_concurrency_test() {
  let registry = create_registry("same_key_high_concurrency")
  let results = process.new_subject()
  let num_requests = 100

  list.range(0, num_requests)
  |> list.each(fn(_) {
    process.spawn(fn() {
      case reki.lookup_or_start(registry, "same_key", test_start_fn) {
        Ok(actor) -> process.send(results, Ok(actor))
        Error(e) -> process.send(results, Error(e))
      }
    })
  })

  let actors =
    list.fold(list.range(0, num_requests), [], fn(accum, _) {
      case process.receive(results, 1000) {
        Ok(Ok(actor)) -> [actor, ..accum]
        _ -> accum
      }
    })

  assert list.length(actors) >= num_requests

  let first_actor = list.first(actors)

  case first_actor {
    Ok(actor) -> {
      assert list.fold(actors, True, fn(acc, a) { acc && a == actor })
    }
    Error(_) -> {
      assert actors == []
    }
  }
}
