# reki

A Gleam actor registry that manages actors by key, similar to Discord's `gen_registry` in Elixir. It provides a way to look up or start actors on demand, ensuring only one actor exists per key and automatically cleaning up dead processes.

```sh
gleam add reki
```

## Usage

```gleam
import reki
import gleam/otp/actor

pub type MyMessage {
  DoSomething
}

pub fn main() {
  let registry = reki.create()

  let assert Ok(my_actor) = reki.lookup_or_start(
    registry,
    "my_key",
    5000,
    fn() {
      actor.new(0)
      |> actor.on_message(fn(state, msg) { actor.continue(state) })
      |> actor.start
    }
  )

  // Use my_actor...
}
```

## How it works

The registry maintains a dictionary of actors keyed by strings. When you call `lookup_or_start`, it checks if an actor exists for that key. If it does, it returns the existing actor. If not, it starts a new one using your provided start function and registers it.

The registry monitors all registered actors and automatically removes them when they die, preventing memory leaks. Concurrent lookups are handled safely through the actor's message queue, ensuring only one actor is created per key even when multiple processes request the same key simultaneously.

This library provides a similar API and behavior to Discord's `gen_registry` for Elixir.
