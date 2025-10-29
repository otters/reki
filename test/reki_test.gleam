import gleam/erlang/process
import gleam/otp/actor
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
    }
  })
  |> actor.start
}

pub fn lookup_or_start_test() {
  let registry = reki.create()

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "test_key", timeout, test_start_fn)
  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "test_key", timeout, test_start_fn)

  assert actor1 == actor2
}

pub fn different_keys_test() {
  let registry = reki.create()

  let assert Ok(actor1) =
    reki.lookup_or_start(registry, "key1", timeout, test_start_fn)
  let assert Ok(actor2) =
    reki.lookup_or_start(registry, "key2", timeout, test_start_fn)

  assert actor1 != actor2
}

pub fn lookup_or_start_multiple_keys_test() {
  let registry = reki.create()

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
  process.send(actor, Get(reply: reply))
  process.receive(reply, within: timeout) |> result.unwrap(0)
}

pub fn state_operations_test() {
  let registry = reki.create()

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "counter", timeout, test_start_fn)

  assert get_state(actor) == 0

  process.send(actor, Incr)
  process.send(actor, Incr)
  process.send(actor, Incr)

  assert get_state(actor) == 3
}

pub fn state_preserved_across_lookups_test() {
  let registry = reki.create()

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
  let registry = reki.create()

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
  let registry = reki.create()
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

  let assert Ok(actor1) = process.receive(results, within: 100)
  let assert Ok(actor2) = process.receive(results, within: 100)
  let assert Ok(actor3) = process.receive(results, within: 100)

  assert actor1 == actor2
  assert actor2 == actor3
}

pub fn concurrent_state_operations_test() {
  let registry = reki.create()

  let assert Ok(actor) =
    reki.lookup_or_start(registry, "concurrent_counter", timeout, test_start_fn)

  let results = process.new_subject()

  process.spawn(fn() {
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(results, Ok(Nil))
  })

  process.spawn(fn() {
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(results, Ok(Nil))
  })

  process.spawn(fn() {
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(actor, Incr)
    process.send(results, Ok(Nil))
  })

  let assert Ok(Ok(Nil)) = process.receive(results, within: 100)
  let assert Ok(Ok(Nil)) = process.receive(results, within: 100)
  let assert Ok(Ok(Nil)) = process.receive(results, within: 100)

  let final_state = get_state(actor)
  assert final_state == 9
}
