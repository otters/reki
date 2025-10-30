# reki

A Gleam actor registry that manages actors by key, similar to Discord's `gen_registry` in Elixir. It provides a way to look up or start actors on demand, ensuring only one actor exists per key and automatically cleaning up dead processes.

## Installation

Add to your `gleam.toml` as a git dependency:

```toml
[dependencies]
reki = { git = "git@github.com:otters/reki.git", ref = "<commit hash>" }
```

## Usage

```gleam
import reki
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
import gleam/result

pub type CounterMessage {
  Increment
  Get(reply: process.Subject(Int))
}

pub fn main() {
  // Create registry at program start (before supervision tree)
  let registry = reki.new("my_registry")

   let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(reki.supervised(registry))
    |> supervisor.start

   let assert Ok(counter) = reki.lookup_or_start(
    registry,
    "user_123",
    fn() {
      actor.new(0)
      |> actor.on_message(fn(state, msg) {
        case msg {
          Increment -> state + 1 |> actor.continue
          Get(reply:) -> {
            process.send(reply, state)
            actor.continue(state)
          }
        }
      })
      |> actor.start
    }
  )

  // Use the actor - send messages and receive replies
  process.send(counter, Increment)
  process.send(counter, Increment)

  let reply = process.new_subject()
  process.send(counter, Get(reply:))
  let assert Ok(2) = process.receive(reply, 1000)

  // Look up the same actor again - returns the same counter
  let assert Ok(same_counter) = reki.lookup_or_start(
    registry,
    "user_123",
    fn() {
      actor.new(0)
      |> actor.on_message(fn(state, msg) {
        case msg {
          Increment -> state + 1 |> actor.continue
          Get(reply:) -> {
            process.send(reply, state)
            actor.continue(state)
          }
        }
      })
      |> actor.start
    }
  )

  assert same_counter == counter
}
```

## How it works

The registry maintains a dictionary of actors keyed by whatever key you want to use. When you call `lookup_or_start`, it checks if an actor exists for that key. If it does, it returns the existing actor synchronously via ETS (no timeout needed). If not, it starts a new one using your provided start function under a factory supervisor and registers it.

All dynamically started actors are supervised by a factory supervisor, ensuring they are properly managed and restarted if they crash abnormally. The registry monitors all registered actors and automatically removes them when they die, preventing memory leaks. Concurrent lookups are handled safely through the actor's message queue, ensuring only one actor is created per key even when multiple processes request the same key simultaneously.
